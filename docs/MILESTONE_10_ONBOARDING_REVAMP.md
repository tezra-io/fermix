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
- discovers non-required surfaces (sandbox profile, MCP servers, skill catalog, search status, built-in tool toggles) by reading docs — none of them appear in `fermix setup`

The wizard's data layer is solid: `FermixCore.Setup.Wizard` already returns a structured prompt list, evaluates readiness, persists via `ConfigStore`, and is shared by the CLI and the LiveView. `FermixWebWeb.SetupLive` already mounts the same report at `/setup`, but it is read-only — it renders state and tells the operator to run the CLI. The gap is purely at the **rendering** layer.

**Goal of M10:** make the existing LiveView the primary interactive surface for setup. On a host with a display, `fermix setup` opens the existing daemon endpoint when the daemon is running; otherwise it launches an ephemeral local Phoenix endpoint and opens the browser. On a host without a display, `fermix setup` keeps the current line prompter unchanged. Headless improvements are deferred. The core prompt/save path (`Setup.Wizard.save_answers/2`, `ConfigStore`, `SecretWriter`) stays authoritative.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| Display detection | P0 | New | `Fermix.CLI.Setup` chooses Web vs Runtime based on flag precedence (§4.1) and `:os.type/0` + `DISPLAY`/`WAYLAND_DISPLAY`. macOS defaults to web; Linux defaults to web only when a display is set. |
| Ephemeral setup endpoint | P0 | New | When no daemon is running, `Fermix.CLI.Setup.Web` starts a minimal `FermixWebWeb.Endpoint` bound to `127.0.0.1:<random>` carrying only the `/setup` LV, opens the browser, blocks until the LV signals done, then tears down. |
| Reuse running daemon | P0 | New | When the daemon is already up (its `FermixWebWeb.Endpoint` is listening), the CLI prints/opens `http://127.0.0.1:<daemon_port>/setup?t=<token>` instead of spinning up a second endpoint. |
| One-time token gate | P0 | New | The setup URL carries a random `t=` token written to `~/.fermix/setup-token` (mode 0600). The LV refuses to mount without a matching token. Protects against same-host neighbors. |
| Full-form `SetupLive` | P0 | Rewrite | Extend the current read-only LV into a category-tabbed form: Provider & Model, Realtime, Channels, Tools, Skills, Search, Sandbox, Memory, Personalization, Doctor. Config-writing categories post back through `Wizard.save_answers/2` or a helper with the same save/apply/report cycle. |
| Browser opener | P0 | Extract/reuse | Reuse the cross-platform opener already implemented in `FermixCore.Auth.OAuthFlow` by extracting it to a shared public helper used by both OAuth and setup. It must keep macOS `open`, Linux `xdg-open`, and Windows `cmd /c start` support. |
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
| Provider OAuth flow inside the LV | `CodexLogin.login/1` is a blocking CLI loopback flow on port 1455. Triggering it from a LV event needs async task state, cancellation, and completion propagation. M10 may import existing Codex CLI tokens, but fresh ChatGPT OAuth stays in `fermix auth login` / terminal setup. | Later |
| Search backend selection | No running `fermix_core.search` config module or wizard prompt exists today. M10 shows search status only; backend selection belongs to M7+ pluggable backends. | M7+ |
| Multi-user setup (auth on the LV) | The endpoint is bound to `127.0.0.1` + protected by a 0600 file token; that is enough for a single-operator install | — |
| i18n | Setup is English-only today | Later |
| Web endpoint on production daemon by default | The daemon already runs `FermixWebWeb.Endpoint`. M10 just makes the `/setup` route stop being read-only. No new exposure. | — |

---

## 3. Design Context — what already exists

### `FermixCore.Setup.Wizard` (data layer, keep as-is)

- `report/0` → `%{status, failures, wizard, config_path, restart_required?, seeding_results}`
- `prompts/2` and `reconfigure_prompts/2` → ordered list of `%{key, label, default, required?}` prompt maps
- `save_answers/2` → persists via `ConfigStore`, re-applies snapshot, triggers `BootReport.refresh_if_started/1`, runs prompt-file seeding

