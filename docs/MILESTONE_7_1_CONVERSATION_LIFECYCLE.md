# Milestone 7.1: Conversation Lifecycle — Threshold Compaction & Channel Commands

**Status:** Draft (rev 2 — incorporates code-grounded review)
**Date:** 2026-05-09
**Author:** Sujeeth / Aira
**Depends on:** M4 (`Memory.Compactor`, `Memory.ConversationStore`), M4.10 (`Providers.ModelCatalog`, `Setup.ConfigStore` round-trip pattern), M4.11 (source-aware memory shape — `/new` must respect job conversation keys)
**Blocks:** none directly; informs M9 (self-knowledge agent) and M10 (governance) since both extend the command surface this milestone introduces
**References:** `apps/fermix_core/lib/fermix_core/memory/compactor.ex`, `apps/fermix_core/lib/fermix_core/memory/conversation_store.ex`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/providers/model_catalog.ex`, `apps/fermix_core/lib/fermix_core/setup/config_store.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_channels/lib/fermix_channels/cli.ex`

---

## 1. Problem / Goal

Two related gaps emerge in real Telegram/Discord usage of Fermix today:

1. **No bounded growth on conversation context.** `Memory.Compactor.compact/2` works (`compactor.ex:24`) but only runs when the agent loop opts into it via `:enabled` and a fixed `:token_budget` from `Memory.Config`. There is no auto-trigger keyed to the model's context window. Long Telegram threads grow without bound until the provider returns a context-overflow error.

2. **No way for end-users to reset or force-summarize a conversation from the channel.** Channels (`telegram.ex`, `discord.ex`, `slack.ex`, `whatsapp.ex`, `cli.ex`) all forward every inbound message to `MainAgent.handle_message/2` as raw user content via `Dispatcher.dispatch/2`. There is no command surface — every `/anything` is fed to the LLM. Operators have no way to say "start fresh here" or "summarize and continue" without restarting the daemon.

**Goal of M7.1:** add a configurable context-window utilization threshold that triggers auto-compaction, plus a unified channel command surface that recognizes `/compact`, `/new`, `/clear`, and `/help` *before* the inbound message reaches `MainAgent`. The threshold needs a per-model context-window number and a config key. The commands need a parser, a dispatcher hook (in `FermixChannels.Dispatcher`, not per-adapter), an authorization model keyed on stable channel sender ids, and a wipe path that clears `ConversationStore` history.

After this milestone:

1. Operators can set `compaction.threshold = 0.85` in `~/.fermix/config.toml`. After every `MainAgent` turn, the daemon checks `tokens_used / model_context_window` against the threshold and runs `Compactor.compact/2` for the conversation key when it crosses. No user action required; emits `[:fermix, :compaction, :auto]` telemetry on each trigger.
2. End-users can type `/compact` in any chat to force-immediate summarization, `/new` (alias `/clear`) to wipe the conversation history for that conversation key, and `/help` to discover available commands. Replies are sent back through the same channel transport.
3. The channel-command intercept lives in **one place — `FermixChannels.Dispatcher`** — after transcription and normalization, before agent delivery. Adding a future command (e.g., `/skills` from M9, `/approve` from M10) is one new handler module; no per-channel changes.
4. Authorization is per-channel: each channel has an owner user id (`[fermix_channels.<channel>.owner_user_id]`) plus optional advanced allowlists. `cli` channel is implicit-owner (operator on the box). A single configured ingress allowlist entry can act as the command owner for compatibility; multiple allowed users require an explicit owner or command allowlist.

**What `/new` does and does not touch:**

- **Touches:** `ConversationStore` history for `{channel, chat_id, thread_scope}`.
- **Does not touch:** durable memory (Hermes-extracted facts, Tier 1 gist, resource registry, scheduled jobs). User identity, preferences, and stored facts persist across `/new`. True user-scope wipe ("forget me everywhere") is M10's privacy/governance scope.

**Cross-turn provider state.** Today neither `MainAgent` nor `AgentLoop` persists provider state across turns. `AgentLoop` carries `provider_state` only inside an in-flight tool-call loop (`agent_loop.ex:191`) and discards it on return (`agent_loop.ex:46`). MainAgent's per-conversation map (`main_agent.ex:75`) only tracks `{next_request_id, active, pending}` for single-flight scheduling — no `prior_input`, no `previous_response_id`. So this milestone has nothing to "reset" on Codex's side. If a future milestone adds persisted cross-turn provider state, that milestone owns the reset path.

**Non-goal:** native per-channel slash-command APIs (Telegram BotFather command list, Slack `/commands` registration, Discord application commands). v1 ships plain text `/cmd` parsing on inbound content; rich slash-command-API integration per channel is M7.1+1.

**Non-goal:** mid-turn compaction. Auto-compaction triggers *between* turns (after one completes, before the next starts).

**Non-goal:** compaction across channels for the same user. Each `conversation_key` (`{channel, chat_id, thread_scope}`) tracks its own threshold and its own compaction state.

---

## 2. References

- **Existing Fermix code:**
  - `apps/fermix_core/lib/fermix_core/memory/compactor.ex` — `compact/2`, `estimate_tokens/1`. Note: `summary_for/3` currently calls the legacy `Keyword.get(opts, :provider, OpenAI).chat(...)` (`compactor.ex:94-98`); §4.10 swaps this for the M4.10 adapter route so compaction follows the agent's configured provider+model.
  - `apps/fermix_core/lib/fermix_core/memory/conversation_store.ex` — `clear/2` exists; this milestone adds `replace_history/3`.
  - `apps/fermix_core/lib/fermix_core/agents/main_agent.ex:497-571` — `process_message/2` → `run_message_loop/2`. The request task runs the loop, writes both user and assistant rows to `ConversationStore`, calls `deliver_reply`, and starts memory extraction — all *inside the task*. The GenServer only sees `:DOWN` (`main_agent.ex:257`). Auto-compaction must therefore run **inside the task**, not from a GenServer `handle_info` hook.
  - `apps/fermix_core/lib/fermix_core/providers/model_catalog.ex` — extends with `context_window_for/2` (M4.10 introduced the catalog for routing).
  - `apps/fermix_core/lib/fermix_core/setup/config_store.ex` — `parse_value/1` and `encode_value/1` cover booleans/integers/quoted strings/lists only (`config_store.ex:360-376, 441-463`); this milestone adds float clauses. `current_snapshot/0`, `apply_snapshot/1`, `persistable_snapshot/1`, `dump_snapshot/1`, `parse_document/1`, and `empty_runtime_config/0` all need a new `:compaction` branch (mirror the `:routing` branch at `config_store.ex:70, 116, 247, 334`).
  - `apps/fermix_channels/lib/fermix_channels/dispatcher.ex:79-113` — `dispatch_message/6` runs `maybe_transcribe_message`, normalizes, builds `reply_fn` (honoring `reply_fn_override`), then calls `agent.handle_message`. The command intercept slots in *after* normalization and `build_reply_fn`, *before* `agent.handle_message`. This is the only correct boundary: it serves every channel uniformly and preserves the `fermix ask` sync-reply path (`cli.ex:65-86`) without per-channel duplication.
  - Per-channel `parse_*` functions populate `metadata`. This milestone standardizes two metadata fields: `chat_type` (already set by `telegram.ex:314` and `slack.ex:151`) and `user_id` (a stable channel-native sender id, distinct from the display-name `Message.sender`). Each channel adds the missing field in its own `parse_*`.

- **Hermes-agent:** `~/projects/hermes-agent/agent/compaction.py` ships a similar threshold trigger (default 0.85) wired into the agent loop. Adopt the **threshold semantics** (`tokens_used / context_window >= threshold`) and the **post-turn placement**.

- **OpenClaw:** `/help`, `/clear`, `/compact` slash commands. Adopt the **command names** and the **silent fail-soft for unknown `/cmd`** (treat `/unknown ...` as raw user content — never error, since users frequently send `/x` strings to the LLM that aren't commands).

---

## 3. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---|---|---|---|
| `ModelCatalog.context_window_for/2` | P0 | Modify | Add per-model `max_input_tokens` to `ModelCatalog` entries. Catalog updates ship in code, not config. Fallback: `:unknown` model id returns a safe default (100k) and emits a `[:fermix, :model_catalog, :unknown_model]` telemetry event. |
| `[fermix_core.compaction]` config section | P0 | New | New TOML section with `threshold = 0.85` (float, validated `0.1 <= x <= 1.0`) and `enabled = true` (boolean). Round-tripped by `ConfigStore`. **Requires three discrete changes:** (a) `parse_value/1` float clause; (b) `encode_value/1` float clause; (c) new `:compaction` branch in `current_snapshot/0`, `persistable_snapshot/1`, `apply_snapshot/1`, `dump_snapshot/1`, `parse_document/1`, `empty_runtime_config/0` mirroring the existing `:routing` branch. |
| Threshold-driven auto-compaction (task-local) | P0 | New | Inside `MainAgent`'s request task, after `add_message(assistant)` and after `deliver_reply`, run `maybe_auto_compact/4`. If `Compactor.estimate_tokens(history) / context_window >= threshold`, call `Compactor.compact/2`, write the result via `ConversationStore.replace_history/3`. Emits `[:fermix, :compaction, :auto]`. **No GenServer round-trip** — the next turn cannot start until the task exits (single-flight per conversation), so writing the compacted history before exit guarantees the next turn sees it. |
| `ConversationStore.replace_history/3` | P0 | New | Atomic clear+repopulate, so the in-flight history is never empty mid-write. New function on the existing GenServer. |
| Channel command surface | P0 | New | `FermixChannels.Commands.parse/2` recognizes `/cmd args...` at message start. Strips Telegram's `@botname` suffix when present. Returns `{:command, name, args, message}` or `{:passthrough, message}`. **Called once from `Dispatcher.dispatch_message/6`**, not per-channel. |
| Channel command dispatcher | P0 | New | `FermixChannels.Commands.dispatch/3` looks up the command in a registry of `Command` behaviour modules and runs the handler with `{message, reply_fn, context}`. Reply uses the same `reply_fn` Dispatcher built (so `fermix ask` sync replies just work). |
| `Command` behaviour | P0 | New | `@callback name() :: String.t()`, `@callback aliases() :: [String.t()]`, `@callback description() :: String.t()`, `@callback authorize(message, channel_metadata, context) :: :ok \| {:error, :unauthorized}`, `@callback execute(message, reply_fn, context) :: :ok \| {:error, term()}`. |
| `/compact` command | P0 | New | Force-immediate `Compactor.compact/2` for `conversation_key(message)`. Replies with `Compacted: 12,400 → 3,800 tokens` (before/after). |
| `/new` and `/clear` commands | P0 | New | Call `ConversationStore.clear/2` for the conversation key. Aliases of one another. Replies with `Started a fresh session.` Does **not** touch durable memory (gist, Hermes facts, resource registry) — explicitly out of scope. |
| `/help` command | P0 | New | Lists all registered commands with one-line descriptions, sourced from `Command.description/0`. |
| Per-channel command authorization | P0 | New | Stable-id keyed: `[fermix_channels.<channel>.owner_user_id = "..."]` (single owner) plus optional `[fermix_channels.<channel>.command_allowlist = [...]]` (additional approved ids). `cli` channel is implicit-owner (operator on the box). If `owner_user_id` is absent and exactly one ingress allowlist id is configured, that id is treated as the owner. Multiple allowed users require explicit command authorization. Authorization reads `metadata.user_id`, NOT the display-name `Message.sender`. |
| Stable `user_id` in channel metadata | P0 | Modify | Each channel's `parse_*` populates `metadata.user_id` with the channel-native stable id (`from.id` in Telegram, `event.user` in Slack, `interaction.user.id` in Discord, contact wa_id in WhatsApp). Telegram and Slack already have raw access; this milestone makes the field uniform. |
| Compactor uses the agent's resolved route | P0 | Modify | `Memory.Compactor` today hardcodes `FermixCore.Providers.OpenAI` and calls the legacy `Provider.chat/2` API (`compactor.ex:94-98`), and `agent_loop.ex:301` does the same. Replace both with `Adapter.for_route(route_key).chat(summary_prompt, [], adapter_opts)` where `{route_key, adapter_opts}` comes from `RouteResolver.resolve!/1` against the same provider/model the main agent uses. All four adapters (OpenAI Responses, Codex, Anthropic Messages, ChatCompletions) already implement `chat/3` and return `provider_turn.content` — no new callback needed. |
| Local CLI parity | P1 | New | `fermix ask /compact` and `fermix ask /new` route through `FermixChannels.CLI.parse_input/2` → `Dispatcher.dispatch/2` → command intercept. Already free once Dispatcher hosts the intercept (CLI sync goes through Dispatcher). |
| Wizard step for compaction threshold + owner ids | P1 | New | New `:compaction` wizard step asks for the threshold (default `0.85`). New per-channel "command owner user id" prompt added to existing channel wizard steps. |
| `fermix doctor` compaction probe | P1 | New | Doctor section reporting current `compaction.threshold`, the per-provider model context windows, the configured `summary_provider` and whether its key is present, and a sample "would compact at N tokens for the configured model" calculation. |
| Telemetry | P1 | New | `[:fermix, :compaction, :auto]`, `[:fermix, :compaction, :forced]`, `[:fermix, :compaction, :auto_skipped]`, `[:fermix, :command, :received]`, `[:fermix, :command, :unauthorized]`. |
| Documentation | P0 | Docs | README CLI reference for `/compact`, `/new`, `/clear`, `/help`. CLAUDE.md updated with the M7.1 doc registration line (already added). |

### Non-Goals

| Feature | Reason | When |
|---|---|---|
| Per-channel native slash-command API integration | Each channel's slash-command surface is a sizable per-channel design. v1 plain-text `/cmd` parsing covers all channels uniformly. | M7.1+1 per channel |
| Slash-command autocomplete or interactive picker | UX polish on top of the basic surface. | M7.1+1 per channel |
| Per-skill or per-channel compaction threshold overrides | Adds a config-shape decision and a precedence table. v1 ships one global threshold. | Future, when measurement shows skill-level pressure |
| Mid-turn compaction (replace history while a tool-call thread is in flight) | The task that runs the loop also writes history. Nothing fires during the loop. By construction, compaction only runs after the assistant reply lands. | Not applicable by design |
| Cross-channel `/new` ("forget about me everywhere") | Privacy feature. Each `conversation_key` is independent in v1. | M10 |
| Long-term memory wipe on `/new` | `/new` is conversation-scoped. Wiping Hermes facts / Tier 1 gist / resource registry is destructive privacy work. | M10 |
| `/undo` or `/replay` commands | Different surface — needs message history rewind, not just clear. | Future |
| Custom user-defined commands | v1 has a fixed set defined by the registered `Command` modules. | Future |
| Approval-gated commands (e.g., `/approve` for `git_push`) | M10 owns the approval-flow surface end-to-end. | M10 |
| Per-conversation summary-model override (e.g., "use a cheaper model for compaction than for the agent") | v1 always uses the agent's provider+model so there's nothing to configure. If operators using a reasoning model find compaction cost unacceptable, add `[fermix_core.compaction] summary_model = "gpt-5.4-mini"` later as a one-line override. | Follow-up if asked |
| Persisted cross-turn provider state (Codex `prior_input`, Responses `previous_response_id`) | None of these exist in MainAgent today. Adding them is its own milestone (likely M9.1 voice or M11 cost optimization). When that lands, that milestone owns reset on `/new` and on auto-compaction. | Future |
| Multilingual checkpoint summaries | The v1 summary system prompt is English. Multilingual conversations may receive English checkpoint summaries. Add a locale-aware summary instruction only when the product has a broader localization policy. | Follow-up |

### Overlap with M4 (clarified)

`Memory.Compactor` already does the heavy lifting (token counting via `count_tokens` / NIF, protected/recent split, summary persistence as resource revisions). M7.1 does NOT rewrite the compaction algorithm. It adds:

- A trigger condition (`tokens_used >= threshold * context_window`) checked from the `MainAgent` request task after the assistant reply is written.
- A user-facing `/compact` command that calls `Compactor.compact/2` directly with `:enabled` forced to true.
- `ConversationStore.replace_history/3` so the auto-compaction code path can swap the history atomically without going through the agent loop.

The M4 in-loop compaction and the M7.1 post-turn compaction intentionally coexist. In-loop compaction owns provider-call safety for the current turn: it trims the prompt before the adapter call if the assembled prompt is already too large. M7.1 auto-compaction owns durable cross-turn history size after the reply is written. If both run on the same turn, the in-loop summary cost belongs to that turn's provider call and the post-turn summary cost belongs to durable history maintenance; neither path resets provider state because no cross-turn provider state is persisted today.

Compactor's existing `:cache` return value (the summary blob) is preserved across calls so the next trigger doesn't re-summarize the same older window if the threshold check fires twice in a row.

---

## 4. Core Design

### 4.1 Runtime Shape

```
inbound message (channel)
  │
  ├── FermixChannels.<Channel>.parse_webhook/parse_input → %Message{} (with metadata.chat_type, metadata.user_id)
  │
  ├── FermixChannels.Dispatcher.dispatch/2
  │     │
  │     ├── maybe_transcribe_message
  │     ├── normalize_message
  │     ├── build_reply_fn (honors reply_fn_override — fermix ask sync path keeps working)
  │     │
  │     ├── FermixChannels.Commands.parse/2
  │     │     │
  │     │     ├── starts with "/" and matches [a-z][a-z0-9_]*? → {:command, name, args, message}
  │     │     │     │
  │     │     │     ├── lookup in CommandRegistry
  │     │     │     ├── handler.authorize(message, metadata, context)
  │     │     │     │     │
  │     │     │     │     ├── :ok → handler.execute(message, reply_fn, context)
  │     │     │     │     │           │
  │     │     │     │     │           ├── /compact → Compactor.compact + ConversationStore.replace_history + reply with delta
  │     │     │     │     │           ├── /new     → ConversationStore.clear + reply
  │     │     │     │     │           └── /help    → render command list + reply
  │     │     │     │     │
  │     │     │     │     └── {:error, :unauthorized} → reply with refusal + telemetry
  │     │     │     │
  │     │     │     └── unknown command → :passthrough → fall through to agent.handle_message
  │     │     │
  │     │     └── plain text → :passthrough → fall through to agent.handle_message
  │     │
  │     └── (passthrough) agent.handle_message(agent_message, agent_server)
  │
  └── inside MainAgent request task (run_message_loop):
        ├── AgentLoop.run
        ├── ConversationStore.add_message(user)
        ├── ConversationStore.add_message(assistant)
        ├── deliver_reply
        ├── maybe_start_extraction
        └── maybe_auto_compact(conversation_key, history_after_writes, model, ctx)
              │
              ├── tokens_used / context_window >= threshold?
              │     │
              │     ├── yes → Compactor.compact + ConversationStore.replace_history + emit :auto telemetry
              │     │
              │     └── no  → no-op + (optionally) :auto_skipped telemetry with reason :under_threshold
              │
              └── (task exits → MainAgent's :DOWN handler advances the queue)
```

### 4.2 Per-Model Context Window Catalog

Extend `ModelCatalog` entries with a third tuple element:

All three providers in `ModelCatalog` (`:openai`, `:openai_codex`, `:anthropic`) get the same treatment — `openai_codex` is a separate provider key in the catalog (`model_catalog.ex:21-25, 34, 38`) and stays separate here. The values below come from each provider's published documentation (verified May 2026):

```elixir
@openai [
  # API path (Responses + Chat Completions)
  {"gpt-5.5", "GPT-5.5 (default, recommended)", 1_050_000},
  {"gpt-5.4", "GPT-5.4", 1_050_000},
  {"gpt-5.4-mini", "GPT-5.4 mini", 400_000}
]

@openai_codex [
  # Codex backend caps the window — confirmed for gpt-5.5 in
  # github.com/openai/codex#19464; the smaller model entries assume
  # the same Codex-side cap and need verification at Stage 1.
  {"gpt-5.5", "GPT-5.5 (default, latest)", 400_000},
  {"gpt-5.4", "GPT-5.4", 400_000},
  {"gpt-5.4-mini", "GPT-5.4 mini (faster, cheaper)", 400_000}
]

@anthropic [
  # Sonnet 4.6 / Opus 4.7 ship with the 1M-token window;
  # Haiku 4.5 stays at the 200k tier.
  {"claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)", 1_000_000},
  {"claude-opus-4-7", "Claude Opus 4.7 (best quality)", 1_000_000},
  {"claude-haiku-4-5", "Claude Haiku 4.5 (fastest)", 200_000}
]
```

**Sources verified for Stage 1:**

- OpenAI gpt-5.5 / 5.4: 1.05M context window via Responses + Chat Completions APIs (see [GPT-5.5 model page](https://developers.openai.com/api/docs/models/gpt-5.5), [GPT-5.4 model page](https://developers.openai.com/api/docs/models/gpt-5.4)). Note: input >272k tokens hits a 2× input / 1.5× output session-pricing tier — that's a *cost* concern, not a capacity one; the threshold-driven trigger doesn't need to know about it.
- OpenAI gpt-5.4-mini: 400k context window (see [GPT-5.4 mini model page](https://developers.openai.com/api/docs/models/gpt-5.4-mini)).
- Codex gpt-5.5: 400k context window per the Codex backend cap (see [Support 1M token context for GPT-5.5 in Codex](https://github.com/openai/codex/issues/19464)). Stage 1 must confirm whether gpt-5.4 and gpt-5.4-mini under Codex hit the same 400k cap or a different one.
- Anthropic Sonnet 4.6 / Opus 4.7: 1M-token context window (see [Claude context windows docs](https://platform.claude.com/docs/en/build-with-claude/context-windows)).
- Anthropic Haiku 4.5: 200k-token context window (same source).

Add `context_window_for/2`:

```elixir
@unknown_model_default_ctx 100_000

@spec context_window_for(provider(), String.t()) :: pos_integer()
def context_window_for(provider, model_id) do
  case Enum.find(models_for(provider), fn {id, _label, _ctx} -> id == model_id end) do
    {_id, _label, ctx} when is_integer(ctx) and ctx > 0 ->
      ctx

    nil ->
      :telemetry.execute(
        [:fermix, :model_catalog, :unknown_model],
        %{count: 1},
        %{provider: provider, model: model_id}
      )

      @unknown_model_default_ctx
  end
end
```

The unknown-model default (100k) is the conservative middle of the modern frontier-model range. Smallest catalogued window today is Anthropic Haiku 4.5 at 200k; everything else sits at 400k–1.05M. Defaulting to 100k means an unknown model triggers compaction at half (or much less than half) its likely true window — at worst we waste a summary call. Going lower (e.g. 16k) was overly defensive against ancient 4k/8k models that nobody routes through Fermix anymore; going higher risks overflow on a smaller model that slips into the configured route. `fermix doctor` flags `:unknown_model` telemetry events at startup so the operator adds the real number.

**Migration:** the existing `@type entry :: {id :: String.t(), label :: String.t()}` becomes `{id :: String.t(), label :: String.t(), context_window :: pos_integer()}`. All call sites that destructure `{id, label}` need updating to `{id, label, _ctx}`. Touched files: `setup/wizard.ex`, the LiveView model picker, any test setup.

### 4.3 `[fermix_core.compaction]` Config Section

New TOML section:

```toml
[fermix_core.compaction]
threshold = 0.85
enabled = true
```

Compaction does not get its own provider/model knob — it uses whatever provider+model the main agent uses, resolved via the same `RouteResolver` path (see §4.10).

`ConfigStore` changes — three discrete pieces:

1. **Float parse.** Add a clause to `parse_value/1` (`config_store.ex:441`) that recognizes `^-?\d+\.\d+$` and returns `Float.parse(value) |> elem(0)`. Comes before the bare-string fallback so quoted strings are still preferred.

2. **Float encode.** Add a clause to `encode_value/1` (`config_store.ex:360`) before the catch-all: `defp encode_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])`. (`:short` produces the minimal round-trippable form, avoiding `0.85000000000` artifacts.)

3. **`:compaction` snapshot/apply branch.** Mirror the `:routing` branch in:
   - `current_snapshot/0` (`config_store.ex:56`) — add `compaction: Application.get_env(:fermix_core, :compaction, [])` under `:fermix_core`.
   - `persistable_snapshot/1` (`config_store.ex:147` area) — preserve the new key.
   - `apply_snapshot/1` (`config_store.ex:104`) — call new `apply_compaction_config(...)` that writes to `Application.put_env(:fermix_core, :compaction, ...)`.
   - `dump_snapshot/1` (`config_store.ex:302`) — add `render_section(["fermix_core", "compaction"], compaction)`.
   - `parse_document/1` (`config_store.ex:407`) — add `compaction: normalize_compaction(get_in(document, ["fermix_core", "compaction"]))`.
   - `empty_runtime_config/0` (`config_store.ex:240`) — add `compaction: []` so missing TOML normalizes to defaults.

Validation lives in `normalize_compaction/1`:

- `threshold` must be a float in `[0.1, 1.0]` inclusive. Below 0.1 thrashes; above 1.0 means the threshold can never trigger.
- `enabled` must be a boolean.

Invalid values → raise from `normalize_compaction/1` with a message the wizard catches and re-prompts.

### 4.4 Threshold-Driven Auto-Compaction (Task-Local)

The trigger lives **inside the MainAgent request task**, NOT in a GenServer `handle_info` hook. Reason: today's `run_message_loop/2` (`main_agent.ex:497-571`) runs the full lifecycle inside the task — `AgentLoop.run`, both `ConversationStore.add_message` calls, `deliver_reply`, `maybe_start_extraction` — and the GenServer only sees the task `:DOWN`. Trying to thread a `{:agent_turn_complete, …}` message back through the GenServer would invert that lifecycle for no benefit, since (a) MainAgent state has nothing to mutate (no cross-turn provider state exists today; see §1), and (b) single-flight per `conversation_key` already serializes turns — the next turn cannot start until the current task exits.

Sketch:

```elixir
# main_agent.ex — added to run_message_loop after maybe_start_extraction (line ~571)

