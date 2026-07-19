# Fermix

## Project
Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

**Stack:** Elixir, Phoenix, OTP, Rustler, SQLite
**Predecessor:** RustyClaw — reference for channels, tools, providers

## Behavioral Guidance
- The approved design is the plan. Implement against it, do not quietly re-design the task mid-flight.
- Don't assume. State assumptions explicitly before coding. If multiple interpretations exist, surface them instead of picking silently.
- If the request or design is unclear, stop and ask. If repo reality conflicts with the design, surface the mismatch before coding.
- Prefer the simplest correct solution. No speculative abstractions, no extra flexibility, no "while I'm here" cleverness.
- Make surgical changes. Touch only what the request requires. Mention unrelated issues, don't fix them unless asked.
- For multi-step work, define success in `step -> verify` form and keep going until the checks pass.
- If 200 lines could be 50, rewrite it.

## Execution Contract
- If changing behavior, write or update a failing test first.
- Implement the smallest change that satisfies the design.
- Run the relevant repo commands below before calling the work done. Default expectation: typecheck or build, tests, and lint.
- For docs, config, or scaffolding changes, run the relevant checks and say what is not applicable.
- When a change adds, removes, or materially alters a feature, capability, tool, channel, provider, config surface, or CLI verb, update the `self_knowledge` skill (`apps/fermix_core/priv/skills/self_knowledge/SKILL.md`) in the same change. It is Fermix's runtime self-reference for explaining and fixing itself, and goes stale silently otherwise.
- When adding/altering a **tool, provider, or run-type**, route its telemetry through the shared emitters so it stays correlatable (and Opik-traceable) — tool events via `FermixCore.Tools.Telemetry.exec/5`, provider calls via `FermixCore.Providers.Telemetry.emit_call/3`; **never** hand-roll `:telemetry.execute([:fermix, :tool|provider, ...])`. A new run-type needs a unique `session_id` (+ `parent_session` if spawned) and lifecycle bookend events; a genuinely new event name/run-kind also needs a `FermixOpik` update (the in-umbrella `apps/fermix_opik`). See `docs/TELEMETRY_CONTRACT.md`.
- Never mark work done without proof.

## Code Rules (Non-Negotiable)

1. **Linear flow.** Max 2 nesting levels. Top to bottom.
2. **Bound loops.** Explicit max on retries, polls, recursion. Define cap behavior.
3. **Small functions.** 40-60 lines max. One job per function.
4. **Own resources.** Open → close on every path, including errors.
5. **Narrow state.** No module globals. Pass deps explicitly.
6. **Assert assumptions.** Guards and validation on every public function. Fail loud.
7. **Never swallow errors.** No bare `rescue`. No `{:error, _} -> :ok`. Log, raise, or return.
8. **Visible side effects.** I/O obvious at call site. Separate pure from effectful.
9. **Minimal indirection.** Readable > elegant. One layer of abstraction max.
10. **Surgical changes only.** Touch only what the request requires. Do not refactor adjacent code, comments, or formatting unless the task needs it. Remove only the dead code your change creates.
11. **Warnings = errors.** Linters, typecheckers, analyzers are hard gates. Zero warnings.
12. **No fallbacks.** One code path per behavior. Do not add a "fallback" branch that silently retries with a different mechanism, reads from a deprecated location, or degrades to a partially-working state when the primary path fails. Fallbacks double the surface area, hide which path actually ran, mask real failures behind "it kind of worked," and turn every bug into a five-branch investigation. The old flow is dead the moment the new flow ships — delete it; do not keep it as a safety net. If the primary path fails, fail loud at the boundary with a clear message and exit non-zero. Two valid configurations are fine (e.g., user-scope vs system-scope service); two paths to handle one configuration is not. If you think you need a fallback, you actually need (a) a clearer error message, (b) a single failure-recovery step for a destructive op (e.g., upgrade rollback — explicitly scoped, no user-facing chain), or (c) a different design that doesn't have the failure mode at all.

