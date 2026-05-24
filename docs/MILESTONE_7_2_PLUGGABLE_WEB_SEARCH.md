# Milestone 7.2: Pluggable Web Search Backends

**Status:** Draft
**Date:** 2026-05-24
**Depends on:** M7 (`web_search` shipped with keyless DuckDuckGo HTML backend), M4.9 (`CapabilityRegistry`), M4.7 (`ConfigStore` + setup wizard)
**References:** `apps/fermix_core/lib/fermix_core/tools/web_search.ex`, `apps/fermix_core/lib/fermix_core/net/guard.ex`, `apps/fermix_core/lib/fermix_core/setup/config_store.ex`
**Relationship to M7+:** `docs/MILESTONE_7_PLUS_PLUGGABLE_BACKENDS.md` drafted this same feature with a heavier architecture (generic `Capabilities.Backend` behaviour + `BackendRegistry` GenServer + `Auth.Store` keys + `BuiltinSeeder.reseed/1` socket). Neither `Capabilities.Backend` nor `BackendRegistry` exists in code, and the shipped setup layer already follows the model below — config.toml `@keyring` via `SecretPaths`/`SecretWriter`, backend read from `Application` env at call time. **M7.2 supersedes the `web_search` portion of M7+; do not build the registry/`Auth.Store` path for `web_search`.** M7+ still owns `web_fetch`, `http_request`, and the DNS cache.

## 1. Problem / Current State

`web_search` currently ignores the setup backend selection. The tool implementation is a hardcoded DuckDuckGo HTML scraper:

- endpoint: `https://html.duckduckgo.com/html/`
- parser: Floki selectors over DuckDuckGo HTML
- failure modes: `rate_limited`, `parser_changed`, `network`

The setup UI and `ConfigStore` now persist:

```toml
[fermix_core.tools.web_search]
backend = "tavily" # or duckduckgo/exa/parallel
tavily_api_key = "@keyring"
exa_api_key = "@keyring"
parallel_api_key = "@keyring"
```

But `FermixCore.Tools.WebSearch` never reads `:fermix_core, :tools`, so choosing Tavily, Exa, or Parallel has no runtime effect. Until backend dispatch lands, setup must not present paid/provider-backed choices as active functionality.

## 2. Goal

Make `web_search` backend-pluggable using direct HTTP calls, with no provider SDKs.

Initial supported backends:

- `duckduckgo` - current keyless HTML backend, retained as the default when no backend is configured (not a runtime fallback for a failed paid backend — see §3.1/§9).
- `tavily` - Tavily Search API.
- `exa` - Exa Search API.
- `parallel` - Parallel Search API.
- `brave` - Brave Web Search API.
- `perplexity` - Perplexity Search API.

xAI search is out of scope for this milestone.

## 3. Design Rules

1. **One configured backend per daemon.** No fallback chains after a backend is selected. Missing credentials fail loudly.
2. **Direct HTTP only.** Use `Req`; do not use Python, JS, or provider SDKs.
3. **Stable tool surface.** Keep the existing `web_search` arguments for v1: `{ "query": string }`.
4. **One normalized result shape.** Every backend returns `title`, `url`, and `snippet`; optional provider metadata stays internal or trace-only.
5. **Secrets stay out of plaintext.** Provider keys are stored through `SecretWriter` as `@keyring` and resolved by `ConfigStore`; logs and traces must redact credentials.
6. **Setup only exposes implemented providers.** UI choices must match runtime support.
7. **NetGuard remains in the path.** Every backend validates its endpoint before HTTP.

## 4. Backend Contract

```elixir
defmodule FermixCore.Tools.WebSearch.Backend do
  @type result :: %{
          title: String.t(),
          url: String.t(),
          snippet: String.t()
        }

  @callback name() :: atom()
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [result()]} | {:error, String.t()}
end
```

`opts` carries the resolved `[fermix_core.tools.web_search]` config keyword. Each backend reads its own credential from `opts` and validates its own endpoint with `Net.Guard` before any HTTP. There is no shared `endpoint/0` or `credential_key/0` callback: Brave is a `GET`-with-querystring while the others `POST`, so the orchestrator cannot validate a generic endpoint, and the credential-key mapping already lives in `SecretPaths` plus the config block — a third copy on the behaviour is redundant.

