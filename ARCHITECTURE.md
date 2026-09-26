# Architecture

This document describes the high-level architecture of Fermix. It is a code map,
not an exhaustive design spec. It should help a contributor answer two questions:
"where does this behavior live?" and "which boundary am I crossing?"

For milestone-level design history, see the files under `docs/design/`. Those
documents explain why individual systems were added. This file describes the
current shape of the repository. Working rules for contributors and coding agents
live in `AGENTS.md`.

## Bird's Eye View

Fermix is an Elixir umbrella application for a self-hosted AI assistant.
Messaging channels, the Phoenix web app, the local companion sockets, and the
agent runtime run in one BEAM VM. There are no HTTP bridges between Fermix
applications.

A chat turn:

1. A channel adapter receives platform input (webhook, long poll, local socket,
   or CLI) and normalizes it into a `FermixChannels.Gateway.Message`.
2. `FermixChannels.Gateway.ingest/2` authorizes the sender, builds the reply
   function, transcribes audio and ingests images, runs slash commands, and hands
   the turn to `Gateway.Queue`, which runs one FIFO turn at a time per
   conversation.
3. The queue checks a turn-state snapshot out of `FermixCore.Agents.MainAgent`
   (the cached runtime context: bootstrap prompt, prompt memory, capability
   profiles, provider routes) and runs `FermixCore.Agents.TurnRunner` in a task.
4. `TurnRunner` loads recent history, compacts it when needed, persists the user
   message, and calls `FermixCore.AgentLoop`.
5. `AgentLoop` calls the provider route chain, executes tool calls through the
   run's capability snapshot, and loops until a final response or a bounded stop.
6. The queue delivers the reply through the channel's reply function;
   `TurnRunner.commit/4` then records the turn and starts post-reply work
   (compaction, memory review).
7. History, memory, prompt resources, jobs, and other durable state are written
   to the core-owned SQLite database; traces and logs go under `FERMIX_HOME`.

`fermix_channels` depends on `fermix_core`; `fermix_web` depends on both.
`fermix_core` depends on `fermix_nif`, the `compux` library, and (in dev and prod
builds) `fermix_opik`, but never on channels or Phoenix. Where core needs a
channel-side implementation at runtime (delivery adapters, the voice bridge,
queue status, mobile management), `fermix_channels` registers it in application
env at boot or config names it, and core resolves it when needed.

## Code Map

### Root Umbrella

The root `mix.exs` defines the umbrella, the releases, and the `mix quality`
alias (format check, `compile --warnings-as-errors`, `credo --strict`,
`dialyzer`, `test`, run in the `:test` env). There are three releases:

- `fermix`: the Burrito standalone binary (macOS and Linux, arm64 and x86_64)
  behind the Homebrew formula.
- `fermix_app_engine`: a plain release tree with web assets and an engine
  manifest, bundled into the macOS app.
- `fermix_linux_package`: the engine for the Linux packages, with a
  package-owned musl loader.

Configuration lives in `config/`. At boot it is layered in this order:

1. compile-time defaults from `config/config.exs` and `config/<env>.exs`
2. the persisted `config.toml`, hydrated by `config/runtime.exs` through
   `Setup.ConfigStore.bootstrap_runtime_config/1` and restated so a release's
   `sys.config` cannot reset it
3. a fixed set of environment-variable overlays in `config/runtime.exs`
   (secrets, paths, channel tokens and allowlists, the bind address, and similar
   deployment values)

After boot, setup and management writers persist a new snapshot and apply it
with `ConfigStore.apply_snapshot/2`; environment overlays are not re-applied then.

Architecture Invariant: `config.toml` is the source of truth for settings.
Environment overlays apply only at boot, and a new setting does not get one
unless it is a secret or a feature flag (`AGENTS.md`, rule 12).

### `apps/fermix_core`

This is the runtime core and the main API boundary for the rest of the umbrella.
It owns agents, providers, capabilities and tools, memory, prompts, setup and
readiness, scheduled work, the sandbox, the coding harness, plugins, the
companion protocols, and traces.

`FermixCore.Application.start/2` first picks a `BootProfile` (`:app_engine`,
`:standalone_cli`, `:linux_package_cli`, or `:source`) from the compiled-in
`BuildInfo`. A CLI verb that needs no daemon runs and halts before the sibling
applications start. Otherwise it checks `auth.json` permissions, installs the
redacting logger, attaches telemetry, and starts the core tree under
`:rest_for_one`, in this order:

1. command hosting, `FermixCore.TaskSupervisor`, the `FermixCore.Finch` HTTP
   pool, and `Trace`
2. `Auth.TokenSupervisor`, plus the Codex token manager when Codex is routable
3. `Browser.Supervisor`
4. `Capabilities.Registry` and its seeders (built-ins, sandbox commands, the
   plugin installer and plugin tools), then `SkillRegistry`
