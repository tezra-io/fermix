import AppKit
import SwiftUI

struct PetView: View {
    @EnvironmentObject private var state: CompanionState
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                AnimatedMascot()
                    .frame(width: 116, height: 108)
                    .compositingGroup()
                    .shadow(color: glowColor, radius: 12, y: 6)
                    .animation(.easeInOut(duration: 0.7), value: state.mode)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.toggleCall()
                    }
                    .help(state.callActive ? "End voice call" : "Start voice call")
            }
            .frame(width: 132, height: 116)

            ControlDock(state: state)
                .opacity(shouldShowControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: shouldShowControls)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.16)) {
                hovered = inside
            }
        }
        .contextMenu {
            Button(state.connected ? "Disconnect" : "Connect") {
                state.toggleConnection()
            }

            Button(state.callActive ? "End Voice Call" : "Start Voice Call") {
                state.toggleCall()
            }

            if state.callActive {
                Button(state.muted ? "Unmute" : "Mute") {
                    state.toggleMute()
                }
            }

            Button("Interrupt") {
                state.interrupt()
            }

            Divider()

            Button("Play Test Tone (440Hz)") {
                state.playTestTone()
            }

            Button("Play System Beep (NSSound)") {
                state.playSystemBeep()
            }

            Divider()

            Button("Quit FermixPet") {
                state.quitApplication()
            }
        }
    }

    private var shouldShowControls: Bool {
        hovered || state.callActive || state.mode == .speaking
    }

    private var glowColor: Color {
        switch state.mode {
        case .listening:
            return Color.cyan.opacity(0.42)
        case .muted:
            return Color.red.opacity(0.22)
        case .speaking:
            return Color.blue.opacity(0.34)
        case .toolUse:
            return Color.indigo.opacity(0.34)
        case .error:
            return Color.blue.opacity(0.22)
        case .offline, .idle, .thinking:
            return Color.black.opacity(0.18)
        }
    }
}

/// Time-driven mascot: a single `TimelineView` drives sine motion on all
/// three axes (breath, bob, sway) plus an audio-RMS speaking pulse, and
/// wraps a `MascotCrossfade` so expression changes fade rather than swap.
private struct AnimatedMascot: View {
    @EnvironmentObject var state: CompanionState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MascotCrossfade(expression: state.petExpression)
                .scaleEffect(scale(at: t))
                .offset(y: offset(at: t))
                .rotationEffect(.degrees(rotation(at: t)))
        }
    }

    private func scale(at t: TimeInterval) -> CGFloat {
        let mode = state.mode
        let breath = MascotMotion.breathAmp(mode)
            * sin(2 * .pi * t / MascotMotion.breathPeriod(mode))
        let speakingPulse = mode == .speaking
            ? Double(0.06 * state.audioLevel)
            : 0
        return CGFloat(1 + breath + speakingPulse)
    }

    private func offset(at t: TimeInterval) -> CGFloat {
        let mode = state.mode
        let amp = MascotMotion.bobAmp(mode)
        let period = MascotMotion.bobPeriod(mode)
        return CGFloat(-amp * sin(2 * .pi * t / period))
    }

    private func rotation(at t: TimeInterval) -> Double {
        MascotMotion.swayAmp(state.mode) * sin(2 * .pi * t / 4.2)
    }
}

/// Cross-fades the four mascot expressions with a brief scale pop instead
/// of hard-swapping the PNG stack on mode change.
private struct MascotCrossfade: View {
    let expression: PetExpression

    var body: some View {
        ZStack {
            ForEach(PetExpression.allCases, id: \.self) { expr in
                if expr == expression {
                    MascotImage(expression: expr)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: expression)
    }
}

private struct MascotImage: View {
    let expression: PetExpression

    var body: some View {
        if hasLayers {
            layered
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    private var layered: some View {
        ZStack {
            layer(.ring)
                .scaleEffect(1.20)

            ZStack {
                layer(.body)
                layer(.face)
            }

            layer(.decor)
                .opacity(0.75)

            ball
                .offset(y: -15)
        }
    }

    @ViewBuilder
    private func layer(_ which: PetLayer) -> some View {
        if let img = PetAssetCache.shared.image(expression.layerAssetName(which)) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    @ViewBuilder
    private var ball: some View {
        if let img = PetAssetCache.shared.image("pet_ball") {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    private var hasLayers: Bool {
        PetAssetCache.shared.image(expression.layerAssetName(.body)) != nil
    }
}

private struct ControlDock: View {
    @ObservedObject var state: CompanionState

    var body: some View {
        HStack(spacing: 12) {
            PetControlButton(
                systemName: state.callActive ? "mic.fill" : "mic",
                tint: state.callActive ? .cyan : .primary,
                help: state.callActive ? "End voice call" : "Start voice call"
            ) {
                state.toggleCall()
            }

            if state.mode == .thinking || state.mode == .speaking {
                PetControlButton(
                    systemName: "stop.circle",
                    tint: .primary,
                    help: "Interrupt reply"
                ) {
                    state.interrupt()
                }
            }

            if state.callActive {
                PetControlButton(
                    systemName: state.muted ? "mic.slash.fill" : "mic.slash",
                    tint: state.muted ? .red : .primary,
                    help: state.muted ? "Unmute microphone" : "Mute microphone"
                ) {
                    state.toggleMute()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
        )
    }
}

private struct PetControlButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