M10 adds two small helpers (§7.1) for non-prompt mutations (capability hide and sandbox overrides). They do not change `save_answers/2`; they share its save/apply/report semantics.

### `Fermix.CLI.Setup` and `FermixCore.Setup.Runtime` (orchestrator)

- `Setup.run/1` already parses answer flags plus `--no-browser`, `--port`, `--skip-probe`, and `--timeout`, then calls `Runtime.run/2` with `puts:`/`prompt:` IO injection
- `Runtime.run/2` decides: print state / seed-only / ask-and-save
- `Runtime.collect_answers/3` walks the prompt list, calling the injected `prompt:` function for each required prompt

M10 leaves `Runtime` exactly as it is. The new web path plugs in **before** `Runtime.run/2` is reached and either fully resolves answers via the LV or falls through.

### `FermixWebWeb.SetupLive` (already at `/setup`, read-only)

143 lines today. Mounts `BootReport.current/0` once, renders a status panel and a "run `mix fermix.setup`" hint. M10 rewrites this into a category-tabbed form (§5) that posts back through `Wizard.save_answers/2`.

### `FermixWebWeb.Endpoint`

Already supervised by the daemon. When `fermix run` or `fermix start` is active, the endpoint is listening (typically on `127.0.0.1:4001` in dev, a configured port in prod). When the daemon is not running, no endpoint is up.

### Existing channel and browser facts

- The wizard already prompts for Telegram, WhatsApp, Discord, Slack, and Signal. The `CLAUDE.md` tree note saying Telegram is the only implemented channel is stale and is not a design constraint for M10.
- `FermixCore.Auth.OAuthFlow` already contains a cross-platform browser opener for macOS, Linux, and Windows. M10 extracts or exposes that helper instead of adding a second setup-only opener.

---

## 4. High-Level Design

### 4.1 Dispatch decision

```
fermix setup [flags]
│
├─ answer-bearing flags are present (provided_answers != [])
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
def display_available? do
  case :os.type() do
    {:unix, :darwin} -> true
    {:unix, :linux} ->
      System.get_env("DISPLAY") != nil or System.get_env("WAYLAND_DISPLAY") != nil
    _ -> false
  end
end
```

macOS always reports `true` (WindowServer is always running). Linux reports `true` only when an X or Wayland display is exported — which covers desktop installs and rules out SSH'd-in servers. The operator can override either direction with `--web` / `--terminal`.

Keep display detection testable: either put `display_available?/0` on a small `@moduledoc false` helper module or inject it into the dispatcher. Do not leave it as a private function that tests have to mock.

Precedence is explicit:

1. Answer-bearing flags (`--provider`, `--openai-api-key`, `--default-model`, channel keys, realtime keys, etc.) use `Runtime.run/2` so the existing non-interactive and partial-answer behavior is preserved.
2. Maintenance flags (`--print-state`, `--migrate-secrets`, `--import-codex`) use `Runtime.run/2`.
3. `--terminal` wins over `--web`.
4. `--web` wins over display detection.
5. Display detection decides only when none of the above are present.

Existing option meanings stay narrow. In web mode, `--no-browser` suppresses the opener and only prints the URL. In web mode, `--port` requests the setup endpoint port; if the daemon is already up on that same port, setup reuses it. If the daemon is already up on a different port, setup fails loud instead of silently switching ports. If no daemon is up and the requested port cannot bind, setup fails loud instead of falling back to another port. Without `--port`, ephemeral setup binds `127.0.0.1:0`. `--skip-probe` disables automatic provider probes after saves, but the Doctor tab can still run a manual probe. `--timeout` remains the existing Codex OAuth timeout for Runtime/terminal setup; it is not a web-session timeout.

### 4.2 Module layout

