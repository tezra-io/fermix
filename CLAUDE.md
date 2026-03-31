# CLAUDE.md — Fermix

## Project Overview

Fermix is an Elixir-native multi-agent AI platform. Phoenix gateway, OTP-supervised agents, Rustler NIFs for crypto/tokenization only.

**Stack:** Elixir, Phoenix, OTP, Rustler, SQLite  
**Predecessor:** RustyClaw (Rust + Elixir hybrid — this replaces it with pure Elixir)

## Architecture

- **Umbrella app:** `fermix_core`, `fermix_channels`, `fermix_web`, `fermix_nif`
- **Gateway:** Phoenix (webhooks, REST API, WebSocket, LiveView dashboard)
- **Agents:** GenServer-based. Persistent Main Agent + ephemeral skill agents.
- **Providers:** Req-based HTTP clients for Anthropic, OpenAI, OpenRouter, Ollama
- **Tools:** Elixir behaviours — shell, file ops, git, memory, web, browser
- **Memory:** Three-tier (gist always in context, daily on demand, conversation compacting)
- **NIFs:** Rustler — HMAC-SHA256 verification and tiktoken token counting only

## Key Design Decisions

1. **No HTTP bridge.** Unlike RustyClaw, everything runs in one BEAM VM.
2. **Hub-and-spoke agents.** One persistent Main Agent, ephemeral skill agents spawned on demand.
3. **Elixir for everything except crypto/tokenization.** Req for HTTP, Jason for JSON, Ecto/SQLite for storage.
4. **Channels are just webhook controllers** — Phoenix handles routing, each channel module parses and sends.
5. **Agent loop is recursive** — LLM call → check tool calls → execute → loop until no more tool calls.

## Repo Structure

```
fermix/
├── apps/
│   ├── fermix_core/       # Agents, providers, tools, memory, security
│   ├── fermix_channels/   # Telegram, WhatsApp, Discord, Signal, etc.
│   ├── fermix_web/        # Phoenix: router, controllers, LiveView, channels
│   └── fermix_nif/        # Rustler: HMAC, tokenizer
├── config/                # Elixir config
├── docs/                  # PROJECT_PLAN.md, ARCHITECTURE.md
├── skills/                # Skill template files (YAML+MD)
└── journals/              # Skill execution logs
```

## Test-First Development (Mandatory)

Every feature follows TDD:
1. **Write failing tests first** — define what correct behavior looks like before writing production code
2. **Make the tests pass** — implement the minimum code to satisfy the tests
3. **Refactor** — clean up while tests stay green

If you can't articulate correct behavior as a test, the requirements aren't clear enough to build from. Stop and clarify.

"Write failing tests for this feature, then make them pass" — not "implement this feature."

## Code Quality Rules (Non-Negotiable)

1. **Keep it linear.** Max two levels of nesting. Flatten `with` chains. Push back on >2 nesting levels.
2. **Bound every loop.** Explicit max on every iteration — retries, polls, recursion. Define what happens at the cap.
3. **One function, one job.** 40-60 lines max. Describable in one sentence without "and."
4. **Know what you own.** Every resource opened gets closed — happy path AND error path. Use `try/after`.
5. **Narrow your state.** No module globals. Pass dependencies explicitly. Data lives close to its use.
6. **State your assumptions.** Guard clauses and input validation on every public function. Fail loudly.
7. **Never swallow errors.** No bare `rescue`. No `{:error, _} -> :ok`. Every failure logged, raised, or returned.
8. **Surface side effects.** I/O and mutations obvious at call site. Separate pure from effectful.
9. **One layer of magic.** Readable > elegant. If you can't trace what runs when you call it, simplify.
10. **Warnings are errors.** `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` must pass. Zero warnings.
11. **Read every line.** AI output is not peer-reviewed. Read it all — especially error paths and edge cases.
12. **Tests first.** Covered in TDD section above.

## Conventions

- **Formatting:** `mix format` — enforced, no exceptions
- **Testing:** `mix test` — write tests for all public functions, tests come BEFORE implementation
- **Dialyzer:** `mix dialyzer` — typespecs on all public functions
- **Credo:** `mix credo --strict` — static analysis
- **Naming:** snake_case for functions/variables, PascalCase for modules
- **Behaviours:** Use `@callback` for all plugin interfaces (providers, channels, tools, memory)
- **GenServer:** Always `use GenServer, restart: :transient` unless explicitly permanent
- **Error handling:** `{:ok, result} | {:error, reason}` tuples, not exceptions
- **Config:** Runtime config in `config/runtime.exs`, compile-time in `config/config.exs`

## Code Style

- Prefer pattern matching over conditionals
- Prefer `with` chains over nested `case`
- Keep GenServer callbacks thin — delegate to private functions
- No business logic in Phoenix controllers — delegate to core modules
- Pipe operator for data transformation chains
- Guard clauses over if/else

## Testing

```bash
mix test                    # All tests
mix test apps/fermix_core   # Core only
mix test --only integration # Integration tests (require external services)
```

## Running

```bash
mix deps.get
mix phx.server              # Start Phoenix + all apps
iex -S mix phx.server       # Interactive mode
```

## Key Files

- `docs/PROJECT_PLAN.md` — Full project plan with phases and effort estimates
- `apps/fermix_core/lib/fermix_core/agent_loop.ex` — Core LLM conversation loop
- `apps/fermix_core/lib/fermix_core/agents/` — Agent lifecycle (GenServers)
- `apps/fermix_core/lib/fermix_core/providers/` — LLM provider implementations
- `apps/fermix_core/lib/fermix_core/tools/` — Tool implementations
- `apps/fermix_web/lib/fermix_web/router.ex` — Phoenix routes

## Related Projects

- **RustyClaw** (`/Users/sujshe/projects/rustyclaw`) — Predecessor. Reference for channel protocols, tool implementations, provider APIs.
- **Axon** (`/Users/sujshe/projects/agent-mesh`) — Agent-to-agent mesh protocol. May integrate later.

## Common Tasks

### Add a new tool
1. Create `apps/fermix_core/lib/fermix_core/tools/my_tool.ex`
2. Implement `FermixCore.Tools.Tool` behaviour
3. Register in `FermixCore.Tools.Registry`
4. Add tests

### Add a new channel
1. Create `apps/fermix_channels/lib/fermix_channels/my_channel.ex`
2. Implement `FermixChannels.Channel` behaviour
3. Add webhook route in `apps/fermix_web/lib/fermix_web/router.ex`
4. Add controller action in `WebhookController`

### Add a new LLM provider
1. Create `apps/fermix_core/lib/fermix_core/providers/my_provider.ex`
2. Implement `FermixCore.Providers.Provider` behaviour
3. Register in provider config
