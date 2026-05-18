# Milestone 10: Onboarding Revamp — Functional Design

**Status:** Draft
**Date:** 2026-05-18
**Author:** Sujeeth / Aira
**Depends on:** M3 (shared wizard surface), M4.7 (personalization step), M4.9 (capabilities), M4.10 (Codex parity), M4.12 (inbound MCP), M5 (sandbox)
**References:** `apps/fermix_core/lib/fermix_core/setup/wizard.ex`, `apps/fermix_core/lib/fermix/cli/setup.ex`, `apps/fermix_core/lib/fermix_core/setup/runtime.ex`, `apps/fermix_web/lib/fermix_web_web/live/setup_live.ex`, `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md`

> An earlier revision of this doc proposed a custom terminal TUI. After review we dropped it: terminal-compat tax, escape-sequence parsing, raw-mode crash recovery, and per-terminal bug reports are too much ongoing cost for a flow the operator hits twice in a year. The web surface already exists, gives real form widgets for free, and works fine over SSH port-forward. M10 now extends the existing LiveView and keeps the line prompter as the headless fallback.

---

## 1. Problem / Goal

`fermix setup` today is a one-shot, top-to-bottom line prompter. For each required answer it writes `Label: ` to stdout and reads a line from stdin. The operator:

- types a provider name from memory (`openai`/`openai_codex`/`anthropic`) with no menu
- types a model name with no list (the wizard prints `(blank = gpt-4o)` and expects the operator to either know the catalog or accept the default)
- types `yes`/`no` for realtime, then walks through four follow-up text prompts even if they only meant to flip it off
- re-runs the whole linear flow with `--reconfigure` to change any single value
- discovers non-required surfaces (sandbox profile, MCP servers, skill catalog, search backend, built-in tool toggles) by reading docs — none of them appear in `fermix setup`

The wizard's data layer is solid: `FermixCore.Setup.Wizard` already returns a structured prompt list, evaluates readiness, persists via `ConfigStore`, and is shared by the CLI and the LiveView. `FermixWebWeb.SetupLive` already mounts the same report at `/setup`, but it is read-only — it renders state and tells the operator to run the CLI. The gap is purely at the **rendering** layer.

