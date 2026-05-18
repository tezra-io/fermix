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

    /// Normalized RMS (0...1) of the model's voice output, updated as
    /// PCM chunks are scheduled for playback. Drives the speaking pulse.
    @Published private(set) var audioLevel: Float = 0

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
            // AudioController dispatches to main; assume isolation to
            // write the @Published value without a Task hop.
            MainActor.assumeIsolated {
                self?.audioLevel = level
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
        audio.shutdown()
        socket.close()
        connected = false
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

    var petExpression: PetExpression {
        PetExpression.resolve(for: mode, callActive: callActive)
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

            // Pre-warm the mic so first call start doesn't pay the
            // engine + tap setup cost (~couple of seconds on macOS).
            // Best-effort: skips silently if mic permission hasn't been
            // granted yet (we don't want connect to trigger the prompt).
            do {
                try audio.warmCapture()
                debugLog("audio capture pre-warmed")
            } catch {
                debugLog("warmCapture failed (will retry on call start): \(String(describing: error))")
            }
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
        // Full mic teardown on disconnect — the pet is going to "off",
        // so we release the audio session entirely (mic indicator clears).
        audio.stopCapture()
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
        // Detach the chunk handler and re-mute — no audio leaves the
        // process after this point. The tap and engine stay alive so the
        // *next* call doesn't repay the warm-up cost. Full teardown
        // happens in disconnect()/shutdown().
        audio.stopStreaming()
        audio.stopPlayback()
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
        case "audio_delta":
            if let encoded = event["audio"] as? String {
                mode = .speaking
                statusText = "speaking"
                audio.play(base64PCM16: encoded)
            }
        case "playback_stop":
            audio.stopPlayback()
            audio.resetUtteranceAnchor()
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
            // mic buffer races back to the (possibly-broken) socket. Keep
            // the engine warm so a recovery / reconnect doesn't pay
            // startup latency again.
            audio.stopStreaming()
            audio.stopPlayback()
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
            // Attaches the chunk handler and unmutes the pre-warmed tap.
            // If the mic wasn't pre-warmed at connect time (permission
            // not yet granted), beginStreaming sets it up now — falling
            // back to the slow path on first ever call.
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
        // way down — there's nothing to stream to and nothing to come
        // back to. A subsequent connect() will re-warm.
        audio.stopCapture()
        audio.stopPlayback()
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
}
