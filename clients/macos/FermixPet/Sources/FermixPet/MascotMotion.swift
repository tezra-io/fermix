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
}