**Goal of M10:** make the existing LiveView the primary interactive surface for setup. On a host with a display, `fermix setup` launches an ephemeral local Phoenix endpoint and opens the browser. On a host without a display, `fermix setup` keeps the current line prompter unchanged. Headless improvements are deferred. The data layer (`Setup.Wizard`, `ConfigStore`, `SecretWriter`) is untouched.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| Display detection | P0 | New | `Fermix.CLI.Setup` chooses Web vs Runtime based on `:os.type/0` + `DISPLAY`/`WAYLAND_DISPLAY`. macOS always gets web; Linux gets web only when a display is set. |
| Ephemeral setup endpoint | P0 | New | When no daemon is running, `Fermix.CLI.Setup.Web` starts a minimal `FermixWeb.Endpoint` bound to `127.0.0.1:<random>` carrying only the `/setup` LV, opens the browser, blocks until the LV signals done, then tears down. |
| Reuse running daemon | P0 | New | When the daemon is already up (its `FermixWeb.Endpoint` is listening), the CLI prints/opens `http://127.0.0.1:<daemon_port>/setup?t=<token>` instead of spinning up a second endpoint. |
| One-time token gate | P0 | New | The setup URL carries a random `t=` token written to `~/.fermix/setup-token` (mode 0600). The LV refuses to mount without a matching token. Protects against same-host neighbors. |
| Full-form `SetupLive` | P0 | Rewrite | Extend the current read-only LV into a category-tabbed form: Provider & Model, Realtime, Channels, Tools, Skills, Search, Sandbox, Memory, Personalization, Doctor. Each category posts back through `Wizard.save_answers/2`. |
| Browser opener | P0 | New | `Fermix.CLI.Setup.Web.open_browser/1` shells out to `open` (macOS) or `xdg-open` (Linux). On failure (no opener), prints the URL and waits. |
| SSH port-forward hint | P0 | New | When the CLI prints the URL it also prints the `ssh -L` line so an operator on a workstation can forward into a remote machine. |
| Headless fallback | P0 | Keep | No-display hosts run `FermixCore.Setup.Runtime.run/2` exactly as today. Tweaks to the line prompter (numbered menus, category subcommands) are tracked separately. |
| Flag-driven non-interactive | P0 | Keep | `fermix setup --provider openai --default-model ...` keeps working byte-for-byte; flag answers skip both web and prompter. |
| `--web` / `--terminal` overrides | P0 | New | `fermix setup --web` forces the web flow even when no display is detected (useful for SSH-forward users). `fermix setup --terminal` forces the line prompter even on macOS. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Custom terminal TUI | Replaced by web flow + line prompter | — |
| Improved headless line prompter (numbered menus, category subcommands, group headers) | Out of scope for M10; current prompter works | Deferred — separate milestone with its own design |
| Web-based MCP server installation form | Adding a new `[mcp.servers.X]` block from a form is rich enough to warrant its own design | Later |
| Web-based skill installation (download from a registry) | Skills are filesystem-backed today; install/uninstall is not a config-only operation | M7+ |
| Provider OAuth flow inside the LV | The Codex OAuth flow already opens a browser callback page; the LV embeds a "Sign in with ChatGPT" button that triggers `CodexLogin.login/1` and waits for the existing callback | Same milestone (already free from existing flow) |
| Multi-user setup (auth on the LV) | The endpoint is bound to `127.0.0.1` + protected by a 0600 file token; that is enough for a single-operator install | — |
| i18n | Setup is English-only today | Later |
| Web endpoint on production daemon by default | The daemon already runs `FermixWeb.Endpoint`. M10 just makes the `/setup` route stop being read-only. No new exposure. | — |

---

## 3. Design Context — what already exists

### `FermixCore.Setup.Wizard` (data layer, keep as-is)

- `report/0` → `%{status, failures, wizard, config_path, restart_required?, seeding_results}`
- `prompts/2` and `reconfigure_prompts/2` → ordered list of `%{key, label, default, required?}` prompt maps
- `save_answers/2` → persists via `ConfigStore`, re-applies snapshot, triggers `BootReport.refresh_if_started/1`, runs prompt-file seeding

M10 adds three small helpers (§7.1) for non-prompt mutations (capability hide, search backend, sandbox overrides) but does not change `save_answers/2`.

### `Fermix.CLI.Setup` and `FermixCore.Setup.Runtime` (orchestrator)

- `Setup.run/1` parses argv and calls `Runtime.run/2` with `puts:`/`prompt:` IO injection
- `Runtime.run/2` decides: print state / seed-only / ask-and-save
- `Runtime.collect_answers/3` walks the prompt list, calling the injected `prompt:` function for each required prompt

M10 leaves `Runtime` exactly as it is. The new web path plugs in **before** `Runtime.run/2` is reached and either fully resolves answers via the LV or falls through.

### `FermixWebWeb.SetupLive` (already at `/setup`, read-only)

143 lines today. Mounts `BootReport.current/0` once, renders a status panel and a "run `mix fermix.setup`" hint. M10 rewrites this into a category-tabbed form (§5) that posts back through `Wizard.save_answers/2`.

### `FermixWeb.Endpoint`

Already supervised by the daemon. When `fermix run` or `fermix start` is active, the endpoint is listening (typically on `127.0.0.1:4001` in dev, a configured port in prod). When the daemon is not running, no endpoint is up.

---

## 4. High-Level Design

### 4.1 Dispatch decision

