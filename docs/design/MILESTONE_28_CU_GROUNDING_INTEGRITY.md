# Milestone 28 — Computer-Use Grounding Integrity

**Status:** rev 3 (2026-07-29) — **Phases A + B implemented** (fermix working tree + compux working tree at 0.7.0/protocol v5; Phase C not started; compux release + fermix ref re-pin are the outstanding owner steps). Rev 3 records the implementation-time corrections: B5 became the looser-of-two-budgets rule (a pure area budget would have softened native crops — see B5), B1's `label` argument was dropped, B2's mechanism is the session-stamped `rulers` field, B3 gained the 60-badge cap + clearing rule, and A3's "maximize first" became "front and unobstructed" (maximizing *reduces* aiming resolution under the region-zoom budget). Rev 2 folded a three-lens adversarial review: corrected grid-conversion worked examples (A1/A2), position-independent tripwire predicate, single-grid budget (no tool/feed split), Elixir-side mark resolution, deterministic AX activation with teardown, verified protocol-compat answer + explicit v5 decision, night-1 `elements` evidence corrected, six-surface steering lockstep. Root-caused from three live voice sessions (Opik + `~/.fermix-dev/traces` forensics) plus a full pipeline audit of fermix + compux; reference mining of OpenAdapt and OS-Copilot.
**Date:** 2026-07-29
**Author:** Sujeeth
**Depends on:** compux v0.6.2 (shipped — interpolated drags, input_control probe), M9.1 realtime voice (shipped), M9.5 screen perception (shipped), `docs/design/COMPUTER_USE.md` v1, `docs/design/REVIEW_2026_07_27_VOICE_CU_STACK.md` (its P0 fixes are live at HEAD and are **not** re-proposed here), `docs/design/COMPUTER_USE_SELECTION_AND_WATCH.md` (the six steering surfaces + lockstep rule), `docs/TELEMETRY_CONTRACT.md`

---

## 1. Incident and evidence

The user experience: "computer use clicks all over the place and says it doesn't work" during voice +
screen-share chess sessions on a Samsung Odyssey G95SC — 3840x1080, 32:9 super-ultrawide, backing scale
1x (not retina), flagged `Television: Yes`.

Three sessions, one saga (all `gpt-realtime-2.1`, voice `marin`; no other model appears in any of them):