defp run_message_loop(msg, state) do
  # … existing AgentLoop.run, add_message(user), add_message(assistant),
  # telemetry, deliver_reply, maybe_start_extraction unchanged …

  maybe_auto_compact(conversation_key, state)
end

defp maybe_auto_compact(conversation_key, state) do
  config = Application.get_env(:fermix_core, :compaction, [])

  if Keyword.get(config, :enabled, true) do
    history = ConversationStore.get_history(conversation_key, server: state.conversation_store)
    tokens_used = Compactor.estimate_tokens(history)
    {route_key, adapter_opts} = active_route(state)
    %{provider: provider, model: model} = route_key
    context_window = ModelCatalog.context_window_for(provider, model)
    threshold = Keyword.get(config, :threshold, 0.85)

    cond do
      tokens_used / context_window >= threshold ->
        run_auto_compaction(conversation_key, history, tokens_used,
                            route_key, adapter_opts, context_window, state)

      true ->
        :telemetry.execute([:fermix, :compaction, :auto_skipped], %{count: 1},
          %{conversation_key: conversation_key, reason: :under_threshold})
        :ok
    end
  else
    :ok
  end
end

defp run_auto_compaction(conversation_key, history, before_tokens, route_key, adapter_opts, ctx, state) do
  budget = trunc(0.5 * ctx)

  case Compactor.compact(history,
         enabled: true,
         token_budget: budget,
         route: {route_key, adapter_opts}
       ) do
    {:ok, %{messages: compacted, compacted?: true}} ->
      after_tokens = Compactor.estimate_tokens(compacted)

      :ok = ConversationStore.replace_history(conversation_key, compacted,
              server: state.conversation_store,
              agent_id: state.memory_agent_id,
              owner_id: state.memory_owner_id)

      :telemetry.execute([:fermix, :compaction, :auto],
        %{before_tokens: before_tokens, after_tokens: after_tokens},
        %{
          conversation_key: conversation_key,
          model: route_key.model,
          provider: route_key.provider
        })

      :ok

    {:ok, %{compacted?: false}} ->
      :telemetry.execute([:fermix, :compaction, :auto_skipped], %{count: 1},
        %{conversation_key: conversation_key, reason: :nothing_to_compact})
      :ok

    {:error, reason} ->
      Logger.error("auto-compaction failed: #{inspect(reason)}")
      :telemetry.execute([:fermix, :compaction, :auto_skipped], %{count: 1},
        %{conversation_key: conversation_key, reason: reason})
      :ok
  end
