# CLAUDE.md — Fermix

## Project

Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

**Stack:** Elixir, Phoenix, OTP, Rustler, SQLite
**Predecessor:** RustyClaw (`/Users/sujshe/projects/rustyclaw`) — reference for channels, tools, providers

## Architecture

```
fermix/ (umbrella)
├── apps/fermix_core/       # Agents, providers, tools, memory, security
├── apps/fermix_channels/   # Telegram, WhatsApp, Discord, Signal
├── apps/fermix_web/        # Phoenix: webhooks, REST, WebSocket, LiveView
└── apps/fermix_nif/        # Rustler: HMAC-SHA256, tiktoken
```

- One BEAM VM, no HTTP bridge. Everything is OTP-supervised.
- Persistent Main Agent (GenServer, `:permanent`) + ephemeral skill agents (`:temporary`)
- Agent loop: LLM call → parse tool calls → execute → loop until done
- Providers via Req. Channels are webhook controllers. Memory is three-tier.

## Test-First (Mandatory)

1. Write failing tests that define correct behavior
2. Make them pass
3. Refactor while green

"Write failing tests, then make them pass" — not "implement this feature."

## Code Rules

1. **Linear flow.** Max 2 nesting levels. Top to bottom.
2. **Bound loops.** Explicit max on retries, polls, recursion. Define the cap behavior.
3. **Small functions.** 40-60 lines max. One job per function.
4. **Own your resources.** Open → close on every path, including errors. `try/after`.
5. **Narrow state.** No module globals. Pass deps explicitly.
6. **Assert assumptions.** Guards and validation on every public function. Fail loud.
7. **Never swallow errors.** No bare `rescue`. No `{:error, _} -> :ok`. Log, raise, or return.
8. **Visible side effects.** I/O obvious at call site. Separate pure from effectful.
9. **Minimal indirection.** Readable > elegant. One layer of abstraction.
10. **Warnings = errors.** `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` must pass.

## Conventions

- `@callback` for all plugin interfaces (providers, channels, tools)
- `{:ok, result} | {:error, reason}` tuples, not exceptions
- GenServer callbacks thin — delegate to private functions
- No business logic in Phoenix controllers
- Typespecs on all public functions

## Commands

```sh
mix test                          # All tests
mix format --check-formatted      # Format check
mix credo --strict                # Static analysis
mix dialyzer                      # Type checking
mix phx.server                    # Run
```

## Key Docs

- `docs/PROJECT_PLAN.md` — Full plan with phases
- `docs/PHASE1_TASKS.md` — 16 tasks with implementation code
- `docs/ROADMAP.md` — Post-MVP feature roadmap
