import AppKit
import AVFoundation
import Darwin
import Foundation

enum BlackHoleAudioSocketServer {
    /// Usage: --request-audio-permission
    static func requestPermissionOnly() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task {
            let granted = await requestAudioPermission()
            log(granted
                ? "MeetingScribe Audio Helper 已获得麦克风/虚拟音频输入权限。"
                : "MeetingScribe Audio Helper 未获得麦克风/虚拟音频输入权限。")
            exit(granted ? 0 : 3)
        }
        application.run()
    }

    /// Usage: --blackhole-audio-server [socket-path] [output.wav]
    static func run(arguments: ArraySlice<String>) {
        let values = Array(arguments.dropFirst())
        guard values.count >= 2 else { exit(2) }
        let socketPath = values[0]
        let outputURL = URL(fileURLWithPath: values[1])
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        DispatchQueue.global(qos: .userInitiated).async {
            startServer(socketPath: socketPath, outputURL: outputURL)
        }
        application.run()
    }

    private static func requestAudioPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private static func startServer(socketPath: String, outputURL: URL) {
        do {
            let listener = try UnixAudioSocket.listen(at: socketPath)
            defer { listener.close() }
            let client = try listener.acceptClient()
            Task {
                guard await requestAudioPermission() else {
                    _ = UnixAudioSocket.writeAll(Data([0]), to: client)
                    log("MeetingScribe Audio Helper 未获得麦克风/虚拟音频输入权限。")
                    Darwin.close(client)
                    exit(3)
                }
                guard UnixAudioSocket.writeAll(Data([1]), to: client) else {
                    Darwin.close(client)
                    exit(1)
                }
                do {
                    let capture = try BlackHoleAudioCaptureService(outputURL: outputURL)
                    capture.logHandler = { log($0) }
                    try capture.start()
                    let stopMonitor = Task.detached {
                        _ = BlackHoleAudioProtocol.waitForStop(on: client)
                        capture.stop()
                    }
                    for await chunk in capture.pcmStream {
                        guard UnixAudioSocket.writeAll(chunk, to: client) else {
                            Darwin.shutdown(client, SHUT_RDWR)
                            break
                        }
                    }
                    // `capture.stop()` finalizes the WAV before the stream ends.
                    // Closing the socket after this await is the client's
                    // completion acknowledgement that the file is safe to copy.
                    await stopMonitor.value
                    Darwin.close(client)
                    exit(0)
                } catch {
                    log("音频服务失败：\(error.localizedDescription)")
                    Darwin.close(client)
                    exit(1)
                }
            }
        } catch {
            log("Unix Socket 启动失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

}

private final class UnixAudioSocket {
    let fd: Int32
    let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    static func listen(at path: String) throws -> UnixAudioSocket {
        guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else { throw Failure.pathTooLong }
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system(errno) }
        var address = makeAddress(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno; Darwin.close(fd); unlink(path); throw Failure.system(code)
        }
        return UnixAudioSocket(fd: fd, path: path)
    }

    func acceptClient() throws -> Int32 {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { throw Failure.system(errno) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    func close() {
        Darwin.close(fd)
        unlink(path)
    }

    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            let value = Array(path.utf8) + [0]
            bytes.copyBytes(from: value)
        }
        return address
    }

    enum Failure: LocalizedError {
        case pathTooLong
        case system(Int32)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: return "Unix Socket 路径过长。"
            case .system(let code): return String(cString: strerror(code))
            }
        }
    }
}
