# Milestone 9.3: FermixPet Native SwiftUI Animation Pass

**Status:** Draft
**Date:** 2026-05-17
**Author:** Sujeeth / Aira
**Depends on:** M9.1 (`clients/macos/FermixPet`, layered PNG mascot, `RealtimeSocketClient`, `CompanionState.Mode`), M9.2 (full-duplex mic/playback path, `AudioController`)
**References:** `clients/macos/FermixPet/Sources/FermixPet/PetView.swift`, `clients/macos/FermixPet/Sources/FermixPet/PetExpression.swift`, `clients/macos/FermixPet/Sources/FermixPet/CompanionState.swift`, `clients/macos/FermixPet/Sources/FermixPet/AudioController.swift`, `clients/macos/FermixPet/Sources/FermixPet/Resources/PetExpressions/`

---

## 1. Problem / Goal

FermixPet today renders the mascot as four stacked PNGs per expression (`pet_<expr>_{body,ring,face,decor}.png`) plus a `pet_ball` overlay. State changes hard-swap the entire layer set and the only motion is a single `@State var animationPhase: Bool` toggled on appear and driven by `.animation(.easeInOut(duration: 0.9).repeatForever(...))` (`PetView.swift:7`, `PetView.swift:44`). All animated values are `phase ? a : b`, so the breathing, ball bob, glow pulse and rotation are a synchronised square wave.

**Five concrete problems:**

| Problem | Today | Symptom |
|---------|-------|---------|
| Two-frame Bool drives everything | One `animationPhase` toggle, branched at the call site (e.g. `mascotScale`, `mascotOffset`, `glowRadius` in `PetView.swift:86-145`) | Every motion pulses on the same beat. The pet feels robotic — there is no organic phase offset between the body and the orbital ball. |
| Hard expression swap | `state.petExpression` flips and all four PNG layers replace in a single frame | Visible flicker on every mode change. State transitions look like a slide deck advancing, not a character reacting. |
| Per-render disk I/O | `MascotImage.nsImage(named:)` calls `Bundle.module.url` + `NSImage(contentsOf:)` on every body evaluation (`PetView.swift:205`) | Hundreds of disk reads per second per visible pet at 60 fps. Cost is hidden today only because the rest of the view is cheap; turning on a continuous timeline would compound it. |
| Zero visual link to audio | `AudioController` plays PCM but never exposes amplitude; speaking pulse is the same boolean wobble used for listening | The pet visibly "moves" when speaking but the motion is decorrelated from the voice. Nothing about what you see matches what you hear. |
| No eye life, no event reactions | Glow colour is the only feedback for `tool_use` / `error` / `call_start` events | The mascot never blinks, never twitches, never reacts to discrete events. Long sessions feel static. |

**Goal of M9.3:** make the mascot feel alive without commissioning new art, adding third-party dependencies, or restructuring the existing `RealtimeSocketClient` → `CompanionState` event flow. Five pure-SwiftUI mechanics, ~130 net LOC, no new bundled assets, no new SPM dependencies.

