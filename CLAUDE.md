# Fermix

Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, SQLite memory.

## Architecture
```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, tools, memory, sandbox, harness
├── apps/fermix_channels/   # Telegram, Slack, Discord, Signal, WhatsApp + gateway/dispatcher
├── apps/fermix_web/        # Phoenix: webhooks, health, LiveView, setup UI
├── apps/fermix_opik/       # Telemetry → Opik trace exporter
└── apps/fermix_nif/        # C NIF, one function: kill_pgid/2 (process-group kill)
```

- One BEAM VM, no HTTP bridge. Everything is OTP-supervised.
- Persistent Main Agent (GenServer, `:permanent`), single-flight per conversation.
- Agent loop: LLM call → parse tool calls → execute → loop until done.
- Providers over Req. Memory is SQLite (`FermixCore.Memory.Repo`, Exqlite) with an ETS/GenServer hot path.
- Predecessor: RustyClaw — reference for channels, tools, providers.

## Working Agreement
- The approved design is the plan. Implement against it; do not quietly re-design mid-flight.
- If repo reality conflicts with the design, or the request has multiple readings, surface the mismatch before coding.
- State assumptions explicitly rather than picking silently.

## Execution Contract
- If changing behavior, write or update a failing test first.
- Gates before calling work done: build, tests, lint. Say explicitly what is not applicable.
- Never mark work done without proof.
- When a change adds, removes, or materially alters a feature, capability, tool, channel, provider, config surface, or CLI verb, update the `self_knowledge` skill (`apps/fermix_core/priv/skills/self_knowledge/SKILL.md`) in the same change. It is Fermix's runtime self-reference and goes stale silently. Never put version numbers in it.
- **Telemetry is not optional.** Route through the shared emitters so events stay correlatable and Opik-traceable: tools via `FermixCore.Tools.Telemetry.exec/5`, provider calls via `FermixCore.Providers.Telemetry.emit_call/3`. **Never** hand-roll `:telemetry.execute([:fermix, :tool|provider, ...])`. A new run-type needs a unique `session_id` (+ `parent_session` if spawned) and lifecycle bookends; a genuinely new event name or run-kind also needs a `fermix_opik` update. Errors are traced before returning `{:error, reason}`. See `docs/TELEMETRY_CONTRACT.md`.
- **A user-facing capability ships with eval coverage, in the same change.** ExUnit proves the unit works; an eval proves the *model actually reaches it* through the real agent path, which is the half that silently rots. Do this without being asked.
  - **Behavioral** (`benchmark/suites/<name>.yaml`, `make regression`) is the default: real-user intent, the model picks the tool, route assertions only for safety plus one labelled sanity case. Vocabulary is `benchmark/suites/SCHEMA.md`.
  - **Capability** (`benchmark/suites/capability/*.yaml`, `make capability-auto`) is for ground-truth scoring, and only for `host_readonly`/`isolated_mutation` — the capability runner **refuses** `private_account_read`, `external_write`, `desktop_input`, and `destructive`.
  - **`risk:` is mandatory and its absence is silent.** A scenario with no risk becomes `unclassified`, and `run_eval.select/3` skips any scenario whose risk is not in the active profile — so the suite validates, reports nothing, and looks like it passed. (The capability runner refuses it loudly instead; do not rely on that asymmetry.)
  - **Pre-grant every human-decision gate in `benchmark/bin/seed_capability_home.py`** — see the eval-home pitfall below. A default-off consent gate turns a working feature into a suite of zeros.
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
10. **Surgical changes only.** Touch only what the request requires. Do not refactor adjacent code, comments, or formatting. Remove only the dead code your change creates. Mention unrelated issues; don't fix them unless asked.
11. **Warnings = errors.** Linters, typecheckers, analyzers are hard gates. Zero warnings.
12. **No fallbacks.** One code path per behavior. Never add a branch that silently retries with a different mechanism, reads a deprecated location, or degrades to partially-working when the primary path fails. Fallbacks hide which path ran, mask failures behind "it kind of worked," and turn every bug into a five-branch investigation. The old flow is dead the moment the new flow ships — delete it. If the primary path fails, fail loud at the boundary and exit non-zero. Two valid *configurations* are fine (user-scope vs system-scope service); two paths for one configuration is not. If you think you need a fallback, you need (a) a clearer error message, (b) a single scoped recovery step for a destructive op (e.g. upgrade rollback), or (c) a design without the failure mode.
    - **Corollary — no env overlays.** Never invent an env var to override a *setting* the config already owns; that is a second code path that drifts and rots. An env overlay is justified only for a secret or a feature flag. Everything else lives in `config.toml`.

