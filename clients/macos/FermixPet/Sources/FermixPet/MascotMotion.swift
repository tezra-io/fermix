import Foundation

/// Per-axis idle motion parameters keyed off the agent's current mode.
///
/// Each axis (breath/scale, vertical bob, sway/rotation) has its own
/// amplitude and period so the resulting sine curves never line up. That
/// desynchronisation is what reads as "alive" rather than "looped."
enum MascotMotion {
    // MARK: Scale (breathing)

    static func breathAmp(_ mode: CompanionState.Mode) -> Double {
        switch mode {
        case .listening, .muted: return 0.025
        case .speaking: return 0.020
        case .thinking, .error: return 0.012
        case .offline: return 0.005
        case .idle, .toolUse: return 0.012
        }
    }

    static func breathPeriod(_ mode: CompanionState.Mode) -> Double {
        switch mode {
        case .listening, .muted: return 2.0
        case .speaking: return 1.6
        case .thinking: return 2.2
        case .offline: return 4.0
        case .idle, .toolUse, .error: return 2.4
        }
    }

    // MARK: Vertical bob

    static func bobAmp(_ mode: CompanionState.Mode) -> Double {
        switch mode {
        case .offline: return 0
        case .speaking: return 3.0
        case .thinking, .error: return 1.5
        case .idle, .listening, .muted, .toolUse: return 2.0
        }
    }

    static func bobPeriod(_ mode: CompanionState.Mode) -> Double {
        switch mode {
        case .speaking: return 1.8
        case .thinking: return 2.8
        case .offline, .idle, .listening, .muted, .toolUse, .error: return 3.1
        }
    }

    // MARK: Sway (rotation)

    static func swayAmp(_ mode: CompanionState.Mode) -> Double {
        switch mode {
        case .thinking: return 1.4
        case .error: return 1.6
        case .offline, .idle, .listening, .muted, .speaking, .toolUse: return 0
        }
    }

    // MARK: Blink

    /// Opacity of the closed-eye (idle) face cross-faded over the open-eye
    /// listening/thinking faces to fake an eyelid blink. Deterministic and
    /// stateless: a jittered ~4.6s cadence with a fast close, brief hold, and
    /// slightly slower open, so it reads as a natural blink, not a flicker.
    /// Returns 0 outside the blink window.
    static func blinkOpacity(at t: TimeInterval) -> Double {
        let period = 2.8
        let closeDur = 0.06
        let holdDur = 0.05
        let openDur = 0.10
        let span = closeDur + holdDur + openDur

        let bucket = (t / period).rounded(.down)
        let jitter = fract(sin(bucket * 12.9898) * 43_758.5453)
        let start = bucket * period + jitter * (period - span)
        let age = t - start

        if age < 0 || age >= span { return 0 }
        if age < closeDur { return smoothstep(age / closeDur) }
        if age < closeDur + holdDur { return 1 }
        return 1 - smoothstep((age - closeDur - holdDur) / openDur)
    }

    private static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    private static func fract(_ x: Double) -> Double {
        x - x.rounded(.down)
    }
}