```
fermix setup [flags]
│
├─ flags provide enough answers (provided_answers != [])
│   → existing Setup.Runtime path (unchanged)
│
├─ --print-state | --migrate-secrets | --import-codex
│   → existing Setup.Runtime path (unchanged)
│
├─ --terminal
│   → existing Setup.Runtime path (unchanged)
│
├─ --web | display_available?()
│   → Fermix.CLI.Setup.Web.run/1  (M10, new)
│
└─ no display
    → existing Setup.Runtime path (unchanged)
```

`display_available?/0`:

```elixir
defp display_available? do
  case :os.type() do
    {:unix, :darwin} -> true
    {:unix, :linux} ->
      System.get_env("DISPLAY") != nil or System.get_env("WAYLAND_DISPLAY") != nil
    _ -> false
  end
end
```

macOS always reports `true` (WindowServer is always running). Linux reports `true` only when an X or Wayland display is exported — which covers desktop installs and rules out SSH'd-in servers. The operator can override either direction with `--web` / `--terminal`.

### 4.2 Module layout

```
apps/fermix_core/lib/fermix/
├── cli/setup.ex                       # existing dispatcher (small edits)
├── cli/setup/web.ex                   # NEW — Web orchestrator (≤150 LOC)
└── cli/setup/web/browser.ex           # NEW — browser opener + url printer (≤60 LOC)

apps/fermix_web/lib/fermix_web_web/
├── live/setup_live.ex                 # REWRITTEN — category-tabbed form (≤500 LOC)
├── live/setup_live/                   # NEW — per-category form components
│   ├── provider_form.ex
│   ├── realtime_form.ex
│   ├── channels_form.ex
│   ├── tools_form.ex
│   ├── skills_form.ex
│   ├── search_form.ex
│   ├── sandbox_form.ex
│   ├── memory_form.ex
│   ├── personalization_form.ex
│   └── doctor_panel.ex
├── components/setup_token.ex          # NEW — token plug for /setup (≤60 LOC)
└── ephemeral_endpoint.ex              # NEW — minimal endpoint when daemon is down (≤120 LOC)
```

Total new/changed envelope: ≤1500 LOC across ~13 files. No new mix dependency (Phoenix and Phoenix.LiveView are already in `fermix_web`).

### 4.3 Layering

```
Fermix.CLI.Setup
        │
        ├──→ FermixCore.Setup.Runtime    (line prompter — unchanged, still used for headless)
        │
        └──→ Fermix.CLI.Setup.Web        (new — for display-bearing hosts)
                │
                ├──→ EphemeralEndpoint   (started when daemon is down)
                │      │
                │      └──→ FermixWebWeb.SetupLive
                │
                ├──→ Browser.open/1
                │
                └──→ wait_for_completion/1
                        │
                        └──→ PubSub :setup_done
                                │
                                └──→ pushed by SetupLive on "save & finish"

FermixWebWeb.SetupLive
        │
        └──→ FermixCore.Setup.Wizard  (data layer — unchanged save path)
```

### 4.4 Lifecycle of `fermix setup` on a desktop host

```
1. Setup.run/1 detects display, opts == [].
2. Setup.Web.run/0:
   a. Write 32-byte random token to ~/.fermix/setup-token (mode 0600).
   b. If FermixWeb.Endpoint is listening (daemon up):
        port = configured port
        reuse_existing = true
      Else:
        start EphemeralEndpoint on 127.0.0.1:<random>
        port = the bound port
        reuse_existing = false
   c. Print:
        Setup running at http://127.0.0.1:<port>/setup?t=<token>
        From your laptop:  ssh -L <port>:127.0.0.1:<port> user@thishost
        Press T to switch to terminal prompts. Ctrl-C to abort.
   d. Browser.open/1 the URL.
   e. Subscribe Phoenix.PubSub topic "setup".
   f. Block on a receive loop:
        receive
          {:setup_done, status} -> :ok
          {:io, "t"}            -> teardown(); call Setup.Runtime.run/2
          {:io, "ctrl-c"}       -> teardown(); exit 130
        after
          30 minutes -> teardown(); exit 1
        end
   g. teardown:
        if not reuse_existing -> stop EphemeralEndpoint
        delete ~/.fermix/setup-token
3. Exit 0 on :setup_done.
```