5. MCP status and `MCP.Supervisor`
6. `Memory.Repo`, `Prompt.TemplateReconciler`, `ConversationStore`, and
   `Memory.Store`
7. secret, boot, restart, and sandbox-environment state (`BootReport`,
   `RestartState`, `Sandbox.EnvHealth`)
8. `AgentSupervisor` and `MainAgent`
9. the job, meeting, and temporal schedulers with their delivery supervisors,
   and `Harness.Supervisor`
10. children gated by config or platform: the daemon socket
    (`Fermix.CLI.Daemon` and the management workers), `Realtime`,
    `ComputerUse`, `ComputerHistory` (macOS only), and `SkillCuration.Scheduler`

Architecture Invariant: core is the only place where agent runtime state, memory
state, prompt composition, capability state, and provider calls meet. Channels
and controllers normalize input and delegate. Turn scheduling, delivery, and
streaming stay in `FermixChannels.Gateway.Queue`.

### `FermixCore.Agents`: Main Agent and Turns

`MainAgent` is the persistent top-level agent process. It caches a
`RuntimeContext` (bootstrap prompt, prompt memory, operator and guest capability
profiles, runtime section) and hands out turn-state snapshots, freezing the
Computer History gate and the provider routes for each one. The route chain is
built at init, so a provider change needs a restart.

`TurnRunner` runs a turn inside the queue's task: history, preflight
compaction, persisting the user message, `AgentLoop`, `[:fermix, :agent, ...]`
telemetry, and `commit/4` after delivery. Conversation identity is
`Agents.ConversationKey`: `{channel, chat_id, thread_scope}`, with `thread_ts`
as the canonical thread identifier when present.

Architecture Invariant: `MainAgent` and `TurnRunner` do not know how Telegram,
Slack, WhatsApp, Discord, Signal, ACP, mobile, voice, or CLI replies are
delivered. The reply function stays with `Gateway.Queue`.

### `FermixCore.AgentLoop`

`AgentLoop` is the bounded LLM/tool loop. It takes the provider route chain, a
capability snapshot, the allowed tool names, the caller's trust policy, and a
context map, and returns the response with iteration, token, and
`tool_failures` counts.

Important bounds live here:

- max iterations: the loop's own default is 25; callers pass
  `Agents.IterationLimits` (100 for interactive turns, sub-agents, and scheduled
  jobs, set in `config/config.exs`, not `config.toml`), and fan-out workers get 40
- two continuation retries, and provider failover only on the first call
- repeated-tool-call detection that warns once and aborts on an unbroken run of
  repeats
- at most one channel side-effect call per iteration
- a loud failure when images reach a model without vision

Compaction is not part of the loop; `TurnRunner` compacts before and after it.

Architecture Invariant: provider responses and tool results are data flowing
through the loop. Tools are dispatched by name from a per-run capability
snapshot built when the loop starts, never hard-coded in the loop.

### `FermixCore.Providers`

`Providers.Adapter` is the provider behaviour (`chat/3`, `continue/3`,
`to_provider_tools/1`, `parse_tool_calls/1`, `parse_response/1`, and optional
`supports_streaming?/0`). The static `Providers.Descriptor` registry is the
single source of truth for the supported providers: `openai_codex` (Codex
OAuth), OpenAI (API key), Anthropic (API key or subscription OAuth), xAI (API
key or Grok OAuth, shown as SpaceXAI), OpenRouter, Mistral, Venice, and a
keyless local Ollama. Each entry names the adapter module, auth modes, secrets,
config keys, and whether the provider supports reasoning effort. Adapters
include `OpenAI.ChatCompletions`, `OpenAI.Responses`, `OpenAI.Codex`,
`Anthropic.Messages`, and `XAI.Responses`; OpenAI is `:routed` (model +
base_url pick Responses vs ChatCompletions).

`Selection` builds the primary-plus-fallback chain (at most one provider may be
marked `primary`), `RouteResolver` resolves a route to `{route_key,
adapter_opts}`, `Adapter.for_route/1` picks the module, and `RoutingOverrides`
applies the `[fermix_core.routing]` model and reasoning-effort overrides for
sub-agents, cron, and meetings. `Failover` and `Transient` classify retryable
errors. Every provider call emits through `Providers.Telemetry.emit_call/3`.

Architecture Invariant: adapters return a normalized turn (`content`,
`tool_calls`, `usage`, `model`, `provider_state`). Agent code should not depend
on provider-specific response bodies.

Architecture Invariant: the supported-provider set and its per-provider metadata
live in `Providers.Descriptor`. Adding a provider is a descriptor entry and an
adapter, plus its model-catalog list, its `Setup.SecretPaths` entry, and its
secret overlay in `config/runtime.exs`, not a sweep of hand-maintained lists.

### `FermixCore.Auth` and `FermixCore.Net`

