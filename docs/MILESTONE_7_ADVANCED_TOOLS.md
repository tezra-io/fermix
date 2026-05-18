# Milestone 7: Advanced Tools — Built-in Capability Catalog

**Status:** Draft
**Date:** 2026-05-05
**Author:** Sujeeth / Aira
**Depends on:** M4.9 (`Capability` behaviour, `CapabilityRegistry`, trust/policy filter), M4.10 (provider/model selection in wizard + TOML), M4.11 (job + memory tools — overlap clarified in §3)
**Blocks:** M9 self-knowledge agent (M9 builds on M7's self-knowledge *skill*), M10 security policy (M10 binds to the `policy_class` and `hidden_from_agent?` hooks each M7 tool declares)
**References:** `~/projects/rustyclaw/src/tools/` (port source for most file/web tools), `~/projects/hermes-agent/agent/prompt_builder.py` (capability summary patterns)

---

## 1. Problem / Goal

After M4.9 (capability framework) and M4.11 (jobs + source-aware memory), Fermix's agent loop has the right plumbing but a thin tool catalog. Today the main agent reaches `shell` for almost everything outside scheduling, memory, and the four file/browser tools that exist. Two things break as a result:

1. **The agent picks `shell` for things Fermix should own.** A `shell` call to `git status` or `find . -name "*.ex"` doesn't go through the trust/policy filter, doesn't generate a structured tool result the loop can act on, and doesn't surface in telemetry as the high-level intent (git read, file glob). Same for `curl` masquerading as `web_fetch` and `grep -r` masquerading as `content_search`. The plan file at `~/.claude/plans/quiet-enchanting-willow.md` already documented this for `schedule_job`; the same pattern repeats across every category.
2. **Capability metadata is too thin to steer model choice.** The `Capability` struct has `description: String.t()` and that's it — no `when_to_use`, no examples, no documented failure modes. With ~12 tools today the model can mostly pick correctly from descriptions alone; with the M7 catalog (~12 new tools landing into a registry that already holds skills + MCP tools) descriptions alone won't carry the weight, and Codex will keep falling back to `shell`.

**Goal of M7:** ship the canonical Fermix built-in tool catalog so the main agent has a first-class capability for every common operating verb (read/edit files, search content, fetch the web, manage git, delegate to a sub-model, scaffold skills, configure routing), and upgrade `Capability` metadata + prompt assembly so the model picks the right tool reliably as the catalog grows. Built-in tools are **not optional** — they ship with the binary, no install step. For v1 every M7 built-in is **keyless** — no API key collection, no `[fermix_core.tools]` TOML schema, no reseed plumbing. `web_search` ships with one default backend (DuckDuckGo HTML SERP scrape — free, no key, fragile). Pluggable backends + paid alternatives (Parallel REST, Tavily, etc.) are a separate future milestone the operator is scoping; that milestone owns the per-capability backend-choice UX, the wizard surface, and the API-key persistence schema.

After this milestone:

1. Every category in the §4.2 catalog has a concrete built-in tool (file/content search, git, web fetch + search, delegate, skill scaffolding, routing config, on-demand `tool_help`). The agent stops reaching for `shell`/`curl`/`grep` for things Fermix owns.
2. `Capability.metadata` has a stable schema for `when_to_use`, `examples`, `failure_modes`, and `requires_setup` fields. Existing tools and all M7 ports populate them.
3. The main-agent system prompt is generated from compact capability summaries (one tight line each + one example), not 12 hand-edited descriptions. Full per-capability docs are reachable on demand via a `tool_help` capability.
4. `web_search` works with no setup. The default backend is DuckDuckGo's HTML SERP scrape — keyless, real web results, brittle to layout/CAPTCHA changes (see §5 Q1 + §8 Risk 1). Switching to a paid backend with better reliability lands in the future "pluggable capability backends" milestone.
5. A Fermix-owned `self_knowledge` skill answers "what is Fermix, what can it do, how do agents/jobs/memory/channels fit together" without bloating every system prompt.

**Non-goal:** the M9 self-knowledge **agent** (which can modify Fermix code). M7 ships the static **skill** that explains the system; M9 turns it into an editor.

**Non-goal:** loosening or rewriting the M10 security policy. M7 declares `policy_class` and `hidden_from_agent?` for each new tool; M10 owns the enforcement model.

---

## 2. Reference Implementations

Most tools are direct ports from RustyClaw with shape tightening for the Fermix `Capability` struct. The reference paths are listed per tool in §4.2.

Two cross-cutting references shape the design beyond individual ports:

- **Hermes-agent's `agent/prompt_builder.py`** — the `MEMORY_GUIDANCE` / `SKILLS_GUIDANCE` injection pattern: each capability ships a one-line "use this when X" hint, and the prompt builder concatenates only the hints for currently-loaded capabilities. This is the source for §4.5 (summary generation).
- **OpenClaw's `/help` and capability manifests** — the source for the `tool_help` on-demand expansion in §4.6 and the self-knowledge skill in §4.7.

**What we do not adopt:**

- RustyClaw's per-tool `permissions` enum proliferation (`FileRead`, `FileWrite`, `NetworkRead`, …). Fermix already has `policy_class :: :read_only | :read_write | :exec | :network | :external_api` on `Capability`. M7 reuses the existing five classes; new tools pick one, no new classes added.
- RustyClaw's tool-level `risk_score` numeric field. We have a binary `hidden_from_agent?` flag from M4.9, scored by M10 governance. A numeric score adds a knob without an enforcement story.
- A pluggable backend abstraction for `web_search`. M7 ships one backend (DuckDuckGo HTML scrape). The `Tools.WebSearch.Backend` behaviour, paid alternatives (Parallel REST, Tavily), and the per-capability backend-choice wizard step are scoped to a separate future milestone the operator is preparing — that milestone owns the onboarding/config/setup changes the multi-backend story requires.
- An API-key wizard step or `[fermix_core.tools]` TOML schema. Same reason — every M7 built-in is keyless, including `web_search`. The `requires_setup/0` callback on `Builtin.Tool` is kept on the metadata schema (§4.1) as a forward-compat hook for the future milestone.
- The `http_request` tool. RustyClaw's `http_request` requires `[http_request].allowed_domains` to be configured (`~/projects/rustyclaw/src/tools/http_request.rs:47`) — a per-tool TOML config that M7 deliberately defers. Shipping `http_request` in M7 without `allowed_domains` would regress RustyClaw's contract. Moves to the future "Pluggable Capability Backends" milestone alongside web_search backend selection.
- Per-tool `allowed_domains` / `blocked_domains` lists for `web_fetch` and `web_search`. M7 ships the shared `NetGuard` (§4.3a) with hardcoded "public hosts only" rules; per-tool customization belongs to the future milestone's TOML schema.
- The `git_push` tool. Needs `hidden_from_agent?: true` to be safe, but M7 has no way to expose approval-gated capabilities to the model — `CapabilityRegistry.list/2` strips them by default (`apps/fermix_core/lib/fermix_core/capabilities/registry.ex:253`), and `AgentLoop.default_capabilities/3` (`agent_loop.ex:119`) does not pass `include_hidden?: true`. M10 owns the approval flow end-to-end; `git_push` lands there, alongside any other `hidden_from_agent?: true` capabilities. Until then the agent uses `shell` for pushes — same friction-less behavior as today.

---

## 3. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---|---|---|---|
| Capability metadata extension | P0 | Modify | Add `when_to_use`, `examples`, `failure_modes`, `requires_setup` keys with a stable shape under `Capability.metadata`. Migrate the 12 existing tools to populate them. |
| Prompt summary generation | P0 | New | `RuntimeSections.capability_summary/1` builds a compact one-line-per-capability section from `metadata.when_to_use`. Replaces the prose-heavy "tool list" in the current bootstrap. |
| `tool_help` capability | P0 | New | On-demand expansion: `tool_help(name)` returns full `description + parameters + examples + failure_modes` for one capability. Lets the agent pull deep docs only when it commits to a tool. |
| `file_edit` tool | P0 | Port | Unique-anchor string replacement in a file. Atomic write via tmp+rename. (`~/projects/rustyclaw/src/tools/file_edit.rs`) |
| `glob_search` tool | P1 | Port | File pattern matching with bounded results. (`~/projects/rustyclaw/src/tools/glob_search.rs`) |
| `content_search` tool | P1 | Port | Grep across the workspace; pure-Elixir implementation, no `rg` shellout. (`~/projects/rustyclaw/src/tools/content_search.rs`) |
| `git_read` / `git_write` tools | P1 | Port (split) | Two tools in M7, one per `policy_class` band, since the registry filters at capability level (`apps/fermix_core/lib/fermix_core/capabilities/registry.ex:176`) — a single `git_operations` tool would either lose `git status` in read-only contexts or let mutations bypass policy. **`git_push` is deferred to M10** — it needs `hidden_from_agent?: true`, but the registry strips approval-required capabilities by default (`registry.ex:253` + AgentLoop's `default_capabilities` at `agent_loop.ex:119` doesn't pass `include_hidden?: true`), so a `git_push` shipped in M7 would be registered but invisible to the model. M10 owns the approval-exposure path. Reference: `~/projects/rustyclaw/src/tools/git_operations.rs`. |
| `web_fetch` tool | P0 | Port | HTTP GET + a new `FermixCore.Tools.HtmlText.extract/1` helper that walks Floki-parsed nodes and emits markdown-light text (preserves headings as `# `, lists as `- `, code blocks as `` ``` ``, links as `[text](url)`). Floki is parser-only; the renderer is ours. Keyless. Bounded body (1MB), bounded redirects (5). All outbound URLs (initial and every redirect) gated by the `NetGuard` module below. (`~/projects/rustyclaw/src/tools/web_fetch.rs`) |
| `web_search` tool | P0 | New | Single backend in M7: DuckDuckGo HTML SERP scrape (`https://html.duckduckgo.com/html/`). Keyless. Returns `[{title, url, snippet}]` parsed via Floki. Failure contract: DDG empty-results marker → `{:ok, []}`; CAPTCHA/challenge body → `{:error, :rate_limited}`; rows missing AND no known empty marker → `{:error, :parser_changed}` (loud, never silent). Outbound POST gated by `NetGuard`. (Reference: `~/projects/rustyclaw/src/tools/web_search_tool.rs` for shape only — backend differs.) |
| `NetGuard` module | P0 | New | Shared outbound-network safety contract. Hardcoded "public HTTP(S) only" rules: scheme allowlist, no whitespace in URL, IP-literal block (RFC 1918 + loopback + link-local + IPv6 equivalents), DNS resolution + every resolved A/AAAA rechecked against the same private/reserved ranges (defense against DNS rebinding), redirect target re-validation on every hop, sensitive-header redaction helper for logging. Used by `web_fetch` and `web_search`. No per-tool TOML config in M7 (that's the future milestone's `allowed_domains` UX). |
| `delegate` tool | P1 | Port | Single-turn delegation to another configured model — different from a skill sub-agent. (`~/projects/rustyclaw/src/tools/delegate.rs`) |
| `skill_create` tool | P1 | Port | Scaffold a new `~/.fermix/skills/<name>/SKILL.md` with frontmatter. (`~/projects/rustyclaw/src/tools/skill_create.rs`) |
| `model_routing_config` tool | P1 | Port | Read/update routing rules (delegate target, per-task model overrides) against the M4.10 TOML schema. (`~/projects/rustyclaw/src/tools/model_routing_config.rs`) |
| Self-knowledge skill | P0 | New | Static `priv/skills/self_knowledge/SKILL.md` answering high-level "what is Fermix" questions. Sourced from CLAUDE.md + roadmap headers. Not regenerated; updated by hand. |
| Telemetry uniformity | P1 | Modify | Every M7 tool emits `[:fermix, :tool, :exec]` with `tool: name, agent, success, duration_ms` (matches existing convention). |
| Skill Creator eval validation | P0 | Test/process | Every new or changed M7 built-in tool and bundled skill must ship eval cases and pass the `skill-creator` eval flow before the stage ships. Tool evals assert the main agent selects the intended capability; skill evals compare with-skill vs baseline output. |
| Documentation of built-in vs skill | P0 | Docs | One README section + the `tool_help` output for each tool says "this is a Fermix built-in. Skills are configured separately under `fermix skills`." |

### Non-Goals

| Feature | Reason | When |
|---|---|---|
| Skills install/toggle CLI (`fermix skills add/remove/disable`) | Skills are a separate user-facing surface. Their install/config UX is a follow-on; M7 only adds `skill_create` (scaffolding) plus the self-knowledge skill. | M7+1 (skills surface) |
| Replacing M4.11's `schedule_job`/`list_jobs`/etc. with `cron_*` | M4.11 already shipped the canonical names. The roadmap's `cron_add`/`cron_list`/etc. are RustyClaw legacy names; Fermix names are the canonical surface. M7 does not re-add them. | Never (renamed) |
| Replacing M4 memory tools | `memory_recall`, `memory_store`, `memory_sources_list` shipped with M4.11. M7 does not touch them. | Never (already shipped) |
| Approval workflow / `/approve` UX | M4.9's `hidden_from_agent?` is a flag. The flow that asks the user lives in M10. M7 sets the flag where appropriate; does not implement the prompt. | M10 |
| `pdf_read`, `image_info`, `screenshot`, `browser_open`, SOP suite, hardware tools | Roadmap "Extended Tools" — demand-driven, not part of M7 scope. | Future ecosystem |
| Replacing `browser` with a richer screenshot/coords API | Existing `browser` tool already routes through `agent-browser`. Tightening it is its own follow-on. M7 leaves it intact and migrates its metadata to the new schema. | M7+1 if needed |
| `composio` integration | Hundreds of integrations behind one API; that's an integration product decision, not an M7 tool. | Never (separate evaluation) |
| Self-knowledge **agent** | Static skill in M7; live editor agent in M9. | M9 |

### Overlap with M4.11 (clarified)

M4.11's tool list and M7's roadmap entry both reference scheduling/cron tools. The split is final:

- **Job lifecycle (shipped, M4.11):** `schedule_job`, `list_jobs`, `pause_job`, `resume_job`, `remove_job`, `update_job` *(if landed)*, `run_job_now` *(if landed)*, `job_runs`, `memory_sources_list`.
- **M7 does not add cron-named duplicates.** RustyClaw's `cron_add`/`cron_list`/`cron_update`/`cron_remove` map 1:1 to the M4.11 names; we do not register both. Capability descriptions in M7's prompt summary include a hint that "schedule_job is Fermix's built-in scheduler — never use shell `crontab` or `launchctl`," which generalizes the plan-file fix already in `RuntimeSections.runtime_contract/0`.

---

## 4. Design

### 4.1 Capability metadata extension

Today `Capability.metadata` is `%{}` and unused except by MCP capabilities (`metadata: %{server: ...}`). M7 fixes a stable schema for built-ins, with all keys optional except `when_to_use`:

```elixir
%{
  # Required for all M7 builtins. One sentence, imperative voice, names the
  # canonical verb. Read by RuntimeSections.capability_summary/1.
  when_to_use: "Search file contents across the workspace for a pattern.",

  # 1-3 short example calls. Each: %{args: %{...}, note: "..."}. Read by
  # tool_help. Not in the system prompt by default — only on demand.
  examples: [
    %{args: %{"pattern" => "TODO", "path" => "apps/"}, note: "find every TODO under apps/"},
    %{args: %{"pattern" => "defp.*do$", "path" => ".", "regex" => true}, note: "grep with regex"}
  ],

  # Failure modes the model needs to know about — surfaces in tool_help and
  # in error result messages. JSON-safe maps (not tuples — `Introspection.Wire.json_safe/1`
  # raises on tuples, see apps/fermix_core/lib/fermix_core/introspection/wire.ex:25).
  failure_modes: [
    %{tag: "not_found", description: "no matches; tool returns success with empty results"},
    %{tag: "timeout", description: "search exceeded timeout_ms"},
    %{tag: "invalid_regex", description: "regex did not compile"}
  ],

  # nil for keyless tools. For API-using tools: %{provider: :tavily, key: :api_key}
  # — the wizard reads this to know which TOML field to populate.
  requires_setup: nil,

  # Capability category for prompt grouping. One of: :file, :web, :git,
  # :delegation, :skill_admin, :config, :memory, :scheduling, :system.
  category: :file
}
```

**Migration plan for existing tools.** The 13 tools currently shipped get a `metadata` block populated in Stage 0. No behavior change — only metadata richness — so the change is mechanical and safe to land before any new tool ports. `memory_*`, `schedule_job`, `list_jobs` etc. (M4.11 shipped) get their `when_to_use` line set to match what's already in the runtime contract; the duplication in `RuntimeSections.runtime_contract/0` (the plan-file fix) becomes generated, not hand-edited, in Stage 6.

**Why `metadata` and not new top-level fields on the struct.** The `Capability` struct is shared across builtins, skills, and MCP capabilities. Skills and MCP tools won't have `examples` or `failure_modes` in any structured way — they're free-form runtime data. Burying M7's schema inside `metadata` keeps the struct flat and lets non-builtin sources opt in only where they have the data.

### 4.2 Tool catalog

Each new tool below ships as `kind: :builtin`, registered at boot via `Capabilities.Builtin.from_tool_module/1`. `policy_class` is conservative (least-privilege); M10 will tighten further when it lands.

| Name | `policy_class` | API key? | Brief |
|---|---|---|---|
| `file_edit` | `:read_write` | no | Replace a unique anchor string in one file. Errors loudly if the anchor isn't unique. Atomic via tmp+rename. |
| `glob_search` | `:read_only` | no | `Path.wildcard/2` with bounded results (default 200, configurable). Returns absolute paths. |
| `content_search` | `:read_only` | no | Pure-Elixir grep with `Regex` and `File.stream!`. Walks file tree, skips binary files (heuristic), bounded result count. |
| `git_read` | `:read_only` | no | Subcommand whitelist: `status`/`log`/`diff`/`branch`/`show`. One tool dispatched on a `command` arg. |
| `git_write` | `:read_write` | no | Subcommand whitelist: `add`/`commit`/`checkout`/`pull`. One tool dispatched on a `command` arg. `git push` is **not** in this whitelist — see §5 Q4 + §3 Non-Goals. Until M10 ships approval, the agent uses `shell` for pushes (same friction-less behavior as today). |
| `web_fetch` | `:network` | no | `Req.get/1` + Floki parsing + `FermixCore.Tools.HtmlText.extract/1` (markdown-light: headings, lists, code blocks, links). Bounded body (1MB), bounded redirects (5). User-Agent: `fermix/<version>`. Initial URL and every redirect target run through `NetGuard.validate/2`. Honors `robots.txt`? — see §5 Q3. |
| `web_search` | `:network` | no | DuckDuckGo HTML SERP scrape. POST to `https://html.duckduckgo.com/html/` with form-encoded `q=<query>`; parse `.result__title a.result__a` (title + href) and `.result__snippet` (snippet) via Floki. Returns `[%{title, url, snippet}]` capped at 10. `:network` (not `:external_api`) because there's no API key boundary. Failure contract is loud (`:rate_limited` / `:parser_changed`), not silent — see §8 Risk 1. |
| `delegate` | `:external_api` | no | Single-turn delegation. Args: `model: "...", prompt: "..."`. Routes through `Adapter.for_model/1`. Returns the model's reply as text. No tool calls inside the delegation. `:external_api` (not `:read_only`) because it makes an outbound provider call with cost/auth implications — third-party skill contexts (which default to `:read_only`-allow) must not invoke it. |
| `skill_create` | `:read_write` | no | Writes `~/.fermix/skills/<name>/SKILL.md` with a frontmatter template. Refuses to overwrite. |
| `model_routing_config` | `:read_write` | no | Reads/writes `[fermix_core.routing]` in `~/.fermix/config.toml`. Uses M4.10's `ConfigStore` round-trip path; preserves comments. |
| `tool_help` | `:read_only` | no | On-demand: `tool_help(name)` returns `description + parameters + examples + failure_modes` for one capability from the registry. Args validate against `Registry.find/2`. |

**Tools NOT in M7 but mentioned for placement clarity:**

- `browser` (already shipped, metadata migrated in Stage 0).
- `shell`, `file_read`, `file_write` (already shipped, metadata migrated in Stage 0).
- All M4.11 job/memory tools (shipped; metadata migrated in Stage 0).

**Counts.** Stage 0 migrates 12 existing built-in tools. Stages 1–5 add 11 new built-ins (`http_request` deferred to the future "Pluggable Capability Backends" milestone, `git_push` deferred to M10 — see §3 Non-Goals for both). Net built-in catalog after M7: 23, plus the `NetGuard` shared module (not a capability), plus skills and MCP-server tools (variable per install).

### 4.3 No API-key plumbing in v1

Every M7 built-in is keyless. `web_search` uses DuckDuckGo's HTML SERP scrape; `web_fetch` is direct `Req.get/1` + Floki; everything else is local OS work or routes through M4.10's existing provider auth. So:

- No `[fermix_core.tools]` TOML section.
- No `ConfigStore.normalize_tools/1` / `apply_tools/1` / extension of `parse_document/1` or `dump_snapshot/1`.
- No `tool_setup_pending` readiness state, no `BuiltinSeeder.reseed/1`, no daemon control-socket `:reseed_builtins` request.
- No new wizard step (the M4.10 `:provider`/`:model` flow stays exactly as today).

This is intentional. The "pluggable backend per capability + paid alternatives + wizard surface for API keys" surface is its own user-facing UX — onboarding text, per-capability backend choice, key persistence, key rotation, doctor probes for each backend, env overlays. That's a milestone of its own (the operator is scoping it separately). Folding even a stripped-down version into M7 means designing the same plumbing twice, then re-doing it when the proper milestone lands.

**Forward-compat hook.** The `requires_setup/0` callback on `Builtin.Tool` (added by §4.1's metadata schema) is wired up but every M7 built-in returns `nil`. The future milestone will exercise it for the *first* built-in that gains an API-keyed backend; the registry filter and per-tool TOML block land then.

**Why not Fermix-shared keys for `web_search`.** Shipping a Fermix-funded API key for any third party (Tavily, Parallel, Brave) means Fermix-the-binary funds search costs for every install — money sink, single-point-of-revocation, terms-of-service exposure. DDG's HTML page is a public unauthenticated endpoint we scrape — there's no shared-key concept, no rate-limited account behind it. The trade-off is fragility, accepted explicitly in §5 Q1 and §8 Risk 1.

**Why `http_request` is not in M7.** RustyClaw's `http_request` (`~/projects/rustyclaw/src/tools/http_request.rs:47`) refuses to start without `[http_request].allowed_domains` configured — i.e., it requires per-tool TOML config that M7 deliberately defers. Shipping `http_request` in M7 would either (a) regress RustyClaw's contract by allowing arbitrary outbound HTTP with no allowlist, or (b) ship a tool that's permanently broken until the future milestone adds the config UX. Neither is acceptable. `http_request` moves to the future "Pluggable Capability Backends" milestone where its allowed_domains lands alongside web_search backend selection.

### 4.3a NetGuard — shared outbound network safety contract

`web_fetch` and `web_search` are the only M7 built-ins that make outbound HTTP calls; both must enforce the same network safety contract or one becomes the SSRF vector for the other. M7 ships a tiny shared module:

```elixir
defmodule FermixCore.Net.Guard do
  @type opts :: [resolver: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})]

  @doc """
  Validate a URL is safe for outbound web traffic.

  Pass `:resolver` to inject a stub for testing. Production defaults to a thin
  wrapper around `:inet_res.lookup/3` (no Mox dep — same plug-style injection
  pattern Fermix uses for HTTP via `Req.Test`).
  """
  @spec validate(String.t(), opts()) :: :ok | {:error, reason}
        when reason: :scheme_not_http_or_https | :url_has_whitespace | :empty_url
                   | {:blocked_host, reason :: atom()}
                   | {:dns_resolution_failed, term()}
                   | {:resolved_to_private_address, ip :: tuple()}
  def validate(url, opts \\ [])

  @doc "Re-validate a redirect target after the original passed."
  @spec validate_redirect(new_url :: String.t(), original :: String.t(), opts()) ::
          :ok | {:error, term()}
  def validate_redirect(new_url, original, opts \\ [])

  @doc "Redact sensitive headers for logging/telemetry."
  @spec redact_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def redact_headers(headers)
end
```

**Why a resolver opt, not a Mox/`:meck` mock.** Fermix has no mocking dep today; tests use `Req.Test`/plug-style dependency injection (e.g. `apps/fermix_core/test/fermix_core/providers/openai/codex_test.exs`). Adding Mox just for NetGuard would be a new umbrella dep and a new test-pattern divergence. A `:resolver` opt that defaults to `:inet_res` matches the existing pattern: production code passes nothing, tests pass `resolver: fn host -> {:ok, [{169, 254, 169, 254}]} end` to exercise the DNS-rebinding branch.

Hardcoded rules in M7 (no per-tool config knobs):

1. **Scheme allowlist.** Only `http://` and `https://`. Reject `file://`, `gopher://`, `data:`, etc.
2. **No whitespace in URL.** Reject URLs containing any whitespace character.
3. **IP literal block.** When the URL host parses as an IP literal, reject if the address is in any private/reserved range:
    - IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 (loopback), 169.254.0.0/16 (link-local), 0.0.0.0/8, 224.0.0.0/4 (multicast), 240.0.0.0/4 (reserved).
    - IPv6: ::1 (loopback), fe80::/10 (link-local), fc00::/7 (unique local), ff00::/8 (multicast), ::ffff:0:0/96 (IPv4-mapped — recheck the embedded v4).
4. **Hostname literal block.** Reject `localhost`, `*.local`, `*.internal`, `*.localhost`.
5. **DNS preflight: resolve + check every A/AAAA.** Resolve the host via `:inet_res.lookup/3` (or the injected `:resolver`); every returned address must pass the same private/reserved-range check. Failure → `{:error, {:resolved_to_private_address, ip}}`. **This is preflight private-address rejection, not full DNS rebinding defense.** Req re-resolves the hostname when it actually opens the connection, so an attacker-controlled authoritative DNS server can return a public IP at preflight time and a private IP for the actual request — classic TOCTOU. Real defense requires pinning the HTTP request to the validated IP (custom Finch/Mint pool with the original hostname kept for SNI + Host header). That's a meaningful additional surface — custom Req adapter, TLS verification handling — and it's deferred to **M10** alongside the broader security-policy work, where the per-tool `allowed_domains` UX also lands. M7 explicitly accepts the residual rebinding TOCTOU as a known gap. The preflight check still has real value: it catches naive misuse (hostnames that *always* resolve to private), names with hardcoded private IPs in their answers, and the common "agent typed `localhost`" case.
6. **Redirect re-validation.** `validate_redirect/2` runs the full check on the new URL on every redirect hop. `web_fetch` uses Req's `redirect: :raw_redirect` mode and validates manually rather than letting Req auto-follow.
7. **Sensitive header redaction.** `redact_headers/1` rewrites values for `authorization`, `cookie`, `set-cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token` to `"***REDACTED***"` for logging/telemetry. Used by `web_fetch` and `web_search` before any tool result is written to traces.

What NetGuard does **not** do in M7 (deferred):
- Per-tool `allowed_domains` / `blocked_domains` lists. RustyClaw has them; M7 does not, because they require per-tool TOML config (deferred to "Pluggable Capability Backends" milestone).
- Full DNS rebinding defense via IP-pinned outbound. Rule 5 above is preflight-only; closing the TOCTOU window requires a custom Finch/Mint pool that connects to the validated IP while preserving SNI + Host header. Deferred to **M10** (Security & Governance).
- Configurable timeout / retry / throttle, plus bounded DNS preflight behavior (explicit lookup timeout and, if needed, a small successful-resolution cache). Hardcoded defaults live in the calling tool for M7; the follow-up "Pluggable Capability Backends" milestone owns the tool-level config surface.
- Outbound proxy configuration. Stays implicit on `Req`'s defaults.
- Robots.txt enforcement (see §5 Q3).

**Why a shared module rather than inline checks per tool.** Three reasons. First, two tools today, more later (the future milestone's paid backends all do outbound HTTP) — duplicating the SSRF logic per tool means three code paths the next reviewer has to audit instead of one. Second, the DNS-recheck dance is easy to get subtly wrong (forgetting IPv6, missing IPv4-mapped-in-IPv6, not re-resolving on redirect); centralizing forces one correct implementation. Third, the redaction helper is needed identically by anything that logs an outbound request.

### 4.4 Setup wizard — no new step

M7 adds no wizard step. The M4.10 flow (`:provider` → `:model` → `:channel` → `:personalization` → `:review`) is unchanged. Every M7 built-in either is keyless on a public endpoint (`web_search`, `web_fetch` — both gated by `NetGuard`) or works against the local filesystem / OS (`file_edit`, `glob_search`, `content_search`, `git_*`, `skill_create`, `model_routing_config`) or the model already configured by M4.10 (`delegate`).

The "ask the user which backend they want for `web_search`" UX is the future milestone's, not M7's. Until that milestone lands, switching `web_search` away from DDG requires editing `web_search.ex` and rebuilding — not a supported user path.

### 4.5 Prompt summary generation

`FermixCore.Prompt.RuntimeSections.runtime_contract/0` currently hand-lists scheduling/memory tools as anti-shell guidance. M7 generalizes:

```elixir
def capability_summary do
  Capabilities.Registry.list(policy: nil, kind: :builtin)
  |> Enum.group_by(&(&1.metadata[:category] || :other))
  |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)
  |> Enum.map_join("\n\n", &format_category/1)
end

defp format_category({category, capabilities}) do
  "## #{category_label(category)}\n" <>
    Enum.map_join(capabilities, "\n", fn cap ->
      "- `#{cap.name}` — #{cap.metadata[:when_to_use] || cap.description}"
    end)
end
```

Output shape:

```text
## File & code
- `file_edit` — Replace a unique anchor string in a file (atomic).
- `file_read` — Read a file's contents by absolute path.
- `file_write` — Write or overwrite a file by absolute path.
- `glob_search` — Find files matching a glob pattern.
- `content_search` — Search file contents across the workspace.

## Web
- `web_fetch` — Fetch a URL and return readable markdown.
- `web_search` — Search the web by query.

## Git
- `git_read` — Inspect git status, logs, branches, diffs, and objects.
- `git_write` — Stage, commit, checkout, or pull changes. (Push deferred to M10 with approval.)

## Scheduling
- `schedule_job` — Create a Fermix scheduled job. Use this instead of shell crontab/launchctl.
- `list_jobs` / `pause_job` / `resume_job` / `remove_job` — Manage scheduled jobs.
...
```

The bootstrap template (`apps/fermix_core/priv/templates/agents.md.eex` — touched in the recent plan file) loses its hand-written tool list and instead embeds `<%= capability_summary() %>`. The fixed text in the template stays focused on routing principles ("prefer built-ins over shell"); the dynamic list always tracks reality.

**Token budget.** With the §4.2 catalog, the summary is ~25 lines (~400 tokens). The previous prose tool list ran ~700 tokens. Net savings of ~300 tokens on every request, despite shipping more tools.

### 4.6 `tool_help` capability

When the model wants depth on a specific tool — full parameters, examples, failure modes — it calls:

```text
tool_help(name: "content_search")
```

Returns a structured block (Markdown for human-readable rendering in traces; the LLM consumes the same text):

```text
# content_search

Search file contents across the workspace.

## Parameters
- `pattern` (string, required) — text or regex to search for
- `path` (string, default ".") — root to walk
- `regex` (boolean, default false) — interpret pattern as regex
- `max_results` (integer, default 200) — cap on hits

## Examples
- `{"pattern": "TODO", "path": "apps/"}` — find every TODO under apps/
- `{"pattern": "defp.*do$", "regex": true}` — grep with regex

## Failure modes
- `not_found` — no matches; tool returns success with empty results.
- `timeout` — search exceeded timeout_ms.
- `invalid_regex` — regex did not compile.
```

This is generated by `tool_help` reading `Registry.find/2` and pretty-printing the metadata. No new prose lives anywhere — it all comes from `metadata`.

### 4.7 Self-knowledge skill

A static skill at `apps/fermix_core/priv/skills/self_knowledge/SKILL.md`:

The frontmatter parser (`apps/fermix_core/lib/fermix_core/agents/skill_registry.ex:263`) is line-oriented, not real YAML — every line must be `key: value` on one line, and `trust:` is rejected from frontmatter (`AgentDefinition.parse_trust/1` at `:239` only accepts `:core | :local | :third_party` atoms; trust is path-derived, not declared). So:

```markdown
---
name: self_knowledge
description: Use when the user asks what Fermix is, what it can do, or how agents/jobs/memory/channels fit together. Returns the canonical Fermix manual.
allowed_tools: []
---

# Fermix self-knowledge

Fermix is an Elixir-native multi-agent platform that runs as a single OS daemon...

## How it fits together
- Channels (Telegram, ...) deliver user messages.
- The Main Agent owns the conversation; sub-agents are spawned per skill invocation.
- Memory is source-aware (main vs job).
- Scheduled jobs run isolated bounded loops.
- Capabilities are provided by built-in tools, skills, and MCP servers.

## Built-in tools
[...summary table, generated by build script and committed...]

## Skills vs built-ins
Built-ins ship with the binary and are always present (modulo API-key opt-out).
Skills are user-installed under ~/.fermix/skills/ and can be enabled or disabled.
...
```

The skill is invoked like any other skill (M4.9 capability dispatch). It carries no tools and produces no side effects — it's a manual the agent can quote from.

The contents are checked in and updated by hand. We do **not** auto-generate from CLAUDE.md or roadmap headers — those move fast and aren't user-facing.

### 4.8 Built-in tools vs skills

One paragraph in the README, in the `tool_help(name: "self_knowledge")` output, and as a comment block in `~/.fermix/config.toml` after the wizard runs:

> Built-in tools ship inside Fermix. They are always available (unless the tool requires an API key you didn't provide at setup, in which case it is not registered). You don't install or remove them. Skills are different: they live under `~/.fermix/skills/`, you install them with `fermix skills add`, you can enable/disable them, and each skill manages its own configuration including any API keys it needs.

Skills CLI commands are out of M7 scope; the paragraph forward-references them so the user understands the model.

---

## 5. Open Decisions (defaults applied unless overridden in review)

**Q1. Web search backend in M7.**
**Default:** DuckDuckGo HTML SERP scrape (`https://html.duckduckgo.com/html/`). Single backend, hardcoded. Reasons: keyless, real web results, zero setup friction, no Fermix-shared key money sink. Trade-offs we accept explicitly: (a) layout-fragile — DDG can change selectors or markup at any time, in which case the parser detects "no result rows AND no known empty-results marker" and surfaces `{:error, :parser_changed}` so the failure is loud, never a silent empty list; (b) CAPTCHA risk under heavy automation, surfaced as `{:error, :rate_limited}`; (c) IP-rate-limit risk for shared environments, same surfacing. Mitigations: bounded result count (10), conservative usage from a single daemon, `User-Agent: fermix/<version>` so DDG can identify and contact us if needed, telemetry tag `tool: "web_search", success: false, error: <atom>` so failures are visible in `~/.fermix/traces/`. The future "pluggable capability backends" milestone replaces this with a per-capability backend choice (Parallel REST, Tavily, etc., all keyed) — until then, this is the only `web_search` path.

**Q2. Unconfigured API tool — not-registered vs error-on-call stub.**
**Moot in M7** because no M7 built-in requires an API key. The decision still applies in principle (and the future milestone will need it); the originally-recorded answer was "not-registered" per CLAUDE.md rule 12. Restating here so the future milestone's design doc can pick it up: when an API-using tool's key is absent, do not register it — model's catalog should match reality.

**Q3. `web_fetch` — honor `robots.txt`?**
**Default:** no. Reasons: Fermix is an agent acting on behalf of the user; `web_fetch` is the user fetching a URL. `robots.txt` exists for bulk crawlers, not for a single user-initiated page load. We do set `User-Agent: fermix/<version>` so site operators can identify and rate-limit if needed. (Reconsidered if abuse becomes a concern.)

**Q4. Git — single tool with subcommand vs split per policy band.**
**Default:** split into two (`git_read`, `git_write`). Reasons: the registry's policy filter (`apps/fermix_core/lib/fermix_core/capabilities/registry.ex:176`) operates at capability level, not per action; a single `git_operations` tool would either lose `git status` in `:read_only` contexts or silently bypass policy on commits. Two tools cleanly map to the `:read_only` and `:read_write` policy classes. `git_push` originally rounded out the trio with `hidden_from_agent?: true`, but the registry's approval filter (`registry.ex:253`) plus AgentLoop's lack of `include_hidden?: true` (`agent_loop.ex:119`) means an approval-gated capability is invisible to the model in M7. M10 owns the approval-exposure path; `git_push` lands there. Trade-off: two names instead of one for `read`/`write`, and `shell` carries pushes until M10. Mitigated by both `git_*` tools sharing a `category: :git` and being adjacent in the prompt summary.

**Q5. `content_search` — pure Elixir vs `rg` shellout.**
**Default:** pure Elixir. Reasons: single-binary distribution (M4.8); no `rg` dependency; predictable on every install. Trade-off: 5–20× slower than `rg` on huge trees. Acceptable for the typical workspace size; if a user has a 100k-file repo, they can use `shell` with `rg` directly.

**Q6. `delegate` — recursion guard.**
**Default:** `delegate` cannot call `delegate` (the spawned model's registry filter excludes it). Reasons: M4.9 already enforces `max_skill_depth` at 4 for skill recursion; `delegate` is single-turn and shouldn't nest at all. Hard cap, not configurable.

**Q7. `tool_help` — always registered, or only when "more than N tools" present.**
**Default:** always registered. Tiny cost (one entry in summary); having it always present teaches the agent the pattern early.

---

## 6. Stages

Each stage is a self-contained PR with code + tests + format/credo green. Stage 0 is mandatory pre-work; Stages 1–5 are tool-category PRs that can land in any order; Stages 6–7 close the loop. **Estimates are agent wall-clock**, not human-developer time (per global memory: "Estimate in agent time").

### Stage 0 — Capability metadata schema + existing-tool migration (1.5–2 h, P0)

- Document `metadata` schema in `Capability.@moduledoc` (the keys in §4.1).
- Add `@callback when_to_use/0`, `examples/0`, `failure_modes/0`, `requires_setup/0` *(default `nil`)*, `category/0` to `Capabilities.Builtin.Tool` behaviour, all with default implementations returning conservative values so the migration can land tool-by-tool.
- Update `Capabilities.Builtin.from_tool_module/1` to read these and populate `metadata`.
- Migrate the 12 existing tools (file_read/write, shell, browser, memory_recall/store/sources_list, schedule_job/list_jobs/pause/resume/remove) — each gets a `when_to_use`, `category`, and 1 example.
- Tests: `metadata_schema_test.exs` asserting every registered builtin has `when_to_use` and `category` populated; `builtin_seeder_test.exs` round-trips one full schema.

Ship gate: existing tests green, every existing builtin has populated metadata, no behavior change.

### Stage 1 — File & code tools (2–3 h, P0)

- Implement `file_edit` (port from `~/projects/rustyclaw/src/tools/file_edit.rs`): args `path, old_string, new_string`; refuse on non-unique `old_string`; atomic via tmp+rename + 0600 perms preserved.
- Implement `glob_search`: args `pattern, path, max_results`; uses `Path.wildcard/2`; returns absolute paths.
- Implement `content_search`: args `pattern, path, regex?, max_results, timeout_ms`; pure-Elixir walker; binary-file skip heuristic (`File.read!/1` first 4KB, look for null byte); explicit timeout.
- Tests: per-tool happy path + each `failure_modes` tag.

Ship gate: three new tools registered; recorded test fixture for each.

### Stage 2 — Git tools (split: read / write) (1–1.5 h, P1)

- Implement `git_read` (subcommands: `status`/`log`/`diff`/`branch`/`show`; `policy_class: :read_only`).
- Implement `git_write` (subcommands: `add`/`commit`/`checkout`/`pull`; `policy_class: :read_write`). `push` is **not** in the whitelist — see §3 Non-Goals; M10 owns the approval-gated `git_push` capability.
- Both share a small `Tools.GitCommand.run/2` helper for `System.cmd("git", [...])` (structured args, no shell concat).
- Tests: each tool's subcommand whitelist (reject unknown including `push`), each happy path, registry filtered to `:read_only` returns `git_read` only and not `git_write`.

Ship gate: two git tools registered, capability filter tested under each policy band, `git_write` rejects `push` subcommand with a clear error pointing at M10.

### Stage 3 — Web tools (`web_fetch` + `web_search`) and `NetGuard` (3–5 h, P0)

All keyless. No wizard surface. `http_request` is **not** in this stage — see §4.3 closing paragraph; it moves to the future "Pluggable Capability Backends" milestone where its `allowed_domains` config lands.

Sub-deliverables:

1. **Add `:floki` to `apps/fermix_core/mix.exs`** — `{:floki, "~> 0.36"}`. (Verify: not present today per `apps/fermix_core/mix.exs:26`.) Used by `web_fetch` for HTML→markdown and by `web_search` for SERP parsing.
2. **Implement `FermixCore.Net.Guard`** per §4.3a:
    - `validate/2` — scheme allowlist, no whitespace, IP literal block (RFC 1918 + loopback + link-local + IPv6 equivalents), hostname literal block, DNS resolution + recheck of every resolved A/AAAA. Accepts `resolver: fn host -> {:ok, [ip]} | {:error, term} end` opt; defaults to a thin wrapper around `:inet_res.lookup/3`. The opt makes DNS-rebinding tests work without a mocking dep — same plug-style injection pattern as Fermix's existing `Req.Test` usage.
    - `validate_redirect/3` — same, applied to a new URL given the original; resolver opt threaded through.
    - `redact_headers/1` — overwrites values for the `~w(authorization cookie set-cookie proxy-authorization x-api-key x-auth-token)` header set with `"***REDACTED***"`.
    - Tests: each rule fires on the right input; IPv4-mapped-in-IPv6 (`::ffff:127.0.0.1`) is blocked; DNS rebinding (`resolver: fn _ -> {:ok, [{169, 254, 169, 254}]} end` for an innocent-looking name) is blocked; redirect from public host to private host is blocked; redaction covers all six sensitive header names case-insensitively.
3. **Implement `FermixCore.Tools.HtmlText.extract/1`** — takes a Floki-parsed document and emits markdown-light text. Walks the node tree, preserving structure for `<h1>`–`<h6>` (rendered as `# `–`###### `), `<ul>` / `<ol>` (rendered as `- ` / `1. `), `<pre><code>` (fenced block), inline `<code>` (`` `code` ``), `<a href>` (`[text](url)`), `<strong>` / `<em>`. Strips `<script>`, `<style>`, `<noscript>`. Output is text the LLM can consume — not full Pandoc-style markdown, just enough structure to keep headings/lists/code from collapsing into one paragraph.
4. **Implement `web_fetch`** — `Req.get/1` with `redirect: false` (manual redirect handling), `connect_options: [timeout: 3_000]`, `receive_timeout: 15_000`, `retry: false`. Body cap 1MB enforced via `into:` callback. Redirect cap 5, every hop validated through `NetGuard.validate_redirect/3`. `User-Agent: fermix/<version>`. Body parsed with `Floki.parse_document!/1` then rendered through `HtmlText.extract/1`. Result and any logged headers run through `NetGuard.redact_headers/1`.
5. **Implement `web_search`** against DuckDuckGo's HTML SERP. POST `https://html.duckduckgo.com/html/` (URL gated by `NetGuard.validate/2`) with `Req.post/1`, `form: [q: query]`, same timeout/retry settings as web_fetch, `User-Agent: fermix/<version>`. Query length cap 1024 chars (reject longer with `{:error, :query_too_long}`). Floki parses `.result__title a.result__a` (title + href) and `.result__snippet` (snippet); cap 10 results. Failure-mode contract:
    - DDG explicit empty-results marker present (e.g., `.no-results` div or known "no results" page text) → `{:ok, []}`.
    - HTTP 202/429, or response body matches a known bot-challenge fingerprint → `{:error, :rate_limited}`.
    - Result rows missing AND no known empty-results marker → `{:error, :parser_changed}` (this is the loud-fail path so users know the scrape broke instead of silently getting empty results).
    - Transport failure → `{:error, {:network, reason}}`.
    - Each error includes a clear message pointing at the future "pluggable backends" milestone as the recovery path.
6. **Tests:**
    - `HtmlText.extract/1` round-trips a small fixture set: heading levels preserved, lists preserved, code blocks fenced, links rendered, scripts/styles stripped.
    - `web_fetch` happy path with 200 + HTML body; body cap enforcement; redirect cap (4 valid + 1 over); redirect to a private host blocked by `NetGuard` (test passes a stub `:resolver` opt that returns a private IP for the redirect target).
    - `web_search` parser fixtures: one happy results page (10 entries), one DDG-empty-results page (`{:ok, []}` from the marker), one CAPTCHA/challenge page (`{:error, :rate_limited}`), one selectors-removed page (`{:error, :parser_changed}`).
    - Both tools' outbound URLs are pre-validated through `NetGuard` — tests inject `resolver: fn _host -> {:ok, [{169, 254, 169, 254}]} end` and assert the call is rejected before the HTTP layer is touched. No `:meck`/Mox; pure function injection.

Ship gate: `web_fetch` + `web_search` + `NetGuard` registered/in-place; fixture corpus coverage for each; SSRF tests demonstrate private hosts and DNS-rebinding-style addresses are rejected before any HTTP call goes out.

### Stage 4 — Delegation, skill scaffolding, routing config (2–3 h, P1)

- Implement `delegate` (port from `~/projects/rustyclaw/src/tools/delegate.rs`): one-shot model call via `Adapter.for_model/1`; no nested tool calls inside; recursion guard (delegate excluded from delegated agent's registry).
- Implement `skill_create`: refuses to overwrite; writes `~/.fermix/skills/<name>/SKILL.md` from a frontmatter template and creates `evals/evals.json` starter cases so the new skill can enter the `skill-creator` eval loop immediately.
- Implement `model_routing_config`: read/update `[fermix_core.routing]` via `ConfigStore` round-trip.
- Tests: per-tool happy + each `failure_modes` tag; recursion guard for `delegate`; `skill_create` emits valid eval scaffolding.

Ship gate: three more tools registered; `delegate`, `skill_create`, and `model_routing_config` each have `skill-creator` eval cases proving the agent chooses the intended capability instead of `shell` or free-form text.

### Stage 5 — `tool_help` + prompt summary refactor (1.5–2 h, P0)

- Implement `tool_help` capability: validates `name` against `Registry.find/2`, formats per §4.6.
- Implement `RuntimeSections.capability_summary/0` per §4.5; group by `metadata.category`.
- Edit `apps/fermix_core/priv/templates/agents.md.eex` to embed `<%= capability_summary() %>`; remove the hand-listed tool block.
- Update `runtime_contract/0` to point at the dynamic summary instead of duplicating tool names. Anti-shell language stays as a routing principle, not a tool list.
- Tests: capability_summary contains every registered builtin; tool_help returns expected shape; bootstrap render snapshot.

Ship gate: prompt token count drops by ~300; agent picks new tools in conversation tests.

### Stage 6 — Self-knowledge skill + CHANGELOG/ROADMAP (1–1.5 h, P0)

- Write `apps/fermix_core/priv/skills/self_knowledge/SKILL.md` per §4.7.
- Add the README "built-in tools vs skills" paragraph (§4.8).
- Add the same paragraph as a comment block in the wizard-written `~/.fermix/config.toml`.
- CHANGELOG entry per §9.
- ROADMAP: mark M7 shipped, note `cron_*` not added (canonical names from M4.11), note "Default Skill Set" section's `skill_create` is now part of M7.

Ship gate: self-knowledge skill loads; user-facing docs reflect built-in vs skill distinction; the self-knowledge skill passes a `skill-creator` eval set comparing with-skill vs baseline answers for "what is Fermix", "what can you do", and "built-ins vs skills".

**Total agent wall-clock: ~12–17 hours.** Variance sources: Stage 1 (pure-Elixir `content_search` perf), Stage 2 (registry filter behavior under three new `policy_class` bands), Stage 3 (NetGuard's IPv6/DNS-rebinding edge cases + DDG fixture corpus), Stage 4 (`delegate` × `Adapter.for_model/1` interaction not tested by M4.9). Stage 3 absorbed the bulk of the network-safety scope (NetGuard module + tests) and is now the largest single stage.

**Reviewable in ~2 review days.** Stages 0 and 5 should be reviewed together (the "schema + prompt" pair that sets up everything else). Stages 1, 2, 3, 4 are independent and can ship one per review pass.

---

## 7. Test Plan

### 7.1 Unit tests

- **`Capability.metadata` schema** — `metadata_schema_test.exs`: every registered builtin has `when_to_use` (string), `category` (atom in known set), `examples` (list of valid shape), `failure_modes` (list of `%{tag: string, description: string}` maps — JSON-safe per `Wire.json_safe/1`), `requires_setup` (nil; the field exists for forward-compat but no v1 built-in sets it).
- **`from_tool_module/1` behavior** — every M7 built-in registers unconditionally because `requires_setup/0` returns `nil`. The skip-registration path stays untested in M7 — the future "pluggable backends" milestone exercises it when it lands.
- **Per-tool tests** — happy path + every documented `failure_modes` tag, per tool added in Stages 1–4.
- **`tool_help`** — known name returns full block; unknown name returns clear error; assert returned block contains description, all parameter names, all examples, all failure modes.
- **`capability_summary/0`** — output contains every registered builtin's name and `when_to_use`; grouped by category in expected order; absent when registry filter removes it.
- **`web_search` DDG parser** — fixture corpus: happy results page → 10 entries; CAPTCHA/challenge page → `{:error, :rate_limited}`; explicit empty-results marker page → `{:ok, []}`; selectors-removed page → `{:error, :parser_changed}` (loud, not silent). No live network in unit tests.
- **`NetGuard` validation** — scheme rejection; whitespace rejection; IPv4 private/loopback/link-local rejection; IPv6 ::1 / fe80::/10 / fc00::/7 rejection; IPv4-mapped-in-IPv6 (`::ffff:127.0.0.1`) rejection; hostname literals (`localhost`, `*.local`) rejection; DNS-rebinding rejection (pass `resolver: fn _ -> {:ok, [{169, 254, 169, 254}]} end` for a public-looking name and assert rejection); redirect from public→private host rejection; sensitive-header redaction covers all six names case-insensitively.
- **`delegate` recursion guard** — `delegate` capability not present in the registry filter passed to the delegated call.
- **Git tool dispatch** — `git_read` and `git_write` route to expected `git ...` invocations; policy filters expose `git_read` to `:read_only` contexts and `git_write` to `:read_write` contexts only; `git_write` rejects the `push` subcommand with a clear error message pointing at M10 (where the approval-gated `git_push` lands).
- **Skill Creator eval artifacts** — every new M7 tool family and every bundled skill has an `evals/evals.json` entry with realistic prompts, expected output, and verifiable expectations. Tool eval expectations must include the intended `tool:exec` name and "no `shell` fallback" when Fermix owns the verb.

### 7.2 Integration tests

- **Bootstrap render snapshot** — `agents.md.eex` rendered with the full Stage-6 registry matches a checked-in golden file. Tests that adding a new tool with proper metadata changes the golden file *only* in the expected place.
- **End-to-end tool selection (recorded fixtures)** — fixture: user asks "find every TODO in apps/" → main agent calls `content_search` (not `shell`). Fixture: user asks "search the web for the latest Elixir release" → main agent calls `web_search` (not `web_fetch` on a guessed URL). Fixture: user asks "what is Fermix" → main agent invokes the `self_knowledge` skill (not free-form summarization).
- **Wizard regression** — fresh `FERMIX_HOME` → wizard runs the unchanged M4.10 flow (provider/model/channel/personalization/review). M7 should add zero new prompts.
- **Token budget regression** — assert the rendered system prompt is under a configured budget (e.g., 3000 tokens). Catches accidental prose creep in `RuntimeSections`.

### 7.3 Skill Creator eval gate

Before any M7 stage is marked shipped, run the `skill-creator` eval flow against the tools or skills changed in that stage:

1. Add or update `evals/evals.json` with 2-3 realistic prompts per tool family or skill.
2. Run paired evaluations where applicable: with the new capability/skill enabled and a baseline without it (or with the previous version for edits).
3. Generate the eval review report from the `skill-creator` workflow and attach the pass/fail summary to the stage review.
4. Do not accept a tool or skill with only unit tests. Unit tests prove the implementation works; evals prove the main agent knows when to use it.

For tool evals, the expected evidence is trace-level: the main agent selected the intended capability (`tool:exec` for the tool name) and did not use `shell`, `browser`, or free-form text when a Fermix-owned capability exists. For skill evals, the expected evidence is output-level: the skill-triggered run beats the baseline on the written expectations.

### 7.4 Manual verification (post-merge sanity)

This is the "is the catalog actually steering the model" check that golden-file tests can't fully cover.

- **Steering check.** ChatGPT Plus user runs the daemon, opens Telegram, asks: (a) "find every `TODO` in this project", (b) "summarize https://hexdocs.pm/req/Req.html", (c) "search the web for the current Tavily pricing", (d) "what's the difference between a Fermix skill and a built-in tool". Verify in `~/.fermix/traces/`:
    - (a) one `tool:exec` for `content_search`, no `shell`.
    - (b) one `tool:exec` for `web_fetch`, no `shell curl`.
    - (c) one `tool:exec` for `web_search` (no key needed in v1 — DDG default), no `web_fetch` on a guessed URL. If DDG returns no results or rate-limits, the agent reports the failure honestly rather than fabricating. Pick a query unlikely to be a definition (so DDG instant-answer-only behaviors don't mask scrape failures).
    - (d) one `tool:exec` for `invoke_skill` (or however M4.9 routes skills) with `skill: "self_knowledge"`, returning the manual.
  Any miss → either a `when_to_use` line is unclear or the prompt summary is being out-weighed by something else. Tighten and re-run.

---

## 8. Risk and Rollback

**Risk 1: `web_search` (DDG HTML scrape) breaks loudly, not silently.** The default backend is unofficial. DDG can change selectors, switch the form action URL, gate the page behind a CAPTCHA challenge, or rate-limit our IP at any time. The Stage 3 contract distinguishes three failures so the agent surfaces the real reason instead of returning a falsely-empty result set: `{:error, :rate_limited}` (challenge body detected), `{:error, :parser_changed}` (no results AND no known empty-results marker — i.e., DDG changed the page shape), and `{:ok, []}` (explicit empty-results marker present — a real "no matches" answer). Mitigations: fixture corpus in Stage 3 to detect parser regressions in CI before they reach users; telemetry on `web_search` failures so a real-world failure rate is visible in `~/.fermix/traces/`; `failure_modes` in `tool_help` documents all three branches so the agent can explain accurately. Accepted trade-off — no-key default beats paid-only-default for v1; reliability is the future milestone's job.

**Risk 2: SSRF / outbound-network safety.** Both `web_fetch` and `web_search` make outbound HTTP calls; either could be steered into hitting cloud-instance metadata (`169.254.169.254`), localhost services, RFC 1918 ranges, or IPv6 link-local addresses if not validated. RustyClaw's `web_fetch.rs:269` had the validation; we'd lose it without the M7 NetGuard module. Mitigation: §4.3a NetGuard is a Stage 3 ship-gate deliverable. Both tools route every outbound URL (and every redirect target) through `NetGuard.validate/2`. SSRF tests in Stage 3 inject a stub `:resolver` opt that returns private addresses for innocent-looking names and assert the call is rejected before any HTTP layer fires (no Mox/`:meck` dep — pure function injection, same plug-style pattern Fermix uses elsewhere). M7 does **not** ship per-tool `allowed_domains` (deferred to the future milestone); NetGuard's hardcoded "public-only" rules are the v1 floor. **Residual gap:** the preflight DNS check is not full DNS rebinding defense — Req re-resolves at connect time, leaving a TOCTOU window. M7 explicitly accepts this gap; M10 closes it via IP-pinned outbound (custom Finch pool with SNI override). See §4.3a rule 5.

**Risk 3: Capability summary still doesn't beat shell for some verbs.** The plan-file fix already showed that `schedule_job` needed both a strong `description` and a runtime-contract anti-shell rule. Adding 11 more tools means 11 more chances for the model to misroute, especially for verbs the catalog doesn't yet name (`web_screenshot`? `pdf_read`? `http_request`-style API calls — deferred to the future milestone; `git push` — deferred to M10). Mitigation: §7.3 Skill Creator evals and the §7.4 manual steering check are mandatory before declaring M7 done; misrouting fixes go into the failing tool's `when_to_use` line, not into prompt-level prose. If a verb has *no* tool, the agent correctly falls back to `shell` — that's not a misroute.

**Risk 4: Pure-Elixir `content_search` is too slow on real repos.** Concrete number: on a 5,000-file Phoenix umbrella, a regex grep is probably 200–800ms. Acceptable. If a user has a 100k-file repo, `shell` + `rg` is still available. Mitigation: bound results (default 200), bound timeout (default 30s). If users hit the cap regularly, M7+1 can add `rg` detection — but only as the *only* implementation if `rg` is present, never alongside the Elixir one (rule 12).

**Risk 5: `delegate` accidentally bypasses skill recursion guard.** `delegate` is single-turn so it shouldn't recurse, but if the delegated model is configured with skills/tools that themselves call `delegate`, we have a back door. Mitigation: §6 Q6's "delegate excluded from delegated agent's registry" is enforced in `Tools.Delegate.execute/2` by passing a filtered registry to the spawned `Adapter.chat/3`. Test for this is mandatory in Stage 4.

**Risk 6: Self-knowledge skill drifts from reality.** Static markdown checked into the binary means a stale manual ships if not updated alongside design changes. Mitigation: a CI check (`mix self_knowledge.lint`?) that asserts every M-doc filename in `docs/` is mentioned somewhere in the skill, plus a CONTRIBUTING note. Doesn't catch semantic drift, but catches "we shipped M8 and never added it to the manual."

**Rollback.** Each stage is independently revertible:

- Stage 0 metadata is additive — reverting drops the schema requirement, no behavior breaks.
- Stages 1–4 each register one to four new capabilities — reverting unregisters them; existing tools/agent loop unaffected.
- Stage 5 swaps the bootstrap template — reverting restores the hand-edited tool list.
- Stage 6 is docs/skill — reverting removes the skill from the registry and the README paragraph.

The riskiest revert is Stage 3 (it ships `web_search` + `web_fetch` + `NetGuard` together — the keyless web stack). Reverting Stage 3 means the agent loses `web_search` and `web_fetch` and falls back to `shell` for web work; existing tools and the rest of the catalog are unaffected.

---

## 9. CHANGELOG entry shape

```
### Added — M7

- Built-in tool catalog expanded: file_edit, glob_search, content_search,
  git_read, git_write, web_fetch, web_search, delegate, skill_create,
  model_routing_config, tool_help. All shipped with the binary; no install
  step. All keyless in v1 — no setup wizard prompts added.
- New shared helper FermixCore.Tools.HtmlText.extract/1: walks Floki-parsed
  documents and emits markdown-light text (headings, lists, code blocks,
  links). Used by web_fetch. Floki is parser-only; the renderer is ours.
- New shared module FermixCore.Net.Guard. Validates outbound URLs for
  web_fetch and web_search against a hardcoded "public HTTP(S) only" rule
  set: scheme allowlist, IP-literal block (RFC 1918 + loopback + link-local
  + IPv6 equivalents + IPv4-mapped-in-IPv6), DNS resolution + recheck of
  every resolved address (defense against DNS rebinding), redirect
  re-validation per hop, and sensitive-header redaction for logging.
- web_search uses DuckDuckGo's HTML SERP scrape as the only backend. Keyless,
  free, real web results, layout-fragile. Loud failure contract: explicit
  empty-results marker → {:ok, []}; CAPTCHA/challenge → {:error, :rate_limited};
  rows missing AND no known empty marker → {:error, :parser_changed}.
  Pluggable backends + paid alternatives (Parallel, Tavily) are scoped to a
  separate future milestone.
- Added :floki ~> 0.36 to apps/fermix_core/mix.exs for HTML parsing
  (web_fetch markdown extraction + web_search SERP parsing).
- Capability metadata schema: when_to_use, examples, failure_modes,
  requires_setup, category. All built-in tools (existing + new) populate it.
  requires_setup stays nil for every M7 built-in; the hook is wired for the
  future "pluggable backends" milestone.
- Main-agent system prompt now generates its tool list dynamically from
  capability metadata (RuntimeSections.capability_summary/0). Smaller,
  always accurate.
- New on-demand capability: tool_help(name) returns full per-tool docs
  (description, parameters, examples, failure modes) without bloating the
  base prompt.
- New self-knowledge skill: explains Fermix architecture, agents/jobs/memory/
  channels, and built-in vs skill distinction. Invoke when the user asks
  high-level "what is/can Fermix" questions.

### Changed — M7

- apps/fermix_core/priv/templates/agents.md.eex now embeds the dynamic
  capability summary; the hand-listed tool block is removed.
- RuntimeSections.runtime_contract/0 anti-shell guidance is now a routing
  principle ("prefer built-ins"), not a hand-maintained tool list. Tool-level
  steering lives in each capability's metadata.when_to_use.
- Capabilities.Builtin.Tool behaviour gains five callbacks
  (when_to_use, examples, failure_modes, requires_setup, category) with
  default implementations so existing tools migrate incrementally.

### Removed — M7

- Nothing. Existing tools are migrated, not replaced. M4.11 job/memory tool
  names are canonical; cron_*-named duplicates from the roadmap are not added.
```
