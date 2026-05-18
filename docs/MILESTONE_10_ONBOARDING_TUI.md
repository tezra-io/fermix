# Milestone 10: Onboarding TUI — Functional Design

**Status:** Draft
**Date:** 2026-05-18
**Author:** Sujeeth / Aira
**Depends on:** M3 (shared wizard surface), M4.7 (personalization step), M4.9 (capabilities), M4.10 (Codex parity), M4.12 (inbound MCP), M5 (sandbox)
**References:** `apps/fermix_core/lib/fermix_core/setup/wizard.ex`, `apps/fermix_core/lib/fermix/cli/setup.ex`, `apps/fermix_core/lib/fermix_core/setup/runtime.ex`, `docs/MILESTONE_3_ONBOARDING_CHANNEL_COVERAGE.md`, OpenCode/openclaw setup TUI

---

## 1. Problem / Goal

`fermix setup` today is a one-shot, top-to-bottom line prompter. For each required answer it writes `Label: ` to stdout and reads a line from stdin. The operator has to:

- type a provider name from memory (`openai`/`openai_codex`/`anthropic`) with no menu
- type a model name with no list (the wizard prints `(blank = gpt-4o)` and expects the operator to either know the catalog or accept the default)
- type `yes`/`no` for realtime, then walk through four follow-up text prompts even if they only meant to flip it off
- re-run the whole linear flow with `--reconfigure` to change any single value
- discover non-required surfaces (sandbox profile, MCP servers, skill catalog, search backend, built-in tool toggles) by reading docs — none of them appear in `fermix setup`

The wizard's data layer is solid: `FermixCore.Setup.Wizard` already returns a structured prompt list, evaluates readiness, persists via `ConfigStore`, and is shared by the CLI and the LiveView. The gap is purely at the **rendering** layer: the CLI uses `IO.gets/1` with no widget surface, and a large slice of configurable Fermix (tools, skills, sandbox, MCP) is not exposed by the wizard at all.

**Goal of M10:** replace the linear stdio prompter with a lightweight category-driven terminal UI. Every configurable surface in Fermix — provider, model, voice, channels, tools, skills, search, sandbox, memory, personalization — appears as a category on a single dashboard with a live readiness indicator, navigable with arrow keys, with type-to-filter menus for catalog values and inline masking for secrets. The data layer (`Setup.Wizard`, `ConfigStore`, `SecretWriter`) stays untouched.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `Fermix.TUI` primitives | P0 | New | Tiny in-tree module — `select/2`, `multi_select/2`, `input/2`, `confirm/2`, `panel/2` — using `IO.ANSI` + raw-mode `:io.setopts/2`. No dependency. |
| Setup dashboard | P0 | New | Top-level category list with per-category status icon (`✓` ready / `!` partial / `·` untouched / `–` disabled). |
| Provider & Model category | P0 | New | Single-select menu for provider, type-to-filter menu populated from `ModelCatalog.models_for/1`, single-select for reasoning effort, masked input for API key, codex-import shortcut. |
| Realtime category | P0 | New | Toggle for `enabled?`, voice picker, session/cost limits, transcript toggle. Hides follow-ups when disabled. |
| Channels category | P0 | New | Sub-menu per channel (Telegram/WhatsApp/Discord/Slack/Signal). Enable toggle → required-fields panel only when enabled. |
| Personalization category | P0 | New | Three text inputs (name, timezone, style) backed by existing wizard keys. |
| Memory category | P1 | New | Compaction threshold (slider stub: free-text float with bounds), extraction timeout. |
| Tools category | P1 | New | Multi-select over built-in `FermixCore.Capabilities.Builtin` tool names; sub-section for outbound MCP servers (`[mcp.servers.*]`) with status (running/error). |
| Skills category | P1 | New | Multi-select over skill packs surfaced by `SkillRegistry`. |
| Search category | P1 | New | Single-select over web-search backends (today: `duckduckgo` only; placeholder rows for `bing`, `google`, `none` keyed to future backends — see M7+ pluggable backends). |
| Sandbox category | P1 | New | Single-select for mode (`strict`/`standard`/`open`), single-select for command profile (`bare`/`assistant`/`extended`), multi-select for env passthrough names. |
| Doctor passthrough | P2 | New | Read-only category that runs `FermixCore.Setup.Doctor.probe_active/1` and renders the result in a panel. |
| Non-TTY fallback | P0 | New | When `IO.ANSI.enabled?/0` is false, stdin/stdout is not a tty, or env `FERMIX_NO_TUI=1` is set, dispatch falls through to the existing line-based `Setup.Runtime.run/2` path unchanged. |
| Flag-driven non-interactive | P0 | Keep | `fermix setup --provider openai --default-model ...` keeps working byte-for-byte; flag answers skip the TUI entirely. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Full-screen TUI framework (Ratatouille / Bubbletea-style) | Overkill for a config screen; would add a heavy dependency to the Burrito binary | — |
| Mouse support | Pure keyboard is enough for setup; mouse parsing across terminals is fragile | — |
| Re-doing the LiveView at `/setup` | M3 LiveView already works; M10 is CLI-only | Later — the LV can adopt the same `Wizard` surface incrementally |
| Plugin/skill installation flows (download from a registry) | Out of scope; tools/skills category only toggles already-installed capabilities | M7+ |
| Provider OAuth flow inside the TUI | OAuth opens the browser — keep the existing modal prompt; TUI just kicks off `CodexLogin.login/1` | — |
| Multi-pane / split-screen UI | Single panel + footer hint line is enough for 80×24 terminals | — |
| i18n | Setup is English-only today | Later |
| Real-time config reload (file-watcher driven) | Saving in the TUI calls `ConfigStore.apply_snapshot/1` then re-reads `Wizard.report/0`; that is enough | — |