`Auth` owns OAuth credentials for providers and plugins. `Auth.Store` keeps
versioned per-provider profiles in `FERMIX_HOME/auth.json`, written atomically
with mode 0600. Login flows are per vendor (`CodexLogin` and `OAuthFlow` with a
loopback listener, `CodexImport`, `AnthropicLogin`, `XAILogin`, and plugin
providers through `OAuthProviders`), and `TokenSupervisor` runs one
`TokenManager` per profile.

`Net.HttpClient` sends outbound HTTP on the shared `FermixCore.Finch` pool,
retrying once on a stale socket and never on a timeout. `Net.TimeoutPolicy`
holds the receive timeout for each request kind, `Net.Tls` the verified TLS
options for WebSockets, and `Net.Guard` the public-URL checks.
`FermixCore.Timeouts` names the non-HTTP deadlines.

Architecture Invariant: core boot aborts if `auth.json` exists with a mode other
than 0600. `Net.TimeoutPolicy` has no default, so an unknown request kind raises.

Architecture Invariant: `auth.json` has two lockfiles beside it, shared by every
VM on the host. Every read-modify-write of the file holds the store lock, and a
refresh, sign-in, import or logout of a profile first holds that profile's lock.
The order is always profile, then store; neither lock is reentrant, and no
locked section calls a `TokenManager`.

### `FermixCore.Capabilities` and Tools

A `Capabilities.Capability` is a struct, not a behaviour: a kind (`:builtin`,
`:skill`, or `:mcp`), an `{m, f, a}` executor, a policy class, and an
`owner_only?` flag, run through `Capability.execute/3`. Built-in tools implement
the `Capabilities.Builtin.Tool` behaviour (name, description, parameters, usage
guidance, `execute/2`), with optional `advertise?/1` and `dynamic_parameters/1`
hooks that decide per turn whether and how a tool is offered.

`Capabilities.Registry` is a GenServer over a protected ETS table. Trust decides
what a caller sees: an operator gets every capability; a guest, or a caller with
no trust set, gets read-only tools and never an owner-only one. Registration is
split by source: `BuiltinSeeder` for built-ins, `Sandbox.CommandCapabilities`
for operator-defined commands, `Plugins.CapabilitySeeder` for plugin HTTP tools
(run by `Plugins.ToolExecutor`), and the MCP client for `:mcp` tools. With
deferral on (the default), plugin and MCP tools sit behind `tool_search`,
`tool_describe`, and `tool_call`. Provider adapters, not the registry, format
tool schemas.

Built-in tool families: file read/write/edit, glob and content search, shell,
and `view_image`; git read/write; web (`web_search`, `web_fetch`,
`place_search`, `browser`); skills and delegation (`skill_*`, `subagents`,
`model_routing_config`); memory (`memory_store`, `memory_recall`,
`memory_sources_list`, `recall_activity`); scheduled jobs; dated events and
reminders (`event_*`, `reminder_snooze`); messaging (`send_attachment`,
`react`); `generate_image`, `request_directory_access`, and `tool_help`.
`computer_use`, the coding-harness tools, and the meeting tools are registered
only when their feature is ready.

Architecture Invariant: tools receive explicit context from the agent runtime
(at least `agent_name` and `conversation_key`). They should not infer
conversation identity, registry state, or provider state from globals.

### Skills and Worker Agents

`Agents.SkillRegistry` discovers skills from three roots: bundled
`priv/skills` and `FERMIX_HOME/skills` (operator trust), and the skill
directories of enabled plugins (guest trust). It seeds bundled defaults only into
an empty default directory and keeps an in-memory snapshot until explicitly
reloaded.

`Agents.AgentSupervisor` dynamically starts `AgentServer` workers. Each runs one
delegated task with its own agent definition, session ID, provider, and parent
metadata; `skill_run` and `subagents` both use them.

Architecture Invariant: skill discovery is tolerant of bad skill files. A
malformed skill, or one whose name collides with a registered capability, is
skipped and logged; it never prevents Fermix from booting.

### `FermixCore.Memory`

Memory has two layers:

- hot-path GenServers and ETS: `ConversationStore` for conversation history and
  `Store` for scoped facts, writing through to the database
- durable SQLite: `Memory.Repo`, an Exqlite GenServer in WAL mode over
  `FERMIX_HOME/memory.db`

The same database also holds full-text search, versioned resources, scheduled
jobs and their runs, temporal events and reminders, harness runs, meetings,
skill usage and curation, mobile timelines, and computer-history rows.

`Memory.Reviewer` writes durable memory. It is a time-gated background review
(daily by default) of the owner's recent messages that applies add, replace,
and archive operations through `ReviewTools`, after which `PromptFiles` rebuilds
`USER.md` and `MEMORY.md` under `FERMIX_HOME/memory/<agent>/`. `Admission` holds
category and scope policy, `Compactor` summarizes long conversations, and
`Search` runs FTS5 lookups.