end
```

Two new touch points:

- **`ConversationStore.replace_history/3`** — new function. Currently the store has `clear/2` and `add_message/4`. `replace_history/3` is a single GenServer call that clears and bulk-appends in one transaction so a concurrent `get_history/2` never sees an empty list mid-write.
- **`maybe_auto_compact/2`** — called from `run_message_loop/2` *after* `maybe_start_extraction`. Failures log + emit `:auto_skipped` telemetry; they never crash the task, since the user has already received the assistant reply and the next turn can still proceed (it will just re-trigger the threshold check with the same too-large history; see Risk #6 for the per-conversation backoff).

**Compaction budget:** `trunc(0.5 * context_window)`. After compaction, the new history occupies at most half the window. If the threshold is 0.85, that means after a trigger we drop from ~85% utilization to ~50%, leaving ~4 turns of headroom before the next trigger. Avoids thrashing.

**Why no provider-state reset.** §1 explains: nothing is persisted across turns today. If M9.1 voice or a future cost-optimization milestone introduces a persisted Codex `prior_input` or Responses `previous_response_id` cache, that milestone's auto-compaction integration adds the reset in `replace_history/3`'s callers.

### 4.5 Channel Command Surface — Hosted in `Dispatcher`

New module `apps/fermix_channels/lib/fermix_channels/commands.ex`:

```elixir
defmodule FermixChannels.Commands do
  @moduledoc """
  Channel-side command parser + dispatcher. Recognizes leading `/cmd`
  on inbound messages and routes to the matching `Command` behaviour
  module before the message reaches the agent.
  """

  alias FermixChannels.Message

  @type result :: {:command, String.t(), [String.t()], Message.t()} | {:passthrough, Message.t()}

  @spec parse(Message.t(), keyword()) :: result()
  def parse(%Message{content: content} = message, opts \\ []) do
    bot_name = Keyword.get(opts, :bot_name)

    case parse_leading_command(content, bot_name) do
      {name, args} -> {:command, name, args, message}
      :no_command -> {:passthrough, message}
    end
  end

  @spec dispatch(result(), reply_fn :: (String.t() -> :ok | {:error, term()}), context :: map()) ::
          :ok | :passthrough | {:error, term()}
  def dispatch({:passthrough, _message}, _reply_fn, _context), do: :passthrough

  def dispatch({:command, name, args, message}, reply_fn, context) do
    case CommandRegistry.lookup(name) do
      {:ok, handler} -> run_command(handler, message, args, reply_fn, context)
      :error -> :passthrough  # unknown /cmd → fall back to LLM
    end
  end

  defp run_command(handler, message, args, reply_fn, context) do
    :telemetry.execute([:fermix, :command, :received], %{count: 1},
      %{command: handler.name(), channel: message.channel})

    case handler.authorize(message, message.metadata || %{}, context) do
      :ok ->
        message_with_args = %{message | content: Enum.join(args, " ")}
        handler.execute(message_with_args, reply_fn, context)

      {:error, :unauthorized} = err ->
        :telemetry.execute([:fermix, :command, :unauthorized], %{count: 1},
          %{command: handler.name(), channel: message.channel})
        reply_fn.("This command requires owner permissions.")
        err
    end
  end

  defp parse_leading_command(content, bot_name) do
    content = content |> to_string() |> String.trim_leading()

    case String.split(content, ~r/\s+/, parts: 2, trim: true) do
      ["/" <> raw_cmd | rest] ->
        cmd = strip_botname(raw_cmd, bot_name) |> String.downcase()
        args = case rest do [r] -> String.split(r, ~r/\s+/, trim: true); [] -> [] end
        if String.match?(cmd, ~r/^[a-z][a-z0-9_]*$/), do: {cmd, args}, else: :no_command

      _ ->
        :no_command
    end
  end

  defp strip_botname(cmd, nil), do: cmd

  defp strip_botname(cmd, bot_name) do
    suffix = "@" <> String.downcase(bot_name)

    if String.ends_with?(String.downcase(cmd), suffix),
      do: String.slice(cmd, 0, String.length(cmd) - String.length(suffix)),
      else: cmd
  end