---

## 3. Design Context — what already exists

### `FermixCore.Setup.Wizard` (data layer, keep as-is)

- `report/0` → `%{status, failures, wizard, config_path, restart_required?, seeding_results}`
- `prompts/2` and `reconfigure_prompts/2` → ordered list of `%{key, label, default, required?}` prompt maps
- `save_answers/2` → persists via `ConfigStore`, re-applies snapshot, triggers `BootReport.refresh_if_started/1`, runs prompt-file seeding

M10 adds no field to `WizardState`, no new prompt key, no new save path. The TUI is a **renderer** on top of the existing prompt list, augmented with category metadata that the TUI derives locally.

### `Fermix.CLI.Setup` and `FermixCore.Setup.Runtime` (orchestrator)

- `Setup.run/1` parses argv and calls `Runtime.run/2` with `puts:`/`prompt:` IO injection
- `Runtime.run/2` decides: print state / seed-only / ask-and-save
- `Runtime.collect_answers/3` walks the prompt list, calling the injected `prompt:` function for each required prompt

M10 leaves `Runtime` exactly as it is for the non-interactive path (`--provider`, `--default-model`, flag-driven runs, pipes, CI). The new TUI plugs in **before** `Runtime.collect_answers/3` is reached and either fully resolves answers (then calls `Wizard.save_answers/2` directly) or falls through.

### `FermixCore.Capabilities.Registry` and related

- Built-in tools enumerated by `FermixCore.Capabilities.Builtin.Tool` implementations, registered into `Capabilities.Registry`
- MCP outbound servers configured under `[mcp.servers.<name>]` and supervised by `Capabilities.MCP.Supervisor`
- Skills registered by `FermixCore.Agents.SkillRegistry`

The TUI reads these registries at render time. It does not introduce a new capability metadata schema — it queries what is already loaded and toggles via `Capability{hidden_from_agent?: bool}` flags surfaced through the existing TOML keys.

### `FermixCore.Sandbox.ConfigMutation`

