import AppKit
import Foundation
import SwiftUI

@MainActor
final class CompanionState: ObservableObject {
    enum Mode: String {
        case offline
        case idle
        case listening
        case muted
        case thinking
        case speaking
        case toolUse
        case error
    }

    @Published private(set) var mode: Mode = .offline
    @Published private(set) var connected = false
    @Published private(set) var callActive = false
    @Published private(set) var muted = false
    @Published private(set) var statusText = "offline"

    /// Normalized RMS (0...1) of the model's voice output, updated as PCM
    /// chunks are scheduled for playback; drives the speaking pulse. Plain
    /// var (not @Published) — the pet's TimelineView samples it every frame,
    /// so per-chunk updates need not invalidate the SwiftUI tree.
    private(set) var audioLevel: Float = 0

    /// Whether the pet window is on-screen (not occluded, minimized, or on
    /// another Space). Drives pausing the animation timeline when hidden.
    @Published private(set) var windowVisible = true

    /// True while the pet is actually playing voice audio. Set when a delta
    /// arrives, cleared when playback drains. The daemon flips `mode` back to
    /// listening as soon as the model stops *generating*, but the buffered
    /// audio keeps playing for seconds after — this tracks that real tail so
    /// the pet keeps its speaking look until the voice actually stops.
    @Published private(set) var audioActive = false

    private let socket = RealtimeSocketClient()
    private let audio = AudioController()
    private let socketPath: String
    private var captureStarted = false