end
```

**`Dispatcher` change.** A single intercept slot in `dispatch_message/6` (`dispatcher.ex:79-113`):

```elixir
defp dispatch_message(channel, message, agent, agent_server, transcription_opts, reply_fn_override) do
  with {:ok, message} <- FermixCore.Transcription.maybe_transcribe_message(channel, message, transcription_opts),
       {:ok, reply_message} <- normalize_message(message) do
    reply_fn = build_reply_fn(channel, reply_message, reply_fn_override)
    typing_fn = build_typing_fn(channel, reply_message)

    context = %{
      conversation_key: conversation_key(reply_message),
      conversation_store: FermixCore.Memory.ConversationStore,
      agent: agent,
      agent_server: agent_server,
      bot_name: bot_name_for(channel)
    }

    case FermixChannels.Commands.dispatch(
           FermixChannels.Commands.parse(reply_message, bot_name: context.bot_name),
           reply_fn,
           context
         ) do
      :ok -> :ok
      {:error, _} = error -> error
      :passthrough -> deliver_to_agent(reply_message, agent, agent_server, reply_fn, typing_fn)
    end
  else
    # … existing error branches unchanged …
  end
end
```

`deliver_to_agent/5` is the existing tail of `dispatch_message` extracted for clarity (build `agent_message`, attach `reply_fn` + `typing_fn`, call `agent.handle_message`). No per-channel changes other than the metadata fields described in §4.7.

**`bot_name_for/1`** reads from `Application.get_env(:fermix_channels, channel_atom_for_module(channel), [])` and returns the configured Telegram bot name (or `nil` for channels that don't need `@botname` stripping).

**Unknown command behavior:** `:passthrough` — falls through to the agent as raw user content. Reason: users frequently type `/x` strings that aren't commands ("/path/to/file", "/regex/", "what does /etc/hosts do?"). Erroring on `/unknown` would hide legitimate user intent.

**Command name validation:** must match `^[a-z][a-z0-9_]*$`. Stops accidental matches on `/Users/...`, `/path/to`, etc.

### 4.6 `Command` Behaviour, Authorization, and Built-in Commands

```elixir
defmodule FermixChannels.Command do
  @callback name() :: String.t()
  @callback aliases() :: [String.t()]
  @callback description() :: String.t()
  @callback authorize(
              FermixChannels.Message.t(),
              channel_metadata :: map(),
              context :: map()
            ) :: :ok | {:error, :unauthorized}
  @callback execute(
              FermixChannels.Message.t(),
              reply_fn :: (String.t() -> :ok | {:error, term()}),
              context :: map()
            ) :: :ok | {:error, term()}
