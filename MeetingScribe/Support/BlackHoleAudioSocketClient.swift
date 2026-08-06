import AppKit
import Darwin
import Foundation

enum BlackHoleAudioProtocol {
    static let stopCommand: UInt8 = 0x53 // ASCII "S"

    static func sendStop(to socket: Int32) -> Bool {
        var command = stopCommand
        return Darwin.send(socket, &command, 1, 0) == 1
    }

    static func waitForStop(on socket: Int32) -> Bool {
        var command: UInt8 = 0
        while true {
            let count = Darwin.recv(socket, &command, 1, 0)
            if count <= 0 { return false }
            if command == stopCommand { return true }
        }
    }
}

final class BlackHoleAudioSocketClient: @unchecked Sendable {
    static var resolvedHelperURL: URL? {
        let installed = URL(fileURLWithPath: "/Applications/MeetingScribeAudioHelper.app")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        let bundled = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/MeetingScribeAudioHelper.app")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    static let audioPrivacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    var pcmStream: AsyncStream<Data> { stream }
    let sourceDescription = "BlackHole 2ch · 独立音频进程 · Unix Socket · 24,000 Hz · mono"
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let outputURL: URL
    private let socketPath: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopRequested = false
    private var readTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var helperApplication: NSRunningApplication?

    init(outputURL: URL) {
        self.outputURL = outputURL
        var continuation: AsyncStream<Data>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        socketPath = "/tmp/meetingscribe-audio-\(UUID().uuidString).sock"
    }

    func start() async throws {
        helperApplication = try await launchAudioHelper()
        let connected: Int32
        do {
            connected = try await Task.detached { [socketPath] in
                try Self.connectWithRetry(path: socketPath)
            }.value
            try await Task.detached {
                try Self.waitForPermissionHandshake(on: connected)
            }.value
        } catch {
            helperApplication?.terminate()
            helperApplication = nil
            throw error
        }
        lock.withLock {
            fd = connected
            stopRequested = false
        }
        readTask = Task.detached { [weak self] in self?.readLoop(connected) }
    }

    func stop() {
        let socket = lock.withLock { () -> Int32 in
            guard fd >= 0, !stopRequested else { return -1 }
            stopRequested = true
            return fd
        }
        if socket >= 0 {
            if !BlackHoleAudioProtocol.sendStop(to: socket) {
                forceClose(socket)
                return
            }
            // EOF is the completion acknowledgement: the Helper only closes
            // after capture.stop() has finalized the WAV header. Keep a bounded
            // fallback so a crashed/stuck Helper cannot hang the UI forever.
            stopTimeoutTask?.cancel()
            stopTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.forceClose(socket)
            }
        }
    }

    func copyWAV(to destination: URL) {
        guard FileManager.default.fileExists(atPath: outputURL.path), outputURL != destination else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: outputURL, to: destination)
    }

    private func launchAudioHelper() async throws -> NSRunningApplication {
        guard let helper = Self.resolvedHelperURL else {
            throw Failure.executableNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--blackhole-audio-server", socketPath, outputURL.path]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: Failure.executableNotFound)
                }
            }
        }
    }

    private func readLoop(_ socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var trailingByte: UInt8?
        while !Task.isCancelled {
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            var bytes = Data(buffer[0..<count])
            if let pending = trailingByte {
                var aligned = Data([pending])
                aligned.append(bytes)
                bytes = aligned
                trailingByte = nil
            }
            if bytes.count.isMultiple(of: 2) {
                continuation.yield(bytes)
            } else {
                trailingByte = bytes.removeLast()
                if !bytes.isEmpty { continuation.yield(bytes) }
            }
        }
        stopTimeoutTask?.cancel()
        closeSocketIfCurrent(socket)
        continuation.finish()
        helperApplication = nil
    }

    private func forceClose(_ socket: Int32) {
        Darwin.shutdown(socket, SHUT_RDWR)
        closeSocketIfCurrent(socket)
        readTask?.cancel()
        continuation.finish()
        helperApplication?.terminate()
        helperApplication = nil
    }

    private func closeSocketIfCurrent(_ socket: Int32) {
        let shouldClose = lock.withLock { () -> Bool in
            guard fd == socket else { return false }
            fd = -1
            stopRequested = false
            return true
        }
        if shouldClose { Darwin.close(socket) }
    }

    private static func connectWithRetry(path: String) throws -> Int32 {
        for _ in 0..<100 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                var address = makeAddress(path)
                let status = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if status == 0 {
                    var noSignal: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                               socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                Darwin.close(fd)
            }
            usleep(50_000)
        }
        throw Failure.connectionTimeout
    }

    private static func waitForPermissionHandshake(on fd: Int32) throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, 120_000) > 0 else {
            Darwin.close(fd)
            throw Failure.permissionTimeout
        }
        var status: UInt8 = 0
        guard Darwin.recv(fd, &status, 1, 0) == 1 else {
            Darwin.close(fd)
            throw Failure.connectionClosed
        }
        guard status == 1 else {
            Darwin.close(fd)
            throw Failure.permissionDenied
        }
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: Array(path.utf8) + [0]) }
        return address
    }

    enum Failure: LocalizedError {
        case connectionTimeout
        case connectionClosed
        case executableNotFound
        case permissionDenied
        case permissionTimeout
        var errorDescription: String? {
            switch self {
            case .connectionTimeout: return "连接本地音频采集进程超时。"
            case .connectionClosed: return "本地音频采集进程在启动时退出。"
            case .executableNotFound: return "找不到 MeetingScribe 音频采集进程。"
            case .permissionDenied: return "没有麦克风/虚拟音频输入权限。请在系统设置中允许 MeetingScribe Audio Helper，然后重新启动实时字幕。"
            case .permissionTimeout: return "等待 MeetingScribe Audio Helper 音频权限超时。"
            }
        }

        var needsPermissionHelp: Bool {
            switch self {
            case .permissionDenied, .permissionTimeout: true
            case .connectionTimeout, .connectionClosed, .executableNotFound: false
            }
        }
    }
}