`WebSearch.execute/2` becomes:

1. Validate `query`.
2. Resolve the backend module from `Application.get_env(:fermix_core, :tools, [])[:web_search][:backend]`.
3. Call `backend.search(query, web_search_config)`. The config is read from `Application` env, where `ConfigStore.apply_snapshot/1` has already resolved every `@keyring` sentinel to the real key (§8) — the tool never calls `SecretWriter`.
4. Trim to `@max_results`.
5. Return `Support.success_json(results, %{result_count: n, backend: backend.name()})`.

Backend resolution rules:

- Missing/blank config → `duckduckgo` (keyless default).
- A backend recognized by config normalization but with no registered module yet (e.g. `brave` before the Brave module ships) → loud `unsupported_backend`, never a silent downgrade to DuckDuckGo.
- An unknown string never reaches the tool: `ConfigStore` normalizes it to `nil` (→ default) and the wizard rejects it at the boundary. So `unsupported_backend` guards only the half-shipped window, not arbitrary input.

## 5. Result Limit and Output Contract

The public tool schema stays:

```json
{
  "query": "latest Elixir release"
}
```

For v1, Fermix always requests at most 10 results and returns at most 10 results, even when a provider can return more. Provider request limits:

| Backend | Request limit sent by Fermix | Provider cap / note |
|---|---:|---|
| `duckduckgo` | parser reads current page, then Fermix trims to 10 | HTML page has no stable API cap |
| `tavily` | `max_results = 10` | provider supports `max_results` |
| `exa` | `numResults = 10` | provider supports `numResults` |
| `parallel` | one `search_queries` entry for v1, then Fermix trims to 10 | query expansion deferred |
| `brave` | `count = 10` | provider caps web `count` at 20 |
| `perplexity` | `max_results = 10` | provider supports `max_results` |

Successful output is always JSON encoded as a list:

```json
[
  {
    "title": "Elixir v1.18 released",
    "url": "https://example.com/elixir-release",
    "snippet": "Short provider-supplied summary or excerpt."
  }
]
```

Response metadata:

```json
{
  "result_count": 1,
  "backend": "brave"
}
```

Rules:

- `title`, `url`, and `snippet` are always strings.
- Results with blank `title` or blank `url` are dropped.
- A 200 response with an empty result list is `result_count: 0` success — not `parser_changed`. Reserve `parser_changed` for a 200 whose shape the backend parser did not recognize.
- `snippet` may be `""` if the provider returns no usable excerpt.
- Provider-specific fields such as score, published date, highlights, or raw content are not exposed in v1.
- No pagination is exposed in v1.

## 6. Provider Matrix

| Backend | Runtime fit | Auth | Endpoint | Notes |
|---|---|---|---|---|
| `duckduckgo` | Supported today | none | `POST https://html.duckduckgo.com/html/` | Keyless, brittle HTML parsing. |
| `tavily` | Good v1 fit | Bearer token | `POST https://api.tavily.com/search` | Returns `results[]` with `title`, `url`, `content`; supports `max_results`, `search_depth`, domain filters, and optional raw content. |
| `exa` | Good v1 fit | `x-api-key` | `POST https://api.exa.ai/search` | Returns web results and can include `contents.highlights` or text for better snippets. |
| `parallel` | Good v1 fit | `x-api-key` | `POST https://api.parallel.ai/v1/search` | Designed for agent queries; returns ranked results with LLM-optimized excerpts. |
| `brave` | Good v1 fit | `X-Subscription-Token` | `GET https://api.search.brave.com/res/v1/web/search` | Independent web index; returns `web.results[]` with `title`, `url`, `description`, and optional `extra_snippets`. |
| `perplexity` | Good v1 fit | Bearer token | `POST https://api.perplexity.ai/search` | Returns structured `results[]` with `title`, `url`, `snippet`, `date`, `last_updated`. |