Already exposes `set_command_profile/2`, `allow_env/2`, `deny_env/2` mutations. The Sandbox category in the TUI is a thin wrapper around these.

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
├─ stdio not a tty | IO.ANSI.enabled?/0 == false | FERMIX_NO_TUI=1
│   → existing Setup.Runtime path with default line-prompt (unchanged)
│
└─ otherwise
    → Fermix.CLI.Setup.UI.run/1  (M10, new)
```

The TUI is opt-out, not opt-in. A piped run (`echo y | fermix setup`) lands on the fallback automatically because `:erlang.element/2` of `:io.getopts/0` reports no terminal.

### 4.2 Module layout

```
apps/fermix_core/lib/fermix/
├── cli/setup.ex                     # existing dispatcher (no behaviour change)
├── cli/setup/ui.ex                  # NEW — TUI orchestrator (≤200 LOC)
├── cli/setup/ui/dashboard.ex        # NEW — category list renderer (≤100 LOC)
├── cli/setup/ui/category.ex         # NEW — per-category state struct + summary helpers (≤150 LOC)
├── cli/setup/ui/categories/         # NEW — one file per category, all ≤120 LOC
│   ├── provider.ex
│   ├── realtime.ex
│   ├── channels.ex
│   ├── tools.ex
│   ├── skills.ex
│   ├── search.ex
│   ├── sandbox.ex
│   ├── memory.ex
│   ├── personalization.ex
│   └── doctor.ex
└── tui.ex                           # NEW — primitives (≤300 LOC; see §5)
```

Total new code envelope: ≤1500 LOC across ~15 files, all under `apps/fermix_core/lib/fermix/`. No new mix dependency.

### 4.3 Layering

```
Fermix.CLI.Setup
        │
        ▼
Fermix.CLI.Setup.UI            ← dispatch loop, owns dashboard ↔ category transitions
        │
        ▼
Fermix.CLI.Setup.UI.Categories.*   ← per-category state + save translation
        │              │
        ▼              ▼
   Fermix.TUI    FermixCore.Setup.Wizard
   (renderer)    (data layer, unchanged)
                       │
                       ▼
                 FermixCore.Setup.ConfigStore
                 FermixCore.Setup.SecretWriter
```

Each category module is independent: it reads what it needs from `Wizard.report/0` + the relevant Application env + (where applicable) `Capabilities.Registry.list/2`, drives one or more `Fermix.TUI` widgets, and returns either `{:save, [answer]}` or `:cancel`. The orchestrator translates `{:save, answers}` into a `Wizard.save_answers/2` call against `report.wizard`.

### 4.4 Frame model

The TUI redraws the **entire visible frame** on every keypress (clear + home + write). Frames are bounded — header (2 rows), body (≤ 18 rows), footer (1 row) — so they fit a default 24-row terminal without scrollback. A category whose body exceeds 18 rows uses an internal scrollable viewport (the dashboard never needs this; only the tools/MCP catalog might).

```
┌──────────────────────────────────────────────────────────────┐
│ Fermix setup — ~/.fermix/config.toml                         │  ← row 1
│ Status: ready · Provider: openai_codex · Model: gpt-4o       │  ← row 2
├──────────────────────────────────────────────────────────────┤
│  ▸ ✓ Provider & Model    openai_codex · gpt-4o · high effort │
│    ✓ Realtime voice      enabled · alloy · 30 min cap        │
│    · Channels            Telegram on · 4 others off          │
│    ! Tools               12 built-in · 0 MCP servers         │
│    · Skills              5 packs available · 5 enabled       │
│    · Search              duckduckgo (keyless)                │
│    ✓ Sandbox             standard · assistant profile        │
│    · Memory              compaction 0.85 · 90s extraction    │
│    ✓ Personalization     Sujeeth · America/Los_Angeles       │
│    ▸ Doctor              run health probe                    │
│                                                              │  ← bounded ≤18 rows
├──────────────────────────────────────────────────────────────┤
│  ↑↓ navigate  ⏎ open  q quit  ? help                         │  ← row N
└──────────────────────────────────────────────────────────────┘
```

Box-drawing characters are ASCII-fallback to `+`/`-`/`|` when `LC_ALL=C` or the terminal does not advertise UTF-8 (`System.get_env("LANG")` parsed for `UTF-8`).

---

## 5. `Fermix.TUI` primitives

A small Elixir module — no dependency, no behaviour, just functions. All functions accept an `io: device` option (default `:stdio`) for testability.

### 5.1 Public API

```elixir
@spec select(opts :: keyword()) :: {:ok, term()} | :cancel
# opts: title, options ([%{value: t, label: String.t(), hint: String.t()}]),
#       initial, filterable?: boolean (default true)