```
apps/fermix_core/lib/fermix/
├── cli/setup.ex                       # existing dispatcher (small edits)
└── cli/setup/web.ex                   # NEW — Web orchestrator + URL printer (≤180 LOC)

apps/fermix_core/lib/fermix_core/auth/
└── browser.ex                         # EXTRACTED — shared OS browser opener used by OAuth + setup

apps/fermix_web/lib/fermix_web_web/
├── live/setup_live.ex                 # REWRITTEN — category-tabbed form (≤500 LOC)
├── live/setup_live/                   # NEW — per-category form components
│   ├── provider_form.ex
│   ├── realtime_form.ex
│   ├── channels_form.ex
│   ├── tools_form.ex
│   ├── skills_form.ex
│   ├── search_panel.ex
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
                ├──→ FermixCore.Auth.Browser.open/1
                │
                └──→ wait_for_completion/1
                        │
                        └──→ PubSub topic "fermix:setup:<token>"
                                │
                                └──→ pushed by SetupLive on connect/disconnect/done

FermixWebWeb.SetupLive
        │
        └──→ FermixCore.Setup.Wizard  (data layer — unchanged save path)
```

### 4.4 Lifecycle of `fermix setup` on a desktop host

```
1. `Setup.run/1` selects web mode by §4.1 precedence.
2. `Setup.Web.run/1`:
   a. Write 32-byte random token to ~/.fermix/setup-token (mode 0600).
   b. If FermixWebWeb.Endpoint is listening (daemon up):
        port = configured port
        reuse_existing = true
      Else:
        start EphemeralEndpoint on 127.0.0.1:<requested-or-random>
        port = the bound port
        reuse_existing = false
   c. Print:
        Setup running at http://127.0.0.1:<port>/setup?t=<token>
        From your laptop:  ssh -L <port>:127.0.0.1:<port> user@thishost
        Type t then Enter to switch to terminal prompts. Ctrl-C to abort.
   d. Unless --no-browser or no display is available, call FermixCore.Auth.Browser.open/1.
   e. Subscribe Phoenix.PubSub topic "fermix:setup:<token>".
   f. Block on a receive loop:
        receive
          {:setup_connected, ^token}    -> cancel disconnect grace timer
          {:setup_disconnected, ^token} -> start 30s timer that sends {:setup_abandoned, token}
          {:setup_abandoned, ^token}    -> teardown(); exit 1
          {:setup_done, ^token, :ready} -> :ok
          {:stdin_line, "t\n"}          -> teardown(); call Setup.Runtime.run/2
        end
   g. teardown:
        if not reuse_existing -> stop EphemeralEndpoint
        delete ~/.fermix/setup-token
3. Exit 0 on :setup_done.
```

The terminal escape hatch is line-mode only: the operator types `t` and presses Enter. There is no raw mode, no single-byte keyboard capture, and no attempt to model Ctrl-C as an IO message. Ctrl-C is handled by normal process interruption; teardown must run through the same cleanup path.

### 4.5 EphemeralEndpoint

A trimmed Phoenix endpoint that:

- binds `127.0.0.1:0` (kernel picks an unused port)
- mounts only `/setup` and the LiveSocket WebSocket
- declares `otp_app: :fermix_web`
- uses the same `secret_key_base` and session signing settings as `FermixWebWeb.Endpoint`; extract the session options into a shared module/function rather than copying the hardcoded signing salt
- uses the existing `Phoenix.PubSub` name, `FermixWeb.PubSub`; the ephemeral supervisor starts that PubSub only when it is not already running
- starts under a one-shot `Supervisor` returned to the CLI for clean shutdown
- does **not** mount channels, health, webhooks, or the home page

Total surface: ~120 LOC of an endpoint module + a tiny router. It reuses the same `FermixWebWeb.SetupLive`, `FermixWebWeb.Layouts`, `secret_key_base`, and session options from the existing fermix_web app, so the visual shell and LiveView session behavior are identical between "daemon up" and "daemon down" modes. The ephemeral endpoint must not mint its own signing salt.

### 4.6 Token gate

A small plug pipeline on `/setup`:

1. Reads `?t=<token>` from the query string.
2. Reads `~/.fermix/setup-token`.
3. Compares with `Plug.Crypto.secure_compare/2`.
4. On match: set `session[:setup_authorized] = true` and `session[:setup_token] = token`, then let the LV mount.
5. On mismatch: `send_resp(403, "setup token invalid")`.

The LV also re-checks the session flag in `mount/3` and refuses sockets without `session["setup_authorized"] == true`, including direct LiveSocket connection attempts to `/live`. The LV subscribes only to `"fermix:setup:<token>"` from session. The token file is unlinked when the CLI tears down. Loss of the file (e.g. operator deletes it mid-flow) forces a CLI restart — same behaviour as today's `~/.fermix/config.toml` mid-write.

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

Left rail: ten category tabs with status icons (`✓` ready / `!` partial / `·` untouched / `–` disabled). Right pane: the form or status panel for the active tab.

LiveView is well-suited to this — each tab is a small component, status icons are derived from `Wizard.report/0` and rerender on each save via a token-scoped `Phoenix.PubSub` broadcast. Components should be stateless function components unless they genuinely need local state; Phoenix LiveView does not provide per-component error boundaries, so the design does not promise category-level crash isolation.

### 5.2 Categories

| Tab | Backed by |
|-----|-----------|
| Provider & Model | `Wizard.prompts/2` keys: `:provider`, `:openai_api_key`, `:default_model`, `:reasoning_effort`. Model dropdown populated from `ModelCatalog.models_for/1`. "Import from Codex" calls `CodexImport.import_tokens/1`. |
| Realtime | `:realtime_enabled`, `:realtime_api_key`, `:realtime_voice`, `:realtime_max_session_minutes`, `:realtime_max_cost_cents`, `:realtime_persist_transcripts`. Form hides follow-ups when `enabled? == false`. |
| Channels | Sub-tabs for Telegram/WhatsApp/Discord/Slack/Signal. Each maps to the wizard's channel keys plus owner ID. |
| Tools | `Capabilities.Registry.list(kind: :builtin)` rendered as a table of checkboxes. Toggling sets `hidden_from_agent?` via `Wizard.set_capability_hidden/3` (§7.1). Sub-section "MCP servers" reads `Application.get_env(:fermix_core, :mcp_servers, [])` and shows server status read-only. |
| Skills | `SkillRegistry.list/0` rendered as checkboxes; same hidden-from-agent mechanism. |
| Search | Read-only status panel for the current keyless `web_search` capability and its configured/available state. Backend selection and keyed provider setup are explicitly deferred to M7+ pluggable backends; no `[fermix_core.search]` or wizard write path is added in M10. |
| Sandbox | Select for sandbox mode, select for command profile, list only the current `sandbox.env.allow` names, and provide an "add env var name" input. Do not expose the full host environment in the browser. Calls `Wizard.set_sandbox_overrides/3`. |
| Memory | Two numeric inputs for compaction threshold and extraction timeout. |
| Personalization | Three text inputs: name, timezone, communication style. Timezone stays free-text in M10; IANA timezone validation is deferred polish. |
| Doctor | Read-only panel with output from `Doctor.probe_active/1`. A "Run probe again" button reruns. Provider tab saves auto-run the probe unless `--skip-probe` was passed. |

### 5.3 Save model

Each tab has its own `phx-submit`. Submitting a tab calls `Wizard.save_answers/2` (or one of the §7.1 helpers) with only that tab's keys. After save the LV:

1. Re-reads `Wizard.report/0`.
2. Updates the status icon in the left rail.
3. If `restart_required?` flips to true, shows a banner above the form.
4. If `report.status == :ready`, enable the "Done" button. The button is disabled for every non-ready status.
5. On authorized mount, broadcasts `{:setup_connected, token}` on `"fermix:setup:<token>"`.
6. If the user clicks "Done", broadcasts `{:setup_done, token, :ready}` on `"fermix:setup:<token>"`. The CLI receive loop picks this up and tears down.
7. If a connected LV terminates before "Done", broadcasts `{:setup_disconnected, token}` only. The CLI starts a 30-second grace timer, cancels it on a later `{:setup_connected, token}`, and exits non-zero as abandoned only if the grace timer expires. If the browser never connects, the CLI keeps waiting until the operator presses Ctrl-C or types `t` + Enter.

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