**Non-goal:** replacing the PNG mascot with a vector or Lottie/Rive character, adding window-level motion (the pet wandering around the screen), reactive physics (cloth on the hood, hair), or building a state machine abstraction. Those remain candidates for a future M9.4+ once the character itself is locked.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `PetAssetCache` | P0 | New | `@MainActor` singleton preloads the 15 PNGs in `Resources/PetExpressions/` into `NSImage` at app launch from `FermixPetApp` init. Replaces per-render `Bundle.module.url` + `NSImage(contentsOf:)` reads in `MascotImage` with dict lookup. `pet_idle_decor` and `pet_listening_decor` do not exist in the repo today — preload tolerates missing optional layers (the existing `guard let url = ...` in `MascotImage` already handles absent assets). |
| Time-driven motion loop | P0 | New | Wrap `MascotImage` in `TimelineView(.animation(minimumInterval: 1.0/30.0))`. Replace all `animationPhase ? a : b` branches with `sin(2π·t/period)` curves with per-axis periods (breath ~2.4s, bob ~3.1s, sway ~4.2s). Each axis gets a different period so they desync naturally. |
| `MascotMotion` helpers | P0 | New | Pure functions: `breathAmp(Mode)`, `bobAmp(Mode)`, `swayAmp(Mode)`, `breathPeriod(Mode)`, plus an `AnimatableModifier` for one-shot reactions (wiggle, hop, droop). Keeps `PetView` body readable. |
| Expression cross-fade | P0 | Refactor | `ZStack` over all four expressions; only the currently-selected one is in the view tree, gated by `.transition(.opacity.combined(with: .scale(0.97)))` and `.animation(.easeInOut(duration: 0.28), value: state.petExpression)`. Replaces the hard PNG swap. |
| Audio level publication | P0 | New | RMS computed over each played PCM chunk in `AudioController`'s existing playback path. Surfaced via an `onOutputLevel: ((Float) -> Void)?` closure — `AudioController` is a plain `final class` (`AudioController.swift:4`), not an `ObservableObject`, so a `@Published` on it would not propagate to views observing `CompanionState`. `CompanionState` sets the closure in `init` and owns `@Published private(set) var audioLevel: Float = 0`, which the view observes. |
| Audio-reactive speaking pulse | P0 | New | During `mode == .speaking`, mascot scale picks up `0.06 * outputLevel`. Body visibly pulses with syllables of the model's voice. Single biggest "feels alive" mechanic in the milestone. |
| `BlinkController` | P2 | New | Tiny `ObservableObject` running a `Task` loop: sleep random 3.5–6.5s, set `isBlinking = true` for 90ms, repeat. Applied to the face layer as `.scaleEffect(x: 1, y: isBlinking ? 0.06 : 1.0)`. **Caveat:** `pet_<expr>_face.png` contains the mouth and expression details, not just eyes — a Y-squash distorts the whole face. Add only after the high-value mechanics land and visual review confirms it reads as a blink rather than a face-squash. |
| One-shot event reactions | P2 | New | `CompanionState` gains `@Published var reactionEvent: ReactionEvent?` where `ReactionEvent` carries `id: UUID` and `kind: ReactionKind` (`.toolFired`, `.callStarted`, `.errored`). The UUID guarantees `.onChange` fires for repeated kinds; a stale clear-task only clears if its own `id` is still active. `.toolFired` / `.errored` are set in `handle(event:)` (the existing `tool_event` and `error` cases). `.callStarted` is set locally in `startCall()` — no `call_start` event arrives over the socket; `handle(event:)` only sees `state`, `audio_delta`, `playback_stop`, `tool_event`, `error` (`CompanionState.swift:267-322`). Add only after the high-value mechanics land. |
| Spring on mode transitions | P2 | Tweak | Replace the existing `.animation(.easeInOut(duration: 0.7), value: state.mode)` at `PetView.swift:19` with `.animation(.interpolatingSpring(stiffness: 180, damping: 12), value: state.mode)`. Adds subtle squash/stretch overshoot on mode change. Cheap one-line tweak; deferred to the polish phase. |

### Non-Goals

- **No new artwork.** Same 16 PNGs in `Resources/PetExpressions/`. Bundle size unchanged (~6.6 MB).
- **No new dependencies.** No Lottie, no Rive, no SwiftUI add-ons. SPM `Package.swift` is untouched.
- **No animation timing tests.** Adding an XCTest harness for sine-curve timing or transition durations is not worth it at this scale. Verification is manual: `swift build` from `clients/macos/FermixPet/` must pass with zero warnings; launch FermixPet and confirm idle motion plays continuously; start a voice call and confirm the speaking pulse tracks the model's voice and stops when playback ends; Activity Monitor shows FermixPet idle CPU under ~2% with the timeline running.
- **No window-level motion.** The pet stays in its existing floating window. Pet wandering, multi-monitor behaviour, and snap-to-edge are M9.4 candidates.
- **No vector mascot pivot.** Rive / Lottie / commissioned art remain on the table for a future milestone but explicitly out of scope here. If after this milestone the mascot still feels stiff, the bottleneck is the character itself, not the animation system.
- **No new event types over the socket.** `RealtimeSocketClient` and the daemon's event schema are unchanged. Every reaction is derived from events `CompanionState.handle(event:)` already receives.

---

## 3. Files and LOC