@spec multi_select(opts :: keyword()) :: {:ok, [term()]} | :cancel
# opts: title, options, initial (list of selected values)

@spec input(opts :: keyword()) :: {:ok, String.t()} | :cancel
# opts: title, prompt, default, mask?: boolean (default false), validator: (String.t() -> :ok | {:error, String.t()})

@spec confirm(opts :: keyword()) :: {:ok, boolean()} | :cancel
# opts: title, default: boolean

@spec panel(rows :: [String.t()], opts :: keyword()) :: :ok
# read-only multi-line display, returns when user presses any key
```

### 5.2 Key bindings (uniform across widgets)

| Key | Action |
|-----|--------|
| `↑`/`k` | move selection up |
| `↓`/`j` | move selection down |
| `Enter` | confirm |
| `Space` | toggle (multi_select only) |
| `Esc`/`q`/`Ctrl-C` | cancel |
| printable char | append to filter buffer (select with `filterable?: true`) |
| `Backspace` | pop filter buffer |
| `?` | show help footer overlay |

`Ctrl-C` is **not** trapped at the TUI level. It propagates as `:interrupt` from `IO.read/2`, which `Fermix.TUI.run/1` catches and returns `:cancel` for; the orchestrator translates that to "back to dashboard." A second `Ctrl-C` at the dashboard exits the program with exit status 130 (standard SIGINT).

### 5.3 Raw-mode handling

```elixir
def with_raw(fun) do
  old = :io.getopts(Process.group_leader())
  :io.setopts(Process.group_leader(), [:binary, {:echo, false}, {:expand_fun, &no_expand/1}])
  try do
    fun.()
  after
    :io.setopts(Process.group_leader(), old)
  end
end
```

- `echo, false` stops the terminal from echoing keypresses (essential for arrow keys and secrets)
- `expand_fun` disables tab-completion expansion which would otherwise eat tab/space
- The `:after` clause restores opts even if the body raises — Code Rule #4 (Own resources).

### 5.4 ANSI escape handling

Single-byte reads via `IO.getn(:stdio, "", 1)`. Sequences are parsed by a tiny state machine:

```
0x1b → enter ESC state
  0x5b ('[') → enter CSI state
    'A' → :up
    'B' → :down
    'C' → :right
    'D' → :left
    other → ignored
  other → :esc
```

Only four escape sequences are supported (arrow keys + ESC). Anything else is treated as a literal printable byte (consistent with how POSIX terminals behave with unrecognized CSI). This is enough for setup; we explicitly do not handle function keys, page-up/down, or modifier combinations.

### 5.5 Color and ANSI fallback

`Fermix.TUI.style/2` wraps `IO.ANSI.format/1`. When `IO.ANSI.enabled?/0` returns `false`, the wrapper passes content through verbatim. The TUI is fully usable without color.

### 5.6 Frame drawing primitive

```elixir
def draw(rows) when is_list(rows) do
  IO.write([IO.ANSI.home(), IO.ANSI.clear(), Enum.intersperse(rows, "\n")])
end
```

Each redraw clears the screen and rewrites every visible row. At 24 rows × 80 cols × ~3 bytes/cell the worst case is ~6KB written per keypress — invisible on any local terminal.

---

## 6. Category specifications

Each category is a module implementing a small behaviour:

```elixir
defmodule Fermix.CLI.Setup.UI.Category do
  @callback id() :: atom()
  @callback title() :: String.t()
  @callback summary(report :: Wizard.report()) :: {status :: :ready | :partial | :untouched | :disabled, String.t()}
  @callback run(report :: Wizard.report()) :: {:save, [Wizard.answer()]} | :cancel
