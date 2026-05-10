# Milestone 7+: Pluggable Capability Backends

**Status:** Draft
**Date:** 2026-05-09
**Author:** Sujeeth / Aira
**Depends on:** M4.8 (`fermix` daemon + control socket), M4.9 (`Capability` behaviour, `CapabilityRegistry`, `BuiltinSeeder`), M4.10 (`Setup.ConfigStore`, wizard step pattern, `Doctor`), M7 (`Tools.WebSearch`, `Tools.WebFetch`, `Net.Guard`, the keyless catalog this milestone makes pluggable)
**Blocks:** any future built-in tool that needs an API key or per-tool TOML config (rendered fetch, structured-output search, image generation, etc.)
**References:** `apps/fermix_core/lib/fermix_core/capabilities/builtin_seeder.ex`, `apps/fermix_core/lib/fermix_core/setup/config_store.ex`, `apps/fermix_core/lib/fermix/cli/daemon.ex`, `apps/fermix_core/lib/fermix_core/tools/web_search.ex`, `apps/fermix_core/lib/fermix_core/tools/web_fetch.ex`, `apps/fermix_core/lib/fermix_core/net/guard.ex`, `apps/fermix_core/lib/fermix_core/setup/doctor.ex`, `~/projects/rustyclaw/src/tools/http_request.rs` (port reference for `http_request`)

---

## 1. Problem / Goal

M7 deliberately shipped every built-in keyless: `web_search` uses DuckDuckGo's HTML SERP scrape, `web_fetch` uses raw HTTP with no rendering. That gets the catalog complete with zero onboarding, but it leaves three real gaps:

1. **`web_search` is fragile.** DuckDuckGo's HTML page changes layout silently, returns CAPTCHA challenges under load, and rate-limits aggressively. M7's failure contract surfaces these honestly (`:rate_limited`, `:parser_changed`), but the operator has no recourse — there's no way to switch to a paid backend (Tavily, Parallel REST, Brave) that returns structured results with an SLA.

2. **`web_fetch` can't render JavaScript.** Many sites the agent gets asked about (Substack, modern docs sites) return a near-empty `<body>` to a non-JS fetch. A second backend (Browserless, ScrapingBee, or a local headless Chrome via the existing browser harness) is the obvious next step but needs per-tool config.

3. **`http_request` is missing.** RustyClaw ships an `http_request` tool that accepts arbitrary URLs, but it requires `[http_request].allowed_domains` to be configured (`~/projects/rustyclaw/src/tools/http_request.rs:47`) — the operator declares which hosts the agent may hit. M7 deferred it because there was no per-tool TOML schema to express that constraint.

All three problems share the same plumbing requirement: **per-capability backend selection plus per-tool TOML config plus an API-key wizard surface plus live re-registration without daemon restart**. Building any one alone duplicates 80% of the other two. M7+ designs the plumbing once and lands all three on top of it.

**Goal of M7+:** ship the per-capability backend abstraction (`Capability.Backend` behaviour + a registry per capability), the `[fermix_core.tools.<name>]` TOML schema with `ConfigStore` round-trip, the `BuiltinSeeder.reseed/1` flow plus the daemon control-socket `:reseed_builtins` request, the API-key wizard surface, doctor probes per backend, and the `http_request` tool that this plumbing finally makes safe to ship.

After this milestone:

1. The operator can run `fermix setup` and pick a backend per capability: `web_search` → `tavily | parallel | duckduckgo` (default), `web_fetch` → `direct | browserless` (default `direct`). The wizard collects API keys via the existing pattern, persists them under `[fermix_core.tools.<name>]`, and reloads the registered backend without a daemon restart.
2. `http_request` ships with `[http_request].allowed_domains` config. The agent gets one new capability that can hit any explicitly allow-listed host. `NetGuard` enforces the allow-list in addition to its existing public-only rules.
3. `BuiltinSeeder` gains a `reseed/1` API and the daemon exposes a `:reseed_builtins` socket method. After the wizard writes a key, the daemon re-registers the affected capabilities with the new backend live; existing in-flight LLM turns are unaffected (the registry is queried per-turn).
4. `fermix doctor` adds a per-backend probe section. For each registered backend that has a known reachability check (Tavily `/health`, Browserless `/json`), doctor reports `ok | unauthorized | unreachable | not configured`.
5. `Net.Guard` gains explicit DNS preflight timeouts and an optional small per-daemon LRU cache for successful public resolutions, mitigating the per-request resolver cost called out in M7's accepted residual gap.

**Non-goal:** tool-side load-balancing, multi-backend fallback cascades, or A/B testing across backends. v1 ships one selected backend per capability per daemon. The agent doesn't see backend choice — it just calls `web_search`, and whichever backend the operator picked answers.

**Non-goal:** secrets management beyond M4.8's `Auth.Store` pattern. Per-tool API keys live in the same encrypted-at-rest store; no new keystore infrastructure.

**Non-goal:** the M9 self-knowledge agent's tool-discovery flow. M7+ provides the surface area; M9 (if it lands) reads it.

---

## 2. References

