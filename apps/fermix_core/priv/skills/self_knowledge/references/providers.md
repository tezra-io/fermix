# Providers — per-provider config, setup panes, retry, and transport

The body carries how an operator picks a provider and a model. This file carries
the per-provider wire detail, the setup surfaces, and the retry/transport
mechanics underneath.

## Per-provider blocks

All eight run turns. The registry behind them is
`FermixCore.Providers.Descriptor` — one declarative entry per provider, holding
labels, auth modes, setup fields, and config-key allowlists. Unknown TOML keys in
any provider block, and an unknown `[fermix_core.agent] provider`, fail loud at
config load rather than being silently dropped.

- **OpenAI** and **Codex** (`openai`, `openai_codex`) ride the OpenAI Responses
  wire. Codex authenticates with a ChatGPT subscription OAuth connection
  (`fermix auth login`) and carries the extra `fast` behavior knob.
- **Anthropic** (`[fermix_core.providers.anthropic]`) supports two auth modes via
  `auth_mode = "api_key" | "oauth"`: an API key (`api_key`), or Claude
  subscription OAuth (profile `anthropic_oauth` in `auth.json`; connect with
  `fermix auth login --provider anthropic` using `--setup-token`,
  `--import-claude-code`, or `CLAUDE_CODE_OAUTH_TOKEN`). OAuth requests emulate
  Claude Code — identity headers plus a system block, and `mcp_`-prefixed tool
  names — and auto-refresh with one 401 retry. Every Anthropic request sends
  prompt-cache breakpoints and requests adaptive thinking on models that support
  it: the model decides when and how much to deliberate, `reasoning_effort`
  calibrates it, and a model without adaptive thinking (Haiku 4.5) gets no
  thinking parameter. Non-streaming output caps at `max_tokens` 16384, sized so
  thinking plus the visible answer fit the buffered receive window.
- **SpaceXAI Grok** (`[fermix_core.providers.xai]`) also supports two auth modes
  via `auth_mode = "api_key" | "oauth"`: a bearer API key (`api_key`,
  `XAI_API_KEY`), or Grok Build subscription OAuth (loopback PKCE, profile
  `xai_oauth`; connect with `fermix auth login --provider xai`). A 403 means the
  Grok plan lacks API access, not a stale token. Grok rides the OpenAI Responses
  wire shape with efforts `none|low|medium|high|xhigh`; some Grok models reject
  an effort field and get it omitted, and slash-containing enum values are
  stripped from tool schemas.
- **OpenRouter** (`[fermix_core.providers.openrouter]`: `api_key` via
  `OPENROUTER_API_KEY`, optional `base_url`, `default_model`, `primary`) rides the
  Chat Completions wire with vendor-prefixed model ids
  (`anthropic/claude-sonnet-4.6`, dots not dashes) and static attribution headers
  (`HTTP-Referer: https://fermix.sh`, `X-Title: Fermix`). It sends no
  reasoning-effort field, so the server default applies.
- **Mistral** (`[fermix_core.providers.mistral]`: `api_key` via
  `MISTRAL_API_KEY`, optional `base_url`, `default_model`, `primary`) also rides
  the Chat Completions wire, with three rolling `-latest` tiers —
  `mistral-large-latest`, `mistral-medium-latest`, `mistral-small-latest` — a
  plain Bearer key, no attribution headers, and no reasoning-effort field.
  Mistral's strict validator rejects an assistant turn carrying empty-string
  `content` alongside `tool_calls`, so the shared Chat Completions adapter omits
  the `content` key whenever tool calls are present — a wire shape valid on every
  Chat Completions provider.
- **Venice** (`[fermix_core.providers.venice]`: `api_key` via `VENICE_API_KEY`,
  optional `base_url`, `default_model`, `primary`) also rides the Chat
  Completions wire, against `https://api.venice.ai/api/v1`, with a plain Bearer
  key, no attribution headers, and no reasoning-effort field. Two constants, not
  settings, ride every request: Venice is told not to prepend its own system
  prompt, and to strip inline thinking out of the reply. Fermix does not use
  Venice's end-to-end encrypted mode, because that mode turns off tool calling
  and system prompts. The default model is `grok-4-6`, a private one. The doctor
  probe asks `/api_keys/rate_limits` rather than the model list, which is public
  and answers without a key.
