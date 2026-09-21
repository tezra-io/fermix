# Fermix

Elixir-native multi-agent AI platform: Phoenix gateway, OTP-supervised agents, SQLite memory. Code map and invariants: `ARCHITECTURE.md`. This is the repo's only agent-instruction file; never add a `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` (Claude Code would read that instead).

## Architecture
```
apps/fermix_core/      # agents, providers, tools, memory, sandbox, harness, management protocol
apps/fermix_channels/  # Telegram, Slack, Discord, Signal, WhatsApp, ACP, mobile, voice + gateway/queue
apps/fermix_web/       # Phoenix: webhooks, health, LiveView, setup UI
apps/fermix_opik/      # telemetry → Opik trace exporter
apps/fermix_nif/       # C: kill_pgid/2 NIF (process-group kill) + macOS disclaim exec shim
```
Umbrella project; one BEAM VM, no HTTP bridge, everything OTP-supervised. Persistent Main Agent (GenServer, `:permanent`), single-flight per conversation; loop: LLM call → parse tool calls → execute → repeat until done. Providers over Req. Memory: SQLite (`FermixCore.Memory.Repo`, Exqlite) behind an ETS/GenServer hot path. Predecessor RustyClaw is the reference for channels, tools, providers.

## Working Agreement
- The approved design is the plan: implement against it, don't quietly re-design mid-flight.
- Repo reality conflicts with the design, or the request has several readings → surface it before coding.
- State assumptions explicitly; never pick silently.