## Conventions
- `@callback` for all plugin interfaces (providers, channels, tools).
- `{:ok, result} | {:error, reason}` tuples, not exceptions.
- GenServer callbacks thin — delegate to private functions.
- No business logic in Phoenix controllers.
- Typespecs on all public functions.

## Docs
Design docs live in **`docs/design/`** — one file per milestone/feature, named for its subject. List the directory and read the relevant file; do not assume a doc's status from its name (many are drafts, some are gitignored). `docs/TELEMETRY_CONTRACT.md` is the one contract doc outside that directory.

## Known Pitfalls
Update this section every time the repo teaches you the same lesson twice. Every mistake is a rule waiting to be written.

**Tests must never mutate or silently depend on host/global state.** Three incidents, one family:
- *A test wiped the host filesystem* (2026-04) — an `on_exit` called `File.rm_rf!(dir)` where an empty interpolation collapsed `dir` to a root path. **Never** call `File.rm_rf`/`rm_rf!`/`rm`/`rm!` directly in `test/`; route through `FermixTestSupport.SafeRm` (hard-asserts a tmp prefix, ≥4 segments, no `..`). Production counterpart for the plugin store: `FermixCore.Plugins.Dist.SafeRm`. Sandbox tests must also never call `System.cmd` or `Port.open` — classify dangerous commands as strings via `Sandbox.classify/3`.
- *Tests clobbered the operator's real keychain* (2026-06) — fixture secrets hit the real macOS `security` writer (`-U` updates in place), green locally, 24 failures on writer-less Linux CI. Anything that can reach `SecretWriter` must run against `FermixTestSupport.SecretWriterStub` (the `config/test.exs` default — never delete it). Tests for the writer-less path override with `UnavailableSecretWriter`, not by removing the stub.
- *Order-dependent flake from leaked app env* (2026-06) — tests asserting "the default when nothing is configured" or "X is NOT captured" read global `Application` env an earlier module had dirtied. Such a test must **establish** its precondition in its own `setup` and restore in `on_exit`. Reproduce deterministically with a throwaway polluter module that `put_env`s at compile time.

**A feature flag is not an environment gate.** `FERMIX_OPIK_ENABLED=1` in the dev shell switched the exporter on inside `mix test` and POSTed every fixture as a near-empty trace — `only: [:dev, :prod]` dep gating doesn't stop a *sibling umbrella app* from booting. Gate "should this run at all" on the compile-time env (`@compiled_env Mix.env()`, release-safe), then let the flag decide within allowed envs. See `FermixOpik.enabled?/0`.

**A gate that inspects a different world than the work runs in is not a gate.** Two incidents in the same function:
- `Harness.Artifacts.admission_check` probed free space with `df` on a directory that `Artifacts.prepare` creates *after* admission — so on a fresh home the probe failed, admission refused, the directory was never created, and the first harness run on every machine was refused forever. A gate must probe something guaranteed to exist at gate time (`existing_ancestor/1`). Pair every fail-closed branch with a first-run-on-a-fresh-machine test, and keep distinct failure kinds distinct (`:quota_exceeded`/`:below_min_free`/`:free_space_unknown` all rendering as "quota full" sent everyone chasing a phantom).
- The same probe spawned through `CommandHost`, but `fermix doctor` is a **tree-less CLI verb** where `resolve_supervisor!/1` raises — so the one command that explains a broken install died with a stacktrace and zero output on every host. Every test injected `quota:`, and `mix test` boots the tree, so the path was structurally unreachable from ExUnit. When correctness depends on *which* world the call site runs in (daemon tree / tree-less CLI / release boot), the test must reproduce that world. A sibling call site that already got it right is the strongest review signal — `Checks.harness/1` passed `supervised: false` five lines above and the probe didn't.