- **Ollama** (`[fermix_core.providers.ollama]`: `base_url`, whose presence is what
  marks it configured, env `OLLAMA_BASE_URL`; `default_model`; `primary`) is
  **keyless** — `auth_mode :none` internally, no Authorization header and no
  secret — against the local OpenAI-compatible endpoint
  (`http://localhost:11434/v1` by default; remote and Tailscale hosts work), with
  a 300s receive timeout for slow local inference. Catalog windows are model
  capability while the server may serve far less and truncate silently, so the
  doctor probe also POSTs the native `/api/show` and **fails loud when the served
  `num_ctx` undercuts the catalog window**; fix that with `OLLAMA_CONTEXT_LENGTH`
  or a Modelfile `num_ctx`. A 404 from the probe means the model is not pulled
  (`ollama pull <model>`).

A Realtime API key reuses the OpenAI provider key slot but does not, on its own,
promote OpenAI to primary — only a real provider credential or an explicit
primary choice does. CLI OAuth login never changes primary.

## Reasoning effort

`reasoning_effort` is accepted only for the effort-capable providers — OpenAI,
Codex, Anthropic, and SpaceXAI. An OpenRouter, Mistral, Venice, or Ollama block
rejects the key at config load, routing-level effort overlays skip their routes,
and their telemetry reports `reasoning_effort: nil`.

Effort is one canonical vocabulary — `FermixCore.Providers.ReasoningEffort`:
`none|low|medium|high|xhigh|max` — with per-provider subsets, mapped to each
provider's wire field (`reasoning.effort` for OpenAI, Codex and SpaceXAI;
`output_config.effort` for Anthropic). Anthropic has no `none`: its floor is
`low` and the API default is `high`. A level above a provider's ceiling clamps.

On top of the provider subset a model can carry its own ceiling in the catalog.
The current OpenAI and Codex generations (GPT-6 Astra, Sol and Luna; GPT-5.6)
reach `max` while `gpt-5.5`, `gpt-5.4` and `gpt-5.4-mini` top out at `xhigh`, and
every Grok before 4.6 tops out at `high`. An over-reaching config self-heals down to that model
ceiling at route resolution instead of 400-ing at the provider. A model with no
catalog ceiling passes through untouched, leaving Anthropic's per-model nuance to
the provider's own 400.

## Setup surfaces

- The web setup provider page renders per-provider cards — status `Primary`,
  `Fallback`, or `Not configured` — as the provider selector. Picking a card
  loads that provider into the "Configuring …" form, and saving it makes that
  provider primary, which needs a daemon restart. A configured, non-primary card
  also carries a "Set primary" button that flips the flag without re-entering
  credentials. Nothing is disabled, so any provider can be selected and set up.
- The page has an API-key vs OAuth picker per provider: SpaceXAI offers a
  loopback "Connect Grok" like Codex, Anthropic takes a pasted
  `claude setup-token` or a Claude Code login import. A stored token is inert
  until `auth_mode = "oauth"`, so connecting in the web page and
  `fermix auth login --provider xai|anthropic` both set `auth_mode = oauth` in
  config, and `fermix auth logout` reverts it to `api_key`. The change reaches the
  daemon on restart.
- The Ollama pane detects the server with a single probe: the configured URL
  either serves `GET /api/tags` or it does not. A reachable server lists **only
  the locally installed models** in the model picker; an unreachable one shows the
  error with `ollama serve` and install guidance plus a free-form model input.
- The OpenRouter pane fetches the **live upstream catalog**
  (`GET /api/v1/models`, tool-capable models only, newest first), so every
  current model is selectable; on fetch failure it shows the error and a
  free-form input (`FermixCore.Providers.ModelListing`). The static catalog stays
  authoritative for defaults and context windows.
- The Venice pane fetches Venice's **live model list** the same way (every
  tool-calling model), ordered by model family and then newest first, and every
  label ends with that model's privacy tier: `Private` (the prompt is not kept),
  `Anonymized` (passed to the model's maker without the account, and the maker
  still reads the prompt), or `Private (TEE)` for a model inside a hardware
  enclave. An info control beside the Model row carries the same explanation, on
  the web page and in the macOS app.