Architecture Invariant: SQLite is canonical for durable memory. Prompt memory
files are derived prompt artifacts, not the source of truth.

Architecture Invariant: memory review runs after the reply is delivered, in a
supervised task. A failed review records backoff state and never turns a
delivered reply into a failed turn.

### `FermixCore.Prompt`

Bootstrap files live in `FERMIX_HOME/bootstrap/<agent_id>/`: `IDENTITY.md`,
optional `SOUL.md`, `FERMIX.md` (operating rules; `BootstrapRename` renames a
legacy `AGENTS.md` at boot), `REALTIME.md` for realtime voice sessions, and
`LIVE.md` for the Live voice frontend.

`PromptComposer` exports prompt parts by cache tier, stable first: identity,
soul, operating rules, realtime rules when relevant, the generated runtime
section (capabilities and skills), then volatile prompt memory. A main turn
sends `stable ++ runtime ++ extra system ++ volatile ++ history ++ user`, with
per-turn notes (channel presentation, the current date, recent activity) added
to the leading system messages. Scheduled jobs use their own isolated prompt.

`BootstrapLoader` reads the files, records `imported` or `manual_edit`
revisions, and renders `Prompt.Defaults` in memory when a required file is
missing or empty. `SetupSeeder` writes the initial files during setup.
`TemplateReconciler` adopts newly shipped templates into files that still match
their seed baseline. `InjectionScan` flags suspicious prompt-memory parts: a
match is logged and traced as `[:fermix, :security, :injection_scan]`, and the
part is kept as data.

Architecture Invariant: loading prompt files never writes or creates them. The
writers are explicit: setup seeding, the boot-time rename and template
reconciler, and owner-confirmed `SoulCuration`.

Architecture Invariant: recalled memory is fenced in `<memory-context>` and
labeled as background data, not live user instruction.

### `FermixCore.Resource`

`FermixCore.Resource.Registry` is a module API over `Memory.Repo`, not a
process. It tracks versioned prompt and memory resources, commits revisions with
SHA-256 hashes and a required `mutation_source`, supports diffs and rollback for
file-backed resources, and offers `commit_and_write/5`, a forward writer with an
expected-hash guard that restores the previous bytes on failure. The
`mix fermix.resource.*` tasks read it.

Architecture Invariant: resource history shares the memory database. There is no
second resource-store process to coordinate.

### `FermixCore.Setup`, `Readiness`, and `Health`

`Setup.ConfigStore` owns `FERMIX_HOME`, the persisted `config.toml`, and the
standard workspace paths (workspace, grants, bootstrap, skills, plugins,
browser, journals, realtime, mobile, traces, logs, and `memory.db`). Secrets
live in the OS keychain, named by profile rather than by home.

`Setup.Wizard` is the shared setup engine. `fermix setup` and `mix fermix.setup`
(through `Setup.Runtime`), the setup LiveView, and the management protocol's
`settings.*` methods all persist through it. `Readiness` reports which required
setup is missing, with the gating and pane keys the setup surfaces use. `Health`
combines cached readiness (`Setup.BootReport`), channel, provider, and realtime
status, restart state, and the version into the runtime health report.

Architecture Invariant: setup logic belongs in core. The CLI, web, and app
surfaces collect answers and call core.

### `FermixCore.Trace` and Telemetry

`Trace` writes one `<type>.jsonl` file per UTC day under
`FERMIX_HOME/traces/YYYY-MM-DD/`. `Trace.TelemetryHandler` bridges telemetry
events into those files. `FermixCore.Telemetry` owns correlation IDs and content
capture, which is on unless `FERMIX_TRACE_CONTENT=0`. Tools emit through
`Tools.Telemetry.exec/5` and provider calls through
`Providers.Telemetry.emit_call/3`; `docs/TELEMETRY_CONTRACT.md` is the contract.

Architecture Invariant: trace writes are best-effort. Failure to write a trace is
logged and should not take down the runtime.

### `FermixCore.Jobs`, `Temporal`, and `Delivery`

`Jobs` owns durable scheduled work. `Jobs.Registry` stores job definitions and
runs in the memory database, `Jobs.Schedule` parses interval, one-shot, and
five-field cron schedules with an IANA zone, and `Jobs.Scheduler` claims due
jobs atomically and starts one `Jobs.Runner` per run. A run is one bounded
`AgentLoop` over an isolated job prompt, with no persona, prompt memory, or
history, and its final text is delivered once.

`Temporal` owns dated events and proactive reminders. `Temporal.Registry`
validates model-supplied events, the pure `Planner` materializes reminder
occurrences, `Temporal.Scheduler` is the single claimer, and `Renderer` builds
reminder text without a model.