The escape hatch in the web flow ("type `t` then Enter to switch to terminal prompts") drops a desktop operator into the same `Runtime.run/2` if they prefer typing.

---

## 7. Wizard integration points

### 7.1 New `Wizard` helpers (small additions)

Two new functions on `FermixCore.Setup.Wizard`, each delegating to `ConfigStore` mutations and returning a refreshed `report/0`:

```elixir
@spec set_capability_hidden(Capability.kind(), name :: String.t(), boolean()) ::
        {:ok, report()} | {:error, term()}

@spec set_sandbox_overrides(mode :: atom() | nil, profile :: atom() | nil, allow :: [String.t()] | nil) ::
        {:ok, report()} | {:error, term()}
```

These exist so category forms can persist without each one re-implementing the `ConfigStore.save_snapshot/1 → apply_snapshot/1 → refresh_boot_report` chain. They must route through the same private save/apply/report helper as `save_answers/2`, including any telemetry or audit event that exists by implementation time.

### 7.2 Save semantics

A tab save → `Wizard.save_answers/2` (or §7.1 helper). All three side effects of the existing save path still fire:

1. `ConfigStore.save_snapshot/1` writes TOML atomically.
2. `ConfigStore.apply_snapshot/1` updates Application env in the process handling setup.
3. `BootReport.refresh_if_started/1` re-computes readiness.

When setup runs inside the daemon endpoint, `apply_snapshot/1` updates the running daemon's Application env. When setup runs inside the ephemeral CLI-owned endpoint, `apply_snapshot/1` updates only that temporary process; durability comes from `save_snapshot/1`, and the next daemon start reloads the persisted TOML.

If `restart_required?` becomes `true`, the LV renders a banner above the form: "Restart required — provider change takes effect after `fermix restart`." The banner is informational; it does not block further edits.

---

## 8. Security

| Concern | Mitigation |
|---------|------------|
| Same-host neighbor reaching the setup form | Bind to `127.0.0.1` only. Token in URL gated by a 0600 file. Plug rejects mismatched tokens with 403. |
| Cross-machine MITM over SSH port-forward | The forwarded connection is inside the SSH tunnel; `127.0.0.1` on both ends. No additional TLS. |
| Token leaked via shell history | Token never appears in argv — only in the URL printed to terminal, and only in the file. CLI prints the URL once; operator copies via mouse, not argv. |
| Stale token if CLI crashes | Token file mtime checked on LV mount; if older than 30 minutes the LV refuses with "token expired — re-run `fermix setup`". Wall-clock jumps can shorten or extend this window, which is acceptable for a local setup token. |
| Operator scripts `fermix setup` and gets stuck waiting for browser | `--terminal` and answer-bearing flags route scripts to `Runtime.run/2`. In web mode, the URL is always printed, `--no-browser` suppresses auto-open, disconnects start a 30-second reconnect grace timer, and Ctrl-C remains the operator-owned abort. |
| Webhook routes exposed during setup | EphemeralEndpoint mounts only `/setup` + LiveSocket. Webhook routes are not in its router. |
| Direct LiveSocket connection bypassing the token plug | The plug sets `session[:setup_authorized]`; `SetupLive.mount/3` refuses any socket without that flag and token. |

The daemon's main endpoint already serves `/setup`; M10 adds the token gate to that route as well. Today a same-host neighbor could already read the read-only setup page; the token gate fixes that pre-existing leak as a side effect.

---

## 9. Testing strategy

### 9.1 Web flow