- The "Model behavior" panel — reasoning effort and Codex `fast` — is hidden for
  providers with no behavior knobs: OpenRouter, Mistral, Venice, and Ollama.
- Both the CLI wizard and the web page offer effort for the effort-capable
  providers only, and list only the levels the selected model accepts.
- The web setup Media tab exposes an editable OpenAI/SpaceXAI key field inline
  beside the image-backend picker. It writes the same `openai_api_key` /
  `xai_api_key` provider secret those providers use for chat: it reads as
  already-configured when a key is stored, blank keeps the stored key, and a
  pasted value replaces it — so the `generate_image` key can be set without
  opening the provider's full setup form.

## Retry before failover

Before any failover hop, the turn's initial model call gets a **bounded
same-provider retry** with short exponential backoff on transient infrastructure
errors: the `connection_unavailable` pool-checkout and wake-from-sleep race,
transport timeout, close or network error, and a provider 5xx. A brief flake
therefore self-heals on the same provider instead of surfacing or burning a
failover hop.

The retry budget is spent **before** any failover hop, on every route. The next
route is a different **model**, and the loop pins the winning route for the rest
of the tool loop, so hopping on the first transient would silently re-target the
whole turn onto a weaker model under a `status: ok`.

`connection_unavailable` is network-wide, so it retries the same route and never
fails over at all. Scheduled jobs opt out of this inner retry entirely — the two
retry loops never stack, and a slow provider `:timeout` cannot overrun the job's
configured timeout — and keep their own coarser deadline-bounded backoff, which
covers only the wake-from-sleep pool-checkout race. A cron run therefore still
fails over on the first transient of any other kind.

A **continuation** call, mid tool loop, that fails transiently is re-issued in
place on the same route with a short bounded backoff, on every surface including
scheduled runs. It replays no tools and never switches provider. Its retryable
classes are explicit:

- a transport timeout the adapter **measured** as pre-response (zero response
  chunks seen — a connect-phase or first-byte stall). Only chunk-counting
  adapters like Codex can prove this, so a buffered adapter's timeout never
  qualifies;
- a pool-checkout failure (`connection_unavailable`), which fires before the
  request function runs — zero bytes on the wire, so re-issuing cannot duplicate
  work;
- a transport cut or network error;
- a provider-declared unavailability or overload.

Each one retries only when the failed attempt itself streamed nothing
user-visible, because a retry after visible content would duplicate it.
Unmeasured timeouts, rate limits, and everything else surface on the first
failure. A genuine rate-limit or quota error whose body carries a reset time
surfaces a friendly "usage limit — try again in ~N min" reply.

## Transport and the Codex delivery gate

Provider and channel HTTP share `FermixCore.Finch`. Idle keep-alive connections
older than 15s are discarded at checkout. Codex retries `:closed` once only when
it happens before response data; a mid-response `:closed` or `:timeout` is not
retried at the HTTP layer.

A Codex 200 whose SSE stream **delivered no text and no tool call** is never read
as an empty answer. The gate is what the turn delivered — not whether the stream
finished tidily, and not how many output items arrived — so a cut carrying only a
`reasoning` item (which every Codex call asks for, making it the first frame on
the wire) and a `completed` response whose items render nothing are both errors
rather than silent empty turns.

The two undelivered facts stay distinct. A stream that **declared** its failure
(`response.failed` / `response.incomplete` / `error` with nothing generated)
becomes an API-classified error: overload and server_error text classify as
provider-unavailable, which is retryable and failover-eligible, and the server's
own sentence is quoted verbatim in the user-facing reply, so a provider-side
outage never reads as a Fermix defect. A stream cut with no declared reason is
classified as a transport close — retryable on the same route, failover-eligible
— with the reason in the log and the trace.

A stream that delivered usable output but never said it finished still returns
that output, with a warning: output items accumulate independently of the
terminal event, discarding them would throw away a usable answer, and on a
continuation, which never fails over, it would kill the turn outright.

A `:timeout` the adapter measured as pre-response (zero chunks) is retried one
level up, at the agent loop's continuation seam. A mid-stream or unmeasured
`:timeout` is never retried.