`Delivery` is the shared outbound layer. `ChannelSend` makes one bounded send
through the adapter named in `[:fermix_core, :jobs, :delivery_channels]`, so core
never compile-depends on channels, and `OwnerInbox` is the one resolver for the
owner's inbox.

Architecture Invariant: a delivery destination is resolved once, at acceptance,
and stored on the row; send time resolves only the adapter. A send watched by
`ChannelSend.with_timeout` is linked to its caller, so it never outlives it.

Architecture Invariant: a job is `running` only while one of its runs is queued
or running. The claim takes the job and inserts the run in one transaction, and
`Repo.settle_job_run` writes the run's final row and releases the job in
another; owner edits write only the columns they own.

### Sandbox and Command Execution

`FermixCore.Sandbox` is an in-process policy gate over paths, working
directories, and shell plans. Modes (`strict`, `standard`, `open`) expand to root
sets, command profiles (`bare`, `assistant`, `extended`) pick the allowed
commands, and `Hardline` refuses catastrophic commands. `Sandbox.Env` resolves
`[sandbox.env] allow` one name at a time, and `EnvHealth` records misses for
readiness. The owner-gated `request_directory_access` tool plus `/confirm
<token>` can grant a denied directory. There is no OS-level jail.

`CommandRunner` is the entry point for spawning external commands. In the daemon
each command runs in a temporary `CommandHost` under `CommandHost.Supervisor`,
the first child of the core tree; the host owns the port and the OS process
group, and ends the group through `ProcessGroup` and `FermixNif.kill_pgid/2`.
Callers without a supervision tree pass `supervised: false`.

Architecture Invariant: however a `CommandHost` ends (exit, timeout, cancel,
output cap, owner death, or shutdown), it signals the whole process group.

### `FermixCore.Harness`

The coding harness runs vendor coding CLIs as background runs: Codex
(`Adapters.CodexExec`), Claude Code (`ClaudeHeadless`), and Codex cloud
(`CodexCloud`). `Harness.Supervisor` is always started and supervises
`Manager`, `RunSupervisor`, and `DeliveryWorker`. `Manager` admits a run
(worktree lock, artifact quota, `harness_runs` ledger row) before it starts; the
run streams the CLI under a sanitized environment (`Harness.Env`,
`Harness.Identity`) and spools output under `FERMIX_HOME/harness/runs/<id>`.
Launch needs both `Authorization` (an attended owner turn or an allowlisted job)
and `Consent` (`[fermix_core.harness] approved`). Outcomes come back through
`Continuation` or `Harness.Delivery`.

Architecture Invariant: run state is ledgered before any OS process starts, and
`Manager` is the only writer of terminal status.

### `FermixCore.Plugins` and MCP

`Plugins.Registry` loads manifests from three disjoint sources: bundled
(`priv/plugins/<name>/`), installed
(`FERMIX_HOME/plugins/installed/<name>/current`), and `dev_local`. The catalog is
`priv/plugins/index.json`, shipped inside the binary with no remote refresh.
`Plugins.Dist.Installer` verifies each artifact's sha256 and its cosign
signature against the fermix-plugins release workflow, then activates it
atomically.

A plugin's tools use one of two rails. The `http` rail runs inside the VM
through an HTTP template interpreter, with credentials resolved outside model
input. The `mcp` rail becomes a local stdio server (`local_stdio`) or a remote
Streamable-HTTP endpoint (`remote_mcp`). `Capabilities.MCP.Supervisor` runs
those servers and the operator's own `[mcp.servers.*]` in isolated subtrees. An
inbound MCP server (`FermixCore.MCP.Inbound`) exists in the code, but nothing
starts it.

Architecture Invariant: MCP clients are keyed by source (`{:plugin, name}` or
`{:operator, name}`), and a `remote_mcp` plugin loads only from a
cosign-verified install.

### `FermixCore.ComputerUse`, `ComputerHistory`, and `Browser`

`ComputerUse` controls the desktop through the `compux` sidecar (macOS arm64
and Linux x86_64). `ready?/0` (enabled and sidecar installed) is the one gate for
both the `computer_use` tool and `ComputerUse.Supervisor`. `SidecarInstaller`
fetches a sha256-pinned binary into `FERMIX_HOME/plugins/compux/`, and `Safety`
refuses state-changing actions under strict access and host sessions outside an
attended chat or voice turn.

`ComputerHistory` is an opt-in, macOS-only recorder. It captures interaction
events through the same sidecar and summarizes them on the device into memories
that `recall_activity` reads. `ComputerHistory.Gate` decides where history may
flow, and `MainAgent` snapshots it per turn.

`Browser` runs the `browser` tool: managed Chrome over the DevTools protocol,
without compux. `Browser.Supervisor` holds a `ProfileManager`, which caps live
Chrome instances, and one `ProfileServer` per owner and profile, which launches
Chrome lazily and shuts it down on every exit path. On macOS, Chrome launches
only through the `disclaim` shim from `fermix_nif`.