end
```

Built-in commands ship as modules implementing `Command`:

- `FermixChannels.Commands.Compact` — name `"compact"`, no aliases.
- `FermixChannels.Commands.New` — name `"new"`, aliases `["clear"]`.
- `FermixChannels.Commands.Help` — name `"help"`, no aliases.

`CommandRegistry` is a simple in-memory map populated at boot from `Application.get_env(:fermix_channels, :commands, [Compact, New, Help])`. M9 and M10 add their own commands by registering more modules.

#### Authorization model — stable id, effective owner

The authorization helper used by all built-in commands:

```elixir
defmodule FermixChannels.Commands.Authorization do
  @spec owner_only(Message.t(), channel_metadata :: map(), context :: map()) ::
          :ok | {:error, :unauthorized}
  def owner_only(%{channel: "cli"}, _metadata, _context), do: :ok

  def owner_only(%{channel: channel}, metadata, _context) do
    user_id = stable_user_id(metadata)
    key = channel_atom(channel)
    owner = FermixCore.Config.channel_command_owner_user_id(key)
    allowlist = FermixCore.Config.channel_command_allowlist(key)

    cond do
      is_nil(owner) -> {:error, :unauthorized}  # fail closed
      is_nil(user_id) -> {:error, :unauthorized}  # no stable id, fail closed
      to_string(user_id) == to_string(owner) -> :ok
      to_string(user_id) in Enum.map(allowlist, &to_string/1) -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp stable_user_id(metadata) when is_map(metadata) do
    Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
  end

  defp stable_user_id(_), do: nil

  defp channel_atom("telegram"), do: :telegram
  defp channel_atom("discord"), do: :discord
  defp channel_atom("slack"), do: :slack
  defp channel_atom("whatsapp"), do: :whatsapp
  defp channel_atom("signal"), do: :signal
  defp channel_atom(_), do: :unknown
end
```

**Why explicit owner instead of "private chat → :ok".** The naive heuristic "this is a 1:1 chat, allow it" trusts the channel's `chat_type` signal and gives no defense against misconfiguration. Fermix instead keys command authorization on the stable `metadata.user_id`. For single-user installs, `owner_user_id` is enough: when no explicit ingress allowlist is configured, ingress defaults to that owner. For compatibility with older configs, a single configured ingress allowlist id can be treated as the owner; multi-user allowlists still require explicit command authorization.

**Operator friction:** the wizard prompts for `owner_user_id` per channel and does not require a second ingress allowlist for the normal single-user path. Until an effective owner exists, channel commands fail closed; the daemon logs a one-time hint at boot per enabled channel. Doctor flags it as a warning, not an error.

#### `/compact` execution

```elixir
def execute(message, reply_fn, context) do
  conversation_key = Map.fetch!(context, :conversation_key)
  conversation_store = Map.fetch!(context, :conversation_store)

  history = ConversationStore.get_history(conversation_key, server: conversation_store)
  before_tokens = Compactor.estimate_tokens(history)

  budget = forced_compact_budget(context)

  case Compactor.compact(history, enabled: true, token_budget: budget) do
    {:ok, %{messages: compacted, compacted?: true}} ->
      after_tokens = Compactor.estimate_tokens(compacted)

      :ok = ConversationStore.replace_history(conversation_key, compacted,
              server: conversation_store)

      :telemetry.execute([:fermix, :compaction, :forced],
        %{before_tokens: before_tokens, after_tokens: after_tokens},
        %{conversation_key: conversation_key})

      reply_fn.("Compacted: #{format(before_tokens)} → #{format(after_tokens)} tokens.")
      :ok

    {:ok, %{compacted?: false}} ->
      reply_fn.("Nothing to compact (#{format(before_tokens)} tokens, below the working budget).")
      :ok

    {:error, reason} ->
      reply_fn.("Compaction failed: #{inspect(reason)}.")
      {:error, reason}
  end
end

defp forced_compact_budget(context) do
  context_window = Map.get(context, :context_window, 100_000)
  trunc(0.5 * context_window)
end
```

`/compact` does not need to go through `MainAgent` at all — it only touches `ConversationStore`. This works because (a) `ConversationStore` is a separate GenServer with its own serialization, and (b) MainAgent's single-flight per conversation_key means the next agent turn cannot start while this is running unless one is already in flight (in which case the user explicitly chose to compact mid-conversation; the running turn keeps its in-task `messages` list and is unaffected — only the next turn sees the compacted history).

#### `/new` and `/clear` execution

```elixir
def execute(_message, reply_fn, context) do
  conversation_key = Map.fetch!(context, :conversation_key)
  conversation_store = Map.fetch!(context, :conversation_store)

  :ok = ConversationStore.clear(conversation_key, server: conversation_store)
  reply_fn.("Started a fresh session. Long-term memory is preserved.")
  :ok