- `FermixWebWeb.SetupLiveTest` — already exists for the read-only LV. Extend it to drive the new form components via `Phoenix.LiveViewTest.render_submit/2` against a real `Wizard` over a tmp `ConfigStore` path. Avoid module stubs unless a proper behaviour/Mox boundary already exists.
- `Fermix.CLI.Setup.WebTest` — drive `Web.run/1` with a fake browser opener, fake line reader, and controllable timer. Assert that on `{:setup_done, token, :ready}` the orchestrator exits 0, on `{:setup_disconnected, token}` it starts a 30-second grace timer, on `{:setup_connected, token}` it cancels that timer, on grace expiry it exits non-zero, and on stdin line `"t\n"` it dispatches to `Runtime.run/2`.
- `EphemeralEndpointTest` — start the endpoint, assert it binds on a localhost port or fails loud on an unavailable explicit `--port`, returns 403 on `/setup` without a token, returns 200 with one, rejects a LiveSocket mount without `session[:setup_authorized]`, and uses the same session signing settings as `FermixWebWeb.Endpoint`.

### 9.2 Headless flow

Existing `FermixCore.Setup.RuntimeTest` coverage is preserved untouched. One new test asserts that `Setup.run/1` dispatches to `Runtime.run/2` when display detection returns false. Do not mock a private function: either expose `display_available?/0` as an internal public function on a `@moduledoc false` helper, or inject the display detector into the dispatcher the way `Runtime.run/2` injects IO.

### 9.3 Browser opener

- `BrowserTest` covers the extracted shared opener with injected command execution: `open` on macOS, `xdg-open` on Linux, `cmd /c start` on Windows, and `{:error, :no_opener}` when no executable exists. Setup.Web tests assert `--no-browser` skips the opener entirely.

### 9.4 What is not unit-tested

- Real browser launch — covered manually in the M10 acceptance checklist (open Safari/Chrome on macOS, Firefox on Linux desktop, no-browser SSH port-forward smoke).

---

## 10. Implementation order

| Stage | Lands | Gate to next stage |
|-------|-------|--------------------|
| **Stage 0** | Extract the private Wizard save/apply/report helper from `save_answers/2`, add `Wizard.set_capability_hidden/3` and `set_sandbox_overrides/3`, and add tests | `save_answers/2` keeps existing behavior, helper mutations round-trip through `ConfigStore`, reflect in `Wizard.report/0`, and use the same side-effect cycle as `save_answers/2`. |
| **Stage 1** | Shared browser opener extraction, `EphemeralEndpoint`, token plug, and `Fermix.CLI.Setup.Web` orchestrator behind explicit `--web` only while `SetupLive` is still read-only | `fermix setup --web --no-browser` prints a tokenized URL and SSH hint, serves the read-only page, rejects unauthorized HTTP and LiveSocket access, and `t` + Enter dispatches to existing `Runtime.run/2`. Default `fermix setup` remains unchanged. |
| **Stage 2** | `SetupLive` rewritten to category-tabbed layout with `Categories.Personalization` and `Categories.Provider` forms functional | A fresh install can reach `status: :ready` via the LV alone. Existing read-only consumers see the new layout (no further LV migration needed). |
| **Stage 3** | `Categories.Realtime`, `Categories.Channels` (Telegram + four sub-tabs), and a one-line `CLAUDE.md` tree update for implemented channels | Full M3 channel coverage available in the LV and repo guidance no longer says Telegram is the only implemented channel. |
| **Stage 4** | `Categories.Tools`, `Categories.Skills`, read-only `Categories.Search` | Toggling a built-in tool to hidden via the LV survives a daemon restart. Search renders current status only and does not write backend config. |
| **Stage 5** | `Categories.Sandbox`, `Categories.Memory`, `Categories.Doctor` | Full M5 sandbox surface available in the LV. |
| **Stage 6** | Flip default dispatch from display hosts to web mode, SSH port-forward hint copy polish, manual smoke checklist | Manual smoke across Safari/Chrome on macOS, Firefox on Ubuntu desktop, headless Ubuntu over SSH port-forward. |

Stages 1 and 2 may land in separate commits, but Stage 1 is gated behind `--web` until Stage 2 makes the LV functional. Operators should not get a browser-opened read-only setup page from default `fermix setup`.

---

