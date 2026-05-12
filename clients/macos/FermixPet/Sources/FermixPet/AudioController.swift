import AVFoundation
import Foundation

final class AudioController {
    private static let realtimeSampleRate = 24_000.0
    private static let captureBufferFrames: AVAudioFrameCount = 4_800

    enum CaptureError: LocalizedError {
        case microphoneDenied
        case microphoneRestricted
        case noInputDevice
        case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case outputFormatUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is denied"
            case .microphoneRestricted:
                return "Microphone access is restricted"
            case .noInputDevice:
                return "No microphone input device is available"
            case let .invalidInputFormat(sampleRate, channels):
                return "Invalid microphone format: sampleRate=\(sampleRate), channels=\(channels)"
            case .outputFormatUnavailable:
                return "Could not create Realtime audio output format"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private var captureTapInstalled = false
    private var utteranceAnchorSampleTime: AVAudioFramePosition?
    private let playbackCounterLock = NSLock()
    private var pendingPlaybackBuffers = 0

    var isPlayingBack: Bool {
        playbackCounterLock.lock()
        defer { playbackCounterLock.unlock() }
        return pendingPlaybackBuffers > 0
    }

    init() {
        self.playbackFormat = AVAudioFormat(standardFormatWithSampleRate: Self.realtimeSampleRate, channels: 1)!

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = 1.0
    }

    func requestCapturePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }

            if !granted {
                throw CaptureError.microphoneDenied
            }
        case .denied:
            throw CaptureError.microphoneDenied
        case .restricted:
            throw CaptureError.microphoneRestricted
        @unknown default:
            throw CaptureError.microphoneDenied
        }
    }

    func startCapture(onChunk: @escaping (Data) -> Void) throws {
        stopCapture()

        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw CaptureError.noInputDevice
        }

        let input = engine.inputNode
        var format = Self.usableInputFormat(from: input)

        if format.sampleRate <= 0 || format.channelCount == 0 {
            try startEngineIfNeeded()
            format = Self.usableInputFormat(from: input)
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidInputFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.realtimeSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.outputFormatUnavailable
        }

        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw CaptureError.outputFormatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: Self.captureBufferFrames, format: format) { buffer, _ in
            let data = Self.pcm16Data(from: buffer, converter: converter, outputFormat: outputFormat)
            if !data.isEmpty {
                onChunk(data)
            }
        }
        captureTapInstalled = true

        do {
            try startEngineIfNeeded()
        } catch {
            stopCapture()
            throw error
        }
    }

    func playTestTone(durationSeconds: Double = 1.0, frequency: Double = 440.0) {
        let pcm16 = Self.makeSineWavePCM16(
            sampleRate: Self.realtimeSampleRate,
            durationSeconds: durationSeconds,
            frequency: frequency
        )
        play(base64PCM16: pcm16.base64EncodedString())
    }

    static func makeSineWavePCM16(
        sampleRate: Double,
        durationSeconds: Double,
        frequency: Double,
        amplitude: Float = 0.3
    ) -> Data {
        let frameCount = Int(sampleRate * durationSeconds)
        var samples = [Int16]()
        samples.reserveCapacity(frameCount)

        let angularStep = 2.0 * Double.pi * frequency / sampleRate

        for index in 0..<frameCount {
            let sample = Float(sin(Double(index) * angularStep)) * amplitude
            samples.append(Int16(sample * Float(Int16.max)))
        }

        return samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    func stopCapture() {
        if captureTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            captureTapInstalled = false
        }
    }

    func shutdown() {
        stopCapture()
        stopPlayback()
        if engine.isRunning {
            engine.stop()
        }
    }

    func diagnostics() -> String {
        let auth = Self.authorizationDescription(AVCaptureDevice.authorizationStatus(for: .audio))
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        let input = engine.inputNode
        let inputFormat = Self.usableInputFormat(from: input)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        return "auth=\(auth), inputDevice=\(device), inputSampleRate=\(inputFormat.sampleRate), inputChannels=\(inputFormat.channelCount), outputSampleRate=\(outputFormat.sampleRate), outputChannels=\(outputFormat.channelCount), engineRunning=\(engine.isRunning)"
    }

    func play(base64PCM16 encoded: String) {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            NSLog("FermixPet: audio play skipped — empty/undecodable base64")
            return
        }

        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else {
            NSLog("FermixPet: audio play skipped — could not allocate float buffer (frames=%u)", frameCount)
            return
        }
        buffer.frameLength = frameCount

        Self.fillFloatBuffer(buffer, fromPCM16: data)

        if !engine.isRunning {
            do {
                try startEngineIfNeeded()
            } catch {
                NSLog("FermixPet: playback engine failed to start: %@", String(describing: error))
                return
            }
        }

        let wasPlaying = player.isPlaying

        playbackCounterLock.lock()
        pendingPlaybackBuffers += 1
        playbackCounterLock.unlock()

        player.scheduleBuffer(buffer, completionHandler: { [weak self] in
            guard let self else { return }
            self.playbackCounterLock.lock()
            self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
            self.playbackCounterLock.unlock()
        })

        if !wasPlaying {
            player.play()
            utteranceAnchorSampleTime = currentPlayerSampleTime() ?? 0
        }
    }

    private static func fillFloatBuffer(_ buffer: AVAudioPCMBuffer, fromPCM16 data: Data) {
        guard let dest = buffer.floatChannelData?[0] else { return }
        let scale: Float = 1.0 / Float(Int16.max)
        let sampleCount = Int(buffer.frameLength)

        data.withUnsafeBytes { raw in
            guard let int16Source = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<sampleCount {
                dest[index] = Float(int16Source[index]) * scale
            }
        }
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private static func usableInputFormat(from input: AVAudioInputNode) -> AVAudioFormat {
        let outputFormat = input.outputFormat(forBus: 0)
        if outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 {
            return outputFormat
        }

        return input.inputFormat(forBus: 0)
    }

    func stopPlayback() {
        player.stop()
        utteranceAnchorSampleTime = nil

        playbackCounterLock.lock()
        pendingPlaybackBuffers = 0
        playbackCounterLock.unlock()
    }

    func resetUtteranceAnchor() {
        utteranceAnchorSampleTime = nil
    }

    func currentUtterancePlayedMs() -> Int? {
        guard let anchor = utteranceAnchorSampleTime,
              let current = currentPlayerSampleTime() else {
            return nil
        }

        let frames = max(0, current - anchor)
        let ms = Double(frames) / Self.realtimeSampleRate * 1_000.0
        return Int(ms.rounded())
    }

    private func currentPlayerSampleTime() -> AVAudioFramePosition? {
        guard let lastRender = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: lastRender) else {
            return nil
        }

        return playerTime.sampleTime
    }

    private static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data {
        let sampleRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * sampleRatio) + 8))
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return Data()
        }

        var providedInput = false
        var conversionError: NSError?

        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            providedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else { return Data() }
        return pcm16Data(fromFloatBuffer: converted)
    }

    private static func pcm16Data(fromFloatBuffer buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }

        guard let floats = buffer.floatChannelData else { return Data() }
        var output = Data(capacity: frames * MemoryLayout<Int16>.size)

        for index in 0..<frames {
            let sample = max(-1.0, min(1.0, floats[0][index]))
            var pcm = Int16(sample * Float(Int16.max)).littleEndian
            output.append(Data(bytes: &pcm, count: MemoryLayout<Int16>.size))
        }

        return output
    }

    private static func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
}