## Execution Contract
- Behavior change → write or update a failing test first.
- Gates before done: build, tests, lint; say which don't apply. Never mark work done without proof.
- A change that adds, removes or materially alters a feature, capability, tool, channel, provider, config surface or CLI verb must update the `self_knowledge` skill (`apps/fermix_core/priv/skills/self_knowledge/SKILL.md`) in the same change: it is Fermix's runtime self-reference and goes stale silently. No version numbers in it.
- **Telemetry is not optional** (`docs/TELEMETRY_CONTRACT.md`): tools via `FermixCore.Tools.Telemetry.exec/5`, provider calls via `FermixCore.Providers.Telemetry.emit_call/3`, so events stay correlatable and Opik-traceable; **never** hand-roll `:telemetry.execute([:fermix, :tool|provider, ...])`. A new run-type needs a unique `session_id` (+ `parent_session` if spawned) and lifecycle bookends; a new event name or run-kind also needs a `fermix_opik` update. Trace errors before returning `{:error, reason}`.
- **A user-facing capability ships with eval coverage in the same change, unasked.** ExUnit proves the unit; an eval proves the model *reaches it* through the real agent path, the half that silently rots.
  - **Behavioral** (default): `benchmark/suites/<name>.yaml`, `make regression`. Real-user intent, the model picks the tool; route assertions only for safety plus one labelled sanity case. Vocabulary: `benchmark/suites/SCHEMA.md`.
  - **Capability**: `benchmark/suites/capability/*.yaml`, `make capability-auto`. Ground-truth scoring, only `host_readonly`/`isolated_mutation`; the runner **refuses** `private_account_read`, `external_write`, `desktop_input`, `destructive`.
  - **`risk:` is mandatory and its absence is silent**: no risk → `unclassified`, and `run_eval.select/3` silently skips any scenario whose risk is outside the active profile, so the suite validates, reports nothing and looks passed. (The capability runner refuses loudly; don't rely on that asymmetry.)
  - Pre-grant every human-decision gate in `benchmark/bin/seed_capability_home.py` (see *Eval homes* below); a default-off consent gate turns a working feature into a suite of zeros.
  - Finish with `--dry-run` (validates + plans, spends nothing) before any live run.

```sh
mix deps.get && mix compile
mix test
mix credo --strict
mix format --check-formatted
```

## Code Rules (Non-Negotiable)
1. **Linear flow.** Max 2 nesting levels. Top to bottom.
2. **Bound loops.** Explicit max on retries, polls, recursion. Define cap behavior.
3. **Small functions.** 40–60 lines max. One job per function.
4. **Own resources.** Open → close on every path, including errors.
5. **Narrow state.** No module globals. Pass deps explicitly.
6. **Assert assumptions.** Guards and validation on every public function. Fail loud.
7. **Never swallow errors.** No bare `rescue`. No `{:error, _} -> :ok`. Log, raise, or return.
8. **Visible side effects.** I/O obvious at call site. Separate pure from effectful.
9. **Minimal indirection.** Readable > elegant. One layer of abstraction max. If 200 lines could be 50, rewrite it.
10. **Surgical changes only.** Touch only what the request requires; don't refactor adjacent code, comments, or formatting. Remove only the dead code your change creates. Mention unrelated issues; don't fix them unless asked.
11. **Warnings = errors.** Linters, typecheckers, analyzers are hard gates. Zero warnings.
12. **No fallbacks.** One code path per behavior: no branch that silently retries another mechanism, reads a deprecated location, or degrades to partially-working when the primary path fails. Fallbacks hide which path ran, mask failures behind "it kind of worked", and turn every bug into a five-branch investigation. When the new flow ships the old one is dead: delete it. If the primary path fails, fail loud at the boundary and exit non-zero. Two valid *configurations* are fine (user- vs system-scope service); two paths for one configuration are not. Think you need a fallback? You need (a) a clearer error, (b) one scoped recovery step for a destructive op (e.g. upgrade rollback), or (c) a design without the failure mode.
    - **Corollary: no env overlays.** Never invent an env var to override a *setting* the config owns (a second code path that drifts and rots). Env overlays are only for secrets and feature flags; everything else lives in `config.toml`.

## Conventions
- `@callback` for all plugin interfaces (providers, channels, tools).
- `{:ok, result} | {:error, reason}` tuples, not exceptions.
- Thin GenServer callbacks that delegate to private functions.
- No business logic in Phoenix controllers.
- Typespecs on all public functions.

## Docs
Design docs live in `docs/design/`, one per milestone/feature, named for its subject. List the directory and read the relevant file; never infer a doc's status from its name (many are drafts, some gitignored). `docs/TELEMETRY_CONTRACT.md` is the one contract doc outside it.

## Releasing across the four repos
An engine fix reaches a Mac user only after all four repos move, in this order; skip one and it stays unshipped while every gate is green.
1. **Engine (`tezra-io/fermix`).** Changes land by PR to `main`. A release is its own chore PR: version in `mix.exs` and the four release apps (`fermix_core`, `fermix_channels`, `fermix_web`, `fermix_nif`; `fermix_opik` keeps its own), plus a dated `CHANGELOG.md` entry naming every user-facing fix since the last tag. Tag `vX.Y.Z` on the merge commit only when the owner says so and that tree is proven green; `release.yml` then publishes the cosign-signed formula binaries and app-engine tarballs and bumps the tap formula. Walk `docs/RELEASING.md` before announcing.
2. **App (`tezra-io/fermix-macos`).** The app runs the engine it *pins*, not the newest tag. One PR bumps: `engine/PIN.json` as a whole (tag, `source_commit`, `certificate_identity`, both `sha256` from the release's `.sha256` sidecars); `Resources/Contracts/SOURCE.json` provenance (re-vendor first if anything under `priv/management` or `priv/realtime` changed between the tags; `scripts/verify_protocol_contract.sh --source <engine checkout at the tag>` must say byte-identical); the version in `Product.json`, `project.yml` and the linked `Info.plist` (`scripts/render_info_plist.sh`). Prove it with `scripts/check_product_config.sh`, then `scripts/fetch_engine.sh` and `scripts/verify_engine.sh` against the published release. Tag `vX.Y.Z` on the merge; the rail pauses at the `release-macos` environment for owner approval, then publishes the DMG, the cumulative `appcast.xml` and the cask file, and opens the tap's cask PR.
3. **Tap (`tezra-io/homebrew-tap`).** The formula bump comes from the engine rail; the cask bump is a PR the owner merges.
4. **Site (`tezra-io/fermix-site`).** A PR to `dev` copies the app release's `appcast.xml` over `public/appcast.xml`; the download and verify pages derive DMG link, size, checksum and cosign identity from it at build time, so nothing else changes. The owner deploys. Installed apps find the update only once the served feed (`https://fermix.ai/appcast.xml`, five-minute cache) carries it.

Always: never push to `main` without a PR; never push a tag the owner hasn't asked for; no AI attribution in commits, PRs, or docs; the app shows the *pinned* engine's version, so say "pinned", not "latest".

## Known Pitfalls
Each rule below has its incident write-up under the same title in `docs/lessons.md`; read that entry before working in the area. When the repo teaches the same lesson twice, add the write-up there and a one-line rule here.

- **Hermetic tests.** A test must never mutate or silently depend on host/global state; a computed-path delete once wiped a host. Never call `File.rm_rf`/`rm_rf!`/`rm`/`rm!` directly in `test/` (use `FermixTestSupport.SafeRm`); run anything that can reach `SecretWriter` against `FermixTestSupport.SecretWriterStub`; a test asserting a default must establish and restore its own app env, because umbrella `mix test` runs every app in ONE VM; a global handler's `assert_receive` must pin its own correlation id; a test that crosses a platform gate must inject the platform (`macos?: true`).
- **Feature flag vs environment gate.** Gate "should this run at all" on the compile-time env (`@compiled_env Mix.env()`), then let the flag decide within it. A runtime-config default must let an already-set compile-time value win, `config/test.exs` must pin the posture the suite asserts, and the base `config/config.exs` must not pin that key at all.
- **Gates and the world they inspect.** A gate must probe the world the work runs in (daemon tree, tree-less CLI, release boot, packaged standalone) and something guaranteed to exist at gate time. Pair every fail-closed branch with a first-run-on-a-fresh-machine test, keep failure kinds distinct, and give any CLI verb that inspects PATH, the process environment or the account's files a `scripts/release/verify_standalone.sh` step.
- **Env sanitizers and credential context.** Test what a sanitizer includes, not only what it excludes; detection and execution must share one environment constructor; resolve identity through `Harness.Identity` instead of making `USER` fatal everywhere; inherit credential-store context such as `CLAUDE_CONFIG_DIR`.
- **Plugin releases.** Releasing a plugin is a two-repo change and the catalog ships inside the binary: follow `fermix-plugins/plugins/README.md`, then regenerate `apps/fermix_core/priv/plugins/index.json` with `scripts/release/sync_plugin_catalog.py` — never hand-write pins. `runtime_kind` must be omitted, never `null`; a `remote_mcp` plugin cannot be developed through `dev_local`; `min_core_version` hides a plugin with no error.
- **Trace files.** A trace file is not a run: bucket `~/.fermix-dev/traces/<date>/*.jsonl` by run window before counting error kinds, and check whether the run itself caused a vendor refusal.
- **Long-lived state.** A defect in long-lived state is invisible to a fresh-process probe; reuse one process across the interval, because per-iteration setup re-establishes the very thing under test.
- **Failures the trace can't show.** A terminal status word is not a diagnosis: the vendor's own words must reach the continuation notice, the delivered message and the persisted ledger row. One model tool call is exactly one `[:fermix, :tool, :exec]` event, via `Tools.Telemetry.exec/5`, under the name the model used.
- **Whole feature surface.** Gate on the whole feature surface, not tool-by-tool: assert "**no** harness tool is advertised" over everything the seeder can register.
- **Validity gates.** A validity gate keys on what was delivered (a positive signal such as non-empty output), never on a missing protocol marker. Before turning a degraded path into a hard error, name the layer that recovers it; mint only provider-error kinds that have their own sentence.
- **Eval homes.** Eval homes are fresh `FERMIX_HOME`s, so every default-off consent gate blocks them silently: pre-grant every human-decision gate in `benchmark/bin/seed_capability_home.py`, and read the traces for a refusal or pending approval before believing an eval's 0.
- **Behavioral gates.** A gate that encodes wording, a weekday or a truncated id fails clean product. A `reply_matches` vocabulary is a hand-maintained allowlist that rots on every model or prompt change (it has twice): use `reply_not_matches` plus a phrasing-independent floor, and a rubric that states requirements the judge cannot invert. Fixtures need absolute dates, and a bounded id keeps its suffix and hashes its middle.
- **compux pairing.** compux and Fermix ship as a paired change, and the handshake refuses a `protocol_version` mismatch: move every ref and version string together, regenerate checksums through a PR, and match library and sidecar when testing an unreleased build.
- **The macOS app.** This engine is half of `tezra-io/fermix-macos`. A change to what the app shows is a change to the management or realtime export in the same commit (goldens, `PROTOCOL.md`, `Management.CopyTest`); a wire-shape change ships daemon-first under a method minimum; bundle identity is fixed, keychain items are named by profile and never by home, and sidecar pins name released tags.
- **macOS TCC identity.** Every process the daemon spawns inherits fermix as its macOS TCC "responsible process", and that identity churns every release: spawn through the `disclaim` exec shim, never an undisclaimed fallback, and keep the shim's strict build flags in lockstep between `apps/fermix_nif/Makefile` and ci.yml.
- **Config round-trips.** A config section that normalizes strings→atoms MUST ship the inverse (`to_keyword/1`), and the persist path must use it; prove it with a save→load round-trip test seeded with the normalized app-env shapes.
- **Default on.** A feature is not "default on" until it works after a fresh install AND a `brew upgrade` with zero new config: derive an operator value deterministically at acceptance time from config that already exists, visibly and snapshotted, with one resolver per concept.
- **Passthrough lists.** A global passthrough list resolved all-or-nothing is one stale entry away from disabling every command, and a shell export never reaches a service: resolve per name, report the misses, and carry `tool_failures` beside a run's `status`.
- **Replayed compile warnings.** Mix records a compile warning against its source and replays it forever ("the Inspect protocol has already been consolidated…"): read `_build/<env>/lib/<app>/.mix/compile.elixir` before theorising, clear it by changing one byte or with `mix compile --force`, and never loosen `warnings_as_errors`.
- **API plugin architecture.** Start an OAuth REST integration from the existing GitHub, Notion and X HTTP plugins, not from a hosted MCP template, and keep provider-specific helpers such as Tesla command signing apart from ordinary REST methods.
- **General-purpose prompt edits.** Keep task examples, sample replies and scripted jokes out of runtime prompts and use them only in evals; start prompt surgery with stale and duplicate instructions, and measure the net token change.
- **App-managed production configuration.** Production Fermix is managed through the macOS app, so never prescribe the `fermix` CLI for its setup or recovery; a sandbox env allowlist neither stores credentials nor imports shell exports into the launchd engine.
- **Completion proofs and the order a daemon opens its doors.** A daemon opens its doors in order (control socket 57-315 ms before the web endpoint), so every half of a completion proof polls — same interval, declared attempt cap, defined behaviour at the cap — and the halves share one budget rather than stacking one each. Never report a failure nobody tested: keep a floor of one attempt, and refuse on the spot only for a condition waiting cannot change. A retry needs a test that injects *n* failures then success, and one that never succeeds and asserts the bound. A component-to-caller boundary gets its own test: a writer returning `{:ok, output}` where callers match `:ok`, and a measured `:keyring_locked` falling into a mapping's catch-all as "unavailable", both passed every test of the component. An instrument that cannot fail proves nothing: measure the control under the same conditions as the change (a rig that came back clean on the unfixed build tested the rig, not the fix), and give every symbol or identity search a negative control, because a missing tool and a missing symbol look the same.
- **Caches keyed by a name.** Name a cache directory after a digest of what it holds, never after a version: Burrito's `<release>_erts-<erts>_<version>` made a same-version upgrade reuse the old engine forever, and `service status` hid it by taking both sides of its comparison from the binary that answered. A freshness comparison reads its two sides from two different places (package on disk vs. the running process). When the consumer reads its key from the environment before our code runs, exactly one launcher sets it for every entry point (unit *and* bare CLI), and the prune that digest-naming makes necessary ships in the same change — bounded, logged, never deleting the entry in use, and never on a path an ordinary CLI invocation takes.
- **Guards whose reason is elsewhere.** A line that prevents a failure carries its reason next to it, not only in a design doc: the vendor unit's separate payload root looked like redundant namespacing and was nearly deleted twice, when it exists because Burrito's wrapper deletes older sibling extractions on EVERY launch (wrapper.zig:110) — with one root, any `fermix` command during an upgrade would delete the running daemon's payload. Before removing a guard, reproduce the failure it was written against; a dependency's launch-time maintenance is part of your design.