- **Existing Fermix code:**
  - `apps/fermix_core/lib/fermix_core/capabilities/builtin_seeder.ex` — single-shot supervised seeder; M7+ adds `reseed/1`.
  - `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex` — the `Tool` behaviour modules (`WebSearch`, `WebFetch`, etc.) that gain backend dispatch.
  - `apps/fermix_core/lib/fermix_core/setup/config_store.ex:308-334` — `[fermix_core.routing]` round-trip pattern, copied for `[fermix_core.tools.<name>]`.
  - `apps/fermix_core/lib/fermix/cli/daemon.ex:160-191` — `handle_request/2`; gains `:reseed_builtins` clause.
  - `apps/fermix_core/lib/fermix_core/auth/store.ex` — atomic + 0600 store; reused for per-tool API keys (separate provider namespace).
  - `apps/fermix_core/lib/fermix_core/setup/doctor.ex` — gains a `:tools` section with per-backend probes.
  - `apps/fermix_core/lib/fermix_core/setup/wizard.ex` — gains an optional `:tools` step gated on the operator opting into a non-default backend.

- **External backends in scope for v1:**
  - **Tavily** (https://tavily.com) — REST, requires API key. Returns structured `{title, url, snippet, score, content}` results. Free tier exists.
  - **Parallel REST** (https://parallel.ai) — REST, requires API key. Returns structured results with citations.
  - **DuckDuckGo HTML SERP** — keyless default, already shipped in M7.
  - **Browserless** (https://browserless.io) — hosted headless Chrome over WS or REST. API key required.
  - **Direct fetch** — keyless default, already shipped as `WebFetch` in M7.

- **Port reference for `http_request`:** `~/projects/rustyclaw/src/tools/http_request.rs:47` — `allowed_domains` config, methods allowlist (`GET, POST, PUT, PATCH, DELETE, HEAD`), max body size, header allow-list.

- **What we do not adopt:**
  - A per-backend retry/circuit-breaker abstraction. `FermixCore.Net.HttpClient` already does the stale-pool retry; backend-level retries belong to each backend module if needed.
  - Backend-side caching. If Tavily caches its own results, fine; we don't add a layer.
  - A "backend marketplace" concept. v1 has a fixed set of backends per capability shipped with the binary. Third-party backends are out of scope.

---

## 3. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---|---|---|---|
| `Capability.Backend` behaviour | P0 | New | `@callback name() :: atom()`, `@callback execute(args, context) :: {:ok, result} \| {:error, term()}`, `@callback configured?(opts) :: boolean()`, `@callback doctor_probe(opts) :: {:ok, info} \| {:error, reason}`. Used by tools that want backend selection (`web_search`, `web_fetch`, `http_request`). |
| Per-capability backend registry | P0 | New | `Capability.BackendRegistry.get(:web_search)` returns the active backend module + opts for the configured backend. Populated at boot and on `reseed_builtins`. |
| `[fermix_core.tools.<name>]` TOML schema | P0 | New | Per-tool config sections. Round-tripped by `ConfigStore`. Each tool's section is opaque to ConfigStore — validation lives in the tool's `Tool.validate_config/1` callback. |
| `Tool.validate_config/1` callback | P0 | Modify | Add `@callback validate_config(map()) :: :ok \| {:error, term()}` to `Builtin.Tool`. Existing tools return `:ok` for empty config. New backend-selecting tools validate the `backend` value and required keys. |
| `BuiltinSeeder.reseed/1` | P0 | New | Re-register the named built-in (or all built-ins) using the current `[fermix_core.tools]` config snapshot. Atomic per-tool: either the new backend installs cleanly or the old one keeps serving. |
| Daemon `:reseed_builtins` socket method | P0 | New | New control-socket method. Called by `Setup.Wizard` after writing config; called by operator-driven `fermix tools reload` CLI (P1). Returns `{ok, [reseeded_tool_names]}` or `{error, reason}`. |
| Per-tool API key persistence | P0 | New | Reuses `Auth.Store` with provider namespace `:tool_<name>` (e.g., `:tool_web_search_tavily`). 0600 file, atomic write. Wizard-collected. |
| `web_search` backend selection | P0 | Modify | `Tools.WebSearch.execute/2` delegates to the configured backend (`Backends.DuckDuckGo`, `Backends.Tavily`, `Backends.Parallel`). DuckDuckGo remains the default; the existing M7 implementation moves into `Backends.DuckDuckGo`. |
| `web_search` Tavily backend | P1 | New | `Tools.WebSearch.Backends.Tavily.execute/2` calls `https://api.tavily.com/search` with the configured key. Returns the same `[%{title, url, snippet}]` result shape as the keyless backend. Failure modes: `:unauthorized`, `:rate_limited`, `:network`. |
| `web_search` Parallel REST backend | P1 | New | Same shape as Tavily. |
| `web_fetch` backend selection | P1 | Modify | Default `direct` backend is the M7 implementation. New `browserless` backend renders JS via Browserless's `/content` REST endpoint. |
| `http_request` tool | P0 | New | Port from RustyClaw. Methods allowlist `GET, POST, PUT, PATCH, DELETE, HEAD`. Per-tool `[http_request].allowed_domains` (string list, exact host match). Max body size 1MB (configurable per tool). NetGuard enforces public-only on top of the allow-list. Headers are operator-controllable via `[http_request].allowed_request_headers`; sensitive headers stripped from telemetry by `Net.Guard.redact_headers_for_trace/1`. |
| `NetGuard` allow-list extension | P0 | Modify | `Net.Guard.validate/2` gains a `:allowed_domains` opt. When set, the validation passes ONLY if the host is in the list (in addition to the existing public-only rules). The keyless tools (`web_fetch`, `web_search`) don't pass this opt; `http_request` always does. |
| `NetGuard` bounded DNS preflight | P1 | Modify | Explicit `:dns_timeout_ms` opt (default 2_000). On timeout: `{:error, {:dns_resolution_failed, :timeout}}`. New `Net.DnsCache` GenServer with a small per-daemon LRU (`:ets`-backed, max 256 entries, TTL 60s) for successful resolutions. Off-by-default behind `[fermix_core.net.dns_cache] enabled = false`. |
| Wizard backend-selection step | P0 | New | New optional `:tools` step in `Setup.Wizard` after the existing M4.10 model step. For each tool with backend choices, the wizard offers `Default (keyless)` plus configured alternatives. Choosing a non-default prompts for the API key, persists it via `Auth.Store`, and writes `[fermix_core.tools.<name>] backend = "..."` to `config.toml`. |
| `fermix doctor` per-backend probes | P0 | New | New doctor section listing each registered tool, the active backend, and a probe result. Probes call `Backend.doctor_probe/1` on each backend module. Network-touching probes are gated on `--full`. |
| `fermix tools reload` CLI | P1 | New | Operator command that triggers `:reseed_builtins` over the daemon socket. Exits 0 on success, 1 on per-tool failure (with which tool failed in stderr). |
| Telemetry | P1 | New | `[:fermix, :tool, :backend_dispatched]` (per call), `[:fermix, :builtin, :reseed]` (per reseed event with success/failure list). |
| Documentation | P0 | Docs | README section for backend selection. Each backend's tool docs (via `tool_help`) state which backend is active. |

### Non-Goals

| Feature | Reason | When |
|---|---|---|
| Multi-backend fallback (try Tavily, fall back to DuckDuckGo on failure) | Adds opaque retry semantics across paid + free providers, makes failures harder to debug, and risks billing surprises. | Future, opt-in only |
| A/B testing across backends | Same complexity, no clear trigger to ship now. | Never |
| Per-conversation backend override (one chat uses Tavily, another uses DDG) | Adds conversation-state coupling; v1 has one daemon-global pick per tool. | Future if asked |
| User-installable third-party backends | Plugin loading is a separate trust + security problem (M10 territory). | Never as part of this milestone |
| `image_generation`, `pdf_render`, `screenshot` tools | Demand-driven — out of scope unless a specific use case lands. | Future ecosystem |
| `git_push` exposure | M10 owns approval-gated capabilities. Not a backend-selection issue. | M10 |
| OAuth-based per-tool auth | Tools today use simple API keys. OAuth (e.g., GitHub OAuth-scoped tool) is a separate plumbing problem with consent UX. | Future |

### Overlap with M4.10 (clarified)

M4.10 introduced `[fermix_core.routing]` and `[providers.<name>]`. M7+ adds `[fermix_core.tools.<name>]` parallel to that. ConfigStore's existing render/parse logic is the template; per-tool sections are opaque key=value bags that ConfigStore round-trips without inspecting (validation lives in the tool itself).

### Overlap with M7 (clarified)

M7 shipped `web_search` and `web_fetch` as single-implementation tools. M7+ refactors each into `Tool` (orchestrator) + `Backends.<Name>` (implementations). The M7 implementations move verbatim into `Backends.DuckDuckGo` / `Backends.Direct` with no behavior change for operators on defaults.

---

## 4. Core Design

### 4.1 Runtime Shape

```
                          ┌───────────────────────────────────┐
                          │  config.toml                      │
                          │    [fermix_core.tools.web_search] │
                          │      backend = "tavily"           │
                          │    [fermix_core.tools.http_request]│
                          │      allowed_domains = [...]      │
                          └─────────────┬─────────────────────┘
                                        │
                                        ▼
        ┌──────────────────────────────────────────────────┐
        │ Setup.ConfigStore                                │
        │   load_runtime_config → snapshot                 │
        │   apply_snapshot       → Application env         │
        └─────────────┬────────────────────────────────────┘
                      │
   ┌──────────────────┼──────────────────┐
   ▼                  ▼                  ▼
Auth.Store      BuiltinSeeder     Capability.BackendRegistry
(API keys)        .reseed/1          (per-tool active backend)
                      │                  ▲
                      └──────────────────┘
                               │
                               ▼
                    Tools.WebSearch.execute/2
                               │
                    ┌──────────┼──────────┐
                    ▼          ▼          ▼
             Backends.       Backends.    Backends.
             DuckDuckGo      Tavily       Parallel
                    │          │          │
                    └──────┬───┴──────────┘
                           ▼
                  FermixCore.Net.HttpClient.request/2
                  (existing stale-pool retry + NetGuard)
```

### 4.2 `Capability.Backend` Behaviour

```elixir
defmodule FermixCore.Capabilities.Backend do
  @callback name() :: atom()                                      # :duckduckgo, :tavily, :parallel
  @callback execute(args :: map(), context :: map()) ::
              {:ok, result :: term()} | {:error, term()}
  @callback configured?(opts :: keyword()) :: boolean()           # are required keys present?
  @callback doctor_probe(opts :: keyword()) ::
              {:ok, info :: map()} | {:error, reason :: atom()}
end
```

Each backend module implements this. The orchestrating `Tool` looks up the active backend from `BackendRegistry`, validates `configured?`, then calls `execute/2`. If `configured?` returns false, the tool returns `{:error, :backend_not_configured}` with an actionable message ("Run `fermix setup --reconfigure-tool web_search`").

### 4.3 `Capability.BackendRegistry`

In-memory state in a GenServer started under the existing capabilities supervisor. Populated at boot from `BuiltinSeeder` and re-populated on `reseed_builtins`.

```elixir
defmodule FermixCore.Capabilities.BackendRegistry do
  use GenServer

  @spec get(tool_name :: String.t()) :: {:ok, backend :: module(), opts :: keyword()} | :error
  def get(tool_name) do
    GenServer.call(__MODULE__, {:get, tool_name})
  end

  @spec install(tool_name :: String.t(), backend :: module(), opts :: keyword()) :: :ok
  def install(tool_name, backend, opts) do
    GenServer.call(__MODULE__, {:install, tool_name, backend, opts})
  end

  @spec uninstall(tool_name :: String.t()) :: :ok
  def uninstall(tool_name), do: GenServer.call(__MODULE__, {:uninstall, tool_name})
end
```

`install/3` is atomic — it replaces the entry under one transaction. Mid-flight tool calls (which already have a captured `{backend, opts}` from `get/1`) are not interrupted. The next call gets the new backend.

### 4.4 `[fermix_core.tools.<name>]` TOML Schema

Each tool with backend choice gets a section. Examples:

```toml
[fermix_core.tools.web_search]
backend = "tavily"               # one of: duckduckgo (default), tavily, parallel

[fermix_core.tools.web_fetch]
backend = "direct"               # one of: direct (default), browserless

[fermix_core.tools.http_request]
allowed_domains = [
  "api.example.com",
  "internal-svc.dev"
]
allowed_request_headers = ["x-correlation-id"]
max_body_bytes = 1048576
methods = ["GET", "POST"]        # subset of the supported set

[fermix_core.net.dns_cache]
enabled = false
max_entries = 256
ttl_seconds = 60
```

API keys live in `Auth.Store`, NOT in `config.toml` (so config.toml stays safe to share/version). The tool's `Backend.execute/2` reads the key via `TokenManager`-equivalent for tools (a thin `Tools.Secrets.fetch/1` wrapper over `Auth.Store`).

`ConfigStore` round-trip:
- `load_runtime_config/0` reads each `[fermix_core.tools.*]` section into a generic `tools: %{web_search: [...], web_fetch: [...], ...}` keyword on the snapshot.
- `apply_snapshot/1` calls `BuiltinSeeder.reseed_with_config/1` with the new tools map.
- `save_snapshot/1` renders each section back, omitting keys that match defaults (so config.toml stays minimal).

### 4.5 `BuiltinSeeder.reseed/1` and Daemon Plumbing

```elixir
defmodule FermixCore.Capabilities.BuiltinSeeder do
  @spec reseed(tools_config :: map() | :all) :: {:ok, [String.t()]} | {:error, term()}
  def reseed(:all), do: reseed(current_tools_config())

  def reseed(tools_config) when is_map(tools_config) do
    Enum.reduce_while(builtin_tool_modules(), {:ok, []}, fn module, {:ok, done} ->
      tool_name = module.name()
      tool_config = Map.get(tools_config, tool_name, %{})

      with :ok <- validate_tool_config(module, tool_config),
           {:ok, backend, backend_opts} <- pick_backend(module, tool_config),
           :ok <- BackendRegistry.install(tool_name, backend, backend_opts) do
        {:cont, {:ok, [tool_name | done]}}
      else
        {:error, reason} ->
          Logger.error("Builtin reseed failed for #{tool_name}: #{inspect(reason)}")
          {:halt, {:error, {tool_name, reason}}}
      end
    end)
  end
end
```

Daemon socket method (`apps/fermix_core/lib/fermix/cli/daemon.ex`):

```elixir
{:ok, %{"method" => "reseed_builtins"} = request} ->
  reseed_builtins_reply(request)
```

```elixir
defp reseed_builtins_reply(request) do
  scope = Map.get(request, "params", %{}) |> Map.get("scope", "all")

  result =
    case scope do
      "all" -> BuiltinSeeder.reseed(:all)
      tool when is_binary(tool) -> BuiltinSeeder.reseed(%{tool => current_tool_config(tool)})
    end

  case result do
    {:ok, names} -> %{status: "ok", reseeded: names}
    {:error, reason} -> %{status: "error", reason: reason_to_string(reason)}
  end
end
```

The `Daemon.handle_request/2` comment about "keep new methods read-only unless explicit auth or operator confirmation" is updated: `:reseed_builtins` is a write but is operator-driven (called by the wizard or `fermix tools reload`); the 0600 UDS remains the trust boundary.

### 4.6 Backend Implementations

#### `Tools.WebSearch.Backends.DuckDuckGo` (default, keyless)

The current M7 implementation moves verbatim into this module. No code change beyond namespace.

#### `Tools.WebSearch.Backends.Tavily`

```elixir
defmodule FermixCore.Tools.WebSearch.Backends.Tavily do
  @behaviour FermixCore.Capabilities.Backend

  alias FermixCore.Net.HttpClient
  alias FermixCore.Tools.Secrets

  @endpoint "https://api.tavily.com/search"

  @impl true
  def name, do: :tavily

  @impl true
  def configured?(_opts), do: match?({:ok, _}, Secrets.fetch(:web_search_tavily))

  @impl true
  def execute(%{"query" => query}, _context) do
    with {:ok, key} <- Secrets.fetch(:web_search_tavily) do
      body = %{api_key: key, query: query, max_results: 10, include_answer: false}

      Req.new(url: @endpoint, method: :post, json: body)
      |> HttpClient.request("Tavily")
      |> handle_response()
    end
  end

  @impl true
  def doctor_probe(_opts) do
    case Secrets.fetch(:web_search_tavily) do
      {:ok, _key} -> {:ok, %{configured: true}}
      :error -> {:error, :not_configured}
    end
  end

  defp handle_response({:ok, %{status: 200, body: body}}), do: parse_results(body)
  defp handle_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp handle_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp parse_results(%{"results" => results}) when is_list(results) do
    {:ok, Enum.map(results, fn r ->
      %{title: r["title"] || "", url: r["url"] || "", snippet: r["content"] || ""}
    end)}
  end

  defp parse_results(_), do: {:error, :unexpected_shape}
end
```

#### `Tools.WebSearch.Backends.Parallel`

Same shape — different endpoint, different request body, same result shape.

#### `Tools.WebFetch.Backends.Direct` (default)

The current M7 implementation moves into this module verbatim.

#### `Tools.WebFetch.Backends.Browserless`

```elixir
defmodule FermixCore.Tools.WebFetch.Backends.Browserless do
  @behaviour FermixCore.Capabilities.Backend

  alias FermixCore.Net.{Guard, HttpClient}
  alias FermixCore.Tools.{HtmlText, Secrets}

  @impl true
  def name, do: :browserless

  @impl true
  def configured?(_opts), do: match?({:ok, _}, Secrets.fetch(:web_fetch_browserless))

  @impl true
  def execute(%{"url" => url}, context) do
    with :ok <- Guard.validate(url, resolver: Map.get(context, :net_resolver)),
         {:ok, token} <- Secrets.fetch(:web_fetch_browserless),
         endpoint <- "https://chrome.browserless.io/content?token=#{token}",
         body <- %{url: url} do
      Req.new(url: endpoint, method: :post, json: body)
      |> HttpClient.request("Browserless")
      |> handle_response()
    end
  end

  @impl true
  def doctor_probe(_opts) do
    case Secrets.fetch(:web_fetch_browserless) do
      {:ok, _} -> {:ok, %{configured: true}}
      :error -> {:error, :not_configured}
    end
  end

  defp handle_response({:ok, %{status: 200, body: html}}) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> {:ok, HtmlText.extract(doc)}
      {:error, reason} -> {:error, {:parse_failed, reason}}
    end
  end

  defp handle_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp handle_response({:error, reason}), do: {:error, reason}
end
```

### 4.7 `http_request` Tool

```elixir
defmodule FermixCore.Tools.HttpRequest do
  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Net.{Guard, HttpClient}
  alias FermixCore.Tools.Support

  @default_methods ~w(GET POST PUT PATCH DELETE HEAD)
  @default_max_body 1_048_576

  @impl true
  def name, do: "http_request"

  @impl true
  def description,
    do: "HTTP request to a configured allow-listed host. Operator-controlled via [http_request]."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["url", "method"],
      properties: %{
        url: %{type: "string", description: "Absolute HTTPS URL on an allow-listed host."},
        method: %{type: "string", enum: @default_methods},
        headers: %{type: "object"},
        body: %{type: "string"},
        body_json: %{type: "object"}
      }
    }
  end

  @impl true
  def when_to_use,
    do: "Hit a known internal/external API on the operator-configured allow-list."

  @impl true
  def examples,
    do: [%{args: %{"url" => "https://api.example.com/v1/widgets", "method" => "GET"}, note: "GET"}]

  @impl true
  def failure_modes do
    [
      %{tag: "host_not_allowed", description: "host not in [http_request].allowed_domains"},
      %{tag: "method_not_allowed", description: "method not in configured methods list"},
      %{tag: "blocked_url", description: "NetGuard rejected the URL or scheme"},
      %{tag: "too_large", description: "response body exceeded max_body_bytes"},
      %{tag: "network", description: "transport or HTTP failure"}
    ]
  end

  @impl true
  def requires_setup, do: [:allowed_domains]

  @impl true
  def category, do: :web

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  @impl true
  def validate_config(%{"allowed_domains" => domains}) when is_list(domains), do: :ok
  def validate_config(_), do: {:error, "[http_request].allowed_domains must be a string list"}

  defp do_execute(args, context) do
    config = tool_config()
    allowed_domains = Keyword.fetch!(config, :allowed_domains)
    methods = Keyword.get(config, :methods, @default_methods)
    max_body = Keyword.get(config, :max_body_bytes, @default_max_body)

    with {:ok, url} <- Support.required_string(args, "url"),
         {:ok, method} <- Support.required_string(args, "method"),
         :ok <- validate_method(method, methods),
         :ok <- Guard.validate(url, allowed_domains: allowed_domains, resolver: net_resolver(context)),
         req <- build_req(url, method, args, max_body),
         {:ok, response} <- HttpClient.request(req, "http_request") do
      render_response(response)
    else
      {:error, {:host_not_in_allowlist, host}} ->
        Support.error("host_not_allowed: #{host} is not in [http_request].allowed_domains")

      {:error, reason} ->
        Support.error("network: #{inspect(reason)}")
    end
  end
end
```

`Net.Guard.validate/2` gains an `:allowed_domains` opt:

```elixir
defp validate_host(host, opts) do
  case Keyword.get(opts, :allowed_domains) do
    nil -> validate_public_host(host)
    list when is_list(list) ->
      if host_in_list?(host, list), do: validate_public_host(host),
        else: {:error, {:host_not_in_allowlist, host}}
  end
end
```

The allow-list is in addition to the public-only rules — `http_request` cannot reach private addresses even if the operator lists `localhost`. (If `localhost` is genuinely needed, that's a separate explicit opt; v1 doesn't have one.)

### 4.8 Wizard Surface

New optional `:tools` step appears after the M4.10 model step. Logic:

1. For each tool with backend choice (currently `web_search`, `web_fetch`):
   - List available backends with status (default vs configured).
   - Prompt: "Pick a backend for `<tool>` (default: keyless)".
   - If non-default chosen: prompt for the API key, persist via `Auth.Store`, write `[fermix_core.tools.<tool>] backend = "..."`.
2. For `http_request`:
   - Prompt: "`http_request` is opt-in. Add allowed_domains? (y/N)".
   - If yes: prompt for comma-separated host list, validate each with `Net.Guard.parse_host/1`, write `[fermix_core.tools.http_request] allowed_domains = [...]`.
3. Persist config + call daemon `:reseed_builtins`.

Wizard skips the step entirely if no tool config exists and the operator hasn't explicitly opted in (so M7 keyless defaults remain frictionless).

### 4.9 Doctor Probes

New `Doctor.Tools` module returns:

```elixir
%{
  web_search: %{backend: :tavily, status: :ok, info: %{configured: true}},
  web_fetch: %{backend: :direct, status: :ok, info: %{}},
  http_request: %{backend: nil, status: :not_configured, info: %{}}
}
```

Network-touching probes (e.g., Browserless `/json` ping) are gated on `--full`. The default `fermix doctor` only checks "is the API key present" / "is the allow-list non-empty"; `fermix doctor --full` calls the actual remote endpoint.

### 4.10 `fermix tools reload` CLI

```bash
fermix tools reload                   # reseed all built-ins
fermix tools reload web_search        # reseed only web_search
```

Implementation: thin wrapper over the daemon socket method. Returns exit 0 / 1 / 3 (3 = daemon not running, matching the existing convention).

### 4.11 Telemetry

- `[:fermix, :tool, :backend_dispatched]` — measurements: `%{count: 1}`. Metadata: `tool, backend, agent`.
- `[:fermix, :builtin, :reseed]` — measurements: `%{duration_ms}`. Metadata: `tools_reseeded :: [String.t()], failures :: [{tool, reason}]`.

The existing `[:fermix, :tool, :exec]` continues to fire per-tool-call (one event per execute, regardless of backend).

---

## 5. Open Decisions

### Q1. Default backend for `web_search` once Tavily is wired

**Question:** Once Tavily is shipped, should the wizard default newly-onboarded operators to Tavily (better quality) or keep DuckDuckGo (zero friction)?

**Proposed:** Keep DuckDuckGo as the default to preserve "no API key required to install" as a Fermix value. Wizard explicitly says "DuckDuckGo (default, keyless, sometimes rate-limited) | Tavily (paid, more reliable)" so operators see the trade.

### Q2. Multi-key rotation for paid backends

**Question:** Should we support `[fermix_core.tools.web_search.tavily] keys = ["k1", "k2"]` for round-robin / quota fan-out?

**Proposed:** No in v1. Single key per backend per daemon. If demand emerges, the multi-key shape goes through a `Backend.next_key/0` helper.

### Q3. Backend dispatch when configured backend fails

**Question:** If Tavily returns 401 (key invalidated), do we silently fall back to DuckDuckGo?

**Proposed:** No. Return the error to the agent loud. Falling back across paid → free silently means the operator never finds out their key broke. The agent's tool-result includes the failure mode so the LLM can choose a different approach (e.g., "the search failed, let me try fetching this URL directly").

### Q4. Tool-side rate limit awareness

**Question:** Tavily has a per-key rate limit. Should the tool track usage and proactively delay or fail with `:rate_limited` before the network call?

**Proposed:** No client-side counter in v1. Let the backend return `:rate_limited` from the actual API response. If proactive throttling becomes useful, it's a per-backend opt.

### Q5. `http_request` body size cap

**Question:** RustyClaw uses 1MB. Tavily/Browserless responses can exceed this for some workflows.

**Proposed:** Default 1MB; per-tool override via `[fermix_core.tools.http_request].max_body_bytes`. Cap stream-enforced by `Net.HttpClient` (similar to `web_fetch.ex`'s `into:` callback pattern).

### Q6. DNS cache placement

**Question:** Does `Net.DnsCache` live under `Net` (alongside `Guard`, `HttpClient`) or under `Capabilities`?

**Proposed:** Under `Net`. It's transport-layer infrastructure shared by every outbound call (provider HTTP, channel sends, tool calls). Disabled by default; operators opt in via `[fermix_core.net.dns_cache] enabled = true`.

### Q7. `reseed_builtins` partial-failure behavior

**Question:** If reseeding 5 tools and the 3rd fails, do we keep the first 2 reseeded changes or roll back?

**Proposed:** Keep the partial state. Each tool's backend install is independent and atomic; the failure surfaces per-tool, the operator fixes the failed config, and re-runs reseed. Rolling back would require snapshotting the prior `BackendRegistry` state which adds complexity for a low-payoff case.

### Q8. Backend-specific telemetry attributes

**Question:** Should each backend emit per-backend telemetry (latency, body size) in addition to the shared `[:fermix, :tool, :backend_dispatched]`?

**Proposed:** Yes, but emit them under the existing `[:fermix, :tool, :exec]` metadata as `backend: :tavily, backend_latency_ms: 350`. One event per tool call, multiple metadata fields.

---

## 6. Stages

### Stage 1: `Capability.Backend` behaviour + `BackendRegistry`

**Files:** `apps/fermix_core/lib/fermix_core/capabilities/backend.ex`, `apps/fermix_core/lib/fermix_core/capabilities/backend_registry.ex`, tests.

**Output:** Behaviour + GenServer registry. No tool wired yet; just the surface area.

**Verification:** unit test for install/get/uninstall, plus a fake backend module that asserts the contract.

**Stage 1 review and fix.**

### Stage 2: `[fermix_core.tools.<name>]` ConfigStore round-trip

**Files:** `apps/fermix_core/lib/fermix_core/setup/config_store.ex` (+ tests), `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex` (`@callback validate_config/1`).

**Output:** Per-tool sections round-trip cleanly. `validate_config/1` callback added with default `:ok` for empty config.

**Verification:** ConfigStore test for round-trip + invalid validate_config + omit-defaults rendering.

**Stage 2 review and fix.**

### Stage 3: `BuiltinSeeder.reseed/1` + daemon socket method

**Files:** `apps/fermix_core/lib/fermix_core/capabilities/builtin_seeder.ex`, `apps/fermix_core/lib/fermix/cli/daemon.ex`, `apps/fermix_core/lib/fermix/cli/daemon/client.ex`, tests.

**Output:** `reseed/1` API + daemon `:reseed_builtins` method. Updated daemon comment for the new write method.

**Verification:** integration test calling the daemon socket from the client wrapper, asserting an installed backend changes after reseed.

**Stage 3 review and fix.**

### Stage 4: `Tools.Secrets` + `Auth.Store` namespace

**Files:** `apps/fermix_core/lib/fermix_core/tools/secrets.ex`, `apps/fermix_core/lib/fermix_core/auth/store.ex` (extend), tests.

**Output:** Per-tool secrets store. Existing `Auth.Store` reused with a separate provider namespace (`:tool_<name>_<backend>`). Same atomic + 0600 file pattern.

**Verification:** secrets round-trip test, plus security test confirming permissions.

**Stage 4 review and fix.**

### Stage 5: `web_search` backend split + Tavily

**Files:** `apps/fermix_core/lib/fermix_core/tools/web_search.ex` (refactor), `apps/fermix_core/lib/fermix_core/tools/web_search/backends/duckduckgo.ex` (new — moves M7 impl), `apps/fermix_core/lib/fermix_core/tools/web_search/backends/tavily.ex`, tests.

**Output:** `web_search` is now a thin orchestrator that dispatches to the configured backend. DuckDuckGo backend is the M7 implementation moved verbatim. Tavily backend works end-to-end against `Req.Test`.

**Verification:** existing M7 web_search tests pass after the move (proves DDG behavior unchanged). New Tavily test asserts request shape, success parsing, 401/429 handling.

**Stage 5 review and fix.**

### Stage 6: `web_search` Parallel + `web_fetch` Browserless

**Files:** `apps/fermix_core/lib/fermix_core/tools/web_search/backends/parallel.ex`, `apps/fermix_core/lib/fermix_core/tools/web_fetch.ex` (refactor), `apps/fermix_core/lib/fermix_core/tools/web_fetch/backends/{direct,browserless}.ex`, tests.

**Output:** Three backends for `web_search`, two for `web_fetch`. All wired through `BackendRegistry`.

**Verification:** matrix test — for each (tool, backend) tuple, assert `execute/2` works against `Req.Test`.

**Stage 6 review and fix.**

### Stage 7: `http_request` tool + NetGuard `:allowed_domains`

**Files:** `apps/fermix_core/lib/fermix_core/tools/http_request.ex`, `apps/fermix_core/lib/fermix_core/net/guard.ex` (+ tests), `apps/fermix_core/lib/fermix_core/capabilities/builtin_seeder.ex` (register the new tool).

**Output:** `http_request` tool ships. NetGuard enforces both public-only AND allow-list when `:allowed_domains` is set.

**Verification:** integration test — allow-list hit goes through, allow-list miss is rejected, private IP is still rejected even on allow-list.

**Stage 7 review and fix.**

### Stage 8: Bounded DNS preflight + optional `Net.DnsCache`

**Files:** `apps/fermix_core/lib/fermix_core/net/guard.ex`, `apps/fermix_core/lib/fermix_core/net/dns_cache.ex` (new), tests.

**Output:** `:dns_timeout_ms` opt with default 2_000. `Net.DnsCache` GenServer implements the LRU + TTL. Off by default; enabled via `[fermix_core.net.dns_cache] enabled = true`.

**Verification:** unit test for the timeout (mock resolver that delays 5s with timeout 2s), unit test for cache hit/miss/eviction.

**Stage 8 review and fix.**

### Stage 9: Wizard step + doctor probes + `fermix tools reload`

**Files:** `apps/fermix_core/lib/fermix_core/setup/wizard.ex` (+ tests), `apps/fermix_core/lib/fermix_core/setup/doctor.ex` (`Doctor.Tools` section + tests), `apps/fermix_core/lib/fermix/cli/tools_command.ex` (new), `apps/fermix_core/lib/fermix/cli.ex` (dispatch), tests.

**Output:** Wizard offers backend selection. Doctor reports per-backend status. CLI `fermix tools reload [name]` triggers reseed.

**Verification:** wizard test for the backend-selection step. Doctor snapshot test. CLI test for `fermix tools reload web_search` against a daemon.

**Stage 9 review and fix.**

### Stage 10: Cleanup + CHANGELOG + README + ROADMAP

**Files:** `CHANGELOG.md`, `README.md` (backend selection section), `docs/ROADMAP.md` (mark M7+ shipped), `CLAUDE.md` (add the M7+ doc registration line).

**Output:** Docs reflect the shipped surface. Roadmap entry updated.

**Stage 10 review and fix.**

---

## 7. Test Plan

**Unit:**
- `Capability.Backend` behaviour smoke test with a fake module.
- `BackendRegistry` install/get/uninstall + concurrent install (no torn state).
- `ConfigStore` round-trip for `[fermix_core.tools.*]` including unknown-key passthrough and validate_config rejection.
- `BuiltinSeeder.reseed/1` for empty config, mixed-default config, and per-tool failure (one tool fails, others still install).
- `Tools.Secrets` round-trip + permissions check.
- `Net.Guard` `:allowed_domains` opt: list hit, list miss, private IP on list (still rejected), case-insensitive host match.
- `Net.Guard` `:dns_timeout_ms` opt with a slow mock resolver.
- `Net.DnsCache` LRU eviction + TTL expiry.

**Integration:**
- Daemon socket: `:reseed_builtins` against a daemon with two tools, assert post-reseed `BackendRegistry.get/1` returns the new backends.
- Daemon socket: `:reseed_builtins` with `params.scope = "web_search"` only, assert other tools unchanged.
- Tavily backend with `Req.Test` plug: request body shape, response parsing, 401 → `:unauthorized`, 429 → `:rate_limited`.
- Browserless backend with `Req.Test` plug: request body shape, response parsing.
- `http_request` end-to-end: configured allowlist + Req.Test plug, assert pass/reject paths.
- `http_request` enforces method allow-list and max body cap.

**Eval (skill-creator pattern):**
- Eval case: agent asked a search-heavy question, configured backend = Tavily, assert response cites at least 2 results from Tavily's structured fields (vs the keyless DDG snippet shape).
- Eval case: agent given an `http_request`-style "hit my internal API" prompt, assert it picks `http_request` (not `web_fetch`) when the host is on the allow-list.

**Manual:**
- Wizard end-to-end: pick Tavily, type test key, verify config.toml + Auth.Store updated, verify subsequent `fermix ask "search the web for X"` returns Tavily results (in `~/.fermix/traces/`).
- `fermix tools reload web_search` on a running daemon, assert no in-flight turn is interrupted.

---

## 8. Risk

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | `BackendRegistry` race during `reseed_builtins` causes a tool call to see partial state | L | M | `install/3` is a single GenServer call (atomic). In-flight tool calls captured `{backend, opts}` from `get/1` before reseed and continue with that pair. New calls get new state. |
| 2 | API key persisted to disk gets leaked via telemetry / logs | L | H | `Auth.Store` is 0600. Backends pass keys directly to Req via the request body / header; never log them. `Net.Guard.redact_headers_for_trace/1` already covers `authorization` / `x-api-key`. |
| 3 | `http_request` agent abuses an allow-listed host (e.g., POSTs garbage to internal API) | M | M | Operator must explicitly add domains to `allowed_domains` (no defaults). Method allow-list further constrains. Logging surfaces every call. M10 governance can layer per-host approval if needed. |
| 4 | DNS cache returns stale entry after a public host changes IPs (unlikely but possible) | L | L | Cache TTL is 60s and the cache is opt-in. If a customer hits this, they disable it. Default-off ships safe. |
| 5 | Wizard step bloats setup for users who don't care about non-default backends | M | L | Step is gated — appears only if the operator opts in. Default install hits zero new prompts. |
| 6 | Backend selection schema drift breaks existing config.toml on upgrade | L | M | `ConfigStore.load_runtime_config/0` returns `{:error, :unknown_backend}` from `validate_config/1` and surfaces it loudly. Operator fixes the config or runs the wizard. No silent fallback. |
| 7 | Per-backend doctor probe makes `fermix doctor` slow when many backends are configured | L | L | Network-touching probes are `--full` only. Default doctor only checks "is the key present". |
| 8 | `:reseed_builtins` can be triggered via the local socket without any extra auth | M | L | The 0600 UDS is the trust boundary (same as every other write method on the socket). Non-root users on the box can already invoke any daemon method. M10 owns user-facing auth on this surface. |

---

## 9. CHANGELOG (planned, on ship)

### Added — M7+ (Pluggable Capability Backends)
- `Capability.Backend` behaviour + per-tool `BackendRegistry` for runtime backend selection.
- `[fermix_core.tools.<name>]` TOML schema with `ConfigStore` round-trip; `Tool.validate_config/1` callback.
- `BuiltinSeeder.reseed/1` and daemon control-socket `:reseed_builtins` method for live re-registration after wizard config changes (no daemon restart required).
- `Tools.Secrets` over `Auth.Store` for per-tool API keys (atomic, 0600).
- `web_search` backend selection: `duckduckgo` (default, keyless), `tavily`, `parallel`. M7's keyless implementation moved verbatim to `Backends.DuckDuckGo`.
- `web_fetch` backend selection: `direct` (default, keyless), `browserless`.
- `http_request` tool with `[http_request].allowed_domains`, method allow-list, and per-tool body cap. `Net.Guard` enforces public-only on top of the allow-list — agents cannot reach private addresses even if listed.
- `Net.Guard` `:dns_timeout_ms` opt (default 2 s) and optional `Net.DnsCache` GenServer (off by default).
- Wizard step for backend selection (gated — appears only on opt-in).
- `fermix doctor` per-backend probes (default: configured? check; `--full`: actual reachability).
- `fermix tools reload [name]` CLI for operator-driven reseed.
- Telemetry: `[:fermix, :tool, :backend_dispatched]`, `[:fermix, :builtin, :reseed]`.

### Changed — M7+
- `Capabilities.Builtin.Tool` behaviour gains `validate_config/1`.
- `Net.Guard.validate/2` accepts an `:allowed_domains` opt.
- `Setup.ConfigStore` rounds-trips arbitrary `[fermix_core.tools.<name>]` sections.
- Daemon socket comment updated: `:reseed_builtins` is a write method; UDS 0600 remains the trust boundary.