The "press T to switch" key is read on the CLI's stdin in line mode — no raw mode, no escape parsing. A single byte read is enough.

### 4.5 EphemeralEndpoint

A trimmed Phoenix endpoint that:

- binds `127.0.0.1:0` (kernel picks an unused port)
- mounts only `/setup` and the LiveSocket WebSocket
- runs the existing `Phoenix.PubSub` (`Fermix.PubSub`) so the CLI and LV share a topic
- starts under a one-shot `Supervisor` returned to the CLI for clean shutdown
- does **not** mount channels, health, webhooks, or the home page

Total surface: ~120 LOC of an endpoint module + a tiny router. It reuses the same `FermixWebWeb.SetupLive` and the same `FermixWebWeb.Layouts` from the existing fermix_web app, so the visual shell is identical between "daemon up" and "daemon down" modes.

### 4.6 Token gate

A small plug pipeline on `/setup`:

1. Reads `?t=<token>` from the query string.
2. Reads `~/.fermix/setup-token`.
3. Compares with `Plug.Crypto.secure_compare/2`.
4. On match: set `session[:setup_authorized] = true` and let the LV mount.
5. On mismatch: `send_resp(403, "setup token invalid")`.

The LV also re-checks the session flag in `mount/3`. The token file is unlinked when the CLI tears down. Loss of the file (e.g. operator deletes it mid-flow) forces a CLI restart — same behaviour as today's `~/.fermix/config.toml` mid-write.

---

## 5. Category-tabbed LiveView

### 5.1 Layout

```
┌──────────────────────────────────────────────────────────────┐
│ Fermix setup                            ~/.fermix/config.toml│
│ Status: ready  ·  Provider: openai_codex  ·  Model: gpt-4o   │
├──────────┬───────────────────────────────────────────────────┤
│ ✓ Provider│  Provider & Model                                │
│ ✓ Realtime│                                                  │
│ · Channels│  [ openai      ▼ ]   Default model: [ gpt-4o ▼ ] │
│ ! Tools   │                                                  │
│ · Skills  │  API key:    [•••••••••••••••••••••]  [Show]    │
│ · Search  │  Reasoning:  ( ) none  ( ) low  (•) high         │
│ ✓ Sandbox │                                                  │
│ · Memory  │  [ Save ]   [ Import from Codex CLI → ]          │
│ ✓ User    │                                                  │
│   Doctor  │                                                  │
└──────────┴───────────────────────────────────────────────────┘
```

Left rail: ten category tabs with status icons (`✓` ready / `!` partial / `·` untouched / `–` disabled). Right pane: the form for the active tab.

LiveView is well-suited to this — each tab is a `live_component`, status icons are derived from `Wizard.report/0` and rerender on each save via `Phoenix.PubSub` broadcast.

### 5.2 Categories

| Tab | Backed by |
|-----|-----------|
| Provider & Model | `Wizard.prompts/2` keys: `:provider`, `:openai_api_key`, `:default_model`, `:reasoning_effort`. Model dropdown populated from `ModelCatalog.models_for/1`. "Import from Codex" calls `CodexImport.import_tokens/1`. |
| Realtime | `:realtime_enabled`, `:realtime_api_key`, `:realtime_voice`, `:realtime_max_session_minutes`, `:realtime_max_cost_cents`, `:realtime_persist_transcripts`. Form hides follow-ups when `enabled? == false`. |
| Channels | Sub-tabs for Telegram/WhatsApp/Discord/Slack/Signal. Each maps to the wizard's channel keys plus owner ID. |
| Tools | `Capabilities.Registry.list(kind: :builtin)` rendered as a table of checkboxes. Toggling sets `hidden_from_agent?` via `Wizard.set_capability_hidden/3` (§7.1). Sub-section "MCP servers" reads `Application.get_env(:fermix_core, :mcp_servers, [])` and shows server status read-only. |
| Skills | `SkillRegistry.list/0` rendered as checkboxes; same hidden-from-agent mechanism. |
| Search | Single-select over `duckduckgo`/`bing`/`google`/`none`. `bing`/`google` are visibly disabled with a "ships in M7+ pluggable backends" caption. Persists to `[fermix_core.search] backend = "..."` via `Wizard.set_search_backend/1`. |
| Sandbox | Select for mode, select for command profile, multi-select for env passthrough. Calls `Wizard.set_sandbox_overrides/3`. |
| Memory | Two numeric inputs for compaction threshold and extraction timeout. |
| Personalization | Three text inputs: name, timezone, communication style. |
| Doctor | Read-only panel with output from `Doctor.probe_active/1`. A "Run probe again" button reruns. |