| File | Change | LOC delta |
|------|--------|-----------|
| `clients/macos/FermixPet/Sources/FermixPet/PetView.swift` | Rewrite `MascotImage` body + motion call sites; remove `animationPhase` and the four phase-branched helpers | -50, +90 |
| `clients/macos/FermixPet/Sources/FermixPet/CompanionState.swift` | Add `@Published audioLevel`, `reactionEvent` publisher, `audio.onOutputLevel` wiring in `init`, `.callStarted` trigger in `startCall()`, `.toolFired`/`.errored` triggers in `handle(event:)` | +25 |
| `clients/macos/FermixPet/Sources/FermixPet/AudioController.swift` | Add `var onOutputLevel: ((Float) -> Void)?` callback and RMS computation in the existing playback path | +20 |
| `clients/macos/FermixPet/Sources/FermixPet/FermixPetApp.swift` | Call `PetAssetCache.shared.preload()` in init; instantiate `BlinkController` and inject via environment | +5 |
| `clients/macos/FermixPet/Sources/FermixPet/PetAssetCache.swift` | New file: preload + dict lookup | +40 |
| `clients/macos/FermixPet/Sources/FermixPet/MascotMotion.swift` | New file: sin amplitude/period helpers, one-shot reaction `AnimatableModifier` | +60 |
| `clients/macos/FermixPet/Sources/FermixPet/BlinkController.swift` | New file: blink loop | +25 |

**Net: ~215 added, ~50 removed. ~165 LOC net.** P0 alone (asset cache + timeline + cross-fade + audio) lands closer to ~110 net; P2 polish adds the rest only if visual review at the go/no-go gate approves.

---

## 4. Design

### 4.1 PetAssetCache

```swift
@MainActor
final class PetAssetCache {
    static let shared = PetAssetCache()
    private var images: [String: NSImage] = [:]

    func preload() {
        let expressions = ["idle", "listening", "thinking", "speaking"]
        let layers = ["body", "ring", "face", "decor"]
        for expr in expressions {
            for layer in layers {
                load("pet_\(expr)_\(layer)")
            }
        }
        load("pet_ball")
    }

    func image(_ name: String) -> NSImage? { images[name] }

    private func load(_ name: String) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return }
        images[name] = img
    }
}
```

Called from `FermixPetApp` init before the first window opens. Lookups in `MascotImage` become `PetAssetCache.shared.image(expression.layerAssetName(.body))`.

### 4.2 Time-driven motion

```swift
TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
    let t = ctx.date.timeIntervalSinceReferenceDate
    expressionLayers
        .scaleEffect(1 + MascotMotion.breathAmp(state.mode) *
                     sin(2 * .pi * t / MascotMotion.breathPeriod(state.mode)))
        .offset(y: -MascotMotion.bobAmp(state.mode) *
                   sin(2 * .pi * t / MascotMotion.bobPeriod(state.mode)))
        .rotationEffect(.degrees(MascotMotion.swayAmp(state.mode) *
                                 sin(2 * .pi * t / 4.2)))
}
```

`minimumInterval: 1.0/30.0` caps the timeline at 30 fps. Visually indistinguishable from 60 fps for this kind of slow continuous motion; cuts CPU roughly in half.

Each axis has its own period so the breath, bob, and sway never line up — that desynchronisation is what reads as "alive" rather than "looped."

### 4.3 Expression cross-fade

```swift
ZStack {
    ForEach(PetExpression.allCases, id: \.self) { expr in
        if expr == state.petExpression {
            ExpressionLayers(expression: expr)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}
.animation(.easeInOut(duration: 0.28), value: state.petExpression)
```

Requires adding `: CaseIterable` to `PetExpression`. 280ms cross-fade with a subtle scale pop replaces the current frame-perfect swap.

### 4.4 Audio-reactive speaking pulse

`AudioController` is a plain `final class`, not an `ObservableObject` (`AudioController.swift:4`), and is stored privately on `CompanionState` (`CompanionState.swift:25`). A `@Published` on `AudioController` would not trigger view updates on `CompanionState`'s observers, and exposing `var audioLevel: Float { audio.outputLevel }` as a computed property also would not — SwiftUI only sees changes to `CompanionState`'s own `@Published` properties. Use a closure callback:

```swift
// In AudioController (plain class — keep it that way):
var onOutputLevel: ((Float) -> Void)?

private func updateLevel(_ samples: UnsafePointer<Int16>, count: Int) {
    var sum: Float = 0
    for i in 0..<count {
        let s = Float(samples[i]) / 32768
        sum += s * s
    }
    let rms = sqrt(sum / Float(count))
    Task { @MainActor [weak self] in self?.onOutputLevel?(rms) }
}
```