end
```

The dashboard calls `summary/1` once per category per redraw. Categories ordered by importance:

### 6.1 Provider & Model (`Categories.Provider`)

| Widget | Source |
|--------|--------|
| `select` provider | `ModelCatalog.providers/0` → `[:openai, :openai_codex, :anthropic]` |
| `input` (mask) OpenAI API key | shown only when provider == `:openai` and `Wizard` has it flagged unpersisted |
| `select` model with filter | `ModelCatalog.models_for(selected_provider)` — labels show context window |
| `select` reasoning effort | `ResponsesShared.valid_reasoning_efforts/0` — hidden for `:anthropic` |

`summary/1`:
- `:ready` if all required fields satisfied → `"openai_codex · gpt-4o · high effort"`
- `:partial` if provider chosen but model/key missing
- `:untouched` if no provider persisted

A shortcut row "Import from Codex CLI" appears as the first option whenever `CodexImport.codex_available?/1` returns true and provider is unset — runs the existing `CodexImport.import_tokens/1` and returns `{:save, [provider: "openai_codex"]}`.

### 6.2 Realtime (`Categories.Realtime`)

| Widget | Source |
|--------|--------|
| `confirm` enable? | `RealtimeConfig.normalize/1` from snapshot |
| `select` voice | hardcoded valid voices `~w(alloy echo fable onyx nova shimmer)` |
| `input` max session minutes | numeric validator (>0) |
| `input` max cost cents | numeric validator (>0) |
| `confirm` persist transcripts? | — |

Hides voice/min/cost rows when `enable? == false`.

### 6.3 Channels (`Categories.Channels`)

Two-level. The category itself is a `select` over the five channels (each row shows channel name + enabled/disabled). Selecting a channel opens a sub-screen:

| Widget | Source |
|--------|--------|
| `confirm` enabled? | persisted snapshot |
| `input` (mask) bot token / access token / signing secret | secret writer–backed (`SecretWriter.put/3` via `Wizard.save_answers/2`) |
| `input` phone number ID / verify token / app secret / owner user ID | channel-specific |

Sub-screen returns `{:save, [...]}` for that channel only; multi-channel changes require multiple round trips through `save_answers/2`. That is intentional — each save is small and revertible.

### 6.4 Tools (`Categories.Tools`)

| Widget | Source |
|--------|--------|
| `multi_select` built-in tools | `FermixCore.Capabilities.Registry.list(kind: :builtin)` → toggle `hidden_from_agent?` |
| Sub-section "MCP servers" | `Application.get_env(:fermix_core, :mcp_servers, [])` — each row shows `name · status · tools_count`; selecting opens a read-only panel with launch error if any |

`hidden_from_agent?` writes go through a new helper on `Wizard` — see §8.1.

### 6.5 Skills (`Categories.Skills`)

`multi_select` over `FermixCore.Agents.SkillRegistry.list/0`. Each row: skill id · short description · enabled?. Toggling writes through the same hidden-from-agent mechanism as tools.

### 6.6 Search (`Categories.Search`)

Single-select with three options:

| Value | Label | Status |
|-------|-------|--------|
| `duckduckgo` | DuckDuckGo (keyless) | Active in M9; default |
| `bing` | Bing Search API | Future (M7+ pluggable backends) — row disabled |
| `google` | Google Custom Search | Future — row disabled |
| `none` | Disable web search | Removes `web_search` from registered builtins |

Selecting a disabled row shows a panel: "Bing backend ships in M7+; track in `docs/MILESTONE_7_PLUS_PLUGGABLE_BACKENDS.md`." Returns `:cancel` from the panel. The non-stub options write the choice to a new TOML key `[fermix_core.search] backend = "duckduckgo"`.

### 6.7 Sandbox (`Categories.Sandbox`)

| Widget | Source |
|--------|--------|
| `select` mode | `~w(strict standard open)a` |
| `select` command profile | `~w(bare assistant extended)a` |
| `multi_select` env passthrough | union of `sandbox.env.allow` and known secret env names (`OPENAI_API_KEY`, `TELEGRAM_BOT_TOKEN`, ...) |

Writes go through `Sandbox.ConfigMutation.set_command_profile/2` etc., then through `Wizard.save_answers/2` (which calls `ConfigStore.save_snapshot/1`).

### 6.8 Memory (`Categories.Memory`)

| Widget | Source |
|--------|--------|
| `input` compaction threshold (0.0–1.0) | `CompactionConfig.normalize/1` |
| `input` extraction timeout ms | positive integer |

### 6.9 Personalization (`Categories.Personalization`)

Three `input` widgets backed by the existing `user_name` / `timezone` / `communication_style` keys. `summary/1` shows `"Sujeeth · America/Los_Angeles"`.

### 6.10 Doctor (`Categories.Doctor`)

Read-only. Runs `Doctor.probe_active/1` and displays the result in a `panel`:

```
auth probe: openai_codex/gpt-4o responded in 312ms
codex token: valid until 2026-05-19 14:33 UTC
realtime: 0 active sessions · last connect 2 hours ago
trace files: 1.2MB across 14 files in ~/.fermix/traces/
```

`run/1` returns `:cancel` (no save).

---

## 7. User flows

### 7.1 First-run (no config.toml)

```
$ fermix setup
[clear screen]
Fermix setup — ~/.fermix/config.toml
Status: needs setup · Provider: (none)

  ▸ · Provider & Model    needs provider
    – Realtime voice      configure provider first
    – Channels            configure provider first
    – Personalization     name · timezone · style
    ...
  ↑↓ navigate  ⏎ open  q quit