    init(socketPath: String = CompanionState.defaultSocketPath()) {
        self.socketPath = socketPath
        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor in self?.handlePeerClose() }
        }
        audio.onOutputLevel = { [weak self] level in
            // AudioController dispatches to main; assume isolation to write
            // without a Task hop. Exponential smoothing turns chunk-quantized
            // RMS into a smooth swell so the speaking pulse doesn't jitter.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioLevel = 0.65 * self.audioLevel + 0.35 * level
            }
        }
        audio.onPlaybackDrained = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.audio.isPlayingBack {
                    self.audioActive = false
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    func shutdown() {
        if connected && callActive {
            try? socket.send(["type": "call_stop"])
        }

        callActive = false
        muted = false
        captureStarted = false
        shutdownAudio()
        socket.close()
        connected = false
    }

    func quitApplication() {
        shutdown()
        NSApp.terminate(nil)
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
    }

    nonisolated private static func defaultSocketPath() -> String {
        let environment = ProcessInfo.processInfo.environment

        if let socket = environment["FERMIX_REALTIME_SOCKET"], !socket.isEmpty {
            return (socket as NSString).expandingTildeInPath
        }

        if let home = environment["FERMIX_HOME"], !home.isEmpty {
            let expandedHome = (home as NSString).expandingTildeInPath
            return (expandedHome as NSString).appendingPathComponent("realtime.sock")
        }

        return ("~/.fermix/realtime.sock" as NSString).expandingTildeInPath
    }

    var tint: Color {
        switch mode {
        case .offline: return Color.gray
        case .idle: return Color.teal
        case .listening: return Color.green
        case .muted: return Color.red
        case .thinking: return Color.indigo
        case .speaking: return Color.orange
        case .toolUse: return Color.purple
        case .error: return Color.red
        }
    }

    var iconName: String {
        switch mode {
        case .offline: return "wifi.slash"
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .muted: return "mic.slash.fill"
        case .thinking: return "sparkles"
        case .speaking: return "waveform"
        case .toolUse: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Mode for presentation only. While voice audio is still playing out, the
    /// pet reads as speaking even though `mode` (server turn state) has already
    /// returned to listening/idle. `mode` itself — and all mic/turn logic keyed
    /// off it — is deliberately left untouched.
    var visualMode: Mode {
        (callActive && audioActive) ? .speaking : mode
    }

    var petExpression: PetExpression {
        PetExpression.resolve(for: visualMode, callActive: callActive)
    }

    func toggleConnection() {
        connected ? disconnect() : connect()
    }

    func connect() {
        do {
            try socket.connect(path: socketPath)
            connected = true
            mode = .idle
            statusText = "idle"
            try socket.send(["type": "client_hello", "protocol_version": 1])
            debugLog("connected realtime socket: \(socketPath)")
        } catch {
            connected = false
            callActive = false
            mode = .error
            statusText = "offline"
            debugLog("realtime socket connect failed: \(String(describing: error)); path=\(socketPath)")
        }
    }

    func disconnect() {
        endCall()
        socket.close()
        connected = false
        mode = .offline
        statusText = "offline"
    }

    func toggleCall() {
        if callActive {
            endCall()
        } else {
            startCall()
        }
    }

    func startCall() {
        if callActive {
            return
        }

        if !connected {
            connect()
        }

        guard connected else {
            statusText = "demo (daemon offline)"
            return
        }

        callActive = true
        muted = false
        captureStarted = false
        // Don't unmute here — `beginStreaming(onChunk:)` (called by
        // `startCaptureIfNeeded()` when the server confirms listening
        // state) is what unmutes and attaches the chunk handler. Keeping
        // the path muted until then guarantees no audio reaches the
        // socket between callActive=true and the server's go-ahead.
        mode = .idle
        statusText = "checking mic"

        Task { @MainActor in
            await beginCall()
        }
    }

    private func beginCall() async {
        do {
            try await audio.requestCapturePermission()
            guard callActive else { return }

            try socket.send(["type": "call_start"])
            statusText = "starting"
        } catch {
            mode = .error
            callActive = false
            captureStarted = false
            if connected {
                try? socket.send(["type": "call_stop"])
            }
            statusText = captureErrorMessage(error)
            debugLog(
                "microphone capture failed: \(statusText); error=\(String(describing: error)); diagnostics=\(audio.diagnostics())"
            )
        }
    }

    func endCall() {
        // Tear capture down fully so macOS clears the microphone privacy
        // indicator as soon as the local call ends.
        shutdownAudio()
        captureStarted = false
        if connected {
            try? socket.send(["type": "call_stop"])
        }
        callActive = false
        muted = false
        if connected {
            mode = .idle
            statusText = "idle"
        } else {
            mode = .offline
            statusText = "offline"
        }
    }

    func playTestTone() {
        audio.playTestTone()
    }

    func playSystemBeep() {
        NSSound.beep()
    }

    func toggleMute() {
        setMuted(!muted)
    }

    private func setMuted(_ enabled: Bool) {
        muted = enabled
        audio.setCaptureMuted(enabled)

        if connected && callActive {
            try? socket.send(["type": "mute", "enabled": enabled])
        }

        if callActive {
            mode = enabled ? .muted : .listening
            statusText = enabled ? "muted" : "listening"
        }
    }

    func interrupt() {
        sendInterruptForCurrentPlayback()
        mode = connected && callActive ? activeInputMode : (connected ? .idle : .offline)
        statusText = mode.rawValue
    }

    private func handle(event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "state":
            let next = event["state"] as? String ?? "idle"
            let previous = mode

            if next == "muted" {
                muted = true
                audio.setCaptureMuted(true)
            } else if next == "idle" {
                muted = false
                audio.setCaptureMuted(false)
            }

            mode = muted && next == "listening" ? .muted : (Mode(rawValue: next) ?? .idle)
            statusText = mode.rawValue

            if next == "listening" {
                startCaptureIfNeeded()
            }

            if previous == .speaking && mode != .speaking {
                audio.resetUtteranceAnchor()
            }

            // The visual "speaking" tail is owned by real playback; once the
            // server has moved on and no audio remains, drop it.
            if !audio.isPlayingBack {
                audioActive = false
            }
        case "audio_delta":
            if let encoded = event["audio"] as? String {
                mode = .speaking
                statusText = "speaking"
                audioActive = true
                audio.play(base64PCM16: encoded)
            }
        case "playback_stop":
            audio.stopPlayback()
            audio.resetUtteranceAnchor()
            audioActive = false
            if callActive {
                mode = activeInputMode
                statusText = mode.rawValue
            }
        case "tool_event":
            switch event["status"] as? String {
            case "completed":
                if callActive {
                    mode = .toolUse
                    statusText = "tool"
                } else {
                    mode = .idle
                    statusText = "idle"
                }
            case "error":
                mode = .error
                statusText = event["reason"] as? String ?? "tool error"
            default:
                mode = .toolUse
                statusText = "tool"
            }
        case "error":
            mode = .error
            statusText = event["reason"] as? String ?? "error"
            // Server signalled an error — detach handler so no in-flight
            // mic buffer races back to the possibly-broken socket.
            shutdownAudio()
            callActive = false
            muted = false
            captureStarted = false
        default:
            break
        }
    }

    private func startCaptureIfNeeded() {
        guard callActive && !captureStarted else { return }

        do {
            // Attaches the chunk handler, starts capture if needed, and
            // unmutes only after the server confirms listening state.
            try audio.beginStreaming { [weak self] chunk in
                self?.socket.sendAudioChunk(chunk)
            }
            captureStarted = true
            statusText = activeInputMode.rawValue
        } catch {
            mode = .error
            callActive = false
            captureStarted = false
            if connected {
                try? socket.send(["type": "call_stop"])
            }
            statusText = captureErrorMessage(error)
            debugLog(
                "microphone capture failed: \(statusText); error=\(String(describing: error)); diagnostics=\(audio.diagnostics())"
            )
        }
    }

    private func sendInterruptForCurrentPlayback() {
        let playedMs = audio.currentUtterancePlayedMs()
        audio.stopPlayback()
        audioActive = false

        if connected {
            var payload: [String: Any] = ["type": "interrupt"]
            if let ms = playedMs {
                payload["audio_end_ms"] = ms
            }
            try? socket.send(payload)
        }
    }

    private var activeInputMode: Mode {
        muted ? .muted : .listening
    }

    private func handlePeerClose() {
        // Daemon socket dropped from the other end. Tear the mic all the
        // way down — there's nothing to stream to.
        shutdownAudio()
        callActive = false
        muted = false
        captureStarted = false
        connected = false

        if mode != .error {
            mode = .offline
            statusText = "offline"
        }
    }

    private func captureErrorMessage(_ error: Error) -> String {
        if let error = error as? AudioController.CaptureError {
            return error.localizedDescription
        }

        return "mic unavailable"
    }

    private func debugLog(_ message: String) {
        NSLog("FermixPet: %@", message)
    }

    private func shutdownAudio() {
        audio.shutdown()
        audioLevel = 0
        audioActive = false
    }
}