```swift
// In CompanionState:
@Published private(set) var audioLevel: Float = 0

init(socketPath: String = CompanionState.defaultSocketPath()) {
    self.socketPath = socketPath
    // ... existing wiring ...
    audio.onOutputLevel = { [weak self] level in
        self?.audioLevel = level
    }
}
```

View reads `state.audioLevel`:

```swift
.scaleEffect(1 + (state.mode == .speaking ? 0.06 * CGFloat(state.audioLevel) : 0))
.animation(.linear(duration: 1.0/30.0), value: state.audioLevel)
```

Constraint: `updateLevel` must be cheap (we run it on every chunk). 256-sample RMS is ~512 multiply-adds; negligible.

### 4.5 Eye blink

```swift
@MainActor
final class BlinkController: ObservableObject {
    @Published private(set) var isBlinking = false
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let interval = Double.random(in: 3.5...6.5)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.isBlinking = true
                try? await Task.sleep(nanoseconds: 90_000_000)
                self?.isBlinking = false
            }
        }
    }
}
```

Applied **only to the face layer** in `ExpressionLayers`:

```swift
PetAssetCache.shared.image(expression.layerAssetName(.face)).map {
    Image(nsImage: $0)
        .resizable().scaledToFit()
        .scaleEffect(x: 1, y: blink.isBlinking ? 0.06 : 1.0)
        .animation(.easeInOut(duration: 0.05), value: blink.isBlinking)
}
```

**Caveat:** `pet_<expr>_face.png` is the full expressive face layer — mouth, highlights, blush — not isolated eyes. A Y-squash distorts the whole face, not just the eyes. Try after the P0 mechanics land; if the squash reads as "the pet just flinched" rather than "the pet blinked," remove it or gate it to `.idle` mode only. A real blink needs separate eye sprites, which is a future-art task.

### 4.6 One-shot reactions

`CompanionState`:

```swift
enum ReactionKind { case toolFired, callStarted, errored }
struct ReactionEvent: Equatable {
    let id = UUID()
    let kind: ReactionKind
}
@Published var reactionEvent: ReactionEvent?
```

The UUID-keyed struct guarantees `.onChange` fires even for back-to-back `.toolFired` events (a nullable enum re-set to the same value triggers nothing) and lets the clear task verify it isn't erasing a newer reaction.

`.toolFired` and `.errored` set inside `handle(event:)` at the existing `tool_event` / `error` branches:

```swift
case "tool_event":
    // ... existing mode/statusText logic ...
    switch event["status"] as? String {
    case "completed": reactionEvent = ReactionEvent(kind: .toolFired)
    case "error":     reactionEvent = ReactionEvent(kind: .errored)
    default: break
    }
case "error":
    // ... existing logic ...
    reactionEvent = ReactionEvent(kind: .errored)
```

`.callStarted` set locally in `startCall()` — no `call_start` event arrives over the socket:

```swift
func startCall() {
    if callActive { return }
    // ... existing logic ...
    reactionEvent = ReactionEvent(kind: .callStarted)
}
```

`PetView` clears with an id-guarded check so a stale 600ms timer can't erase a newer reaction:

```swift
.onChange(of: state.reactionEvent) { event in
    guard let event else { return }
    withAnimation(.interpolatingSpring(stiffness: 220, damping: 9)) {
        reactionPhase = event.kind
    }
    let firedId = event.id
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 600_000_000)
        if state.reactionEvent?.id == firedId {
            state.reactionEvent = nil
            reactionPhase = nil
        }
    }
}
```

`reactionPhase` drives the `MascotMotion.reaction(kind:)` modifier: `.toolFired` → 8px x-wiggle, `.callStarted` → 12px hop up + bounce, `.errored` → 4° rotation then return.

### 4.7 Spring on mode transitions

One-line change at `PetView.swift:19`: replace `.animation(.easeInOut(duration: 0.7), value: state.mode)` with `.animation(.interpolatingSpring(stiffness: 180, damping: 12), value: state.mode)`. The mascot's mode-driven scale/offset/rotation now overshoot subtly, giving Disney-style squash & stretch on every state change.

---

## 5. Before / After