### 5.3 Save model

Each tab has its own `phx-submit`. Submitting a tab calls `Wizard.save_answers/2` (or one of the §7.1 helpers) with only that tab's keys. After save the LV:

1. Re-reads `Wizard.report/0`.
2. Updates the status icon in the left rail.
3. If `restart_required?` flips to true, shows a banner above the form.
4. If `report.status == :ready` and the user clicks "Done", broadcasts `{:setup_done, :ready}` on the `"setup"` PubSub topic. The CLI receive loop picks this up and tears down.

There is no "Save all" button. Each save is small, atomic at the TOML write level, and revertible by re-editing the tab.

---

## 6. Headless path (unchanged)

When `display_available?/0` is false and no `--web` flag is provided, `Setup.run/1` calls `Runtime.run/2` exactly as today. Operators see the existing line prompter:

```
$ fermix setup
Provider (openai/openai_codex/anthropic; blank = openai):
OpenAI API key:
...
```

No code is removed from `Runtime`. Improvements (numbered menus, category subcommands, group headers) are explicitly deferred to a separate milestone — we can decide later whether they're worth doing or whether SSH port-forward to the web flow is enough for everyone.

The escape hatch in the web flow ("Press T to switch to terminal prompts") drops a desktop operator into the same `Runtime.run/2` if they prefer typing.

---

## 7. Wizard integration points

### 7.1 New `Wizard` helpers (small additions)

Three new functions on `FermixCore.Setup.Wizard`, each delegating to `ConfigStore` mutations and returning a refreshed `report/0`:

```elixir
@spec set_capability_hidden(Capability.kind(), name :: String.t(), boolean()) ::
        {:ok, report()} | {:error, term()}

@spec set_search_backend(atom() | String.t()) :: {:ok, report()} | {:error, term()}

@spec set_sandbox_overrides(mode :: atom() | nil, profile :: atom() | nil, allow :: [String.t()] | nil) ::
        {:ok, report()} | {:error, term()}
```

These exist so category forms can persist without each one re-implementing the `ConfigStore.save_snapshot/1 → apply_snapshot/1 → refresh_boot_report` chain.

### 7.2 Save semantics

A tab save → `Wizard.save_answers/2` (or §7.1 helper). All three side effects of the existing save path still fire:

1. `ConfigStore.save_snapshot/1` writes TOML atomically.
2. `ConfigStore.apply_snapshot/1` updates Application env in the running daemon.
3. `BootReport.refresh_if_started/1` re-computes readiness.

If `restart_required?` becomes `true`, the LV renders a banner above the form: "Restart required — provider change takes effect after `fermix restart`." The banner is informational; it does not block further edits.

---

## 8. Security