[Enter on Provider & Model]
Provider & Model
  ▸ Import from Codex CLI  (detected ~/.codex/auth.json)
    openai
    openai_codex
    anthropic
  ↑↓ navigate  ⏎ select  esc back

[Enter on Import]
[runs CodexImport.import_tokens/1, writes provider: openai_codex]
[returns to dashboard with Provider row showing ✓]
```

After the first save the dashboard re-reads `Wizard.report/0`; downstream categories that were `–` (disabled "configure provider first") become `·` and openable.

### 7.2 Reconfigure (`fermix setup` after ready)

Same dashboard, all rows openable. Each category save is independent.

### 7.3 Non-interactive (CI, piped, `--*` flags)

```
$ fermix setup --provider openai --default-model gpt-4o --openai-api-key sk-...
```

`Setup.run/1` sees flag-provided answers, never enters `Fermix.CLI.Setup.UI.run/1`, calls the existing `Runtime` path. Output identical to today.

### 7.4 No TTY (pipes, dumb terminals)

```
$ echo y | fermix setup
```

`IO.ANSI.enabled?/0` returns `false`. `Setup.run/1` falls through to the existing line-prompt path; behaviour identical to today.

---

## 8. Wizard integration points

### 8.1 New `Wizard` helpers (small additions)

Three new functions on `FermixCore.Setup.Wizard`. Each is a thin wrapper that delegates to `ConfigStore` mutations and returns a refreshed `report/0`:

```elixir
@spec set_capability_hidden(Capability.kind(), name :: String.t(), boolean()) ::
        {:ok, report()} | {:error, term()}

@spec set_search_backend(atom() | String.t()) :: {:ok, report()} | {:error, term()}

@spec set_sandbox_overrides(mode :: atom() | nil, profile :: atom() | nil, allow :: [String.t()] | nil) ::
        {:ok, report()} | {:error, term()}