| Behaviour | Today | After M9.3 |
|-----------|-------|------------|
| Idle motion | Synchronised 2-frame Bool toggle | Independent sine curves per axis with their own periods |
| Expression change | Hard PNG swap, visible flicker | 280ms opacity + scale cross-fade |
| Speaking pulse | Same wobble as listening, no audio link | Body scale modulated by output RMS — visibly pulses on syllables |
| Eye life | None | Blink every 3.5–6.5s, 90ms close, jittered |
| Tool / error reactions | Glow colour change only | Glow change **plus** one-shot wiggle / droop / hop on body |
| Mode transitions | Linear ease, no overshoot | Interpolating spring, subtle squash & stretch |
| Per-frame cost | ~360 disk reads/s while visible (hidden today, would compound under a real timeline) | Dict lookup, O(1) |
| Asset bundle | 6.6 MB PNGs | 6.6 MB PNGs (unchanged) |
| Third-party dependencies | None | None |

---

## 6. Build Order

### P0 — high-value, mandatory

1. **`PetAssetCache` + wire `MascotImage` to it** (15 min). Invisible behaviour change; unblocks the 30 fps timeline by removing the per-render disk I/O.
2. **`TimelineView` + sine-driven idle motion + `MascotMotion` helpers** (30 min). First visible upgrade — pet stops feeling robotic.
3. **Expression cross-fade** (15 min). Biggest visual win per line of code in the milestone.
4. **`AudioController.onOutputLevel` closure + `CompanionState.audioLevel` + speaking pulse** (45 min). Pet visibly speaks — the moment the mascot feels alive.

### Hard go/no-go visual review

After step 4, stop. Launch the pet, run a real voice call, watch idle motion for ~2 minutes. Decision:

- **If it feels alive and on-character** → continue to P2 polish below.
- **If the mascot still feels stiff or off-character** → the bottleneck is the character itself, not the motion system. Stop and reconsider commissioning new art / Rive before sinking more time. P2 polish on a character that doesn't carry it is animation-system bloat.

### P2 — polish, only if review passes

5. **Spring on mode transitions** (5 min — one-line tweak at `PetView.swift:19`).
6. **One-shot event reactions** (45 min) — UUID-keyed `ReactionEvent`, `.callStarted` in `startCall()`, `.toolFired`/`.errored` in `handle(event:)`.
7. **Eye blink** (20 min) — gated on the face-distortion caveat in §4.5. Keep only if it reads as a blink.

---

## 7. Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `TimelineView` keeps the view tree updating even when the pet is occluded or another space is active | Medium | The `minimumInterval: 1.0/30.0` cap bounds the cost; SwiftUI also pauses `TimelineView` when the window is offscreen. Re-evaluate only if Activity Monitor shows the pet using >2% CPU at idle. |
| Audio RMS computation adds latency to the playback path | Low | RMS over 256 samples is ~512 FLOPs — negligible compared to PCM decode. Compute synchronously on the audio thread and `Task { @MainActor }` only the publish. |
| Cross-fade interacts badly with the breathing scale (compound transforms during transition) | Low | Both transforms are commutative scale operations; in practice this looks like a slightly enhanced pop. Worst case, drop the `.scale` portion of the transition. |
| Spring on mode transitions feels too bouncy for `.error` | Low | Spring is only on `state.mode` value; `.error` triggers a one-shot droop reaction separately. Tune `damping` upward if it reads as too rubbery. |
| Per-`AnimatableModifier` allocation on every reaction | Low | Reactions fire at most a few times per minute. No meaningful allocation pressure. |

---

## 8. Open Questions

- Should `BlinkController` pause blinking during `.speaking` mode (the existing face layer may be mid-talking-pose where a Y-squash looks wrong)? Easy to gate; defer until visual review.
- Should the one-shot reactions be per-mode (e.g. `errored` reaction differs in `.speaking` vs `.idle`)? Probably overkill — same modifier across modes for v1.
- Is 30 fps enough for the audio pulse? At low pulse amplitudes (`0.06 * rms`) the visual change per frame is small enough that 30 fps reads as smooth. Bump to 60 if needed.

---

## 9. What This Milestone Does Not Promise

- The mascot will not look like a different character. The PNGs are the same. M9.3 makes the existing character feel alive; it does not redesign the character.
- This does not unlock per-state hand-drawn animation. For frame-by-frame Disney-style motion, a future milestone would adopt Lottie or Rive with a commissioned animator. M9.3 is the cheapest credible "feels alive" pass on what already ships.