Architecture Invariant: the computer-use tool is registered only when `ready?/0`
holds, as a GUI-control capability that guests never get. Computer history
reaches a model only when every hop in the provider chain is local or granted.

### `FermixCore.Transcription` and `Meetings`

`Transcription` sends audio to the configured backend (`openai`, `xai`,
`deepgram`, or `local`) through `Transcription.Registry`, and opens live streams
behind one `StreamSession` contract. `local` drives the `fermix-stt` sidecar.
Callers are channel voice notes and meetings.

`Meetings.join/2` checks, in order, that meetings are enabled, the turn is an
attended owner turn, the URL is valid, the capture lane is installed, and no
other meeting is running, then starts a temporary `Meetings.Session`. Google Meet
uses the `fermix-meetbot` sidecar; Zoom uses RTMS WebSockets. A session streams
audio into `Transcription`, writes transcripts under
`FERMIX_HOME/workspace/meetings/<id>/`, summarizes with speech treated as
untrusted, and delivers notes to the originating chat or the owner's inbox.

Architecture Invariant: an unknown or unconfigured transcription backend fails
loudly, and at most one meeting runs at a time.

### `FermixCore.SkillCuration` and `SoulCuration`

`SkillCuration` proposes new skills from the owner's history on a slow cycle,
started only when curation and memory are both enabled; proposals go to the
owner's inbox and are acted on only after `/skills` approval. `SoulCuration`
drafts `SOUL.md` edits with one provider call and applies, reverts, or resets
them only after `/soul apply <token>`.

Architecture Invariant: neither curator changes a skill or `SOUL.md` without an
explicit owner action.

### Companion Protocols: `Management` and `Realtime`

The native companion apps (`tezra-io/fermix-macos`, `tezra-io/fermix-linux`)
never read config, secrets, or state themselves. `Fermix.CLI.Daemon` serves
`FERMIX_HOME/daemon.sock` (length-prefixed JSON, mode 0600).
`Management.Protocol` owns the versioned envelopes and one ordered method table
in which each method has a minimum protocol version, and `Management.Router`
maps requests onto daemon capabilities (overview, doctor, logs, lifecycle,
settings, secrets, providers, auth, plugins, jobs). `Management.Settings`
publishes the same setting descriptors the setup LiveView renders and saves them
through `Setup.Wizard`. The canonical export is
`apps/fermix_core/priv/management/` (`PROTOCOL.md`, the JSON schema, and golden
fixtures).

`Realtime` serves local full-duplex voice on `FERMIX_HOME/realtime.sock`
(newline-delimited JSON defined by `Realtime.Protocol`, exported in
`priv/realtime/`). `SessionServer` runs OpenAI Realtime with tools through
`ToolBridge` and optional screen perception; `LiveSessionServer` runs OpenAI
Live, which executes no tools and delegates every task to an agent turn through
the `VoiceBridge` behaviour, implemented in channels by `Voice.Bridge`.

Architecture Invariant: each wire is defined once, in its protocol module, and
exported; `protocol_contract_test.exs` fails when the management export drifts,
and a method called below its minimum version is refused with
`{method, requires}` so an older app degrades to a sentence instead of crashing.

### CLI, Mix Tasks, and Releases

`apps/fermix_core/lib/fermix/` is the `fermix` command. Its verbs cover setup and
auth (`setup`, `auth`), talking to the agent over the daemon socket (`ask`,
`chat`), lifecycle (`run`, `service`, `start`, `stop`, `restart`, `status`,
`health`, `upgrade`, `uninstall`, `migrate-to-app`), diagnostics (`doctor`,
`diagnostics`, `logs`), administration (`agents`, `capabilities`, `skills`,
`plugins`, `memory`, `sandbox`, `grant`, `revoke`), and companion surfaces
(`voice`, `acp`, `pair`, `devices`). Mix tasks: `fermix.dev`, `fermix.setup`,
`fermix.resource.*`, and the eval tasks in core; `fermix.bench*` in channels;
`opik.ping` and `opik.replay` in opik. `Release.AppEngineManifest` records the
version, source commit, tree digest, and protocol ranges that the macOS app
verifies.

`FermixCore.Introspection` provides read-only snapshots (overview, agents, jobs,
capabilities) for the daemon socket, the management `overview.get` method, and
the web home page. `FermixCore.Bench` and `FermixChannels.Bench` are latency
tooling that drives scenarios through the real gateway and queue with a mock
provider.

Architecture Invariant: only `run` and `service run` start the daemon tree
(`setup` and `memory` start it only when needed); every other verb halts before
the sibling applications start. An app engine is recognized from its
compiled-in build identity, never from runtime detection.

### `apps/fermix_channels`

