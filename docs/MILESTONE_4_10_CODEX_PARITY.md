# Milestone 4.10: Codex Parity & Provider Selection UX

**Status:** Draft
**Date:** 2026-04-30
**Author:** Sujeeth / Aira
**Depends on:** M4.9 (Unified Capabilities — `Adapter` behaviour, `RouteResolver`, `OpenAI.Codex` adapter scaffold, `OpenAI.Responses` continuation model)
**Sequel to:** M4.9 review fix #4 ("stop auto-routing OAuth → Codex"), which surfaced the gap this milestone closes
**Blocks:** M4.11 (Scheduled Agents) — scheduled jobs are agent loops with tool calls; without M4.10 they degrade to text-only or 401 on ChatGPT Plus tokens

---

## 1. Problem / Goal

After M4.9 shipped, the supported provider matrix is:

| Provider key | Adapter | Tool calls? | Auth that works |
|---|---|---|---|
| `:openai` | `OpenAI.Responses` (gpt-* on api.openai.com) / `OpenAI.ChatCompletions` (other) | Yes | API key with `api.responses.write` scope, OR a real OpenAI org OAuth token with the same scope |
| `:openai_codex` | `OpenAI.Codex` (`chatgpt.com/backend-api/codex/responses`) | **No** — `to_provider_tools/1` returns `[]`, `continue/3` returns `{:error, :tool_calls_not_supported_on_codex}` | ChatGPT Plus OAuth (Codex auth flow) |
| `:anthropic` | `Anthropic.Messages` | Yes | Anthropic API key |

The gap: **a ChatGPT Plus user has no working configuration that gives them the agent loop**. Their OAuth token does not carry `api.responses.write` on `api.openai.com`, so `:openai` 401s. Their only working surface is `chatgpt.com/backend-api/codex/responses`, which Fermix's `OpenAI.Codex` adapter explicitly does not implement tool calls for. The result: the bot responds with text but can never invoke a capability — no `MemoryRecall`, no `Shell`, no skills, no MCP. That is a P0 user-facing breakage of the M4.9 design promise.

The secondary gap: there is **no UX for choosing a provider or model**. `RouteResolver` reads `:provider`, `:default_model`, and (newly added in the post-M4.9 patch) honors a configured provider, but `ConfigStore.normalize_openai/1` does not round-trip `default_model`, the wizard never asks, and there is no per-provider model catalog. Users edit TOML by hand; new users have no path at all.

The tertiary gap: **reasoning effort is unwired**. `OpenAI.Codex` does not send a `reasoning_effort` body field. Both rustyclaw and hermes-agent set this per call (`low | medium | high | xhigh`); without it, the user's choice of "intelligence" is meaningless.

**Goal of M4.10:** make `:openai_codex` a first-class agent provider with full tool-call support, persist provider/model/reasoning_effort in user config with TOML round-trip and env-var overlays, expose a wizard step for provider+model+effort selection, and surface the chosen surface in `fermix doctor` with a real auth probe so configuration mistakes fail at boot instead of on the first user message.

After this milestone:

1. ChatGPT Plus users configure `provider = "openai_codex"` and get the same agent loop tool-call behavior as API-key users — no degraded mode.
2. The setup wizard prompts: provider → model → reasoning effort, with the selected combination written to `~/.fermix/config.toml`.
3. `fermix doctor` performs an auth-scope probe per provider (a minimal real API call) and fails loudly with an actionable message when, e.g., a ChatGPT Plus token is configured against `:openai`.
4. Per-agent provider/model overrides from M4.9's `AgentDefinition` continue to work; this milestone only adds the *defaults* surface and the Codex adapter completion.
5. Reasoning effort is plumbed end-to-end for Codex (and forward-compatible for Responses' newer reasoning fields).

**Non-goal:** new providers (Gemini, OpenRouter, Ollama) — those are separate work in `Additional Providers (Ongoing)` from `docs/ROADMAP.md`. Streaming partial tokens to channels is also out — agent loop continues to deliver complete turns.

---

## 2. Reference Implementations

Two existing codebases implement Codex tool calls correctly. We borrow shape, not code.

### 2.1 RustyClaw (`~/projects/rustyclaw`)

`src/providers/openai_codex.rs`:

- POSTs to `https://chatgpt.com/backend-api/codex/responses` with `stream: true`.
- Sends the same `tools: [{type: "function", name, description, parameters, strict: false}]` shape as standard Responses.
- Adds Codex-specific headers: `openai-beta: responses=experimental`, `originator: pi`, optional `chatgpt-account-id` decoded from the JWT (we already do this in `OpenAI.Codex.chat/3`).
- Sends `reasoning: {effort: <level>}` body field, with per-model clamping (`clamp_reasoning_effort/2` at line 277). Reasoning effort sourced from env var `RUSTYCLAW_CODEX_REASONING_EFFORT`, default `xhigh`.
- Parses the SSE stream line by line; `data:` lines are JSON objects with `type` discriminator: `response.created`, `response.output_item.added`, `response.output_item.done`, `response.output_text.delta`, `response.completed`, etc. Function calls arrive as `output_item.added` items of type `function_call`, populated incrementally by `function_call_arguments.delta` events, finalized on `output_item.done`.
- Continuation: same shape as standard Responses — prior input + preserved output items (function_call, reasoning) + new function_call_output items keyed by call_id.

### 2.2 Hermes-agent (`~/projects/hermes-agent`)

`hermes_constants.py`:

- `VALID_REASONING_EFFORTS = ("minimal", "low", "medium", "high", "xhigh")`.
- `parse_reasoning_effort/1` returns `{"enabled": False}` for `"none"`, otherwise `{"enabled": True, "effort": <level>}`. Caller decides default.

`run_agent.py:679–712`, `run_agent.py:3435–3454`, `run_agent.py:3567–3612`:

- The `gpt-*` model family is force-routed onto `codex_responses` mode regardless of provider name — same observation that M4.9 §4.10 already documents.
- Function-call continuation is keyed by API-emitted `call_id`. The deterministic SHA256 fallback (already present in `OpenAI.Responses` at `responses.ex:254`) is used only when the API omits one.
- Reasoning items are carried byte-identical between turns.

**What we do not adopt:**

- Per-model reasoning-effort *clamping tables* (rustyclaw's `clamp_reasoning_effort`). The model list is volatile (gpt-5-codex / gpt-5.4-codex / gpt-5.4-mini constraints differ; new models drop the table out of date in weeks). M4.10 sends the user's chosen effort verbatim and surfaces the API's 400 if the model rejects it, with a hint pointing at the wizard. (See §4 Q2.)
- Env-var-only effort selection. M4.10 stores effort in TOML (with env override) so it round-trips.
- JSON job storage (hermes uses `~/.hermes/cron/jobs.json`) — that's M4.11's concern.

---

## 3. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---|---|---|---|
| Codex tool-call adapter | P0 | Modify | Implement `to_provider_tools/1` (function-tool shape, `strict: false`), `parse_tool_calls/1` (read from SSE-accumulated `function_call` items), and `continue/3` (next-turn input = prior input + preserved output items + `function_call_output` items, keyed by API `call_id`). |
| Codex SSE stream parser | P0 | New | Stateful accumulator that consumes `data:` lines, builds the final response item list (function_call args assembled from incremental `function_call_arguments.delta` events), terminates on `response.completed`. Module-private to `OpenAI.Codex`. |
| Codex reasoning effort | P1 | New | Send `reasoning: %{effort: <level>}` in the request body when configured. Level read from adapter opts, sourced from agent definition or app config. |
| Provider/model/effort persistence | P0 | New | `ConfigStore.normalize_openai/1` (and `normalize_anthropic/1` for parity) read/write `provider`, `default_model`, `reasoning_effort`. TOML render (`render_section`) emits them. |
| Env-var overlays | P0 | New | `runtime.exs` overlays `FERMIX_PROVIDER`, `FERMIX_DEFAULT_MODEL`, `FERMIX_REASONING_EFFORT` on top of TOML — same pattern as the existing OpenAI auth_mode/api_key overlay. |
| Model catalog | P0 | New | `FermixCore.Providers.ModelCatalog` module exposing `models_for(provider)` returning `[{id, label}]`. Static lists per provider, plus a `:custom` escape hatch for the wizard. |
| Wizard provider step | P0 | New | New `:provider` wizard step (extends `wizard_state.ex` `step` type). Asks: provider (radio), then model (single-select from catalog or custom), then reasoning effort (radio: `none | minimal | low | medium | high | xhigh`). Persists into `[fermix_core.providers.<provider>]` block. |
| Wizard Codex disclaimer | P0 | New | When the user picks `:openai_codex`, surface the ChatGPT Plus auth requirement and the M4.10 tool-call support note inline, before model select. |
| Doctor auth probe | P0 | New | Per-provider, perform a minimal real API call (1-token completion or equivalent) to verify auth scope works against the chosen surface. Fails with actionable message. |
| Doctor surface report | P1 | Modify | `fermix doctor` output includes the resolved provider/model/effort and the probe result. |
| MainAgent provider source | P0 | Modify | MainAgent currently passes `state.adapter_overrides` (set only via opts) to `RouteResolver.resolve!`. Make it default to `[provider: configured_provider, model: configured_model, reasoning_effort: configured_effort]` when not explicitly overridden, sourced from `:fermix_core` app env. (Builds on the post-M4.9 patch that already plumbs `:provider` via config fallback.) |
| Telemetry | P1 | New | `:fermix, :provider, :call` metadata gains `reasoning_effort` field. |
| Test corpus | P0 | New | Recorded SSE fixtures for Codex (1 function_call, N function_calls, function_call + reasoning, completion-only). Fixtures replay through `parse_tool_calls/1` and `continue/3` in unit tests. |

### Non-Goals

| Feature | Reason | When |
|---|---|---|
| New providers (Gemini, OpenRouter, Ollama) | Each is its own surface decision and adapter implementation. M4.10 is about closing the existing 3-provider gap, not expanding it. | Additional Providers (Ongoing) |
| Streaming partial tokens to channels | Agent loop today delivers complete turns; channels render text as a single message. Real streaming is a cross-cutting UX change. | M6 (DX) or later |
| Per-model reasoning-effort clamping table | Volatile, goes stale, hides the real API error. We send verbatim and surface the 400. | Never (intentional) |
| Switching reasoning effort mid-conversation | Effort is set at agent boot per agent definition / config. | Later if needed |
| Web UI for provider config | CLI/wizard first. LiveView dashboard is a separate concern. | M5/M6 |
| Auto-detection of token type (Plus vs API key) | Doctor's auth probe is a better signal — it tells you what works, not what we guessed. | Avoid |

---

## 4. Design

### 4.1 Codex SSE Parser

The Codex Responses stream is line-oriented SSE. Each line is either empty (event delimiter), a comment (`:` prefix), or `data: <json>`. Final event is `data: [DONE]` or `event: response.completed`.

State accumulator structure:

```elixir
%{
  output_items: [],            # finalized items in order (function_call, reasoning, message)
  in_progress: %{              # item index -> partial item (key matches `output_index`)
    0 => %{type: "function_call", id: "fc_...", call_id: "call_...",
           name: "memory_recall", arguments_buffer: "{\"query\":\"sun"}
  },
  text_chunks: [],             # accumulated message output_text deltas, in order
  usage: %{prompt_tokens: 0, completion_tokens: 0},
  model: nil,
  done?: false
}
```

Event handling (subset; full event grammar follows the OpenAI Responses streaming spec):

| Event `type` | Action |
|---|---|
| `response.created` | Capture `model`. |
| `response.output_item.added` | Insert partial item at `output_index`. For `function_call`: capture `id`, `call_id`, `name`, init `arguments_buffer = ""`. For `reasoning`: capture `id`, init `encrypted_content_buffer = ""`. |
| `response.function_call_arguments.delta` | Append `delta` to `in_progress[output_index].arguments_buffer`. |
| `response.reasoning_summary_text.delta` | Append `delta` to reasoning buffer (where present). |
| `response.output_text.delta` | Append to `text_chunks`. |
| `response.output_item.done` | Move item from `in_progress` to `output_items`, finalizing buffers (e.g., `arguments = arguments_buffer`). |
| `response.completed` | Capture final `usage`, set `done? = true`. |
| `[DONE]` | Terminate stream loop. |

Result of stream consumption: a `body`-shaped map identical to the standard Responses `body["output"]` shape, so the existing `parse_tool_calls/1` and `build_turn/5` in `OpenAI.Responses` can be reused — we extract them into `OpenAI.ResponsesShared` and have both adapters call into it.

**Module-private to `OpenAI.Codex`.** No streaming abstraction layer. `Req`'s built-in stream handling (`into: :self` or `Req.Response.Async`) feeds lines to the accumulator inside the adapter call.

### 4.2 `to_provider_tools/1`

Same shape as `OpenAI.Responses.to_provider_tools/1`:

```elixir
%{type: "function", name: cap.name, description: cap.description,
  parameters: cap.parameters, strict: false}
```

Move the implementation into `OpenAI.ResponsesShared.to_provider_tools/1` and have both adapters delegate.

### 4.3 `continue/3`

Same continuation logic as `OpenAI.Responses.continue/3`:

```elixir
next_input = prior_input ++ output_items ++ function_call_outputs
```

`function_call_outputs` are `%{type: "function_call_output", call_id: ..., output: ...}`, keyed by the API-emitted `call_id` from the previous turn's `function_call`.

Codex-specific differences:

- The body still includes `stream: true` and the Codex headers.
- Reasoning items present in the previous turn's output must be passed through byte-identical (per M4.9 §4.10), including any `encrypted_content` field if Codex emits it (TBD — fixture-driven).

### 4.4 Reasoning effort

Adapter opts gain `:reasoning_effort` (atom or binary, validated against `~w(none minimal low medium high xhigh)a`). When non-nil and non-`:none`, the request body includes:

```elixir
reasoning: %{effort: Atom.to_string(effort)}
```

The route resolver reads it from agent opts → app config (`:fermix_core, :providers, :openai, :reasoning_effort`) → omitted (no body field) in priority order. If the value is `:none`, the field is omitted entirely (the model uses its provider-side default).

### 4.5 Config schema

New TOML keys under `[fermix_core.providers.openai]`:

```toml
[fermix_core.providers.openai]
auth_mode = "oauth"            # existing
api_key = ""                   # existing
provider = "openai_codex"      # NEW (added in post-M4.9 patch)
default_model = "gpt-5.5"      # NEW
reasoning_effort = "high"      # NEW (only meaningful for codex/responses)
```

Same shape under `[fermix_core.providers.anthropic]`:

```toml
[fermix_core.providers.anthropic]
auth_mode = "api_key"          # NEW
api_key = ""                   # NEW
default_model = "claude-sonnet-4-6"   # NEW
```

`ConfigStore.normalize_openai/1` and `normalize_anthropic/1` read all of these into the keyword list. `render_section/2` writes them back when the user re-runs setup or saves over an existing config.

### 4.6 Env-var overlays

`config/runtime.exs` adds (parallel to existing `OPENAI_AUTH_MODE` / `OPENAI_API_KEY`):

```
FERMIX_PROVIDER          → :openai | :openai_codex | :anthropic
FERMIX_DEFAULT_MODEL     → string, no validation against catalog (allows new releases)
FERMIX_REASONING_EFFORT  → none | minimal | low | medium | high | xhigh
```

Validation: invalid enum values log a warning and fall back to the TOML value (don't crash boot). Same fail-soft pattern as the existing `OPENAI_AUTH_MODE` overlay.

### 4.7 Model catalog

`FermixCore.Providers.ModelCatalog`:

```elixir
@spec models_for(:openai | :openai_codex | :anthropic) :: [{id :: String.t(), label :: String.t()}]
def models_for(:openai_codex), do: [
  {"gpt-5.5",      "GPT-5.5 (default, latest)"},
  {"gpt-5.4",      "GPT-5.4"},
  {"gpt-5.4-mini", "GPT-5.4 mini (faster, cheaper)"}
]

def models_for(:openai), do: [
  {"gpt-5.5",      "GPT-5.5 (default, recommended)"},
  {"gpt-5.4",      "GPT-5.4"},
  {"gpt-5.4-mini", "GPT-5.4 mini"}
]

# The first entry is the wizard default for that provider.

def models_for(:anthropic), do: [
  {"claude-sonnet-4-6", "Claude Sonnet 4.6 (recommended)"},
  {"claude-opus-4-7",   "Claude Opus 4.7 (best quality)"},
  {"claude-haiku-4-5",  "Claude Haiku 4.5 (fastest)"}
]
```

The wizard renders this list plus a `Custom...` option that takes free-form input. Free-form is not validated — the doctor probe catches typos at boot time.

Catalog updates require a code change. We do not fetch model lists from provider APIs at runtime — that adds a network dependency to setup and most providers don't expose a clean enumeration anyway.

### 4.8 Wizard step

Extend `WizardState.step` type:

```elixir
@type step :: :provider | :model | :channel | :personalization | :review
```

(`:provider` already exists; we add `:model` immediately after.) The provider step also collects `reasoning_effort` for OpenAI/Codex providers (Anthropic does not use it).

Step UX (CLI):

```
Which provider should fermix use?
  1) OpenAI (api.openai.com)             — needs an API key with api.responses.write
  2) OpenAI Codex (chatgpt.com)          — uses ChatGPT Plus OAuth (Codex auth flow)
  3) Anthropic (api.anthropic.com)       — needs an Anthropic API key

Pick a model:
  1) GPT-5.5         (default, latest)   ← default
  2) GPT-5.4
  3) GPT-5.4 mini    (faster, cheaper)
  4) Custom...

Reasoning effort? (only used by OpenAI / Codex)
  1) none
  2) minimal
  3) low
  4) medium
  5) high              ← default
  6) xhigh             (slowest, most thorough)
```

After the user picks, the wizard writes to TOML, runs the doctor probe, and on probe failure offers to re-pick instead of completing the wizard.

### 4.9 Doctor auth probe

`FermixCore.Setup.Doctor` gains `probe_provider/1`:

| Provider | Probe |
|---|---|
| `:openai` | `POST /v1/responses` with `model: <default_model>, input: [<minimal>], max_output_tokens: 1`. 200 = pass. 401/403 = fail with "auth scope mismatch — token does not have api.responses.write on api.openai.com". |
| `:openai_codex` | `POST /backend-api/codex/responses` with same body + Codex headers. 200 = pass. 401 = fail with "Codex token rejected — re-run `fermix codex login`". |
| `:anthropic` | `POST /v1/messages` with `model: <default_model>, max_tokens: 1, messages: [...]`. 200 = pass. 401 = fail with "API key rejected". |

Probes cost ~$0.0001 (1 token). They run during `fermix doctor` and at the end of the wizard. They do not run on every boot.

---

## 5. Open Decisions (defaults applied unless overridden in review)

**Q1. Per-agent vs global reasoning effort.**
**Default:** per-agent, with the main-agent default sourced from app config. Matches M4.9's `AgentDefinition.{provider, model}` precedent. Sub-agent effort, when unspecified, inherits the configured default.

**Q2. Per-model effort clamping vs let-the-API-reject.**
**Default:** no clamping. Pass the user's chosen effort verbatim. On 400, surface the error with a hint to re-run the wizard. Avoids stale tables. (Trade-off: users see one bad call before being told what's wrong; doctor probe catches the common case at config time.)

**Q3. Model catalog source of truth.**
**Default:** static list in `FermixCore.Providers.ModelCatalog`, with `Custom...` escape hatch in the wizard. Catalog updates ship in code, not config.

**Q4. Doctor probe mechanism.**
**Default:** real $0.0001 minimal API call per provider. Token introspection isn't reliably available across surfaces. Probes are gated behind `fermix doctor` and the wizard finalize step — not run on every daemon boot.

---

## 6. Stages

Each stage is a self-contained PR with code + tests + format/credo green. No stage merges with the prior stage's promised-but-deferred work outstanding. Estimates are **agent wall-clock**, not human-developer time — the entire milestone fits in one review day.

### Stage 1 — Codex tool-call adapter (1.5–3 h, P0)

- Extract shared logic into `OpenAI.ResponsesShared` (`to_provider_tools/1`, `build_turn/5`, `parse_tool_calls/1`, `deterministic_call_id/3`).
- Build `OpenAI.Codex.SSEParser` (module-private struct + reducer).
- Implement `OpenAI.Codex.to_provider_tools/1`, `parse_tool_calls/1`, `continue/3`.
- Update `OpenAI.Codex.chat/3` to send `tools:` body field, consume the SSE stream into a body map, and return the same shape as `OpenAI.Responses.chat/3`.
- Tests: SSE fixture corpus (1 function_call, N function_calls, function_call + text, error responses). Replay through adapter; assert returned `tool_calls` and `provider_state`.
- Drop the `:tool_calls_not_supported_on_codex` error path entirely.

### Stage 2 — Reasoning effort plumbing (30–45 min, P1)

- Add `:reasoning_effort` to `OpenAI.Codex.chat/3` opts. When non-nil and non-`:none`, send `reasoning: %{effort: <string>}`.
- Same for `OpenAI.Responses.chat/3` (forward-compatible — Responses also supports a reasoning field on o-series models).
- `RouteResolver.resolve!/1` reads `:reasoning_effort` from opts → `Config.provider(:openai)[:reasoning_effort]` → omitted.
- Tests: assert request body shape with/without effort, with `:none` (omitted), with each valid level.

### Stage 3 — Config schema + env overlays (30–45 min, P0)

- `ConfigStore.normalize_openai/1` reads `provider`, `default_model`, `reasoning_effort` from TOML.
- `ConfigStore.normalize_anthropic/1` reads `auth_mode`, `api_key`, `default_model`.
- `ConfigStore.render_section/2` writes them back. Round-trip test: parse → render → parse, byte-equal where possible.
- `runtime.exs` overlays `FERMIX_PROVIDER`, `FERMIX_DEFAULT_MODEL`, `FERMIX_REASONING_EFFORT`. Invalid enum → warning + fall back.
- Tests: env overlay precedence (env > TOML > default), invalid enum logs and falls back.

### Stage 4 — Model catalog + wizard step (1–1.5 h, P0)

- `FermixCore.Providers.ModelCatalog.models_for/1` static lists.
- Extend `WizardState.step` with `:model`. Provider step now also asks for reasoning effort (OpenAI/Codex only).
- Wizard writes the selection through `ConfigStore.write/1`.
- Tests: simulate wizard input → assert TOML output.

### Stage 5 — Doctor auth probe (45 min – 1 h, P0)

- `FermixCore.Setup.Doctor.probe_provider/1`. Per-provider real minimal API call. Returns `{:ok, %{model, latency_ms}}` or `{:error, {:auth_scope_mismatch, surface, hint}}`.
- `fermix doctor` invocation includes the probe in its output and exits non-zero on probe failure.
- Wizard finalize step calls the probe before declaring success.
- Tests: mock provider responses (200, 401, 403, 5xx); assert error mapping.

### Stage 6 — MainAgent default sourcing (20–30 min, P0)

- MainAgent reads provider/model/reasoning_effort from `:fermix_core, :providers` at init, populates `state.adapter_overrides` if not already set by opts.
- Tests: boot MainAgent with config → assert resolved route matches.

### Stage 7 — Cleanup + CHANGELOG + ROADMAP (15–20 min)

- Remove the M4.9 module doc note in `OpenAI.Codex` saying tool calls aren't supported.
- Update `docs/MILESTONE_4_9_UNIFIED_CAPABILITIES.md` "Codex auth → Responses" line to point at this milestone for the actual user path.
- CHANGELOG entry.
- ROADMAP: confirm M4.10 entry, M4.11 sequencing.

**Total agent wall-clock: ~5–8 hours. Stage 1's SSE parser is the only realistic source of variance — fixture surprises, retry patterns from Codex's stream shape, or `Req` streaming quirks could push that stage to the high end. Everything downstream is small and additive.**

**Reviewable in one end-of-day pass.**

---

## 7. Test Plan

### 7.1 Unit tests

- **Codex SSE parser** — golden-file replay of recorded streams, asserting final `output_items` order and content.
- **Codex `to_provider_tools/1`** — shape matches Responses adapter byte-for-byte (since they delegate to shared module).
- **Codex `continue/3`** — assert `function_call_output` items match `call_id`s from prior turn; assert reasoning items pass through byte-identical.
- **Reasoning effort body shape** — every level + `:none` (omitted) + nil (omitted).
- **`ConfigStore.normalize_openai/1`** — reads provider/default_model/reasoning_effort from TOML.
- **`ConfigStore.render_section/2`** — round-trips written values.
- **Env overlays** — precedence and invalid-value handling.
- **`ModelCatalog.models_for/1`** — returns expected lists per provider.
- **`Doctor.probe_provider/1`** — happy path + 401 + 403 + 5xx + transport error.
- **`MainAgent` boot** — picks up configured provider/model/effort when adapter_overrides empty.

### 7.2 Integration tests

- **End-to-end Codex tool call** — recorded fixture: chat → tool call → continue → terminal message. Asserts `provider_state` survives the round-trip.
- **End-to-end Codex parallel tool calls** — fixture with N function_calls in one response; all outputs returned in correlation order.
- **Wizard happy path** — provider Codex → model gpt-5.5 → effort high → write TOML → doctor probe (mocked) → success.
- **Wizard probe failure path** — provider OpenAI + ChatGPT Plus token → probe 401 → wizard re-prompts.

### 7.3 Manual verification (post-merge sanity)

- ChatGPT Plus user runs `FERMIX_HOME=~/.fermix-test mix run -e 'Fermix.CLI.main(["setup"])'`, picks Codex + gpt-5.5 + high, sees doctor pass, messages bot, bot recalls memory.
- Same user re-runs setup, switches to Anthropic with API key, doctor passes, bot still works.

---

## 8. Risk and Rollback

**Risk 1: Codex SSE shape diverges from documented Responses streaming.** Codex is a private surface — no public spec. We mitigate by recording fixtures from a real ChatGPT Plus session and round-tripping them through the parser. If the API changes shape post-merge, the recorded tests will pass while production breaks. Mitigation: doctor probe runs a real call, so the divergence is caught at config/boot.

**Risk 2: Model name volatility.** GPT-5.4-mini today, GPT-5.6 tomorrow. We mitigate via the wizard's `Custom...` escape hatch and free-form `default_model` writes. Catalog updates are code-shipped but not blocking.

**Risk 3: Reasoning effort rejection per model.** Some models reject `xhigh` or `minimal`. We do not clamp (Q2 default). Doctor probe is sent without effort, so a probe pass does not guarantee the chosen effort is accepted. Acceptable trade-off; a 400 on first message is recoverable by re-running the wizard.

**Risk 4: Wizard regressions.** `WizardState.step` already exists; we are adding to it. We mitigate by running existing wizard tests and adding new ones before extending the type.

**Rollback:** any stage can be reverted independently. The Codex adapter changes (Stage 1) are the only ones that change runtime semantics; reverting Stage 1 returns Codex to text-only (the M4.9 state) while leaving config schema and wizard intact.

---

## 9. CHANGELOG entry shape

```
### Added — M4.10
- OpenAI.Codex adapter now supports tool calls. ChatGPT Plus users can run the
  full agent loop without an API key.
- Provider, default model, and reasoning effort persist in config.toml
  ([fermix_core.providers.openai|anthropic]) and round-trip through the wizard.
- New env-var overlays: FERMIX_PROVIDER, FERMIX_DEFAULT_MODEL, FERMIX_REASONING_EFFORT.
- FermixCore.Providers.ModelCatalog exposes per-provider curated model lists
  for the wizard.
- Setup wizard prompts for provider → model → reasoning effort, with a
  doctor auth probe at finalize.
- fermix doctor performs a per-provider auth probe; mismatched token/surface
  combinations fail with an actionable message instead of producing 401s on
  the first message.

### Removed — M4.10
- :tool_calls_not_supported_on_codex error path. Codex now supports tool
  calls in line with OpenAI.Responses.
```