**Env sanitizers, credential context, and OS-blind requirements** (harness, 2026-07-26):
- *Test what a sanitizer INCLUDES, not just what it excludes.* `Harness.Env` spawned vendors under `env -i HOME/PATH/TERM`; the test proved no secret leaked but never that the child could still authenticate. Claude Code reads its Keychain item under account `$USER`; wiped, it read an empty account and died with "Not logged in" in ~2s. Every env-sanitizer test needs a **fidelity** assertion paired with its non-leak assertion. Stub CLIs need no identity, so a fake-vendor test is structurally incapable of catching this — the missing coverage is a real-child env dump.
- *Detection and execution must share one environment constructor.* `Vendors` probed with the daemon's own env while runs spawned under `env -i`, so readiness could never observe the missing variable and `fermix doctor` stayed green.
- *Make the value resolvable; don't make its absence fatal everywhere.* Hard-requiring `USER` fixed macOS and broke Linux, where Claude Code has no platform branch, no libsecret, and falls back to `$HOME/.claude/.credentials.json` — `USER` is a no-op there, yet bare containers don't set it, so every run refused (including codex, which never wanted it). `Harness.Identity` reads `$USER`, else `id -un` (`getpwuid(geteuid())`), and refuses only when neither answers. Never consult `LOGNAME` or `Path.basename(home)` — both can name a *different* account, and a wrong account yields a healthy CLI reporting "not logged in." `System.user_home!()` is not an independent source: it re-reads `$HOME` and raises without it.
- *Inherit credential-store CONTEXT, not just identity.* `CLAUDE_CONFIG_DIR` re-keys the Keychain service (`Claude Code-credentials-<sha256(dir)[0..8]>`); a child that can't see it reads an empty store. Resolve that context (Fermix key → daemon env → vendor default) and have detection read the same resolver.

**Releasing a plugin is a two-repo change, and the catalog ships INSIDE the binary.** The procedure lives in `fermix-plugins/plugins/README.md` § *Releasing a plugin* and is the authority — bump `version` + `CHANGELOG.md`, PR to `main`, tag `<name>/v<version>` (must equal the manifest version), then regenerate fermix's `apps/fermix_core/priv/plugins/index.json` with `scripts/release/sync_plugin_catalog.py` and land it as a normal PR. Do not hand-write catalog pins; the script downloads every artifact, checks its sha256, and cosign-verifies it against the release-workflow identity, failing the whole run rather than writing a bad pin. What that README does not yet say, learned the hard way (2026-08-03):
- *A `remote_mcp` plugin cannot be developed through `dev_local` at all.* The provenance gate refuses an unsigned remote manifest (`:unverified_remote_runtime`), because a remote manifest binds a live credential to an endpoint with nothing vouching for it. The author loop for a remote plugin is release-then-install, not edit-in-place. The refusal excludes that one plugin rather than failing the registry, so the symptom is "my plugin vanished", not an error.
- *`runtime_kind` must be OMITTED, never `null`.* `Index.parse/1` tolerates an absent key (entries published before the field existed) but throws `{:invalid_plugin_entry, nil}` on a present-and-null one — which takes down the **entire catalog**, not the one entry. The field is derived from the manifest's `runtime.kind`, and it is what picks the pre-install consent sentence: with it missing, a hosted plugin renders the *local-process* line and tells the operator it runs on their machine while it ships their content to a vendor.
- *The installed `fermix` binary carries a stale baked-in catalog.* There is no remote index and no refresh, so a freshly synced `index.json` is only visible to a daemon run **from source**. Testing an install against the binary will silently use the old catalog.
- *`min_core_version` gates installability* — set it above the core you are installing into and the plugin is simply never offered, with no error.

**A trace file is not a run — split it before you believe any error distribution.** `~/.fermix-dev/traces/<date>/*.jsonl` accumulates *every* run that day. Counting error kinds across the whole file mixed a 01:20 run with a 22:04 one and produced two confidently wrong diagnoses in a row (first "it's all credits", then "no, connection closes outnumber credits" — the closes were entirely in the other run). Bucket by run window first, then count; a tool that both succeeded 24× and failed 10× in the same file is the tell that you are reading two populations. And when a vendor refusal looks like a standing account condition, check whether the run *caused* it: 49 metered calls succeeded and then everything after 22:07:50 refused, which is a cliff the suite walked off, not a precondition it started from.