end
```

Scope is intentionally narrow:

- **Cleared:** `ConversationStore` history for this `{channel, chat_id, thread_scope}`.
- **Preserved:** Hermes-extracted facts, Tier 1 gist, resource registry entries, scheduled jobs that reference this conversation, prompt-context memory rendered into the system message.

The reply explicitly mentions long-term memory persistence to set user expectations.

#### `/help` execution

```elixir
def execute(_message, reply_fn, _context) do
  body =
    CommandRegistry.list()
    |> Enum.sort_by(& &1.name())
    |> Enum.map_join("\n", fn cmd -> "/#{cmd.name()} — #{cmd.description()}" end)

  reply_fn.("Available commands:\n#{body}")
  :ok
end
```

### 4.7 Per-Channel Metadata Standardization

The Dispatcher hosts the parser and authorization, but each channel still has to report two pieces of metadata. This is *data*, not behavior — minimal per-channel change.

| Channel | `metadata.chat_type` source | `metadata.user_id` source |
|---|---|---|
| Telegram (`telegram.ex:294-321`) | `update.message.chat.type` (already populated) | `update.message.from.id` (raw available; add to metadata) |
| Slack (`slack.ex:148-153`) | `event.channel_type` (already populated) | `event.user` (already populated as `metadata.user_id`) |
| Discord | `interaction.guild_id` → `nil ? "private" : "guild"` (new) | `interaction.user.id` (new) |
| WhatsApp (`whatsapp.ex:200-204`) | `"private"` (single-user product convention) | `entry.changes.value.contacts.[0].wa_id` (already accessed for sender resolution) |
| Signal | `"private"` (single-user product convention) | `envelope.source` (signal-cli sender id) |
| CLI (`cli.ex`) | `"private"` (operator on the box) | `nil` (CLI bypass in authorizer) |

**Failure mode for missing `chat_type`:** treated as "group" by absence — unknown context defaults to "not safe" — but since auth now keys on `user_id` + explicit owner, `chat_type` is informational only (used by `/help` to suggest correct command flow per channel). The hard failure is "no `user_id` and no owner configured."

### 4.8 Telemetry

Five new events:

- `[:fermix, :compaction, :auto]` — measurements: `before_tokens`, `after_tokens`. Metadata: `conversation_key`, `model`, `provider`.
- `[:fermix, :compaction, :forced]` — same shape, fired by `/compact`.
- `[:fermix, :compaction, :auto_skipped]` — measurements: `%{count: 1}`. Metadata: `conversation_key`, `reason` (`:under_threshold | :nothing_to_compact | term()`).
- `[:fermix, :command, :received]` — measurements: `%{count: 1}`. Metadata: `command`, `channel`.
- `[:fermix, :command, :unauthorized]` — same shape, plus `reason: :no_owner_configured | :user_id_missing | :not_owner_or_allowed`.

Existing `[:fermix, :channel, :message]` continues to fire for every inbound message (commands included) so the inbound count stays consistent.

### 4.9 Local CLI Parity

`fermix ask /compact` works for free once the intercept lives in `Dispatcher`. The CLI sync path (`cli.ex:65-86`) calls `Dispatcher.dispatch/2` with a `reply_fn` override that `send`s the reply back to the parent. The Dispatcher intercept fires, executes the command, calls the override `reply_fn`, the parent receives it through `await_reply/3`, and `dispatch_input_sync/2` returns. No CLI-specific code needed.

`cli` channel is implicit-owner in the authorizer (operator on the box).

### 4.10 Compaction Routes Through the Agent's Adapter

Compaction uses whatever provider+model the main agent is configured with. No separate provider, no separate API key, no separate model. The operator configures the agent once (via `[fermix_core.agent] provider = ...` and `[fermix_core.providers.<provider>] default_model = ...`) and compaction follows.

**How:**

The `Adapter` behaviour (`apps/fermix_core/lib/fermix_core/providers/adapter.ex`) defines `chat/3` returning `{:ok, provider_turn()}` where `provider_turn` has a required `:content :: String.t()` field. Every adapter — `OpenAI.Responses`, `OpenAI.Codex`, `OpenAI.ChatCompletions`, `Anthropic.Messages` — already implements it. Calling `adapter.chat(messages, [], adapter_opts)` with an empty capability list yields a tools-disabled response whose `content` is the assistant text, exactly what the summary turn needs. No new callback, no new behaviour.

**Compactor change** (`compactor.ex:94-108`):

```elixir
defp call_summary_provider(older, prior, budget, opts) do
  {route_key, adapter_opts} = Keyword.fetch!(opts, :route)
  adapter = FermixCore.Providers.Adapter.for_route(route_key)

  case adapter.chat(summary_prompt(older, prior, budget), [], adapter_opts) do
    {:ok, %{content: content}} when is_binary(content) and content != "" ->
      {:ok, String.trim(content)}

    {:ok, %{content: ""}} ->
      {:error, {:compaction_failed, :empty_summary}}

    {:error, reason} ->
      {:error, {:compaction_failed, reason}}
  end