## 7. Provider Request Shapes

### 7.1 Tavily

Request:

```json
{
  "query": "latest Elixir release",
  "max_results": 10,
  "search_depth": "basic",
  "include_answer": false,
  "include_raw_content": false,
  "include_images": false
}
```

Headers:

```text
Authorization: Bearer <TAVILY_API_KEY>
Content-Type: application/json
```

Normalize:

- `results[].title` -> `title`
- `results[].url` -> `url`
- `results[].content` -> `snippet`

Use `search_depth = "basic"` by default to avoid accidentally doubling cost through advanced search. Do not enable `auto_parameters` for v1; provider docs note it can select advanced search and consume extra credits.

### 7.2 Exa

Request:

```json
{
  "query": "latest Elixir release",
  "numResults": 10,
  "contents": {
    "highlights": true
  }
}
```

Headers:

```text
x-api-key: <EXA_API_KEY>
Content-Type: application/json
```

Normalize:

- result title -> `title`
- result URL -> `url`
- first highlight, joined highlights, or result text excerpt -> `snippet`

Use highlights first because Exa documents them as token-efficient content for search results.

### 7.3 Parallel

Request:

```json
{
  "objective": "Find current, reliable web sources for: latest Elixir release",
  "search_queries": ["latest Elixir release"]
}
```

Headers:

```text
x-api-key: <PARALLEL_API_KEY>
Content-Type: application/json
```

Normalize:

- `results[].title` -> `title`
- `results[].url` -> `url`
- `results[].excerpts` joined with spaces -> `snippet`

Parallel recommends concise keyword search queries, 3-6 words each, with 2-3 queries for best results. V1 should send the user's query as the single query to preserve the existing `web_search` contract; query expansion can be a later model-side feature.

### 7.4 Perplexity

Request:

```json
{
  "query": "latest Elixir release",
  "max_results": 10
}
```

Headers:

```text
Authorization: Bearer <PERPLEXITY_API_KEY>
Content-Type: application/json
```

Normalize:

- `results[].title` -> `title`
- `results[].url` -> `url`
- `results[].snippet` -> `snippet`

Perplexity's Search API is the correct endpoint for `web_search`; do not use Sonar for this tool because Sonar returns a prose answer with citations instead of a results array.

### 7.5 Brave

Request:

```text
GET https://api.search.brave.com/res/v1/web/search?q=latest%20Elixir%20release&count=10&safesearch=moderate
```

Headers:

```text
X-Subscription-Token: <BRAVE_API_KEY>
Accept: application/json
Accept-Encoding: gzip
```

Normalize:

- `web.results[].title` -> `title`
- `web.results[].url` -> `url`
- `web.results[].description` -> `snippet`
- if present, append selected `web.results[].extra_snippets` after the main description

Use `count = min(@max_results, 20)` because Brave caps web-result count at 20. Keep `offset = 0` in v1; if pagination is added later, check `query.more_results_available` before requesting more pages. Use `safesearch = "moderate"` by default. Brave's Web Search API enforces a provider query limit of 400 characters and 50 words, so the backend should return `query_too_long` before issuing the request when the query exceeds either cap.

Brave's documentation recommends its LLM Context endpoint for agents/chatbots, but Fermix's current `web_search` contract is a list of sources. Use Web Search for this milestone; evaluate LLM Context later if Fermix adds a separate answer/context tool.

## 8. Config

```toml
[fermix_core.tools.web_search]
backend = "perplexity" # duckduckgo | tavily | exa | parallel | brave | perplexity
tavily_api_key = "@keyring"
exa_api_key = "@keyring"
parallel_api_key = "@keyring"
brave_api_key = "@keyring"
perplexity_api_key = "@keyring"
```

`web_search` has exactly one active backend. Changing the search engine updates the
single `backend` value in place; it must not create per-backend `enabled` flags or
multiple backend entries. Credentials for inactive backends may remain in the same
block as stored secrets so an operator can switch back without re-entering the key.
At runtime, only the credential for the selected backend is read.

