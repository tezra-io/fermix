import AppKit
import Combine
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
                    .animation(.easeInOut(duration: 0.7), value: state.visualMode)
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
        hovered || state.callActive || state.visualMode == .speaking
    }

    private var glowColor: Color {
        switch state.visualMode {
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
/// Motion is blended across mode changes so a switch eases in over ~0.5s
/// instead of snapping, and the timeline pauses when the window is hidden.
private struct AnimatedMascot: View {
    @EnvironmentObject var state: CompanionState

    @State private var fromMode: CompanionState.Mode = .offline
    @State private var modeMirror: CompanionState.Mode = .offline
    @State private var modeChangedAt: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !state.windowVisible)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MascotCrossfade(
                expression: state.petExpression,
                blinkOpacity: MascotMotion.blinkOpacity(at: t)
            )
            .scaleEffect(lerpedScale(at: t))
            .offset(y: lerpedOffset(at: t))
            .rotationEffect(.degrees(lerpedRotation(at: t)))
        }
        .onReceive(state.$mode) { newMode in
            let visual: CompanionState.Mode = (state.callActive && state.audioActive) ? .speaking : newMode
            beginTransition(to: visual)
        }
        .onReceive(state.$audioActive) { active in
            let visual: CompanionState.Mode = (state.callActive && active) ? .speaking : state.mode
            beginTransition(to: visual)
        }
    }

    /// Start a 0.5s eased blend toward a new visual mode. Deduped so the server
    /// flipping `mode` to listening mid-playback — while the pet is still
    /// visually speaking — doesn't retrigger a transition.
    private func beginTransition(to visual: CompanionState.Mode) {
        guard visual != modeMirror else { return }
        fromMode = modeMirror
        modeMirror = visual
        modeChangedAt = Date().timeIntervalSinceReferenceDate
    }

    /// 0→1 ease over 0.5s since the last mode change; 1 means "settled".
    private func transitionProgress(at t: TimeInterval) -> Double {
        let duration = 0.5
        let age = t - modeChangedAt
        guard age >= 0, age < duration else { return 1 }
        let x = age / duration
        return x * x * (3 - 2 * x)
    }

    private func lerpedScale(at t: TimeInterval) -> CGFloat {
        let target = scale(for: modeMirror, at: t)
        let p = transitionProgress(at: t)
        guard p < 1 else { return target }
        let from = scale(for: fromMode, at: t)
        return from + (target - from) * CGFloat(p)
    }

    private func lerpedOffset(at t: TimeInterval) -> CGFloat {
        let target = offset(for: modeMirror, at: t)
        let p = transitionProgress(at: t)
        guard p < 1 else { return target }
        let from = offset(for: fromMode, at: t)
        return from + (target - from) * CGFloat(p)
    }

    private func lerpedRotation(at t: TimeInterval) -> Double {
        let target = rotation(for: modeMirror, at: t)
        let p = transitionProgress(at: t)
        guard p < 1 else { return target }
        let from = rotation(for: fromMode, at: t)
        return from + (target - from) * p
    }

    private func scale(for mode: CompanionState.Mode, at t: TimeInterval) -> CGFloat {
        let breath = MascotMotion.breathAmp(mode)
            * sin(2 * .pi * t / MascotMotion.breathPeriod(mode))
        let speakingPulse = mode == .speaking
            ? Double(0.06 * state.audioLevel)
            : 0
        return CGFloat(1 + breath + speakingPulse)
    }

    private func offset(for mode: CompanionState.Mode, at t: TimeInterval) -> CGFloat {
        let amp = MascotMotion.bobAmp(mode)
        let period = MascotMotion.bobPeriod(mode)
        return CGFloat(-amp * sin(2 * .pi * t / period))
    }

    private func rotation(for mode: CompanionState.Mode, at t: TimeInterval) -> Double {
        MascotMotion.swayAmp(mode) * sin(2 * .pi * t / 4.2)
    }
}

/// Cross-fades the four mascot expressions with a brief scale pop instead
/// of hard-swapping the PNG stack on mode change. The head "ball" lives here,
/// above the fading faces, so the shared pearl stays put across expression
/// changes instead of fading and popping with every swap.
private struct MascotCrossfade: View {
    let expression: PetExpression
    let blinkOpacity: Double

    var body: some View {
        ZStack {
            ForEach(PetExpression.allCases, id: \.self) { expr in
                if expr == expression {
                    MascotImage(expression: expr, blinkOpacity: blinkOpacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }

            ball
                .offset(y: -15)
        }
        .animation(.easeInOut(duration: 0.28), value: expression)
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
}

private struct MascotImage: View {
    let expression: PetExpression
    let blinkOpacity: Double

    var body: some View {
        if hasLayers {
            layered
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    // Ring sits behind the body at 1.20x so the orbit reads as passing behind
    // the mascot (its authored 3D depth). The ball is drawn by MascotCrossfade.
    private var layered: some View {
        ZStack {
            layer(.ring)
                .scaleEffect(1.20)

            ZStack {
                layer(.body)
                faceLayer
            }

            layer(.decor)
                .opacity(0.75)
        }
    }

    // Face plate plus a blink: the idle face is a closed-eye frame, so cross-
    // fading it over the open-eye listening/thinking faces reads as an eyelid
    // blink with no new art. Speaking is excluded — its face carries the mouth
    // and is separately mis-registered (see speakingFaceCompensation).
    @ViewBuilder
    private var faceLayer: some View {
        ZStack {
            layer(.face)

            if blinkOpacity > 0, expression == .listening || expression == .thinking {
                closedEyeFace
                    .opacity(blinkOpacity)
            }
        }
        .offset(speakingFaceCompensation)
    }

    @ViewBuilder
    private var closedEyeFace: some View {
        if let img = PetAssetCache.shared.image(PetExpression.idle.layerAssetName(.face)) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    // The speaking face PNG is baked ~12px right / ~24px up vs the other faces
    // (measured alpha bboxes on the shared 1024px canvas). Undo it at display
    // scale — 108/1024 governs, since scaledToFit fits the square into the
    // 116x108 frame by height. Eyeball the exact pixels on a live speaking turn.
    private var speakingFaceCompensation: CGSize {
        guard expression == .speaking else { return .zero }
        let s = 108.0 / 1024.0
        return CGSize(width: -12 * s, height: 24 * s)
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

            if state.mode == .thinking || state.visualMode == .speaking {
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
