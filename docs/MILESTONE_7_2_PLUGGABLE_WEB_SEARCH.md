# Milestone 7.2: Pluggable Web Search Backends

**Status:** Draft
**Date:** 2026-05-21
**Author:** Sujeeth
**Depends on:** M7 (`web_search` shipped with keyless DDG backend; capability metadata + dynamic prompt summary), M4.9 (`CapabilityRegistry`)
**References:** `apps/fermix_core/lib/fermix_core/tools/web_search.ex`, `apps/fermix_core/lib/fermix_core/net/guard.ex`, `apps/fermix_core/lib/fermix_core/setup/config_store.ex`, `docs/ROADMAP.md` ("Milestone 7+: Pluggable Capability Backends")

---

## 1. Problem / Goal

M7 shipped `web_search` with a single backend — DuckDuckGo's keyless HTML SERP scrape. The failure contract is loud at the boundary (`:rate_limited`, `:parser_changed`), but two real-world failure modes still degrade trust silently from the agent's perspective:

1. **`empty_results?(doc) → []`** returns `success: true, output: "[]"` indistinguishable in the trace from a real zero-hit query. (Fixed in trace as of this PR: `result_count` now appears in metadata. The underlying brittleness remains.)
2. **DDG layout changes** flip every search to `parser_changed` until someone updates Floki selectors.

The keyless DDG backend should remain available so a fresh install with no API keys still gets useful search. But operators with a Brave / Tavily / Serper API key should be able to switch the backend in one config change — without touching tool code or losing the existing capability surface, telemetry, or NetGuard contract.

**Goal of M7.2:** make `web_search` backend-pluggable, ship one keyed backend (Brave), and make backend choice an operator decision in `config.toml`. No silent fallback chains: one configured backend per daemon, fail loud at the boundary.

After this milestone:

1. `[fermix_core.tools.web_search] backend = "brave" | "duckduckgo_html"` selects the active backend.
2. Brave API key lives in `[sandbox.env]` (keychain on macOS) — never plaintext in `config.toml`.
3. Telemetry records `backend: "brave"` alongside `result_count`.
4. `fermix doctor` runs a 1-result probe and reports `backend`, `credential_present?`, `last_ok_ts`.
5. The setup wizard offers a backend step with free-tier links; declining keeps DDG.
6. The DDG backend's existing failure modes (`rate_limited`, `parser_changed`) are preserved for the keyed backends in shape — same tags, same trace contract.

**Non-goal — explicitly deferred to the wider "Pluggable Capability Backends" milestone (roadmap M7+):**

- Generalizing the pluggable-backend pattern to other capabilities (e.g., `web_fetch`, future `http_request`, future cloud-storage tools).
- `BuiltinSeeder.reseed/1` daemon control-socket request for live re-registration.
- `[fermix_core.tools.<name>]` schema codified across all capabilities in `ConfigStore`.
- `tool_help` updates showing per-backend documentation.

This milestone is scoped to `web_search` because the failure cost is highest there (the agent confidently writes a Paris plan when search returned 0 hits). The other capabilities can follow once the shape is proven.

---

## 2. Backend Behaviour

```elixir
defmodule FermixCore.Tools.WebSearch.Backend do
  @moduledoc """
  Contract for `web_search` backends. One backend per daemon, chosen via
  `[fermix_core.tools.web_search] backend` in config.toml. No fallback
  chains — the resolver picks one backend at boot, calls it, and surfaces
  whatever it returns.
  """

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t()}

  @callback name() :: atom()
  @callback requires_credentials?() :: boolean()
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [result()]} | {:error, String.t()}
end
```

**Backends shipped in M7.2:**

| Backend module | Name | Keyless? | Free tier | Notes |
|---|---|---|---|---|
| `WebSearch.Backends.DuckDuckGoHtml` | `:duckduckgo_html` | yes | n/a | Current M7 implementation moved verbatim into a module. Default when no backend configured. |
| `WebSearch.Backends.Brave` | `:brave` | no | 2k queries/mo | Best free tier; structured JSON; ToS-friendly for agent use. Reads `BRAVE_API_KEY` from `[sandbox.env]`. |

