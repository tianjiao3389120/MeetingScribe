@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Audio-device POC for systems where ScreenCaptureKit permission is not usable.
/// Select BlackHole (or another virtual input) as the macOS input device first.
final class BlackHoleAudioCaptureService: @unchecked Sendable {
    private static let targetSampleRate = 24_000
    let deviceName: String
    private(set) var sourceDescription = "未启动"
    var logHandler: ((String) -> Void)?
    /// 24 kHz mono PCM16 chunks, emitted as they arrive from the audio tap.
    var pcmStream: AsyncStream<Data> { pcmStreamStorage }
    var currentPeak: Float {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private let engine = AVAudioEngine()
    private let writer: BlackHoleWAVWriter
    private let pcmStreamStorage: AsyncStream<Data>
    private let pcmContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sourceFormat: AVAudioFormat?
    private var sourceFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var peak: Float = 0
    private var startedAt: Date?

    static func inputDeviceAvailable(named name: String = "BlackHole 2ch") -> Bool {
        AudioDevice.findInput(named: name) != nil
    }

    init(outputURL: URL, deviceName: String = "BlackHole 2ch") throws {
        self.deviceName = deviceName
        let streamPair = Self.makePCMStream()
        pcmStreamStorage = streamPair.stream
        pcmContinuation = streamPair.continuation
        writer = try BlackHoleWAVWriter(url: outputURL,
                                        sampleRate: Self.targetSampleRate,
                                        channels: 1)
    }

    func start() throws {
        engine.reset()
        let input = engine.inputNode
        guard let device = AudioDevice.findInput(named: deviceName) else {
            throw Failure.deviceNotFound(deviceName)
        }
        guard let audioUnit = input.audioUnit else {
            throw Failure.deviceSelectionFailed("无法访问 AVAudioEngine 输入 AudioUnit")
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw Failure.deviceSelectionFailed("AudioUnit 错误码 \(status)")
        }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw Failure.noInputDevice
        }
        sourceFormat = format
        sourceDescription = "\(device.name) (id \(device.id)) · \(Int(format.sampleRate)) Hz · \(format.channelCount) ch"
        lock.lock()
        peak = 0
        lock.unlock()

        log("BlackHole/音频设备采集已启动")
        log("输入设备：\(device.name) (id \(device.id))")
        log(String(format: "源格式：%.0f Hz / %d ch / commonFormat=%d",
                   format.sampleRate, format.channelCount, Int(format.commonFormat.rawValue)))
        log("目标格式：24,000 Hz / mono / signed 16-bit little-endian PCM")
        log("输出文件：\(writer.url.path)")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        do {
            try engine.start()
            startedAt = Date()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineStart(error.localizedDescription)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        let sourceFrames = self.sourceFrames
        let outputFrames = self.outputFrames
        lock.unlock()
        writer.finish()
        pcmContinuation.finish()

        log("采集已停止")
        log("源音频帧：\(sourceFrames)")
        log("输出音频帧：\(outputFrames)")
        log("输出帧大小：2 bytes/frame")
        log("输出 PCM：\(outputFrames * 2) bytes")
        log(String(format: "音频峰值：%.1f%%", currentPeak * 100))
        log(String(format: "实时吞吐：%.2fx",
                   elapsed > 0 ? Double(outputFrames) / Double(Self.targetSampleRate) / elapsed : 0))
    }

    private func log(_ message: String) {
        if let logHandler { logHandler(message) } else { print(message) }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let data = pcm16MonoData(from: buffer) else { return }
        writer.append(data)
        pcmContinuation.yield(data)
        lock.lock()
        let chunkPeak = peakValue(in: buffer)
        // Keep the highest observed level for this capture session so the UI
        // cannot miss a short spoken test between 21 ms callbacks.
        peak = max(peak, chunkPeak)
        sourceFrames += Int64(buffer.frameLength)
        outputFrames += Int64(data.count / 2)
        lock.unlock()
    }

    private static func makePCMStream() ->
        (stream: AsyncStream<Data>, continuation: AsyncStream<Data>.Continuation) {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        return (stream, continuation)
    }

    private func pcm16MonoData(from buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frameCount > 0, channels > 0, sampleRate > 0 else { return nil }
        let outputCount = max(1, Int((Double(frameCount) * Double(Self.targetSampleRate) / sampleRate).rounded()))
        var output = Data(capacity: outputCount * 2)

        for index in 0..<outputCount {
            let position = min(Double(frameCount - 1),
                               Double(index) * sampleRate / Double(Self.targetSampleRate))
            let first = Int(position.rounded(.down))
            let second = min(frameCount - 1, first + 1)
            let fraction = Float(position - Double(first))
            var mixed: Float = 0
            for channel in 0..<channels {
                mixed += sample(buffer, frame: first, channel: channel) * (1 - fraction)
                mixed += sample(buffer, frame: second, channel: channel) * fraction
            }
            let value = Int16(max(-1, min(1, mixed / Float(channels))) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: value) { output.append(contentsOf: $0) }
        }
        return output
    }

    private func sample(_ buffer: AVAudioPCMBuffer, frame: Int, channel: Int) -> Float {
        if let channels = buffer.floatChannelData {
            return channels[channel][frame]
        }
        if let channels = buffer.int16ChannelData {
            return Float(channels[channel][frame]) / Float(Int16.max)
        }
        return 0
    }

    private func peakValue(in buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }
        var result: Float = 0
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                result = max(result, abs(sample(buffer, frame: frame, channel: channel)))
            }
        }
        return min(result, 1)
    }

    enum Failure: LocalizedError {
        case noInputDevice
        case deviceNotFound(String)
        case deviceSelectionFailed(String)
        case engineStart(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "没有可用的音频输入设备，请把 BlackHole 设为 macOS 输入设备。"
            case .deviceNotFound(let name): return "找不到音频输入设备：\(name)"
            case .deviceSelectionFailed(let detail): return "选择音频输入设备失败：\(detail)"
            case .engineStart(let detail): return "音频引擎启动失败：\(detail)"
            }
        }
    }
}