```

These exist so categories can persist without each one re-implementing the `ConfigStore.save_snapshot/1 → apply_snapshot/1 → refresh_boot_report` chain.

### 8.2 Save semantics

A category save → `Wizard.save_answers/2` (or one of the new helpers in §8.1). All three side effects of the existing save path still fire:

1. `ConfigStore.save_snapshot/1` writes TOML
2. `ConfigStore.apply_snapshot/1` updates Application env in the running daemon
3. `BootReport.refresh_if_started/1` (if the daemon is up) re-computes readiness

If `restart_required?` becomes `true` after a save (e.g. provider changed), the dashboard shows a banner row: `! Restart required — run 'fermix restart' to pick up provider change`. The banner is informational; it does not block further edits.

---

## 9. Testing strategy

### 9.1 `Fermix.TUI` primitives

`Fermix.TUI` takes `io: device` so tests inject an `:io_device` backed by a binary stream. A test that exercises `select/2`:

```elixir
test "select returns the highlighted option after Enter" do
  input = StringIO.open!("\e[B\e[B\r")   # Down, Down, Enter
  output = StringIO.open!("")
  assert {:ok, :third} = Fermix.TUI.select(
    title: "pick",
    options: [%{value: :first, label: "First"}, %{value: :second, label: "Second"}, %{value: :third, label: "Third"}],
    io: %{in: input, out: output}
  )
