import AppKit
import SwiftUI

struct PetView: View {
    @EnvironmentObject private var state: CompanionState
    @State private var hovered = false
    @State private var animationPhase = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                MascotImage(expression: state.petExpression, breathing: animationPhase)
                    .frame(width: 116, height: 108)
                    .scaleEffect(mascotScale)
                    .offset(y: mascotOffset)
                    .rotationEffect(mascotRotation)
                    .compositingGroup()
                    .shadow(color: glowColor, radius: glowRadius, y: 6)
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
        .onAppear {
            animationPhase = true
        }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: animationPhase)
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
                NSApp.terminate(nil)
            }
        }
    }

    private var shouldShowControls: Bool {
        hovered || state.callActive || state.mode == .speaking
    }

    private var mascotScale: CGFloat {
        switch state.mode {
        case .listening, .muted:
            return animationPhase ? 1.035 : 0.99
        case .speaking:
            return animationPhase ? 1.02 : 0.985
        case .thinking, .error:
            return 1.0
        default:
            return animationPhase ? 1.008 : 0.995
        }
    }

    private var mascotOffset: CGFloat {
        switch state.mode {
        case .offline:
            return 3
        case .speaking:
            return animationPhase ? -3 : 1
        default:
            return animationPhase ? -2 : 1
        }
    }

    private var mascotRotation: Angle {
        switch state.mode {
        case .thinking:
            return .degrees(animationPhase ? 1.4 : -1.4)
        case .error:
            return .degrees(animationPhase ? -1.6 : 1.6)
        default:
            return .degrees(0)
        }
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
        default:
            return Color.black.opacity(0.18)
        }
    }

    private var glowRadius: CGFloat {
        switch state.mode {
        case .listening, .muted, .speaking:
            return animationPhase ? 16 : 10
        default:
            return 12
        }
    }
}

private struct MascotImage: View {
    let expression: PetExpression
    let breathing: Bool

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
            .scaleEffect(breathing ? 1.003 : 0.999)

            layer(.decor)
                .opacity(breathing ? 0.9 : 0.5)

            ball
                .offset(y: breathing ? -16 : -15)
        }
    }

    @ViewBuilder
    private func layer(_ which: PetLayer) -> some View {
        if let img = nsImage(named: expression.layerAssetName(which)) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    @ViewBuilder
    private var ball: some View {
        if let img = nsImage(named: "pet_ball") {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    private var hasLayers: Bool {
        nsImage(named: expression.layerAssetName(.body)) != nil
    }

    private func nsImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
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