**Deferred to a later patch (not blocking M7.2 ship):** `Tavily`, `Serper`. The Backend behaviour is designed so each is a single new module — no changes to `WebSearch.execute/2`.

---

## 3. Config Schema

```toml
[fermix_core.tools.web_search]
backend = "brave"        # one of: "duckduckgo_html", "brave"
# No api_key key here — credentials live in [sandbox.env].

[sandbox.env]
allow = ["OPENAI_API_KEY", "BRAVE_API_KEY"]

[sandbox.env.BRAVE_API_KEY]
source = "command"
command = "/usr/bin/security"
args = ["find-generic-password", "-a", "sujshe", "-s", "BRAVE_API_KEY", "-w"]
timeout_ms = 3000
```

**Resolution rule:** `Application.get_env(:fermix_core, [:tools, :web_search, :backend])` resolves at call time (so config reloads via `ConfigStore.apply_snapshot/1` take effect without daemon restart). If the key is missing or unknown, fall back to `:duckduckgo_html` and emit a one-time warning at boot — same pattern as other unconfigured providers.

**ConfigStore extension required.** `ConfigStore` today parses and dumps `[fermix_core.agent]`, `[fermix_core.personalization]`, `[fermix_core.memory]`, `[fermix_core.realtime]`, `[fermix_core.providers.*]`, `[fermix_core.routing]`, `[fermix_core.jobs]`, `[sandbox.*]`, and `[fermix_channels.*]`. It does **not** parse a `[fermix_core.tools.*]` section — anything the wizard writes there is silently dropped on the next `load_runtime_config/0` round-trip. M7.2 must extend `ConfigStore` to recognise a `tools` block with a minimal supported shape (`backend` string per tool name) and round-trip it through `current_snapshot/0`, `persistable_snapshot/0`, and `apply_snapshot/1`. See migration Step 0.

**Why credentials aren't in `config.toml`:** existing pattern in M4.10 — `OPENAI_API_KEY` already routes through `[sandbox.env]` with a `security` command. Reusing it keeps secrets out of plaintext config and out of git accidents.

---

## 4. Selection and Execution

`WebSearch.execute/2` becomes a one-line dispatch:

```elixir
def execute(args, context) do
  Support.run(name(), put_trace_metadata(context), fn ->
    backend = configured_backend()

    with {:ok, query} <- Support.required_string(args, "query"),
         :ok <- validate_query(query),
         {:ok, results} <- backend.search(query, backend_opts(context)) do
      trimmed = Enum.take(results, @max_results)
      Support.success_json(trimmed, %{
        result_count: length(trimmed),
        backend: backend.name()
      })
    else
      {:error, reason} -> Support.error(reason)
    end
  end)
end
```

All error shaping moves into the backend module. NetGuard stays where it is — each backend calls `Guard.validate(@endpoint, ...)` for its own endpoint before any HTTP.

---

## 5. Observability

Trace `web_search` tool_exec entries gain two keys:

| Key | Type | Example | Set by |
|---|---|---|---|
| `result_count` | integer | `8`, `0` | This PR (already shipped) |
| `backend` | string | `"brave"`, `"duckduckgo_html"` | M7.2 |

The existing `request_headers` (redacted) and `error` keys are untouched.

**Why both:** `result_count: 0` plus `backend: "brave"` answers "why does the agent think Paris has no hotels" — was it the backend, the credential, or a genuine zero-hit query — in a single trace line.

---

## 6. Doctor Probe

`fermix doctor` adds a `web_search` check that:

1. Reads the active backend.
2. Resolves credentials (without printing them).
3. Issues a single 1-result probe (`q=fermix`) via the backend.
4. Reports:
   - `backend` name
   - `credential_present?` (does the env var resolve to a non-empty string)
   - `last_ok_ts` (cached from the most recent successful run, optional)
   - `probe_result` — `:ok`, `:rate_limited`, `:auth_failed`, `:parser_changed`

This is the same shape as the existing M4.10 Codex auth probe in `Fermix.CLI.Doctor.Checks`.

---

## 7. Wizard Step