| Concern | Mitigation |
|---------|------------|
| Same-host neighbor reaching the setup form | Bind to `127.0.0.1` only. Token in URL gated by a 0600 file. Plug rejects mismatched tokens with 403. |
| Cross-machine MITM over SSH port-forward | The forwarded connection is inside the SSH tunnel; `127.0.0.1` on both ends. No additional TLS. |
| Token leaked via shell history | Token never appears in argv — only in the URL printed to terminal, and only in the file. CLI prints the URL once; operator copies via mouse, not argv. |
| Stale token if CLI crashes | Token file timestamp checked on LV mount; if older than 30 minutes the LV refuses with "token expired — re-run `fermix setup`". |
| Operator scripts `fermix setup` and gets stuck waiting for browser | The 30-minute timeout kills the wait. The `--terminal` flag and `display_available?/0` checks already route CI/headless to the prompter. |
| Webhook routes exposed during setup | EphemeralEndpoint mounts only `/setup` + LiveSocket. Webhook routes are not in its router. |

The daemon's main endpoint already serves `/setup`; M10 adds the token gate to that route as well. Today a same-host neighbor could already read the read-only setup page; the token gate fixes that pre-existing leak as a side effect.

---

## 9. Testing strategy

### 9.1 Web flow

- `FermixWebWeb.SetupLiveTest` — already exists for the read-only LV. Extended to drive the new form components via `Phoenix.LiveViewTest.render_submit/2` and assert that `Wizard.save_answers/2` is called with the expected answers. Stub the Wizard module to capture args.
- `Fermix.CLI.Setup.WebTest` — drive `Web.run/0` with a fake browser opener and a fake `IO.read/2`. Assert that on `{:setup_done, :ready}` the orchestrator exits 0 and on a stdin `"t"` byte it dispatches to `Runtime.run/2`. Time-travel the timeout with a configurable clock.
- `EphemeralEndpointTest` — start the endpoint, assert it binds on a localhost port, returns 403 on `/setup` without a token, returns 200 with one.

### 9.2 Headless flow

Existing `FermixCore.Setup.RuntimeTest` coverage is preserved untouched. One new test asserts that `Setup.run/1` dispatches to `Runtime.run/2` when `display_available?/0` returns false (mocked).

### 9.3 Browser opener

- `BrowserTest` injects a fake `System.cmd/3` and asserts `open` on macOS, `xdg-open` on Linux, and a printed "no opener available" error fallback on other platforms.

### 9.4 What is not unit-tested

- Real browser launch — covered manually in the M10 acceptance checklist (open Safari/Chrome on macOS, Firefox on Linux desktop, no-browser SSH port-forward smoke).

---

## 10. Implementation order

| Stage | Lands | Gate to next stage |
|-------|-------|--------------------|
| **Stage 0** | `Wizard.set_capability_hidden/3`, `set_search_backend/1`, `set_sandbox_overrides/3` plus their tests | Mutations round-trip through `ConfigStore` and reflect in `Wizard.report/0`. |
| **Stage 1** | `EphemeralEndpoint`, token plug, `Fermix.CLI.Setup.Web` orchestrator wired to dispatch (current read-only `SetupLive` still mounted) | `fermix setup` on macOS opens browser, shows current read-only page, "T" key dispatches to existing `Runtime.run/2`. Headless unchanged. |
| **Stage 2** | `SetupLive` rewritten to category-tabbed layout with `Categories.Personalization` and `Categories.Provider` forms functional | A fresh install can reach `status: :ready` via the LV alone. Existing read-only consumers see the new layout (no further LV migration needed). |
| **Stage 3** | `Categories.Realtime`, `Categories.Channels` (Telegram + four sub-tabs) | Full M3 channel coverage available in the LV. |
| **Stage 4** | `Categories.Tools`, `Categories.Skills`, `Categories.Search` | Toggling a built-in tool to hidden via the LV survives a daemon restart. |
| **Stage 5** | `Categories.Sandbox`, `Categories.Memory`, `Categories.Doctor` | Full M5 sandbox surface available in the LV. |
| **Stage 6** | Browser opener fallbacks (`no opener` path prints the URL clearly), SSH port-forward hint copy polish, manual smoke checklist | Manual smoke across Safari/Chrome on macOS, Firefox on Ubuntu desktop, headless Ubuntu over SSH port-forward. |