| Session | Opik trace | What happened |
|---|---|---|
| 07-26 21:38 EDT (`session:4`, traces/2026-07-27) | `019fa136-9dd2-…` | 2 `left_click_drag` + 2 `left_click` on the lichess board, region `{8,11,406,341}`. Board never changed. Three stacked causes: the v0.6.1 sidecar drag was structurally broken (fixed in v0.6.2, per the 07-27 review), the wrong-grid fingerprint below is already present, and — notably — `elements` had returned **38 AX targets over this exact focused Chrome/lichess window** 1.5s before the first drag, but board *squares* are not among them (AX exposes the page's buttons/links, not chessground squares), so the model fell to pixel drags anyway. |
| 07-27 22:27 EDT (`session:4`, traces/2026-07-28) | `019fa68c-17b8-…` (the trace the user pasted) | Zero CU clicks. The model looked (3 region screenshots, `windows`, `elements` → empty this night), then **refused pixel clicks** — "guessing coordinates would just misclick" — and played via the managed-browser CDP rails (`act click ref=…`, PGN fill). The good path — with the caveat that it worked because a lichess game is server-synced across views; the rail is not generally safe for un-synced pages already open on the user's screen (see A3). |
| 07-28 23:08 EDT (`session:16`, traces/2026-07-29) | `019fabd7-ce57-…` | The miss storm: 15 `left_click`s (Chrome bookmark, then lichess "Start game"), every one missed, `elements` empty again, session ended seconds after the user said "now you're not clicking at the start game actually". |

### 1.1 The fingerprint (session:16)

Every click carried the correct region `{x:23,y:11,w:482,h:341}` and was answered against the magnified
crop the model had just been sent — a **1355x959** image. Yet all 15 coordinate pairs fall inside the
**482x341 region rectangle** (x∈[44,430], y∈[20,335]). Under an independent-uniform model the probability
of that is ~3e-14; even collapsing the correlated retries to the ~6 distinct aims actually present, it is
still <1e-5 — conclusive either way. The model was answering on the **full-screen sent grid** (the
1366x384 space of the `windows` list and the ambient screen-share frames), not the crop grid.

Worked example — the "Start game" clicks (region `{23,11,482,341}`, view 1355x959, magnification
`kz_eff = view_w / r.w = 2.811`):

- Model sends `(400,265)` + the region.
- Contract says coords are crop-space; compux maps `phys = region_origin_phys + xy / kz` with `kz = 1.0`
  → executes at **(465, 296)** physical: far-left ~13% of the ultrawide.
- Read as full-screen sent-space (what the model meant): `(400,265) × 2.811` → **(1124, 745)** physical —
  center-right, where lichess renders the button. Its coordinate in the crop the model was actually
  holding: `((400−23)×2.811, (265−11)×2.811)` ≈ **(1060, 714)**.
- Off by exactly the magnification factor **2.811**, toward the region origin. All 15 clicks, both bursts.

### 1.2 Why nothing caught it

- **The transform is not the bug.** Capture and the click inverse share one `CropRect` ("built once …
  so the two can never disagree", `deps/compux/native/compux/src/main.rs:591-596`), the geometry is
  unit-tested for exactly 3840x1080@1x (`main.rs:2100-2118`), and every post-action cursor read-back in
  the live traces matches the requested sent coordinate exactly. The 07-27 stack review's dedicated pass
  called the coordinate model "verified clean end to end".
- **Verification is structurally blind to this class.** The cursor read-back is rendered through the same
  crop transform (`to_sent`), so a wrong-grid click echoes back as a perfect hit at the requested point —
  `Cursor at (430,315)` — every time. Delivery verification proves "the OS put the cursor where compux
  computed", never "where the model intended".
- **The existing guard covers the inverse case only.** `check_view_region` refuses bare coords after a
  magnified view (`session.ex:271-296`) — but in-range coords on the wrong grid sail through.
- **Prose steering does not hold.** Every screenshot result already says "the x,y you read HERE are in
  this magnified image". The model acknowledged and violated it 15/15 times. A speech-first realtime
  model doing modal coordinate bookkeeping is the failure, not the wording.
- **The deterministic rail was dead on nights 2–3 — with no cause and no revival.** `elements` came back
  empty over Chrome on 07-27 EDT and 07-28 EDT (Chromium exposes its AX tree only to detected assistive
  clients; the same call had returned 38 elements on night 1). The empty result does steer to other rails
  (managed-browser `get field=rect` + `click_coords`), but it cannot explain the emptiness or revive the
  AX rail — and night 1 shows the flip side: 38 targets in hand did not stop pixel drags when the actual
  targets (board squares) weren't AX-backed.
- **The full-screen view is unreadable here.** `MAX_EDGE = 1366` (`main.rs:39`) on the long edge turns
  this display into a 1366x384 strip (menu bar items 11px tall). That forces the region workflow — which
  multiplies grid switches, which is where the model fails. 32:9 is punished disproportionately: a 16:9
  1080p display keeps 1366x768.

### 1.3 Root causes, ranked

- **RC1 — modal coordinate contract.** "Answer in the space of the latest screenshot" flips the answer
  grid on every region switch and relies on the model to track the mode. Enforcement exists on one side
  of the flip only.
- **RC2 — the grounder is a speech model.** Voice sessions give `gpt-realtime-2.1` the `computer_use`
  tool directly (capability parity, `session_server.ex:1340-1360`); there is no delegation to a
  grounding-capable loop. `COMPUTER_USE.md:92-94` documents "weaker grounding … materially worse click
  accuracy on dense GUIs" as the v1 tradeoff.
- **RC3 — verification proves delivery, not aim** (see 1.2).
- **RC4 — Chromium AX exposure is session-dependent and opaque.** The rail silently flips between
  38-elements and empty across nights, with no activation attempt and no cause in the result.
- **RC5 — long-edge image budget vs 32:9** (see 1.2).

Refuted for the record (do not re-litigate): retina/scale-factor arithmetic (sf=1 here; the physical-edge
`sent_scale` fix already covers sf=2), capture-vs-injection space divergence (shared `CropRect` + exact
cursor echoes), TV/overscan offsets (capture and injection share one CoreGraphics geometry; window
regions and echoes are sane), and screen-share frames as the coordinate source — every click *burst*
followed a fresh region screenshot carrying the same region and every click echoed that region, and the
frames are captioned awareness-only at `detail:"low"`; the wrong grid the model used is the full-screen
*sent* grid, which frames merely share.

---

## 2. What the reference stacks teach

Mined targeted (OpenAdaptAI/OpenAdapt at `legacy/openadapt/`, OS-Copilot/OS-Copilot):

| Lesson | Source | Verdict for Fermix |
|---|---|---|
| **Never ask a general VLM for raw pixel coordinates.** Production strategies segment the view, have the model pick a target by numbered mark / description, then compute the click point deterministically (mask centroid / element bbox). Raw-coordinate replay is explicitly labeled the "if AGI happens" baseline. | OpenAdapt `strategies/visual.py`, `vanilla.py:29-31`; prompts delete stale coords so the model cannot anchor on them | **Adopt** — as AX-backed set-of-marks (§5.2 B3). Fermix currently ships the anti-pattern as its only aiming path. |
| One conversion identity between image space and input space, measured not assumed, restated at every crossing; inference-resolution outputs resized back before any bbox math. | OpenAdapt `utils.get_scale_ratios`, `adapters/ultralytics.py` | **Already sound in compux** (shared `CropRect`). The gap is the *model-facing* half — make the grid visible in the image itself (§5.2 B2) and disclose both spaces in results (§5.1 A2). |
| Crop to the active window before grounding; never feed a full multi-monitor/ultrawide frame to a VLM. | OpenAdapt `models.py cropped_image` | **Already present** (`windows` → region workflow) — keep, and stop punishing the full view (§5.2 B5). |
| Grounding failures re-prompt **with the concrete failure**, never a bare retry. | OpenAdapt exception-feedback loops | **Adopt** in refusal texts (§5.1 A1) — matches the existing "vendor's own words" rule. |
| Remove clicking from the hot path entirely: type-routed execution (Python/Shell/AppleScript/API) has no click verb; app control goes through named-object AppleScript; whole click classes replaced by keyboard/CLI ("never mouse-click to open an app — Spotlight"). | OS-Copilot `friday_pt.py:326-331`, `applescript_env.py`; `friday_vision.py:137` rule pack | **Adopt as steering** (§5.1 A3) across all six surfaces from `COMPUTER_USE_SELECTION_AND_WATCH.md`, in lockstep. |
| Where clicking is unavoidable: one canonical space (resize the image into the injection space before grounding), coordinates only from a provided element table, verify against the next observation, never assume success. | OS-Copilot `friday_vision.py:110-115,168-173` | **Adopt** the element-table form via marks; effect-verification steering already shipped at HEAD. |
| Segmentation runtimes (FastSAM/SAM), SSIM segmentation caches, DOM least-squares calibration. | OpenAdapt adapters | **Reject for now** (§5.3 C3) — AX covers macOS; no ML runtime in the sidecar; calibration solves a divergence Fermix provably does not have. |

---

## 3. Goal and non-goals

**Goal:** a model — including a speech-first one — either aims by a deterministic reference (mark,
element, managed-browser ref) or, when it must aim by pixels, does so on a grid it can *see*, with any
grid confusion caught **before injection** and any executed click visibly disclosed **after**. The wrong
grid must stop being silently executable.

**Non-goals:**
- Provider-native CU tools (Anthropic `computer_*` / OpenAI `computer_use_preview`) — still deferred, per `COMPUTER_USE.md`.
- Segmentation/OCR runtimes in the sidecar (FastSAM, OmniParser class) — AX marks cover macOS; revisit only if C1 data says otherwise.
- Multi-display coordinate work (compux v1 drives one display; unchanged).
- New config knobs. Everything below is constants or existing-surface behavior. No env overlays.
- Re-proposing anything the 07-27 review already fixed (drag interpolation, input probe, delivery tolerance, response.create coalescing, feed last_hash, image retention).

---

## 4. Design principles

1. **The model never does coordinate-space arithmetic.** Every number it emits is either a mark id or a
   coordinate on a grid that is visibly drawn in the image it is reading.
2. **Deterministic rails outrank pixel regression.** elements/marks → managed-browser refs (same-session
   targets only) → scripting (`open -a`, AppleScript, shell) → raw pixels, in that order, chosen
   explicitly — refusals are typed and loud, never a silent downgrade to another mechanism (rule 12:
   rails, not fallbacks).
3. **One full-screen grid per session.** Feed frames, the `windows` list, and full-screen tool
   screenshots share a single sent geometry — never two full views at different scales.
4. **Verification must be able to falsify the aim.** A check that renders the model's own request back to
   it in the same space can only ever agree; disclose the executed point in *all* spaces and draw it into
   the check image.
5. **Fail before injection, not after.** A deterministically-detectable ambiguity refuses with the exact
   conversion in the message; a wrong click that executes costs a real-world side effect.

---

## 5. Changes

### 5.1 Phase A — fermix-side, ships alone (no compux release required)

**A1. Ambiguous-grid tripwire (`ComputerUse.Session`).** For a pointer action carrying region `r` whose
current view is magnified by `kz_eff = view_w / r.w > @ambiguity_min_zoom` (constant, 1.5): if the
coordinates *also* fall inside the **positioned** region rectangle — `r.x ≤ x ≤ r.x + r.w` and
`r.y ≤ y ≤ r.y + r.h` — the numbers are plausible on both live grids (a full-screen-grid answer aimed at
the window's content lands in the positioned rect, wherever the window sits; an origin-anchored
`x ≤ r.w` test would go silently blind for any window not at the screen's top-left). Refuse with a typed
`ambiguous_coordinates` result naming both readings and the **complete** conversion:

> Ambiguous: (400,265) fits both this 1355x959 magnified crop and the on-screen region box
> {23,11,482,341}. This view is the CROP — if you meant the crop, resend as-is with
> `confirm_grid: true`; if you read the full screen, subtract the region origin then multiply by 2.81:
> ((400−23)×2.81, (265−11)×2.81) ≈ (1060,714) in this crop.

`confirm_grid: true` executes without re-tripping. One extra round-trip in the worst case; would have
refused **all 15** incident clicks (all inside the positioned rect [23,505]×[11,352]). False-positive
surface is `(r.w × r.h) / (view_w × view_h)` of a magnified view (12.6% by area in the incident
geometry) — bounded, position-independent, and the refusal text makes recovery one turn. This is a guard
on one path, not a second path: nothing silently proceeds.

Plumbing (verified against HEAD): session state today tracks only `view_region` — `track_view_region`
must also stash the last pixel response's `width`/`height` (dropped after summarizing today), and
`kz_eff` is computed only when the action's region **equals** the tracked view region (the existing guard
checks presence, not equality). `confirm_grid` is read from raw params **before** `Protocol.validate`
(validate canonicalizes and drops unknown params — which also guarantees the sidecar never sees it), and
is added to the tool parameters schema + `dynamic_parameters` (the schema is `additionalProperties:
false`).

**A2. Dual-space disclosure.** Every pointer-action result and screenshot summary reports position in
all three spaces, computed Elixir-side from region + returned dims (no protocol change):

> clicked (400,265) in this 1355x959 crop = (165,105) on the full 1366x384 screen (= physical (465,296),
> backing scale 1.0)

Formulas (the examples above are the implementation spec): `full = (r.x + x/kz_eff, r.y + y/kz_eff)`;
`phys = full × (phys_long_edge / full_sent_long_edge)`. The model that answered on the wrong grid now
reads a full-screen coordinate it can check against its visual memory of the frames and `windows` list;
today it sees only its own number echoed back.

**A3. Steering pack.** Genuinely new steering (managed-browser-first aiming, feed-frames-never-a-source,
and delivered-but-no-effect-means-change-mechanism are already shipped at HEAD):
- Apps open by `open -a` / Spotlight, never by clicking icons; menu/settings/Finder intents go through
  named-object AppleScript or shell before any click (OS-Copilot's rule pack).
- Bring the target window to the FRONT, unobstructed, before precision clicking — deliberately **not**
  "maximize first" (OS-Copilot's form of this rule, corrected at implementation): under the region-zoom
  budget a window that fits the capture budget ships at native detail, while a maximized window grows the
  crop past the budget and gets downscaled — maximizing would *reduce* aiming resolution here.
- Browser targets, reconciled with the shipped anti-desync prong as **one principle**: managed-browser
  rails first **only when the managed page is the user's view** — the model's own window co-viewed, or
  page state server-synced across views (a lichess game qualifies; an arbitrary form does not).
  Otherwise a target on the user's screen stays `computer_use`. This edit and the existing
  shared-live-session prong of `COMPUTER_USE_SELECTION_AND_WATCH.md` land together.

Per that doc's lockstep rule, the pack lands on **all six surfaces** in one commit: system-prompt runtime
contract (`prompt/runtime_sections.ex`), `browser_guidance` skill, `computer_use` tool description +
`when_to_use`, `browser` tool description + `when_to_use`, and the `self_knowledge` skill.

**A4. Voice policy: no new gate yet.** The realtime model demonstrably self-selects good rails when they
exist (07-27 session). A1–A3 + Phase B make the pixel path honest; whether voice additionally needs
grounding delegation is decided by data in Phase C, not by adding a mode now.

### 5.2 Phase B — compux 0.7.0 + fermix, one paired change

Cross-repo process, per the documented pitfalls and verified against the protocol code: version bump in
both compux `mix.exs` and `Cargo.toml` (+ `cargo build` to re-pin `Cargo.lock`), grep the compux repo
for old version strings (test literals), tag → CI signs/notarizes → checksum PR → fermix pins the
checksum commit + `mix deps.get` re-pins `mix.lock`. On compatibility: unknown request fields ARE
ignored by the sidecar (untyped `serde_json::Value` parsing) and additive response fields pass Elixir's
tolerant `decode_response` — but `Protocol.validate` canonicalizes requests (unknown params dropped), so
every new field needs the compux *library* change anyway, and lib + sidecar ship in lockstep via the
ref-pinned dep and version-derived sidecar download. Precedent (v3, v4) bumps the protocol version for
every additive wire change, and a new model-facing capability an old sidecar would silently ignore is
exactly what the handshake refusal exists for. **Decision: bump to protocol v5**; the fake-sidecar test
fixture's default proto bumps with it (known pitfall).

**B1. Executed-point marker in check screenshots.** The post-action check image gets a small crosshair +
ring at the executed point, labeled with the executed coordinate, drawn sidecar-side in the check image's
own space. Mechanism (the dominant incident path issues the check as a *separate* fermix request):
`screenshot` gains an optional `annotate_point {x,y}` field (the drafted `label` argument was dropped at
implementation — the label is always the point itself, so the sidecar renders "(x,y)" and a free-text
label would only have added an atlas-unsupported surface); `take_crop_check` threads the executed
crop-space point (drag end point for drags) through it; the sidecar-internal `screenshot_after` path
derives the same marker from the action's own coordinates. The model *sees* where its click landed
relative to the target — the one disclosure that falsifies wrong-grid aim visually.

**B2. Ruler overlay on magnified crops.** Region screenshots get 1px edge ticks every 100px with labels
every 200px, in crop-pixel space; full-screen screenshots get the same (labels topping out at the sent
dims), making the two grids visually distinct at a glance. A model cannot label-match "400" against a
ruler that tops out at 384 without noticing. Tool-screenshot path only (never feed frames) — mechanism,
fixed at implementation: an optional `rulers: true` request field that `ComputerUse.Session` stamps on
every request it finalizes (screenshot, `wait_for_change`, and the mutating actions whose
`screenshot_after` check reads it), while the realtime feed's `ScreenCapture` builds its own request and
never sets it; the feed's request shape is pinned rulers-free by test.

Drawing cost, stated honestly: compux's image stack is `image` (png+jpeg only) — no imageproc/ab_glyph
anywhere in the tree, and the sidecar is built `opt-level="z"`, `lto`, `strip`. B1/B2/B3 need lines,
circles, and *digits only* — hand-roll line/circle drawing on the image buffer and embed a small bitmap
digit atlas (0–9) rather than pulling in a font-rasterization dependency. Budgets: <5% PNG-size delta,
plus an explicit sidecar binary-size delta recorded in the release notes.

**B3. AX set-of-marks: `screenshot {marks: true}` + `mark`-addressed clicks — resolved in fermix.** The
sidecar already computes interactive-element click points (`elements_for`, `main.rs:1522-1540`); with
`marks: true` it draws numbered badges at those points on the (cropped) screenshot and returns the mark
table `{id, role, title, x, y}` alongside the image. **Mark→coordinate resolution lives in
`ComputerUse.Session`, not the sidecar**: the session stores the table keyed to the current view region,
translates `left_click {mark: N}` into the existing x/y + region request, and refuses with a typed
`stale_marks` error when the view has changed since the marked screenshot. The click wire stays
x/y-only — no cross-request sidecar state (the sidecar is deliberately stateless and respawned on
timeout/capture-wedge; responses are matched by Port order with no request id), no renumbering hazard,
no stale-centroid click. Zero marks → the image ships unannotated with an explicit "0 accessibility
marks" note (loud absence, no silent downgrade). Steering: "prefer `mark` when marks are present";
`self_knowledge` updated in the same change. Implementation constants: badges cap at 60 (a 250-badge
soup grounds worse than pixels; tree-walk order is roughly top-down, and a `marks_truncated` count rides
the payload + summary), the table is cleared by ANY marks-less pixel response (the screen those badges
described is gone), and a mark resolved from the table bypasses the A1 tripwire — its point is copied,
not read off an image.

**B4. Accessibility target + activation — REVISED post-ship (compux 0.7.1), on live evidence.** The
first-shipped form (activate on the `AXFocusedApplication` element) failed in production the same night:
the focused-application query is unreliable from the spawned sidecar ("no focused application" reproduced
on a quiet desktop with the signed binary), and during a voice call it resolves to the floating voice
companion instead of the app on screen — the observed `-25208` (`kAXErrorNotImplemented`) was that
attribute landing on a non-Chromium app. Live probes on Chrome 150 also showed **both** activation
attributes refused (`AXManualAccessibility` −25205, `AXEnhancedUserInterface` −25208) while a bounded
walk rooted at `AXUIElementCreateApplication(pid)` returns the full tree immediately — Chromium switches
accessibility on for a *querying* AX client and builds its tree lazily. The shipped mechanism therefore:
(1) resolves the target app **from the window list** — front-to-back candidates (minimized and Window
Server windows excluded, off-display clipped, enumeration failure a typed note distinct from an empty
desktop), the frontmost window with **substantial overlap** (≥10% of the request region) winning on
stacking order so a maximized background window can never beat the window in front of it and a small
always-on-top panel is never substantial, with raw max overlap only for a sparse desktop (pure
`select_target`, unit-tested); (2) roots enumeration at that pid's own application element; (3) fires
**one** typed activation attempt (falling through to `AXEnhancedUserInterface` on both typed rejections)
**only when the app's tree walked to zero interactive nodes overall** — an app whose elements merely
fall outside the view has nothing gated, and flipping enhanced-UI mode on it would be a pure side effect;
(4) settle-polls the re-walk (5×300ms, exiting early once the tree appears); (5) names every outcome in
the result — which app was read (success included), what activation did, how long the tree took — and
still **clears any attribute it set on teardown**. Known accepted limitation: an app with no named
on-screen window (a menu-bar app with an open popover) cannot be resolved from the window list; the old
query never reached those reliably either, and the typed no-window note says what happened.

**B5. Looser-of-two-budgets sent scale — one grid for everything.** The drafted "replace the long-edge
cap with a pixel-area budget" was corrected at implementation: a *pure* area budget regresses large
near-square crops that ship native today — the incident's own 1355x959 region crop is 1.30MP, over the
1.05MP budget, and would have been softened to ~0.9x, trading readable-full-screen for blurrier zooms.
The shipped rule is one formula for full captures and crops alike:
`kz = min(1, max(MAX_EDGE/long_edge, sqrt(MAX_AREA/area)))` with `MAX_AREA = 1366×768` — the sent image
uses whichever budget grants MORE pixels, never upscaled. Every case that fits today is byte-identical
(16:9 stays exactly 1366x768, retina/13" stay long-edge-bound, fitting crops stay native); only the
pathological aspect ratios move: the 32:9 full view becomes **1931x543** (readable). One `budget_scale`
serves `sent_scale` and `CropRect::sent_scale`, so **every** surface — tool screenshots, the `windows`
region list, the click inverse, and feed frames — moves together. Splitting tool captures from feed
frames was considered and rejected: it would put two full-screen grids live in one session, and §1.1's
own evidence is that this model aims on the ambient grid despite captions — a new wrong-grid class, plus
it breaks the explicit invariant comment in `screen_capture.ex` ("frames stay in the same space as every
other capture"), which this change instead re-affirms. Feed frames remain bandwidth-bound the honest
way: same geometry, JPEG q60 (quality may drop further if measured frame bytes at 1931-wide demand it —
§8). The geometry unit tests pin 1931x543, the 16:9/retina fixed points, native crop preservation, and
the window-region round trip under the new arithmetic.

### 5.3 Phase C — measurement and the delegation decision

**C1. Aimed-click accuracy harness.** A managed-browser page renders a target grid at known viewport
coordinates; the run drives clicks through the *compux pixel path* (not CDP), and CDP-injected listeners
(`Runtime.evaluate` via the existing passthrough, headed `fermix_visible` profile) report which element
actually received each OS-level click — exact miss vectors, no human judging. Suites: full-screen aim,
magnified-crop aim, marks aim; run per grounding model (realtime vs main-agent model) on the live
display. Lands next to the existing benchmark suites; results are counts + miss-vector stats
(content-free telemetry).

**C2. Voice grounding delegation — decision gate.** If C1 shows realtime + marks still under an
acceptable hit rate on realistic targets, design the delegation: the voice session's `computer_use`
pointer verbs route through one bounded grounding call on a vision-strong model (crop + intent → mark or
point). That is a new run kind — child session with `session_id` + `parent_session`, lifecycle bookends,
`Trace.TelemetryHandler` `event_definitions/0` routing (so it lands in the JSONL traces this very
investigation depended on), and the `fermix_opik` run-kind mapping — the full `TELEMETRY_CONTRACT.md`
checklist. Not built until the numbers demand it.

**C3. Considered and parked/rejected** (decision log for future readers):
- *Normalized 0–1000 / fractional coordinates*: dimension-free answers would blunt the wrong-grid class,
  but churn the entire contract and fight OpenAI CU training priors; B1/B2 attack the same class visibly.
  Revisit only if C1 still shows grid confusion after Phase B.
- *ONNX FastSAM segmentation in the sidecar*: L effort, ~30MB model, mask post-processing port — AX marks
  cover macOS targets; games/canvas apps (including chessground squares, night 1's residual gap) remain
  pixel-aimed, now on honest rulers.
- *SSIM segmentation cache, DOM least-squares calibration, 3-point startup calibration*: solve problems
  Fermix provably does not have today (no segmentation; transform verified; settle already fails loud).
- *view-id echo on every action*: the incident's clicks already echoed the correct region — an id echo
  would not have caught in-range-wrong-grid answers. Subsumed by A1/B1/B2.
- *Tool/feed grid split* (B5 first draft): rejected — manufactures a 1.41x wrong-grid pair; see B5.

---

## 6. Telemetry

Phases A/B add **no** event names and **no** run kinds: refusals (`ambiguous_coordinates`,
`stale_marks`, AX-activation notes, zero-marks notes) are tool *results*, flowing through the existing
`Tools.Telemetry.exec/5` emitter (verified: `tools/computer_use.ex:278`) and visible in traces/Opik as
the model saw them. The C1 harness emits counts-only suite results. C2, if adopted, follows the full
new-run-kind checklist enumerated in §5.3 — including the `Trace.TelemetryHandler` routing step, called
out so it is costed, not discovered.

## 7. Testing

- **A1 geometry**: unit tests on the live incident fixture — region `{23,11,482,341}` / view 1355x959:
  `(400,265)` refuses with `(1060,714)` as the in-message conversion (the conversion text itself is
  asserted — a wrong recovery recipe is the bug class this milestone kills); `(1060,714)` executes;
  `confirm_grid` bypass executes; `kz_eff ≤ 1.5` never trips. Property test: refusal iff the point lies
  inside the **positioned** region rect in view coordinates and magnification exceeds the threshold.
  A non-origin fixture (the `main.rs:2100` window-at-(400,60) geometry) so the origin-anchored
  regression cannot ship.
- **A2 math**: round-trip property vs the compux mapping semantics (crop → full-sent → physical) on the
  3840x1080@1x and a 2x-retina fixture, asserting the disclosure string's numbers.
- **B (Rust)**: golden-dimension tests for ruler/marker/badge placement math (no pixel-perfect asserts),
  digit-atlas rendering bounds, area-budget arithmetic for 32:9/16:9/retina fixtures **including the
  click inverse and `windows` regions**, `annotate_point`/`marks` request parsing, AX activation behind
  the ax-module seam with a fake (no live AX in CI). Protocol v5: contract tests updated, fermix's
  fake-sidecar fixture default proto bumped (known pitfall).
- **Fermix mark table**: mark→x/y+region translation, `stale_marks` on view change, zero-marks pass-through.
- **Hermetic discipline**: all fermix tests stub the sidecar (existing fake), touch no host state
  (SafeRm/keychain/app-env rules apply); the C1 harness is live-tier (benchmark suite), not `mix test`.
- **Docs/impl bookkeeping**: `self_knowledge` updated in the same changes that land A3 and B3;
  `fermix-site` docs sync after ship.

## 8. Risks and open questions

- `gpt-realtime-2.1` pixel regression may remain weak even on honest, ruler-marked crops — that is what
  C1 measures and C2 answers; A/B still convert silent misses into visible or refused ones.
- Feed frame bytes: same-geometry feed at ~1932-wide roughly doubles frame bytes vs today's 1366x384 at
  equal quality — measure against the ≤20 frames/min budget; the release valve is JPEG quality, never a
  second geometry.
- Overlay bytes and binary size: rulers/badges grow PNGs (<5% budget) and the digit atlas + drawing code
  grow the size-optimized sidecar (delta recorded per release).
- `kAXManualAccessibility` is a de-facto (not formally documented) Chromium contract — activation is
  probe-and-report, never assumed; a Chromium change degrades to today's behavior plus a truthful note.
  `AXEnhancedUserInterface` is used only on a typed unsupported error, because of its known
  window-manager side effects, and whichever attribute was set is cleared on session teardown.
- OpenAI Realtime's server-side pixel budget for `detail:"high"` images is unobservable from our side;
  if it shrinks 1932-wide crops the area budget may need a provider-aware ceiling (open question carried
  from the audit).
- The tripwire's `confirm_grid` must not become a reflex (blindly confirming every refusal); C1's
  crop-aim suite will show whether confirmations correlate with hits, and the refusal text deliberately
  demands a re-read, not a yes.

## 9. Rollout

1. Phase A lands in fermix behind nothing (pure behavior), with unit tests; observable immediately in
   dev-daemon voice sessions.
2. Phase B ships in the compux order (the inverse of the fermix-macos daemon-first rule): compux 0.7.0
   tag → signed release → checksum PR → fermix ref-pin commit (protocol v5 handshake refuses any
   mismatched pairing loudly).
3. C1 harness runs before and after B on the live ultrawide; numbers decide C2.