**A defect in long-lived state is invisible to a fresh-process probe.** Eden sessions expire server-side, and `Session` classified the 404 but never renewed — so a daemon up since yesterday failed *every* Eden call with `:session_expired`. The probe written to look for it opened a new `Owner` per iteration and reported a healthy connection at 70s idle, because expiry is a property of the MCP **session**, not the socket. When the suspected fault is "it rots over hours," the probe must reuse one process across the interval; per-iteration setup silently re-establishes the very thing under test. Related: MCP 2025-06-18 *requires* the 404→re-initialize recovery, so this was a spec gap, not a hardening idea.

**A failure the trace can't show is a failure nobody can diagnose.**
- *Quote the vendor's own words.* An auth error was captured in `events.jsonl` then discarded four times (`record_diagnostic` fires only for non-JSON lines; `result.txt` persisted only on `"completed"`; both `Continuation.body/2` and `Delivery.failed_body/1` used `result_text` only for completed runs). The agent saw a bare `reason: exit_1`, blind-retried into the same wall, and fabricated a codex failure that never happened. A terminal status word is not a diagnosis — vendor text must reach the continuation notice *and* the delivered message, and be persisted so the durable retry (which sees only the ledger row) can recover it.
- *One model tool call = exactly one `[:fermix, :tool, :exec]` event*, recorded under the name the **model** used (the only name a reader can search for), routed through `Tools.Telemetry.exec/5`. `AgentLoop` returned "Tool not found"/"not available"/parse errors emitting nothing, so two iterations spent guessing withdrawn tool names left no tool row anywhere. Keep the three miss kinds distinctly messaged.

**Gate on the whole feature surface, not tool-by-tool.** The harness `approved` test asserted "all three run tools are hidden," and passed while four other harness tools gated on `enabled` alone — an unapproved host advertised tools whose entire prompt category `RuntimeSections` had dropped. Write the invariant as "**no** harness tool is advertised" and loop over everything the seeder can register, so a tool added later either joins the invariant or fails the test.

**A validity gate keys on what was DELIVERED, not on whether the protocol finished tidily.** A Codex 200 whose SSE stream ended before `response.completed` yielded `output: []` + `usage: %{}`, which `ResponsesShared.build_turn/5` renders as a *successful empty turn* — 72 silent ones over three months. But rejecting any non-`completed` status is also wrong: `items` fill from `response.output_item.added/.done`, independent of the terminal event, so a cut stream can still carry real content (3 of the 72 did). Require a **positive** delivery signal (non-empty output); never infer failure from a missing protocol marker. Two corollaries: before turning a degraded path into a hard error, name the layer that will recover it — `AgentLoop.continue_with_retry/3` runs `eligible?: fn _ -> false end` with `retryable?: &Transient.pre_response_timeout?/1`, and `Jobs.Runner` refuses to retry once tools have started, so "retryable" is a property of the *call site*, not the error. And a bespoke reason atom on `ProviderError.transport/4` falls to `TurnRunner.provider_error_reply/1`'s catch-all, which shows operators raw `inspect(reason)` — only kinds with their own sentence (`:timeout`, `:transport_closed`) are safe to mint.

**Eval homes are fresh `FERMIX_HOME`s, so every default-off consent gate blocks them silently.** The capability home (`benchmark/bin/seed_capability_home.py`, regenerated on every `capability-daemon.sh up` — hand edits do not survive) carried no `[fermix_core.harness]`, so `approved` defaulted false while `enabled` defaulted true: tools were advertised, the model delegated, and every run stalled on an interactive prompt no eval can answer. Five tasks scored 0 with nothing wrong in the product. Pre-grant every human-decision gate in the seeder. When an eval scores 0, read the traces before believing the model failed — check for a refusal or pending approval first. Related: a delegation-steering prompt change silently re-routes *existing* eval tasks, so a suite that ranks the model must tell the task not to delegate.