`mix fermix.setup` (and the CLI's interactive setup) adds one step after the provider step:

```
Web search backend
  Default (DuckDuckGo, no key, layout-fragile)         [ ]
  Brave Search (2k queries/month free)                 [x]
    ↳ paste your Brave API key, or skip to use default
```

If the user pastes a key, the wizard:

1. Writes `BRAVE_API_KEY` to keychain via `security add-generic-password`.
2. Sets `[sandbox.env.BRAVE_API_KEY]` to the `find-generic-password` command shape.
3. Sets `[fermix_core.tools.web_search] backend = "brave"`.
4. Runs the doctor probe to confirm before returning to the main wizard flow.

If they skip, no config change — DDG stays the default.

---

## 8. Migration

| Step | Change | Validation |
|---|---|---|
| 0 | Extend `ConfigStore` to round-trip `[fermix_core.tools.<name>]`. Add the `tools` keyword to `current_snapshot/0`, parse/dump it in the TOML codec alongside `routing` and `jobs`, and load it into `Application.get_env(:fermix_core, :tools, [])`. Schema for v1: one key per tool, value is a keyword list (e.g., `[web_search: [backend: "brave"]]`). | Snapshot round-trip test: write `[fermix_core.tools.web_search] backend = "brave"`, call `load_runtime_config/0` then `current_snapshot/0`, assert equality. |
| 1 | Extract current `parse_html` / `result_rows` / `challenge?` into `WebSearch.Backends.DuckDuckGoHtml` implementing the `Backend` behaviour. No behavior change. | Existing web_tools_test.exs passes unchanged. |
| 2 | Add `WebSearch.Backend` behaviour module. | Compile-time only. |
| 3 | Add `WebSearch.Backends.Brave` (HTTP GET, JSON parse). Read key via `System.get_env("BRAVE_API_KEY")`. | New test: stub Brave with `Req.Test`, assert structured results. |
| 4 | Refactor `WebSearch.execute/2` to dispatch via `configured_backend/0`. Default `:duckduckgo_html` when unset. | Existing telemetry tests assert `backend` key present; result_count unchanged. |
| 5 | Wizard step + `mix fermix.setup` write path. | Wizard test asserts roundtrip of `[fermix_core.tools.web_search] backend = "brave"` through ConfigStore (depends on Step 0). |
| 6 | Doctor probe. | New doctor check test for both backends. |

Each step is independently shippable. Step 0 is a pure plumbing change in `ConfigStore` with no behavior on the tool surface — the prerequisite that makes Steps 4-5 actually round-trip through `config.toml`.

---

## 9. Open Questions

1. **Caching.** Brave/Tavily charge per query; same query within a session shouldn't double-bill. Worth adding a small TTL cache (60-300s) keyed on (backend, normalized query)? Defer to a follow-up if measurements show repeat queries are common.
2. **Per-conversation backend override.** Should a sub-agent be able to request a specific backend, or is daemon-level config sufficient? Default: daemon-level only. Matches the M7.1-style decision that operators own backend choice.
3. **Empty-result soft-failure shape.** Today `result_count: 0` returns `success: true, output: "[]"`. Should the tool result include a `warning: "no_results"` field so the calling LLM is more likely to admit ignorance rather than confabulate? Worth experimenting with after the trace lands — measure how often agents over-generate on `[]` and decide.
4. **NetGuard endpoint allowlist.** Each backend has its own endpoint. Right now `NetGuard` validates per call. Should there be a configured endpoint allowlist per backend, or is that overkill given the backend module hardcodes its endpoint? Default: backend hardcodes; NetGuard validates the resolved IP at call time as today.

---

## 10. Success Criteria

- One backend module per supported provider, implementing `Backend` behaviour.
- `WebSearch.execute/2` is a thin dispatch — no provider-specific code outside backend modules.
- Trace entries record `result_count` and `backend`.
- `fermix doctor` reports the active backend and probe outcome.
- Wizard offers Brave with one-keystroke acceptance and a free-tier link.
- All existing M7 `web_search` tests still pass without modification.
- Switching backends never silently degrades to DDG: invalid config = boot warning + default; credential missing = `:auth_failed` at probe; backend HTTP error = loud error in trace.
