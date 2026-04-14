# Fermix

## Project
Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

**Stack:** Elixir, Phoenix, OTP, Rustler, SQLite
**Predecessor:** RustyClaw (`/Users/sujshe/projects/rustyclaw`) — reference for channels, tools, providers

## How to Work

### Planning
- Plan mode for any non-trivial task (3+ steps or architectural decisions)
- Detailed specs upfront — good plan = 1-shot implementation
- State assumptions explicitly before coding. If multiple interpretations exist, surface them instead of picking silently.
- If the request is ambiguous, ask. If a simpler approach exists, say so.
- For multi-step work, write a short plan in `step -> verify` form.
- If something goes sideways, STOP and re-plan

### Test-First (Mandatory)
1. Write failing tests that define correct behavior
2. Make them pass
3. Refactor while green

"Write failing tests, then make them pass" — not "implement this feature."

### Verification
1. Write failing tests
2. Implement to pass them
3. Typecheck: `mix compile --warnings-as-errors`
4. Full test suite: `mix test`
5. Lint: `mix credo --strict`

Never mark done without proving it works.

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
- `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md` — M3 design (draft)

## Don'ts
- Don't commit without running tests
- Don't implement without failing tests first
- Don't add abstractions you weren't asked for
- Don't silently choose among ambiguous interpretations
- Don't improve adjacent code that wasn't part of the request
- Don't assume intent on ambiguous bugs — ask

## Principles
- Simplest correct solution
- If 200 lines could be 50, rewrite it
- Find root causes, no band-aids
- Minimal blast radius
- Own mistakes — write a rule to prevent repeating

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