private struct AudioDevice {
    let id: AudioDeviceID
    let name: String

    static func findInput(named requestedName: String) -> AudioDevice? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &devicesAddress, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &devicesAddress, 0, nil, &size, &devices) == noErr else { return nil }

        return devices.compactMap { deviceID in
            guard let name = name(of: deviceID), hasInput(deviceID) else { return nil }
            guard name.caseInsensitiveCompare(requestedName) == .orderedSame else { return nil }
            return AudioDevice(id: deviceID, name: name)
        }.first
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

private final class BlackHoleWAVWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var dataBytes: UInt32 = 0

    init(url: URL, sampleRate: Int, channels: Int) throws {
        self.url = url; self.sampleRate = sampleRate; self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0, count: 44))
    }

    func append(_ data: Data) {
        try? handle.write(contentsOf: data)
        dataBytes = min(UInt32.max - dataBytes, dataBytes + UInt32(data.count))
    }

    func finish() {
        let byteRate = UInt32(sampleRate * channels * 2)
        var header = Data("RIFF".utf8)
        header.appendLE(UInt32(36) + dataBytes)
        header.append(contentsOf: Data("WAVEfmt ".utf8))
        header.appendLE(UInt32(16)); header.appendLE(UInt16(1)); header.appendLE(UInt16(channels))
        header.appendLE(UInt32(sampleRate)); header.appendLE(byteRate); header.appendLE(UInt16(channels * 2))
        header.appendLE(UInt16(16)); header.append(contentsOf: Data("data".utf8)); header.appendLE(dataBytes)
        try? handle.seek(toOffset: 0); try? handle.write(contentsOf: header); try? handle.close()
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