Today only `tavily`, `exa`, and `parallel` are wired through setup; `brave` and `perplexity` are net-new. Each keyed backend needs **all five** wiring points — miss one and the key silently fails:

| # | File | Change |
|---|---|---|
| 1 | `setup/secret_paths.ex` | add `:brave_api_key`/`:perplexity_api_key`, path `[:fermix_core, :tools, :web_search, :*]` (set `sandbox_env: true` to match the existing entries — see note) |
| 2 | `setup/config_store.ex` `normalize_web_search_backend/1` | accept the atom and string forms |
| 3 | `setup/config_store.ex` `normalize_web_search_tool/1` | normalize the new `*_api_key` field |
| 4 | `setup/wizard.ex` | `@type answer`, `normalize_web_search_backend/1` (currently **raises** on unknown), `put_web_search_config/2` |
| 5 | `fermix_web .../setup_live.ex` + `setup_live/components.ex` | `normalize_search_backend/1`, `search_form` assign, `save_search`, the radio option, and the key field |

`SecretPaths` (point 1) is load-bearing: `SecretWriter.put`/`get!` resolve the key via `SecretPaths.fetch!/1` and raise `unknown setup secret key` for an unregistered key, and `ConfigStore` only resolves `@keyring` sentinels for paths in `SecretPaths.all/0`. Skip it and the wizard crashes on save, or the backend receives the literal string `"@keyring"` as its key.

Registration is what enables `@keyring` resolution; `sandbox_env: true` is independent of it. That flag only controls whether the env name is also injected into spawned subprocesses via `[sandbox.env]` (`Wizard.ensure_sandbox_env_sources/2`). The web_search backends call providers BEAM-side over `Req`, so they don't functionally need subprocess injection — keep `sandbox_env: true` only to match the existing `tavily`/`exa`/`parallel` entries, not because resolution requires it.

`ConfigStore.dump_snapshot/1` renders the whole `web_search` keyword generically, so no dump change is needed. Keep credentials optional in TOML because only the selected backend needs its key.

**Trace redaction (required for Brave):** add `x-subscription-token` to `Net.Guard`'s `@sensitive_headers`. Tavily/Perplexity (`Authorization`) and Exa/Parallel (`x-api-key`) are already redacted, but Brave's `X-Subscription-Token` is not — without this the key lands in `web_search` trace metadata, breaking design rule §3.5.

## 9. Error Contract

All backends return existing tool-style string errors:

| Error tag | Meaning |
|---|---|
| `query_too_long` | query exceeds Fermix's max length, or a backend-specific cap (e.g. Brave's 400 chars / 50 words per §7.5) |
| `unsupported_backend` | configured backend is recognized by config but has no implemented module (e.g. `brave` before its module ships). Unknown strings normalize to `nil` → DuckDuckGo per §4 and never reach this tag. |
| `auth_failed` | key missing, invalid, or unauthorized |
| `rate_limited` | provider returned a rate-limit or quota response |
| `provider_error` | provider returned non-auth, non-rate-limit 4xx/5xx |
| `parser_changed` | response shape did not match the backend parser |
| `network` | transport or NetGuard failure |

Do not silently fall back to DuckDuckGo when a paid provider fails. The operator configured that backend; failures must be visible.

## 10. Setup UI Rule

**Current state (must fix):** the LiveView already renders `tavily`/`exa`/`parallel` as live, selectable radios with active key fields (`setup_live/components.ex`), and `save_search` persists them — while the runtime tool ignores config entirely. That is exactly the bug this section guards against, already shipped. The CLI wizard, by contrast, has no web_search prompt at all (`Wizard.prompts/2` covers provider/compaction/realtime/channel/personalization only) — backend selection is LiveView-only. Decide explicitly: gate the LiveView options until runtime dispatch lands, or land dispatch first.

Before backend implementations land:

- show only DuckDuckGo as selectable, or
- render Tavily/Exa/Parallel/Brave/Perplexity as disabled "coming soon" choices.

After implementations land:

- show only implemented backends.
- show the matching key field for the selected provider.
- allow changing the active search engine by overwriting the single
  `[fermix_core.tools.web_search].backend` value.