## Conventions
- `@callback` for all plugin interfaces (providers, channels, tools)
- `{:ok, result} | {:error, reason}` tuples, not exceptions
- GenServer callbacks thin — delegate to private functions
- No business logic in Phoenix controllers
- Typespecs on all public functions

## Commands
```sh
mix deps.get && mix compile
mix test
mix credo --strict
mix format --check-formatted
```

## Docs
- `docs/TELEMETRY_CONTRACT.md` — Telemetry/observability contract — how new tools/providers/run-types stay correlatable + Opik-traceable (shared emitters, `session_id`/`parent_session`, content gating, the `fermix_opik` rule)
- `docs/PROJECT_PLAN.md` — Full plan with phases
- `docs/PHASE1_TASKS.md` — 16 tasks with implementation code
- `docs/ROADMAP.md` — Post-MVP feature roadmap (M2-M9)
- `docs/MILESTONE_2_MULTI_AGENT_ORCHESTRATION.md` — M2 design (partially implemented)
- `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md` — M3 design (shipped)
- `docs/MILESTONE_4_ADVANCED_MEMORY.md` — M4 design (draft)
- `docs/MILESTONE_4_5_PROMPT_BOOTSTRAP_ARCHITECTURE.md` — M4.5 design (draft)
- `docs/MILESTONE_4_6_VERSIONED_PROMPT_RESOURCES.md` — M4.6 design (draft)
- `docs/MILESTONE_4_8_DISTRIBUTION.md` — M4.8 design (draft) — Burrito single-binary, OS daemon, native Codex OAuth, `fermix upgrade`
- `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md` — M4.9 design (shipped) — `Capability`/`Adapter` behaviours, `CapabilityRegistry`, MCP outbound
- `docs/MILESTONE_4_10_CODEX_PARITY.md` — M4.10 design (shipped) — Codex tool calls, provider/model/effort persistence, wizard step, doctor auth probe
- `docs/MILESTONE_4_11_SCHEDULED_AGENTS.md` — M4.11 design (draft) — cron jobs, persistent memory sources, isolated runs
- `docs/MILESTONE_4_12_INBOUND_MCP.md` — M4.12 design (draft) — Fermix as an MCP server (stdio + streamable HTTP), `[mcp.inbound]` config, policy-gated capability exposure, `fermix mcp serve`
- `docs/MILESTONE_4_13_ANUBIS_MIGRATION.md` — M4.13 design (shipped) — MCP dependency migration from Hermes to Anubis for outbound and inbound MCP surfaces
- `docs/MILESTONE_5_WORKSPACE_SANDBOX.md` — M5 design (shipped core) — workspace-rooted sandbox floor, modes (`strict`/`standard`/`open`), command profiles (`bare`/`assistant`/`extended`), hardline blocklist, `fermix grant` UX, env passthrough via `source = "command"` (no Fermix-owned keystore — defers to operator's OS helpers like `security`/`secret-tool`/`pass`/`op`), `SafeRm` test discipline
- `docs/POST_M5_PLAN.md` — Post-M5 plan (draft) — finishes M5's unshipped halves (wizard secret writer, `auth.json` perms refusal, doctor trace scan, deny-message audit, rename migration error) and unifies MCP env routing through `Sandbox.Env`
- `docs/MILESTONE_7_ADVANCED_TOOLS.md` — M7 design — keyless built-in tool catalog (file/git/web/delegate/skill_create), capability metadata + dynamic prompt summary, self-knowledge skill
- `docs/MILESTONE_7_1_CONVERSATION_LIFECYCLE.md` — M7.1 design (draft) — threshold-driven auto-compaction, channel command surface (`/compact`, `/new`, `/clear`, `/help`), per-channel command authorization
- `docs/MILESTONE_7_PLUS_PLUGGABLE_BACKENDS.md` — M7+ design (draft) — `Capability.Backend` behaviour, `[fermix_core.tools.<name>]` TOML, per-tool API-key wizard surface, `BuiltinSeeder.reseed/1`, `http_request` tool with `allowed_domains`
- `docs/design/MILESTONE_8_PLUGIN_DISTRIBUTION.md` — M8 design (draft) — external plugin distribution: plugins move to the `fermix-plugins` repo, two rails (declarative HTTP templates in-VM + MCP process via Anubis), signed lazy per-plugin tarballs (sha256 + cosign + h1), static bundled catalog, versioned store under `FERMIX_HOME/plugins`, Google-plugin migration out of core — §6 superseded by M8.1
- `docs/design/MILESTONE_8_1_STATIC_CATALOG_AND_FIRST_PLUGINS.md` — M8.1 design (draft) — static plugin catalog shipped in the fermix repo (no remote index/refresh), OAuth-first plugin auth, GitHub/Notion/Obsidian wave-1 plugins, fermix-plugins repo cleanup
- `docs/MILESTONE_9_1_REALTIME_VOICE.md` — M9.1 design (shipped) — native macOS floating voice companion backed by OpenAI Realtime, daemon-owned tools/memory/traces, click-to-talk first, always-listening later
- `docs/MILESTONE_9_2_FULL_DUPLEX_VOICE.md` — M9.2 design (draft reviewed) — full-duplex cleanup for macOS AEC, Realtime API shape, setup prompts, and removed legacy voice mode knobs
- `docs/MILESTONE_9_3_PET_ANIMATION.md` — M9.3 design (P0 shipped, P2 superseded by M9.4) — pure-SwiftUI animation pass for FermixPet: `TimelineView` sine motion, PNG cache, expression cross-fade, audio-RMS speaking pulse, blink, one-shot event reactions
- `docs/design/MILESTONE_9_4_PET_ANIMATED_ASSET_AND_DISTRIBUTION.md` — M9.4 design (draft) — FermixPet upgrade in three parts: Part A adopt-now animation set on the current PNG rig (blink from the idle face, per-layer motion, occlusion pause, one-shot reactions); Part B Rive `.riv` state-machine asset (format decision + artist commission spec + `PetRiveView`, gated on an integration spike, macOS 14 floor); Part C Developer ID → notarized drag-to-Applications DMG + Homebrew cask — §7.4's same-repo `pet-v*` assumption superseded by the extraction below
- **FermixPet moved to `tezra-io/fermix-macos`** (extraction implemented per `docs/design/FERMIXPET_REPO_EXTRACTION_AND_NOTARIZED_DISTRIBUTION.md`) — SwiftPM source under `Apps/FermixPet/`, notarized universal2 DMG + Homebrew cask via `fermixpet-v*` tags, pet design docs tracked in its `docs/design/`. The daemon side of the realtime wire contract stays here: `apps/fermix_core/lib/fermix_core/realtime/` with the canonical machine-readable export in `apps/fermix_core/priv/realtime/` (vendored checksum-pinned by fermix-macos; a wire change is a paired cross-repo change — daemon ships first, N/N-1 window)
- `docs/design/ANTHROPIC_XAI_PROVIDER_IMPLEMENTATION.md` — Anthropic + xAI provider design (draft) — API-key + OAuth auth modes (Claude Code / Grok subscription), Claude Code request emulation, provider touchpoint checklist
- `docs/design/SUBAGENT_MODEL_SELECTION.md` — Sub-agent & cron model selection (implemented) — a smaller/cheaper model + thinking level for delegated `subagents` workers (config + wizard + web setup + on-the-fly `subagents` `model` arg) and unpinned cron jobs (`[fermix_core.routing]` `subagent_*`/`cron_*`, validated by `Providers.RoutingOverrides`); main agent never changes its own model. §15 = implementation log
- `docs/design/MILESTONE_12_PROVIDER_EXPANSION.md` — M12 design (implemented) — OpenRouter + Ollama as first-class providers over the new `Providers.Descriptor` registry (replaces the ~25 hand-maintained provider lists), generic api-key/keyless resolver, `auth_mode :none`, ChatCompletions reuse + provider-attribution fix, fail-loud sweep for the silent unknown-provider traps; Gemini/Perplexity/Bedrock designed then descoped — §3.3 is the do-not-implement reference for a later wave. §16 = implementation log + deviations
- `docs/design/MILESTONE_19_IOS_COMPANION_APP.md` — M19 design (draft) — iOS companion app backend: `mobile` channel on a dedicated WSS listener (:4031, separate from the loopback web endpoint), Noise IK/IKpsk2 E2E with device pairing (`fermix pair` QR + interactive owner approval, `fermix devices list|revoke`), profile-keyed conversations (`{"mobile", profile_id, :root}`), chunked media + voice notes via the transcription pipeline, direct APNs with E2E payloads (NSE decrypt), LAN mDNS + Tailscale reachability, realtime-voice relay reserved for M19.1. App UX/wireframes in the companion `docs/design/MILESTONE_19_IOS_COMPANION_APP_UI.html`
- `docs/design/SOUL_SELF_CURATION.md` — Soul self-curation design (implemented) — owner-only `/soul review` drafts versioned `SOUL.md` persona edits via one bounded provider call (`SoulCuration.propose/2`, no tools/no writes, mirrors `Memory.Reviewer`); `:review` (subtle, change-budget-bounded) vs `:suggest` (instruction-driven); `--with-context` folds bounded owner-authored evidence (guests filtered); propose→token→`/soul apply` confirmation; `revert`/`reset` over the resource registry; injection markers surfaced on the diff; `[:fermix, :soul_curation, :run_*]` telemetry + `fermix_opik` soul_curation run-kind

## Known Pitfalls
- Update this section every time the repo teaches you the same lesson twice.
- **Test cleanup wiped the host (M5-shaped pass, 2026-04).** Codex generated a unit test whose `on_exit` hook called `File.rm_rf!(dir)` on a computed path; an empty interpolation collapsed `dir` to a root path and the host filesystem was wiped during `mix test`. **Rule:** never call `File.rm_rf` / `File.rm_rf!` / `File.rm` / `File.rm!` directly in `test/`. Route through `FermixCore.TestSupport.SafeRm.rm_rf!/1` (lands in M5 Stage 0), which hard-asserts the path is under a tmp prefix with ≥4 segments and no `..`. Sandbox tests must also never call `System.cmd` or `Port.open` — classify dangerous commands as strings via `Sandbox.classify/3`, never execute them. See `docs/MILESTONE_5_WORKSPACE_SANDBOX.md` §11.
- **Tests overwrote real keychain secrets (secure-on-save, 2026-06).** When secure-on-save landed, tests that persisted config snapshots with fixture secrets ran against the real macOS `security` writer (`-U` updates in place) and clobbered the operator's actual keyring entries (`fermix:OPENAI_API_KEY`, `fermix:TELEGRAM_BOT_TOKEN`) — silently green locally, 24 failures on writer-less Linux CI. **Rule:** any test that can reach `SecretWriter` must run against `FermixTestSupport.SecretWriterStub` — `config/test.exs` now sets it as the test-env default; never delete that default, and tests exercising the writer-less path override with `UnavailableSecretWriter`, not by removing the stub. Same family as the SafeRm rule: tests must never mutate host state (filesystem, keychain, real `FERMIX_HOME`).
- **Order-dependent test flake from leaked global app env (hermetic-config, 2026-06).** Two `async: false` tests asserted defaults that depend on global `Application` env they never established themselves, so an earlier module's leaked env flipped them — green locally, red on CI only under the right seed/`max_cases` (run 27104818459, seed 587472). `RouteResolverTest` "sane defaults" read `Config.provider/1` (global `:fermix_core, :providers`) and a leaked `anthropic: [auth_mode: "oauth"]` made the default resolve `:oauth` instead of `:api_key`; `Jobs.TelemetryTest` "run_start" `refute`d a captured `:input` but a leaked `:telemetry capture_content: true` attached it. **Rule:** a test asserting "the default when nothing is configured" or "X is NOT captured" must *establish* that precondition in its own `setup` (force `:providers`/`:agent`/`:telemetry` to the production baseline and restore on `on_exit`) — never assume the global env is clean. Reproduce these deterministically with a throwaway polluter module whose top-level `put_env` dirties app env before ExUnit runs. Same family as the SafeRm / keychain rules: tests must neither mutate nor silently depend on un-isolated host/global state.
- **No unnecessary env overlays.** Don't invent an env var to override a *setting* the config already owns — that's a fallback: a second code path that drifts from the config and rots when the config model evolves. If clean config-driven design covers it, that *is* the design. An env overlay is justified only for a secret or to gate a new feature behind a flag; everything else is a setting and lives in `config.toml`. (Rule #12, applied to config.)
- **Opik exported empty traces during `mix test` (env flag beat the env gate, 2026-06).** `FERMIX_OPIK_ENABLED=1` exported in the dev shell (needed for the daemon + eval skill) switched the exporter on inside `mix test`: the `only: [:dev, :prod]` dep gating in `fermix_core/mix.exs` only stops *fermix_core* from auto-starting opik, but `fermix_opik` is a **sibling umbrella app** whose `Application` still boots in `:test`, read the flag, attached the global telemetry `Reporter`, and POSTed every fixture's telemetry as near-empty traces. **Rule:** a feature flag is not an environment gate — an env-only switch can't tell `:dev`/`:prod` from `:test`. Gate "should this run at all" on the **compile-time env** (`@compiled_env Mix.env()`, release-safe), then let the flag decide within the allowed envs. Fixed in `8bc080f`: `FermixOpik.enabled?/0` is `@compiled_env != :test and enabled_by_flag?()`, so `mix test` never exports regardless of the flag. Same family as the host-state test rules: a test run must neither mutate nor export to live infra.
- **Bumping the `compux` dependency — update the git ref EVERYWHERE, not just `mix.exs`.** compux (the computer-use sidecar library) is pinned by git `ref:` in `apps/fermix_core/mix.exs`, and the sidecar download URL/version derives from the loaded compux app version (`Compux.Binary` builds `…/releases/download/v<vsn>/…`). When bumping it (e.g. 0.3.0 → 0.4.0), the ref lives in **more than one place** and a partial bump silently ships a mismatched sidecar: update `apps/fermix_core/mix.exs` (`ref:`), run `mix deps.get` so **`mix.lock`** re-pins to the same commit, and **grep the repo for the old ref/version** (`git grep <old-ref>` and `git grep 0.3.0`) — tests and comments reference the version (e.g. `sidecar_installer_test.exs`), and a new compux may change the cache layout (v0.4.0 moved the macOS binary into a signed `Fermix.app` bundle). Verify with `mix compile --warnings-as-errors` (compux API compatibility) + the `computer_use/` test dir before shipping. Prefer the release **tag commit** as the ref so the download URL resolves to a real published release.
- **Releasing a new `compux` version (the upstream half of the bump above) — the regular process.** compux (`tezra-io/compux`) and fermix ship as a **paired** change; the wire `protocol_version` pins them together and the handshake refuses a mismatch. Steps, in order: (1) in the compux repo bump the version in **both** `mix.exs` `@version` and `native/compux/Cargo.toml` (`cargo build` re-pins `Cargo.lock`), grep for the old version string (e.g. `binary_test.exs` format literals), and bump `PROTOCOL_VERSION` in **both** `native/compux/src/main.rs` and `lib/compux/protocol.ex` **only on a wire-incompatible change** (a new action counts); run `cargo test`/`clippy`/`fmt` + `mix test`/`credo --strict`/`format`. (2) **Push to `main` is safe** — `ci.yml` runs on push (tests only); `release.yml` fires **only** on a `v*.*.*` tag, so pushing does not cut a release. (3) **Tag `vX.Y.Z`** → `release.yml` builds + Developer-ID-signs + notarizes + staples the `Fermix.app` sidecar (the 7 Apple secrets already live on `tezra-io/compux`; signing is mandatory/fail-loud). (4) **Regenerate the checksum via a PR** (the regular process — see PRs #7/#9): `gh release download vX.Y.Z --repo tezra-io/compux --dir <dist> --pattern '*.tar.gz' --pattern '*.zip'`, then `mix compux.checksum --dir <dist>`, then commit `checksum-compux.exs` on a `chore/checksum-vX.Y.Z` branch and open a PR to `main`. Never hand-write it — it is per-artifact sha256 from the real signed bytes; stale/missing entries fail the download loud. (5) In fermix, pin `apps/fermix_core/mix.exs` compux `ref:` to that **checksum commit hash** (per the bump pitfall above) + `mix deps.get`. **Installed fermix is insulated** — it pins the old ref and downloads the old `v<vsn>` sidecar, so a new compux release never touches shipped users; only fermix builds whose ref you bump pick up the new protocol.
- **Testing an unreleased/new compux in a dev daemon — BOTH halves must be the same protocol or the handshake refuses (`{:protocol_mismatch, %{library, sidecar}}`).** (a) **Library** = the compiled-in `Compux.Protocol.protocol_version` → point fermix's compux dep at a local `path:` (or the new git `ref:`) + `mix deps.get`. (b) **Sidecar** = a *separate* resolution: **`SidecarInstaller` does NOT honor `COMPUX_BUILD`** (that flag is compux-standalone only) — Fermix resolves the sidecar from `[fermix_core.plugins] dev_local`, at `<dev_local>/computer_use_sidecar/bin/<target>/compux` (e.g. `macos-aarch64`; note underscores). So `cp native/compux/target/release/compux` into that path. A bare local build is **unsigned/ad-hoc**: it shows in Privacy settings as **`compux`** (not "Fermix") and **re-prompts TCC every run** because its cdhash churns and no `.app` bundle keys the grant — the persistent "Fermix" identity + sticky permission come **only** from the signed/notarized release build. Revert a `path:` dep before committing. When re-pinning to a new protocol, also **bump the test fake sidecar** `test/support`-style fixture (`fake_compux_sidecar.pl`'s default proto) or its handshake tests fail.

---
_Every mistake is a rule waiting to be written._

## Preserved Project-Specific Notes
These notes came from the previous `CLAUDE.md`. Keep the template above as the primary operating guide, and use the preserved context below where it is still relevant.

## Architecture
```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, tools, memory
├── apps/fermix_channels/   # Telegram (only channel implemented so far)
├── apps/fermix_web/        # Phoenix: webhooks, health, LiveView
└── apps/fermix_nif/        # Rustler: HMAC-SHA256, tiktoken
```

- One BEAM VM, no HTTP bridge. Everything is OTP-supervised.
- Persistent Main Agent (GenServer, `:permanent`) with single-flight per conversation
- Agent loop: LLM call → parse tool calls → execute → loop until done
- Providers via Req. Memory is in-memory (ConversationStore GenServer + ETS Store).

## Observability (Every Task)
Every component must emit structured traces. This is not optional.
- LLM calls → `:telemetry.execute([:fermix, :provider, :call], measurements, metadata)`
- Tool executions → `:telemetry.execute([:fermix, :tool, :exec], ...)`
- Channel messages → `:telemetry.execute([:fermix, :channel, :message], ...)`
- Agent lifecycle → `Trace.record(:agent_event, agent, data)`
- Errors → always traced before returning `{:error, reason}`

Traces write to `~/.fermix/traces/YYYY-MM-DD/` as JSONL. See `FermixCore.Trace`.