Each stage ships independently. Landing Stage 1 alone gives operators a browser-opened read-only dashboard plus the "T" escape to the line prompter — already a UX improvement.

---

## 11. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| EphemeralEndpoint port conflict with the daemon's `FermixWeb.Endpoint` | The orchestrator detects whether the daemon is up by probing `127.0.0.1:<configured_port>/health`. If up, reuse; if not, bind to `127.0.0.1:0` and let the kernel pick. No race on a fixed port. |
| Browser opener fails silently | `Browser.open/1` returns `{:ok, _}` only when `System.cmd/3` exits 0. On failure the orchestrator prints "Could not auto-open browser; open the URL above manually" and continues waiting. The operator can copy/paste. |
| Operator on macOS without a browser (rare — Recovery Mode, Server install) | Same fallback as above; URL is always printed before attempting to open. |
| Daemon already running with a different operator's session | The token gate is per-setup-token. If the daemon-owned `/setup` route is already mounted, M10's token plug guards it from the daemon side too. A second `fermix setup` rotates the token and invalidates the first session's URL. |
| Operator opens the URL on a phone via screen-share / handoff | The token is bound to the host, not the device — works fine. The form is responsive (LiveView + Tailwind). |
| Bug in a category form breaks the whole LV | Each category is a separate `live_component` with its own error boundary. A crash in one tab renders the tab as "Form failed to load — check `~/.fermix/logs/fermix.log`" without taking the parent LV down. |
| 30-minute timeout fires while operator is mid-edit | The LV pings the CLI every 5 minutes with `{:setup_alive}`; the receive loop resets its timer on each ping. Genuine 30 minutes of inactivity ends the wait. |
| Same-host attacker reads `~/.fermix/setup-token` | File mode 0600 (owner-only). Same posture as `~/.fermix/auth.json`, which already stores OAuth tokens. |

---

## 12. Open questions

1. **Should `--web` work without a display?** Yes — it's the SSH-port-forward escape hatch. The orchestrator prints the port-forward command and waits without trying to call `open`. Decide whether to gate this with `--web=remote` or just `--web` always. Lean toward plain `--web`.
2. **Daemon reuse vs always ephemeral.** Reusing the daemon's endpoint avoids a second OS process but means setup happens inside the same BEAM as live agent work — a buggy save could disturb running channels. Ephemeral-always is safer but means an extra process. Lean toward "reuse when daemon is up, ephemeral when down" and revisit if save bugs surface.
3. **Should "Done" auto-run `fermix restart`?** Only when `restart_required?` is true. A confirm dialog asks before restarting. Defer to Stage 6.
4. **Headless prompter improvements scope.** Numbered menus + category subcommands are cheap (~300 LOC, no raw mode) and would benefit `--terminal` users. Track in a separate doc once M10 lands. Not in this milestone.

---

## 13. What this milestone does not promise

- It does not change the persisted TOML shape — every key written today is written the same way.
- It does not replace `fermix doctor`; the Doctor tab embeds a probe result.
- It does not add a new mix dependency. Phoenix and LiveView are already in `fermix_web`.
- It does not improve the line prompter. Headless operators see the same flow as today.
- It does not change what counts as "ready." `Readiness.report/0` and `Wizard.report/0` are authoritative; the dashboard renders what they report.
- It does not introduce browser-side persistence. Every save goes through the BEAM → `ConfigStore` path; closing the tab loses no committed state.

---

## 14. Summary

M10 routes `fermix setup` to the existing LiveView on hosts with a display, opens the browser, and keeps the current line prompter for headless hosts. The LV gains real form widgets for the ten configuration categories — provider, realtime, channels, tools, skills, search, sandbox, memory, personalization, doctor — backed by the unchanged `Setup.Wizard` data layer. An ephemeral 127.0.0.1 endpoint with a one-time file token handles the daemon-down case; the running daemon's existing endpoint handles the daemon-up case. ~1500 LOC across ~13 files, no new mix dependency, six independent stages, headless behaviour unchanged.