## 11. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| EphemeralEndpoint port conflict with the daemon's `FermixWebWeb.Endpoint` | Decision: reuse the daemon endpoint when it is already listening, otherwise start ephemeral. These are two valid configurations, not fallback chains. With no `--port`, ephemeral binds to `127.0.0.1:0`; with explicit `--port`, a match with the running daemon reuses it, while a mismatch with the running daemon or bind failure exits non-zero. |
| Browser opener fails silently | `FermixCore.Auth.Browser.open/1` returns success only when the OS command exits 0. On failure the orchestrator prints "Could not auto-open browser; open the URL above manually" and continues waiting. The operator can copy/paste. |
| Operator on macOS without a browser (rare — Recovery Mode, Server install) | Same fallback as above; URL is always printed before attempting to open. |
| Daemon already running with a different operator's session | The token gate is per-setup-token. If the daemon-owned `/setup` route is already mounted, M10's token plug guards it from the daemon side too. A second `fermix setup` rotates the token and invalidates the first session's URL. |
| Operator opens the URL on a phone via screen-share / handoff | The token is bound to the host, not the device — works fine. The form is responsive (LiveView + Tailwind). |
| Bug in a category form breaks the whole LV | Phoenix stateful components run in the parent LV process. Keep components small, pure, and well-tested; if the LV crashes, the browser can reload and the CLI keeps waiting until Done, abandon, `t` + Enter, or Ctrl-C. |
| Browser tab closes without Done | `SetupLive.terminate/2` is not a clean "tab closed" signal. It broadcasts only `{:setup_disconnected, token}`. The CLI starts a 30-second grace timer, cancels it on reconnect, and exits non-zero as abandoned only if no reconnect arrives. If the browser never connects, the CLI waits for explicit operator action. |
| Codex OAuth and setup endpoint both need loopback listeners | M10 does not start Codex OAuth from the LV. Existing terminal OAuth still defaults to port 1455; setup uses the daemon port or ephemeral/requested setup port, so the listeners are distinct. |
| Same-host attacker reads `~/.fermix/setup-token` | File mode 0600 (owner-only). Same posture as `~/.fermix/auth.json`, which already stores OAuth tokens. |

---

## 12. Open questions

1. **Should "Done" auto-run `fermix restart`?** Only when `restart_required?` is true. A confirm dialog asks before restarting. Defer to a later milestone unless operator testing proves it is essential.
2. **Headless prompter improvements scope.** Numbered menus + category subcommands are cheap (~300 LOC, no raw mode) and would benefit `--terminal` users. Track in a separate doc once M10 lands. Not in this milestone.

---

## 13. What this milestone does not promise

- It does not change the persisted TOML shape — every key written today is written the same way.
- It does not replace `fermix doctor`; the Doctor tab embeds a probe result.
- It does not add search backend configuration or `[fermix_core.search]`. Search backend choice remains owned by M7+ pluggable backends.
- It does not start ChatGPT/Codex OAuth from LiveView. Fresh OAuth remains a terminal flow.
- It does not add a new mix dependency. Phoenix and LiveView are already in `fermix_web`.
- It does not improve the line prompter. Headless operators see the same flow as today.
- It does not change what counts as "ready." `Readiness.report/0` and `Wizard.report/0` are authoritative; the dashboard renders what they report.
- It does not introduce browser-side persistence. Every save goes through the BEAM → `ConfigStore` path; closing the tab loses no committed state.

---

## 14. Summary

M10 routes `fermix setup` to the existing LiveView on hosts with a display, opens the browser unless `--no-browser` is set, and keeps the current line prompter for headless or `--terminal` hosts. The LV gains real form widgets for provider, realtime, channels, tools, skills, sandbox, memory, personalization, and doctor, plus a read-only search status panel; backend selection stays with M7+ pluggable backends. The core prompt/save path stays authoritative. A tokenized daemon endpoint handles the daemon-up case; an ephemeral 127.0.0.1 endpoint handles daemon-down. ~1500 LOC across ~13 files, no new mix dependency, staged behind `--web` until the LV is functional, headless behaviour unchanged.