This app owns messaging-platform and companion transports and depends on
`fermix_core`. Every adapter implements `FermixChannels.Gateway.Channel`.
Required callbacks parse inbound payloads (or return `:unsupported_transport`
when the channel has no webhook), verify authenticity, and send text and media;
optional callbacks cover health, typing, streaming tiers with draft editing,
album coalescing, reactions, approval buttons, and turn results for machine
surfaces. `Gateway.ChannelRegistry` is the channel list of record: each
channel's adapter, transport, supervised child, trust, and whether slash
commands are allowed.

`FermixChannels.Gateway.ingest/2` is the bridge from channels into core. It
normalizes input into `Gateway.Message`, authorizes the sender through
`Gateway.Authorizer` (the owner is an operator, allowlisted senders are guests,
anyone else is dropped), builds the reply function (`Gateway.Delivery`),
transcribes audio and ingests images, runs slash commands unless the channel
disables them, and hands the turn to `Gateway.Queue`.
`FermixChannels.Dispatcher` remains only as a thin alias for `Gateway.ingest/2`,
used by tests.

Current channels:

- `Telegram` uses long polling through `Telegram.Poller`, with albums coalesced
  by `Gateway.AlbumBuffer`; webhook transport is intentionally unsupported.
- `WhatsApp` uses Cloud API webhook ingress and Graph API replies, with audio,
  image, and document download.
- `Slack` uses signed Events API webhook ingress and Web API replies.
- `Discord` uses a supervised Gateway connection and REST replies.
- `Signal` polls `signal-cli receive` once a second and sends through
  subprocesses.
- `Acp` exposes Fermix as an Agent Client Protocol agent on
  `FERMIX_HOME/acp.sock` (`Acp.Endpoint`, one `Acp.Peer` per connection);
  `fermix acp` pipes stdio to that socket. Client identities are kept by
  `FermixCore.Acp.Identity`.
- `Mobile` serves the iOS companion on its own Bandit TLS listener (port 4031,
  Noise sessions, a pairing window, APNs push). It is off by default, and
  `FermixCore.Companion.Timeline` keeps each profile's synced timeline apart from
  conversation history.
- `Voice` turns Live-voice delegations into `voice`-channel turns
  (`Voice.Bridge`).
- `CLI` is the channel behind `fermix ask` and `fermix chat`.

`outbound/` holds pure long-form text helpers, and `harness/` re-ingests
coding-harness completion notices.

Architecture Invariant: channel adapters own platform quirks and webhook
authenticity; sender authorization and trust are central (`Gateway.Authorizer`,
`Gateway.ChannelRegistry`). After ingest the agent sees only normalized message
fields, the source trust, and gateway-built closures, never the channel module.
A remote channel enabled without an owner is refused at boot.

### `apps/fermix_web`

This is the Phoenix application. It owns HTTP ingress, the web UI, health
endpoints, and static assets.

The router exposes:

- `/` (`HomeLive`), a dashboard fed by `FermixCore.Introspection` that redirects
  to `/setup` until boot is ready
- `/setup` (`SetupLive`) behind `SetupAuth`: a one-time launch token, then a
  session cookie; `embed=1` serves the macOS app
- `/health` and `/health/ready` for readiness, and `/health/live` for a static
  liveness payload
- `GET`/`POST /webhook/whatsapp` and `POST /webhook/slack`

`WebhookController` verifies the request and parses it with the channel adapter,
drops duplicates, and hands the message to `Gateway.ingest/2` asynchronously
under `FermixCore.TaskSupervisor`; a failed handoff returns 503 and rolls back
the duplicate record. `HealthController` reports from `FermixCore.Health`.
`SetupLive` drives `Setup.Wizard` and the core setup modules. Not all ingress is
Phoenix: the mobile listener, the OAuth loopback listener, and the Unix sockets
(`daemon.sock`, `realtime.sock`, `acp.sock`) live in core and channels.

Architecture Invariant: Phoenix does not contain agent business logic. It is an
HTTP and UI boundary over core APIs.

### `apps/fermix_nif`

Native helpers, built with `elixir_make`. The NIF exports one function,
`FermixNif.kill_pgid/2` (`kill(-pgid, signal)`), called only through
`FermixCore.ProcessGroup` by `CommandHost`, `CommandRunner`, the local speech
sidecar, and meetings. The app also builds `disclaim`, a macOS-only exec shim: a
process spawned through it becomes its own TCC "responsible process" instead of
inheriting the daemon's. Chrome and the meetings sign-in and sidecar launch
through it, `fermix doctor` checks it, and CI cross-compiles it.

Architecture Invariant: native code stays a leaf dependency for narrow platform
primitives, and its error policy lives in Elixir (`ProcessGroup`). Agent
orchestration, provider calls, channel flow, and persistence belong in Elixir.

### `apps/fermix_opik`