end
```

The `:route` opt is required — Compactor no longer falls back to a hardcoded provider. Callers pass `route: {route_key, adapter_opts}` from `RouteResolver.resolve!/1`.

**Two call sites are updated:**

1. **Auto-compaction (M7.1, this milestone)** — `MainAgent.maybe_auto_compact/2` resolves the agent's route once and threads it through `Compactor.compact/2`.
2. **In-loop compaction (`agent_loop.ex:295-315`)** — uses the route already resolved into `state.route_key` and `state.adapter_opts`, so its summary call follows the same adapter as the current turn.

This eliminates a hardcoded-OpenAI dependency in two places at once.

**Trade-off accepted:** if the operator's main model is a reasoning model (e.g., `gpt-5.5` with high effort), compaction summaries also use it — slower and pricier than necessary for a one-shot summary. v1 accepts this because (a) it's a clean default that needs zero configuration, (b) compaction triggers infrequently (only above the 0.85 threshold), and (c) the alternative — a separate `summary_model` knob — adds wizard surface, doctor surface, and TOML key for a problem nobody has reported yet. If real cost data shows it matters, add `[fermix_core.compaction] summary_model = "..."` later as a single optional override.

**Failure mode:** if the agent provider itself is misconfigured (no key, OAuth expired, etc.), the summary call returns `{:error, {:compaction_failed, reason}}`. Auto-compaction logs and emits `:auto_skipped`; `/compact` replies with the underlying error. No special "compaction unavailable" branch — failure surfaces through the same path as any other adapter failure.

---

## 5. Open Decisions

These are intentionally left for the wizard/eval phase; the current shape is the proposed v1 answer with the alternative noted.

### Q1. Auto-compaction policy when summary is empty

**Question:** What if `Compactor.compact/2` returns `compacted?: false` even when over threshold (the protected/recent split has no `older` window)?

**Proposed:** No-op + `[:fermix, :compaction, :auto_skipped]` with reason `:nothing_to_compact`. The next turn proceeds with full history; the user may immediately hit a context-overflow error from the provider, which is surfaced with the model's actual error message.

**Alternative:** Truncate the oldest non-protected message and retry. Risk: model loses important early context silently. Rejected for v1.

### Q2. Threshold below 0.5

**Question:** Should we allow `threshold = 0.3`? It thrashes (compacts every 2-3 turns) but might be useful for cost-conscious operators.

**Proposed:** Allow `threshold ∈ [0.1, 1.0]`. Document in the README that values below 0.5 cause frequent compaction (each compaction is itself an LLM call, so the cost trade is real).

### Q3. `/new` confirmation

**Question:** Should `/new` require a confirmation (`/new yes` to actually wipe)?

**Proposed:** No confirmation in v1. The owner-only authorization already gates it. If accidental wipes become a real complaint, add `[fermix_core.compaction] new_requires_confirmation = true` as an opt-in.

### Q4. Owner identification UX

**Question:** Each owner setup requires the operator to know their stable channel-side user id. Telegram numeric ids aren't user-visible by default; Discord requires developer mode to copy ids; Slack member ids are accessible but obscure.

**Proposed:** Wizard step prompts: "Send `/whoami` to the bot from your account, then paste the id printed in the daemon log." Add a `/whoami` command (same surface, no auth required since it only reveals the caller's own metadata.user_id) that replies with `Your user id on this channel: <id>` so the operator never has to dig through API consoles. `/whoami` is registered alongside the built-ins; intentionally exempt from owner-only auth.

**Alternative:** Auto-detect "first sender" as owner. Rejected — too easy for the wrong person to claim ownership in a brief window during deployment.

### Q5. Per-skill command overrides

**Question:** Some skills might want their own `/compact` semantics.

**Proposed:** No in v1. Commands are global. Skills can affect compaction *behavior* via the `enabled: false` per-conversation override, but the command surface is uniform.

### Q6. Telemetry: per-conversation_key cardinality

**Question:** Emitting `conversation_key` as telemetry metadata creates high-cardinality metrics if there are thousands of chats.

**Proposed:** Emit `conversation_key` as a string so operators can downsample with relabel rules. Document the cardinality trade.

### Q7. Compactor failure backoff

**Question:** If auto-compaction fails (provider error), the threshold is still over for the next turn — re-trigger immediately? Risk: thrash.

**Proposed:** Track a per-conversation `last_auto_compact_failed_at` timestamp inside MainAgent state (this IS state worth carrying since it's about MainAgent scheduling, not provider state). Skip auto-compact for 60s after a failure. Failure during the 60s window emits `:auto_skipped` with `reason: :recent_failure_backoff`.

**Alternative:** No backoff, log only. Rejected — first-flight failures during provider outages would re-trigger every turn.

---

## 6. Stages

Each stage ends with `mix format`, `mix credo --strict`, `mix test`, and a CHANGELOG bullet.

### Stage 1: Per-model context window catalog

**Files:** `apps/fermix_core/lib/fermix_core/providers/model_catalog.ex`, `apps/fermix_core/test/fermix_core/providers/model_catalog_test.exs`, plus call-site fixes for `setup/wizard.ex` and the LiveView model picker.

**Output:** `ModelCatalog.context_window_for/2` returns the right window per model, returns the safe default + emits telemetry on unknown models. All existing call sites pattern-match the new 3-tuple shape.

**Verification:** unit test asserts the per-model windows, the unknown-model telemetry, and that all callers compile cleanly.

**Stage 1 review and fix.**

### Stage 2: Compaction config + ConfigStore round-trip

**Files:** `apps/fermix_core/lib/fermix_core/setup/config_store.ex` (+ test). New module `apps/fermix_core/lib/fermix_core/memory/compaction_config.ex` for the validation helper consumed by both `ConfigStore` and `MainAgent`.

**Output:** `[fermix_core.compaction]` round-trips through TOML. Float parse + encode clauses land. Validation rejects out-of-range thresholds and non-boolean enabled. `Application.put_env(:fermix_core, :compaction, [...])` lands the values at apply.

**Verification:** ConfigStore test for round-trip with floats, invalid threshold, invalid enabled. Snapshot test for the full TOML dump including the new section.

**Stage 2 review and fix.**

### Stage 3: Adapter-routed compaction + ConversationStore.replace_history + threshold-driven auto-compaction

**Files:** `apps/fermix_core/lib/fermix_core/memory/compactor.ex` (+ test), `apps/fermix_core/lib/fermix_core/agent_loop.ex` (drop hardcoded `OpenAI` at `agent_loop.ex:301`, pass `route` instead), `apps/fermix_core/lib/fermix_core/memory/conversation_store.ex` (+ test), `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/test/fermix_core/agents/main_agent_test.exs`.

**Output:** `Compactor.summary_for/3` accepts `route: {route_key, adapter_opts}` and calls `Adapter.for_route(route_key).chat(prompt, [], adapter_opts)`. `agent_loop.ex` in-loop compaction uses the same route the agent loop is already running on. `ConversationStore.replace_history/3` exists and atomically swaps the history. `MainAgent.run_message_loop/2` calls `maybe_auto_compact/2` after `maybe_start_extraction`, threading the resolved route. Per-conversation 60s backoff after a compactor failure (Q7).

**Verification:** integration test with a stubbed adapter that returns scripted summary content; assert auto-compact fires when crossing threshold, that `Adapter.chat/3` is invoked with `[]` capabilities, that `replace_history` was called, and that the 60s backoff suppresses re-triggers on simulated failure. Per-provider unit test that `compactor.ex` works against `OpenAI.Responses`, `OpenAI.Codex`, and `Anthropic.Messages` stubs (each returning `{:ok, %{content: "..."}}`).

**Stage 3 review and fix.**

### Stage 4: Channel command surface + parser

**Files:** `apps/fermix_channels/lib/fermix_channels/commands.ex`, `apps/fermix_channels/lib/fermix_channels/command.ex` (behaviour), `apps/fermix_channels/lib/fermix_channels/commands/registry.ex`, `apps/fermix_channels/lib/fermix_channels/commands/authorization.ex`, tests.

**Output:** `Commands.parse/2` recognizes `/cmd args...` with Telegram `@botname` stripping and the `[a-z][a-z0-9_]*` validation. `CommandRegistry` is populated from app env. `Authorization.owner_only/3` enforces effective owner + command allowlist with CLI bypass.

**Verification:** parser test (the `@botname` strip, the unknown-command passthrough, the `/Users/...` non-match, leading whitespace). Authorization test (CLI :ok; channel with no effective owner = unauthorized; matching owner_user_id = :ok; single ingress allowlist owner fallback = :ok; multi-user ingress allowlist does not grant command auth; command allowlist match = :ok; missing user_id = unauthorized).

**Stage 4 review and fix.**

### Stage 5: Built-in commands + Dispatcher intercept

**Files:** `apps/fermix_channels/lib/fermix_channels/commands/{compact,new,help,whoami}.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex` (intercept slot), tests.

**Output:** Four commands work end-to-end through `Dispatcher`. `/whoami` returns the caller's stable id (no auth). `/help` lists everything that's registered. `/compact` and `/new` enforce owner-only auth.

**Verification:** end-to-end test through `Dispatcher.dispatch/2` with a synthetic channel module — assert command path runs, asserts passthrough on plain text, asserts `reply_fn_override` (as used by CLI sync) is honored when commands run.

**Stage 5 review and fix.**

### Stage 6: Per-channel metadata standardization

**Files:** `apps/fermix_channels/lib/fermix_channels/{telegram,discord,slack,whatsapp,signal,cli}.ex` (+ tests).

**Output:** Each channel's `parse_*` populates `metadata.user_id` and `metadata.chat_type` consistently. Per-channel test asserts the fields are populated from the right webhook source.

**Verification:** per-channel parse test using the existing fixtures.

**Stage 6 review and fix.**

### Stage 7: Wizard step + doctor probe + docs

**Files:** `apps/fermix_core/lib/fermix_core/setup/wizard.ex` (+ test), `apps/fermix_core/lib/fermix_core/setup/doctor.ex` (+ test), `README.md`, `CHANGELOG.md`.

**Output:** Wizard asks for `compaction.threshold` and per-channel `owner_user_id` (with the `/whoami` flow described in Q4). Doctor reports current threshold, per-model windows, the agent's resolved route (which compaction will follow), and per-channel owner configuration. README documents the four commands and `/whoami`.

**Verification:** wizard test asserts the new steps appear at the right point. Doctor snapshot test.

**Stage 7 review and fix.**

---

## 7. Test Plan

**Unit:**
- `ModelCatalog.context_window_for/2` for each known model + unknown model fallback + telemetry.
- `CompactionConfig.normalize/1` validation: in-range, out-of-range, invalid type.
- `ConfigStore` round-trip for `[fermix_core.compaction]` including float `threshold`.
- `Commands.parse/2`: command, command-with-args, command-with-`@botname`, `/Users/...` non-match, leading whitespace, trailing whitespace, mixed case.
- `Commands.Authorization.owner_only/3`: CLI bypass, channel with no effective owner = unauthorized, matching owner_user_id = :ok, single ingress allowlist owner fallback = :ok, multi-user ingress allowlist does not grant command auth, command allowlist match = :ok, missing `user_id` in metadata = unauthorized, channel = "telegram" with the configured `owner_user_id` matching `metadata.user_id` succeeds, mismatch fails.

**Integration:**
- `MainAgent` auto-compact: synthesize an 85%+ utilization conversation, assert one auto-compact telemetry event after the next turn, assert `ConversationStore.replace_history/3` was called with a smaller history.
- `MainAgent` auto-compact failure backoff: synthesize a Compactor failure, assert `:auto_skipped` with `reason: :recent_failure_backoff` on the next-turn check within 60s, then assert the 61st-second turn re-triggers.
- `Compactor` adapter routing: invoke `Compactor.compact/2` with `route: {route_key, adapter_opts}` for each of OpenAI Responses, Codex, and Anthropic Messages stubs; assert the summary text round-trips correctly and that no hardcoded provider is reached.
- `Dispatcher` intercept: synthetic channel, assert `/compact` runs through the intercept and never reaches `agent.handle_message`, assert plain text falls through.
- CLI end-to-end: `fermix ask /compact` returns a `Compacted: ...` reply, exits 0. `fermix ask /new` returns the fresh-session reply, exits 0. `fermix ask /help` lists the commands. `fermix ask /whoami` returns `Your user id on this channel: cli` (or the equivalent CLI marker).
- Telegram end-to-end: simulated `/compact@bot_name` from the configured owner user id → command runs. From a non-owner user id → "requires owner permissions" reply, telemetry event for `:unauthorized` with `reason: :not_owner_or_allowed`.

**Eval (skill-creator pattern):**
- Eval case: simulated long conversation with auto-compact threshold 0.85, assert response quality after compaction is comparable to baseline.
- Eval case: `/compact` followed by a question whose answer requires older context (which should now be in the summary). Assert the answer is correct.

**Manual:**
- Real Telegram chat: chat until context grows large, observe auto-compact in `~/.fermix/traces/YYYY-MM-DD/`.
- Real Telegram chat: `/new` from the owner account, then ask the agent to summarize the prior turn — it should not have access to the previous message content. Then ask the agent for a fact previously stored in long-term memory (e.g., the user's name) — it should still know.
- Real Telegram chat: `/new` from a non-owner account → reply is "requires owner permissions"; conversation history is unchanged.

---

## 8. Risk

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Auto-compaction fires too eagerly and over-summarizes (loses important detail) | M | M | Default threshold is 0.85 (matches Hermes-agent's default; only fires near limit), compaction budget is 50% (preserves recent half), summary cache prevents re-summarizing the same window twice. Eval cases catch quality regressions. |
| 2 | Channel command parser false-positive on `/path/to/file` content | L | M | Regex `^[a-z][a-z0-9_]*$` rejects multi-segment paths. Unknown commands fall through to LLM. |
| 3 | Operator deploys without an effective command owner, then is surprised commands don't work | H | L | Boot-time warning per channel that has ingress enabled but no effective owner. Doctor flags it. Wizard prompts for `owner_user_id` with the `/whoami` discovery flow, while a single existing ingress allowlist id remains compatible. |
| 4 | `/new` wipes a conversation the user actually wanted to keep (no undo) | M | M | v1: no confirmation (Q3). The `Started a fresh session. Long-term memory is preserved.` reply tries to set expectations. If complaints, add `new_requires_confirmation` config. |
| 5 | Compaction summary creation fails (provider error) and loops on every turn | L | M | Per-conversation 60s backoff after failure (Q7). |
| 6 | Per-model context windows in catalog drift from upstream changes | M | L | `[:fermix, :model_catalog, :unknown_model]` telemetry surfaces gaps. Doctor flags them. Catalog updates ship with provider releases (same convention as M4.10). |
| 7 | Slash-command surface conflicts with future Telegram BotFather command-list integration | L | L | The plain-text parser is forward-compatible: even when BotFather command list is added, Telegram still delivers `/cmd` as message content. |
| 8 | Operator sets `owner_user_id` to a numeric id but channel reports it as a string (or vice versa) | M | M | Authorization helper compares via `to_string/1` on both sides. Test covers both shapes per channel. |
| 9 | Compaction summary uses a reasoning model and burns tokens because that's what the agent is configured with | L | M | Eval cases monitor cost; if real measurements show a problem, add `[fermix_core.compaction] summary_model = "..."` as a single-key override (one-line change). v1 ships without it to avoid speculative knobs. |
| 10 | `metadata.user_id` not populated by every channel after Stage 6 → fail-closed everywhere on that channel | L | M | Stage 6's per-channel parse tests assert the field exists. Doctor at startup samples a recent message per channel and reports if `user_id` is missing. |

---

## 9. CHANGELOG (planned, on ship)

### Added — M7.1 (Conversation Lifecycle)
- Per-model context-window catalog (`ModelCatalog.context_window_for/2`) plus a safe default + telemetry for unknown models.
- `[fermix_core.compaction]` config section with `threshold` (`0.1`–`1.0`, default `0.85`) and `enabled` (default `true`). Round-tripped by `ConfigStore`, including float parse/encode and a new `:compaction` snapshot/apply branch mirroring `:routing`.
- `Memory.Compactor` now routes its summary turn through the M4.10 `Adapter.chat/3` path instead of the legacy hardcoded `Provider.OpenAI.chat/2`. Compaction follows whatever provider+model the main agent uses — OpenAI API key, Codex, or Anthropic — with no separate config. The same change drops the hardcoded `OpenAI` fallback in `agent_loop.ex:301`.
- Threshold-driven auto-compaction inside the `MainAgent` request task: after each assistant reply lands, if `tokens_used / context_window >= threshold`, the cached history is replaced via `ConversationStore.replace_history/3`. Per-conversation 60s backoff after a compaction failure.
- Channel command surface: `FermixChannels.Commands` parses leading `/cmd` (with Telegram `@botname` stripping), invoked from `FermixChannels.Dispatcher` after normalization and before agent delivery — works uniformly for every channel and preserves the `fermix ask` sync-reply path.
- Built-in commands `/compact`, `/new`, `/clear`, `/help`, `/whoami`. Authorization is owner-only via per-channel `owner_user_id` + optional `command_allowlist`; `owner_user_id` doubles as the default ingress allowlist for single-user installs, and a single legacy ingress allowlist id can act as the owner. `cli` channel is implicit-owner.
- `metadata.user_id` standardized across all channels (Telegram, Slack, Discord, WhatsApp, Signal, CLI) so authorization keys on the stable channel-native id, not the display-name `Message.sender`.
- New telemetry: `[:fermix, :compaction, :auto]`, `[:fermix, :compaction, :forced]`, `[:fermix, :compaction, :auto_skipped]`, `[:fermix, :command, :received]`, `[:fermix, :command, :unauthorized]`.
- Wizard step + `fermix doctor` section for the new compaction settings and per-channel command owner.

### Changed — M7.1
- `ConversationStore` gains `replace_history/3` for atomic history swaps.
- `FermixChannels.Dispatcher.dispatch_message/6` gains a one-place command intercept slot after normalization, before agent delivery.
- Each channel's `parse_*` populates `metadata.user_id` and `metadata.chat_type` consistently.

### Notes — M7.1
- `/new` clears `ConversationStore` history for the conversation key only. Hermes-extracted facts, Tier 1 gist, and resource registry entries are preserved. True user-scope wipe is M10's privacy/governance scope.
- Compaction summaries use the agent's configured provider+model. If the operator runs a reasoning model, summaries also use it. A `[fermix_core.compaction] summary_model = "..."` override is reserved as a follow-up if cost data shows it matters.