- save the selected backend and key through `Wizard.save_answers/1`.
- keep stored credentials for non-selected providers unless the operator explicitly
  removes them through a future credential-management path.
- run a doctor probe before showing the provider as healthy.

This prevents the current bug: setup can persist a backend that runtime ignores.

## 11. Doctor Probe

Add a `fermix doctor` check for `web_search`. Split along the existing offline-default / `--full`-network convention (`fermix/cli/doctor.ex`: `--full` already gates the provider auth probe), so a routine `fermix doctor` never spends a paid search credit.

**Default (`fermix doctor`) — offline:**

1. Resolve the active backend.
2. Check whether the required credential is present, without printing it.
3. Report `backend` and `credential_present?`. If the active backend is recognized but unimplemented, report `unsupported_backend`. No network call.

**`fermix doctor --full` — adds the live probe:**

4. Run a one-result probe query against the live provider.
5. Add `probe_result: ok | auth_failed | rate_limited | provider_error | parser_changed | network` and `result_count`.

Gating the live query behind `--full` keeps repeated `fermix doctor` runs free and rate-limit-safe, and matches the cost-consciousness in §7.1. Only an explicit `--full` spends a credit.

## 12. Implementation Plan

| Step | Change | Verify |
|---|---|---|
| 0 | Fix setup UI so unsupported providers are disabled or hidden until runtime backends exist. | LiveView test: selecting unsupported backend is impossible or clearly disabled. |
| 1 | Add `WebSearch.Backend` behaviour and `WebSearch.Backends.DuckDuckGo`. Move existing parser unchanged. | Existing `web_search` tests pass unchanged. |
| 2 | Refactor `WebSearch.execute/2` to resolve configured backend and emit backend metadata. | Unit tests for default, unknown backend, and missing credential. |
| 3 | Add Tavily backend. | Req stub tests for success, 401, 429, bad shape. |
| 4 | Add Exa backend. | Req stub tests for highlights/text normalization. |
| 5 | Add Parallel backend. | Req stub tests for excerpts normalization and warnings ignored safely. |
| 6 | Add Brave backend, config/secret path support, and `x-subscription-token` to `Net.Guard` redaction. | Req stub tests for `web.results` normalization, 401, 429, provider query limits, plus a trace-redaction assertion for `X-Subscription-Token`. |
| 7 | Add Perplexity backend plus config/secret path support. | Config round-trip and Req stub tests. |
| 8 | Re-enable provider options in setup only after each backend's tests pass. | Setup test changes the active backend in the existing config block, preserves inactive credentials, saves the selected key sentinel, and doctor reports health. |
| 9 | Add doctor probe: offline default (presence-only) + `--full` live probe. | Doctor test: offline path reports `credential_present?` with no network call; `--full` runs the live probe, on one keyless and one keyed backend. |

## 13. Tests

- `ConfigStore` round-trips `backend` and each key sentinel.
- `SecretPaths` covers every keyed implemented provider.
- Backend resolver:
  - missing config -> DuckDuckGo
  - unknown persisted config -> DuckDuckGo after normalization
  - recognized but unimplemented backend -> `unsupported_backend`
  - selected keyed backend with missing key -> `auth_failed`
- Each backend:
  - maps provider JSON to `[%{title, url, snippet}]`
  - redacts auth headers in trace metadata
  - handles 401/403 as `auth_failed`
  - handles 429/quota as `rate_limited`
  - handles schema drift as `parser_changed`
- `WebSearch.execute/2` includes `result_count` and `backend` metadata.
- Setup UI cannot persist a backend that is not implemented.
- Setup UI changes search engines by overwriting the single `backend` value and
  leaving stored credentials for inactive providers intact.

## 14. Success Criteria

- Selecting Tavily, Exa, Parallel, Brave, or Perplexity changes runtime search behavior.
- No SDKs are used; all providers are direct HTTP adapters.
- Setup choices match implemented runtime backends.
- Paid provider failures are loud and traceable, never silently routed to DuckDuckGo.
- Doctor can validate the active backend without exposing credentials.