This app exports Fermix's telemetry to an [Opik](https://www.comet.com/opik)
instance for trace inspection. It is compiled into dev and prod builds but stays
inert unless enabled: `FermixOpik.enabled?/0` requires a non-test compile-time
env and `FERMIX_OPIK_ENABLED` (or the `:fermix_opik, :enabled` config), and when
disabled it attaches no telemetry handler. The reporter covers agent, provider,
tool, job, memory, harness, curation, plugin, MCP, reminder, realtime, meeting,
management, and computer-use events and nests runs by `session_id` and
`parent_session`. `mix opik.ping` and `mix opik.replay` help debug the export.

Architecture Invariant: observability export is opt-in and side-car. The handler
only casts to a bounded aggregator; it never sits on the reply path, and its
absence or failure must not affect a turn.

### `docs/` and `benchmark/`

Milestone design documents live in `docs/design/`. Most are machine-local
(gitignored), and all are more detailed and more historical than this file.
Tracked contracts and runbooks include `docs/TELEMETRY_CONTRACT.md`,
`docs/RELEASING.md`, and `docs/DEVELOPMENT.md`. `docs/lessons.md` holds the
incident write-ups behind the one-line rules in `AGENTS.md`; the wire contracts are exported
under `apps/fermix_core/priv/{management,realtime}/`. When a milestone is
implemented, update this map only for durable boundaries and invariants, not for
every implementation detail.

`benchmark/` holds the evals that prove the model reaches a capability through
the real agent path: behavioral suites (`benchmark/suites/*.yaml`,
`make -C benchmark regression`) and capability suites
(`benchmark/suites/capability/*.yaml`, `make -C benchmark capability-auto`).

## Cross-Cutting Concerns

### Supervision and Concurrency

Fermix relies on OTP supervision, not service boundaries. The core supervisor
uses `:rest_for_one` because later runtime processes depend on earlier command
hosting, registry, memory, and trace processes. Channel and web apps run their
own top-level `:one_for_one` trees. Inside the channels tree,
`Gateway.QueueSupervisor` is `:one_for_all`: it pairs `Gateway.Queue` with the `Task.Supervisor` its
turn tasks run under, so a Queue that dies takes its turns with it and the
restarted Queue never runs a turn beside a survivor. Nothing then sends those
turns' results, so `Acp.Peer` watches the Queue process it handed each prompt
to and answers the prompt as a failed turn. Mobile's `RequestCoordinator`
fences the request on the Queue it finds after the hand-off and releases it when
that Queue dies (a restart between the hand-off and that lookup leaves the
attempt running until its fence expires). Voice does not watch (accepted: a
call is bounded and the operator can cancel it).

Long-running or blocking work runs under `FermixCore.TaskSupervisor` or a
dedicated supervised process (channel turns under `Gateway.QueueSupervisor`'s
`Gateway.TurnTasks`), and external commands run in a `CommandHost`.
GenServer callbacks should enqueue, delegate, or update state, not perform slow
provider or network work inline.

### Configuration

Runtime configuration is ordinary application env after boot. `config.toml` is
the source of truth: `runtime.exs` hydrates it and applies the boot-time
environment overlays, and live changes go through `ConfigStore.apply_snapshot/2`.
A config section that normalizes strings to atoms ships the inverse, so a save
round-trips. Channel enablement affects both readiness and which long-running
channel clients are supervised.

### Error Handling

Public APIs generally return `:ok`, `{:ok, value}`, or `{:error, reason}`.
Channel controllers translate auth and validation errors into HTTP status codes.
A failed agent turn is logged and traced, closed in history with a stopped-turn
marker, and answered with a per-kind sentence from `TurnRunner.error_reply/1`;
machine surfaces such as ACP receive the raw reason through their turn-result
callback instead.

### Testing

Tests live beside each umbrella app; shared support is in the root
`test/support/` and compiles into core. `mix quality` is the local full gate. CI
runs four legs (Linux and macOS, x64 and arm64) with compile, format, credo, and
`mix test --warnings-as-errors`, plus jobs for the benchmark harness, the release
scripts, and the disclaim shim, gathered by an aggregate `gate` job; CI does not
run dialyzer.

For focused work, run the smallest relevant `mix test` target first, then
broaden before merging. The umbrella runs every child app's tests in one VM, so a
test must not leak global state (see `AGENTS.md`).

### Observability

Telemetry is the common event surface for provider calls, tool execution,
channel messages, agent turns, memory review, jobs, reminders, the harness,
meetings, curation, MCP, plugins, management, voice, computer use, and sandbox
decisions. Durable traces are JSONL. Logs go to `FERMIX_HOME/logs/fermix.log`
through a redacting formatter, rotated at 10 MB with ten files kept.

Architecture Invariant: observability should be added at boundaries where work
enters, leaves, blocks, or fails, through the shared emitters. Avoid scattering
trace writes through pure transformation code.