**compux (computer-use sidecar) and Fermix ship as a paired change** — the wire `protocol_version` pins them and the handshake refuses a mismatch.
- *Bumping the dep here:* the ref lives in more than one place and a partial bump silently ships a mismatched sidecar. Update `apps/fermix_core/mix.exs` `ref:`, run `mix deps.get` so `mix.lock` re-pins, then `git grep` the old ref **and** the old version string (tests and comments hardcode it). Prefer the release tag commit so the download URL resolves. Verify with `mix compile --warnings-as-errors` plus the `computer_use/` tests.
- *Releasing upstream (`tezra-io/compux`):* bump `mix.exs` `@version` **and** `native/compux/Cargo.toml`; grep the old version string; bump `PROTOCOL_VERSION` in **both** `native/compux/src/main.rs` and `lib/compux/protocol.ex` only on a wire-incompatible change (a new action counts). Push to `main` is safe — `release.yml` fires only on a `v*.*.*` tag. Tag → signed/notarized `Fermix.app` sidecar. Then regenerate checksums **via a PR**: `gh release download`, `mix compux.checksum --dir <dist>`, commit `checksum-compux.exs`. Never hand-write it. Finally pin fermix's `ref:` to that checksum commit. Installed fermix is insulated — it pins the old ref and downloads the old sidecar.
- *Testing an unreleased compux locally:* both halves must match or you get `{:protocol_mismatch, ...}`. The **library** comes from the dep (`path:` or new `ref:`); the **sidecar** is resolved separately — `SidecarInstaller` does **not** honor `COMPUX_BUILD` — from `[fermix_core.plugins] dev_local` at `<dev_local>/computer_use_sidecar/bin/<target>/compux` (e.g. `macos-aarch64`, underscores). A bare local build is unsigned: it shows in Privacy settings as `compux`, not "Fermix", and re-prompts TCC every run because its cdhash churns. Revert a `path:` dep before committing, and bump the fake sidecar fixture's default proto (`fake_compux_sidecar.pl`).

**FermixPet lives in `tezra-io/fermix-macos`, not this repo.** This repo owns only the daemon side of the realtime wire: `apps/fermix_core/lib/fermix_core/realtime/` plus the canonical export in `apps/fermix_core/priv/realtime/` (`PROTOCOL.md`, `protocol.schema.json`, golden `fixtures/`), pinned together by `protocol_contract_test.exs`.
- *A wire change is a paired cross-repo change and the daemon ships FIRST (N/N-1 window).* Bump `realtime/protocol.ex` `@protocol_version` (+ `@min_supported_version`) only on a wire-shape change, update the export, release the daemon, *then* re-vendor the checksum-pinned export in fermix-macos and cut a `fermixpet-v*` release. The hello-first handshake refuses out-of-window clients — never widen the window without the N-1 support actually present.
- *The tag IS the version.* There is no in-repo version file; `release-fermixpet.yml` derives version from the `fermixpet-vX.Y.Z` tag and build number from the run number. It builds universal2, signs/notarizes/staples the DMG, cosign-signs, cuts a Release, smoke-installs the cask, then opens a PR on `tezra-io/homebrew-tap` (skips loudly without `HOMEBREW_TAP_TOKEN`).
- *Upgrades do not auto-resolve — tell users.* The cask installs to `/Applications`; an older self-signed build in `~/Applications` shares bundle id `io.tezra.FermixPet` and the two fight over the Microphone TCC grant. Upgraders must delete the old copy and `tccutil reset Microphone io.tezra.FermixPet`. A GUI/cask launch inherits no shell env and always targets `~/.fermix/realtime.sock`; point it elsewhere with `open --env FERMIX_HOME=… -a FermixPet`.

**A feature is not "default on" until it works after a fresh install AND a `brew upgrade` with zero new config.** `brew upgrade` swaps the binary and never touches `config.toml`, and upgraders never re-run setup — so a wizard-seeded key reaches nobody who already installed. M30 shipped reminders default-on but hard-required `[fermix_core.jobs] default_delivery_target`, which neither install path provides: every upgrader's first "remind me…" refused, while M26 (same week) derived the owner's inbox from the configured channel owner — two subsystems answering "where is the owner's inbox" differently was the tell. Rule for any new feature that needs an operator value: derive it deterministically at acceptance time from config that already exists (visibly — the acknowledgment names the derived choice so the owner can correct it; snapshot it, never re-resolve per use), or don't advertise the surface until the value exists. A loud first-use error is a last resort, not a posture. One concept, one resolver — shared by every subsystem that needs the answer.
