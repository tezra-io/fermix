# Fermix

## Project
Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

**Stack:** Elixir, Phoenix, OTP, Rustler, SQLite
**Predecessor:** RustyClaw (`/Users/sujshe/projects/rustyclaw`) — reference for channels, tools, providers

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
- `docs/MILESTONE_7_ADVANCED_TOOLS.md` — M7 design — keyless built-in tool catalog (file/git/web/delegate/skill_create), capability metadata + dynamic prompt summary, self-knowledge skill
- `docs/MILESTONE_7_1_CONVERSATION_LIFECYCLE.md` — M7.1 design (draft) — threshold-driven auto-compaction, channel command surface (`/compact`, `/new`, `/clear`, `/help`), per-channel command authorization
- `docs/MILESTONE_7_PLUS_PLUGGABLE_BACKENDS.md` — M7+ design (draft) — `Capability.Backend` behaviour, `[fermix_core.tools.<name>]` TOML, per-tool API-key wizard surface, `BuiltinSeeder.reseed/1`, `http_request` tool with `allowed_domains`
- `docs/MILESTONE_9_1_REALTIME_VOICE.md` — M9.1 design (shipped) — native macOS floating voice companion backed by OpenAI Realtime, daemon-owned tools/memory/traces, click-to-talk first, always-listening later
- `docs/MILESTONE_9_2_FULL_DUPLEX_VOICE.md` — M9.2 design (draft reviewed) — full-duplex cleanup for macOS AEC, Realtime API shape, setup prompts, and removed legacy voice mode knobs

## Known Pitfalls
- Update this section every time the repo teaches you the same lesson twice.

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