end
```

Frames written to `output` are asserted with `assert frame =~ "▸ Third"`. Tests run async because each call owns its own StringIO devices.

### 9.2 Category orchestrators

Each `Categories.*` module has a test that scripts a keypress stream and asserts the returned `{:save, answers}`. No real `ConfigStore` writes — the test stubs `Wizard.save_answers/2` to capture answers. This is the same injection model used by `Setup.RuntimeTest` today.

### 9.3 Fallback path

Existing `Setup.RuntimeTest` coverage is preserved untouched. One new test asserts that when `FERMIX_NO_TUI=1` is set, `Setup.run/1` dispatches to `Runtime.run/2` even when `Setup.UI` is loaded.

### 9.4 What is not tested in unit form

- Real terminal raw-mode round-trip (requires a pty) — covered manually in a `scripts/tui_smoke.sh` that runs `fermix setup` against an `expect`-driven session, gated behind `mix test --include tui_smoke` and run by the M10 acceptance checklist, not CI.
- Color rendering on weird `$TERM` values — pure visual, no asserts.

---

## 10. Implementation order

| Stage | Lands | Gate to next stage |
|-------|-------|--------------------|
| **Stage 0** | `Fermix.TUI` primitives (`select`, `input`, `confirm`) + StringIO test harness | All primitive tests green; tests prove raw mode is restored after exceptions |
| **Stage 1** | Dispatch wiring (`Setup.run/1` chooses TUI vs Runtime), empty dashboard, `Categories.Personalization` end-to-end | First-run dashboard renders; Personalization save round-trips through `Wizard.save_answers/2`; existing `Setup.RuntimeTest` still green |
| **Stage 2** | `Categories.Provider` (incl. Codex import shortcut) and `Categories.Realtime` | First-run can reach `status: :ready` via TUI alone |
| **Stage 3** | `Categories.Channels` (sub-screens for all five channels) | Full M3 channel coverage available from TUI |
| **Stage 4** | `Categories.Tools`, `Categories.Skills`, `Categories.Search` plus `Wizard.set_capability_hidden/3` and `set_search_backend/1` | Toggling a built-in tool to hidden survives a daemon restart |
| **Stage 5** | `Categories.Sandbox`, `Categories.Memory`, `Categories.Doctor` | Full M5 sandbox surface available from TUI |
| **Stage 6** | `multi_select` widget + ASCII-fallback box-drawing + 80×24 layout audit | Manual smoke on iTerm2, macOS Terminal.app, Alacritty, tmux, plain xterm |

Each stage ships independently and behind no flag — landing Stage 1 alone gives the operator a usable TUI dashboard that delegates everything except Personalization back to the existing line prompter.

---

## 11. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Raw-mode left enabled after a crash leaves the operator's terminal broken | `with_raw/1` uses `try/after` (Code Rule #4). Stage 0 includes a test that raises mid-widget and asserts `:io.getopts/0` is restored. |
| Burrito-packaged binary missing `:io.setopts/2` support on some Linuxes | The fallback path is the line prompter, which is the current code. If raw-mode setup returns `{:error, _}` we log once, set process dict `:fermix_tui_disabled`, and dispatch to fallback. No silent degradation. |
| `IO.ANSI.enabled?/0` lies on Windows-via-WSL or unusual `$TERM` | Operator sees no TUI, gets the line prompter (correct fallback). They can force the TUI with env `FERMIX_FORCE_TUI=1` if they know their terminal works. |
| Tools/Skills categories expose capabilities not yet loaded (daemon not running) | Categories.Tools renders only what `Capabilities.Registry.list/2` returns. When the registry process is missing it shows a single panel row: "Built-in catalog visible only while the daemon is running. Run `fermix start`." No partial state. |
| Saving a single category mid-flight produces an inconsistent TOML | `ConfigStore.save_snapshot/1` writes atomically (existing M3 contract). A save either fully persists or fails with an error rendered in a panel. |
| Operator scripts `fermix setup` in CI and gets stuck on the TUI | `IO.ANSI.enabled?/0 == false` in non-tty environments. Plus `FERMIX_NO_TUI=1` documented escape hatch. Plus every flag-driven invocation skips the TUI entirely. Three independent guarantees. |
| Adding a category later requires touching the dashboard | Categories self-register via a `@categories` module attribute in `Fermix.CLI.Setup.UI`; adding one is one `alias` + one list entry. |

---

## 12. Open questions

1. **Should the TUI surface a "Save and restart daemon" button after a provider change?** Currently the operator must run `fermix restart` themselves. A guarded confirm could shell out to `RestartCommand.run/1`. Defer: only useful for the "daemon-managed" install path; the foreground `fermix run` user can `Ctrl-C` and re-run. Pick this up in Stage 6.
2. **Skills toggle persistence model.** Skills today are filesystem-backed (`~/.fermix/skills/`). A toggle that sets `hidden_from_agent?` is config-side and works. A toggle that "uninstalls" would need a delete path that does not yet exist. M10 only does config-side hiding; the doc is explicit.
3. **MCP server installation flow.** Adding a new `[mcp.servers.X]` entry from the TUI requires capturing a command + args + env. That is a richer form than any existing category. Defer to a separate milestone — M10 only shows installed servers and their status.
4. **Help (`?` key) content.** Should it be a per-widget overlay or a static help panel? Lean toward a static help panel because per-widget help adds widget-state complexity. Decide during Stage 0.
5. **Should `fermix setup` keep printing the line-based report at the end?** When the TUI exits with status `:ready` the operator already saw a healthy dashboard. The line report is now redundant. Strip it from the TUI exit path; keep it for the fallback path. Confirm with operator preference in Stage 1.

---

## 13. What this milestone does not promise

- It does not change the persisted TOML shape — every key written today is written the same way.
- It does not replace `fermix doctor`; the Doctor category embeds a probe result, it does not absorb the full diagnostic.
- It does not introduce a TUI dependency — the primitives are ~300 LOC of Elixir.
- It does not change the LiveView at `/setup`; that surface keeps using `BootReport.current/0` and the same `Wizard` data layer. A future milestone can rebuild the LV against the new category model if the parity matters.
- It does not change what counts as "ready." `Readiness.report/0` and `Wizard.report/0` are authoritative; the dashboard renders what they report.

---

## 14. Summary

M10 keeps every existing setup contract intact — same `Wizard` data layer, same `ConfigStore` writes, same `Doctor` probes, same flag-driven non-interactive path, same LiveView — and adds a thin renderer on top: a single-screen category dashboard with arrow-key navigation, type-to-filter menus for catalog values, masked secret inputs, and a non-TTY fallback that is just the existing line prompter. Tools, skills, sandbox, search, and MCP all become discoverable from `fermix setup` instead of being doc-only configuration. The implementation is ~1500 LOC across ~15 files, no new mix dependency, and ships in six independent stages.
