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
   function, runs the attachment pipeline (`Gateway.Attachments`: fetch,
   classify, render, transcribe audio), runs slash commands, and hands the turn
   to `Gateway.Queue`, which runs one FIFO turn at a time per conversation.
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
2. `Auth.TokenSupervisor`
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
11. `Cues.Supervisor`, last, only with cues enabled (see `FermixCore.Cues`
    below)

Architecture Invariant: core is the only place where agent runtime state, memory
state, prompt composition, capability state, and provider calls meet. Channels
and controllers normalize input and delegate. Turn scheduling, delivery, and
streaming stay in `FermixChannels.Gateway.Queue`.

### `FermixCore.Agents`: Main Agent and Turns

`MainAgent` is the persistent top-level agent process. It caches a
`RuntimeContext` (bootstrap prompt, prompt memory, operator and guest capability
profiles, runtime section) and hands out turn-state snapshots, freezing the
Computer History gate, the provider routes and, for an owner's chat turn, the
Live call in the chat (`Agents.LiveCallTurn`, asked of `VoiceBridge`) for each
one. The route chain is
built at init, so a provider change needs a restart.

`TurnRunner` runs a turn inside the queue's task: history, preflight
compaction, persisting the user message, `AgentLoop`, `[:fermix, :agent, ...]`
telemetry, and `commit/4` after delivery. Conversation identity is
`Agents.ConversationKey`: `{channel, chat_id, thread_scope}`, with `thread_ts`
as the canonical thread identifier when present. It takes one override, with
two users: Channels names the conversation a message runs in when it is not
the message's own, so the queue lane, the history, the commit and the memory
review all agree. A trusted Live hand-off names it in its `voice_call` map
(`Agents.VoiceCall`, believed only on an operator message on the `voice`
channel); a phone message carries the Mac's chat in `conversation_key`, which
only `Gateway.ingest/2` sets, from the adapter (M56 D9).

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
single source of truth for the supported providers: `openai_codex` (OpenAI
Codex, Sign in with ChatGPT on the person's plan), OpenAI (API key), Anthropic
(API key or subscription OAuth), xAI (API key or Grok OAuth, shown as
SpaceXAI), OpenRouter, Mistral, Venice, and a keyless local Ollama. Each entry names the adapter module, auth modes, secrets,
config keys, and whether the provider supports reasoning effort. Adapters
include `OpenAI.ChatCompletions`, `OpenAI.Responses`, `OpenAI.ChatGPTPlan`
(OpenAI Codex on the public Responses API), `Anthropic.Messages`, and
`XAI.Responses`; OpenAI is `:routed` (model + base_url pick Responses vs
ChatCompletions). OpenAI Codex ships no model catalog: `ModelListing` reads the
signed-in account's list, and after a sign-in `Setup.LiveModel` sets the
configured model to the first listed one when the list does not have it.

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
with mode 0600. Login flows are per vendor (`Auth.ChatGPT`, Sign in with ChatGPT
for `openai_codex`, under the `chatgpt` profile; `OAuthFlow` with a loopback
listener; `AnthropicLogin`, `XAILogin`, and plugin providers through
`OAuthProviders`), and `TokenSupervisor` runs one `TokenManager` per profile.
Every loopback listener a sign-in opens (the provider, plugin and MCP
sign-ins all run `OAuthFlow`) is recorded in `Auth.LoopbackRegistry` while it
is open, with its port, its deadline and the management caller that started
it (M75 D17): a sign-in a desktop started over the rail (router `:actor`
`{:desktop, device_id}`, threaded through `Management.Auth` to the flow as
`:loopback_owner`) is forwarded there by the channels side, which subscribes
to the registry, and a desktop that cannot listen on the port ends the flow
with `{:loopback_forward_failed, failure}` through `LoopbackRegistry.fail/3`.

`Net.HttpClient` sends outbound HTTP on the shared `FermixCore.Finch` pool,
retrying once on a stale socket and never on a timeout. `Net.Egress` decides how
each connection leaves: direct, or through the HTTP proxy `[fermix_core.network]`
names, in which case pooled requests use the `FermixCore.Finch.Proxied` twin and
HTTPS is tunnelled with `CONNECT`. A direct dial tries IPv6 first and falls back
to IPv4 (`Net.Egress.prefer_ipv6/1`). `Net.TimeoutPolicy`
holds the receive timeout for each request kind, `Net.Tls` the verified TLS
options for WebSockets, and `Net.Guard` the public-URL checks. `Net.PinnedUrl`
pins a public URL to the address the guard checked and builds the request to
it (`Host` and the TLS name keep the original host), for `web_fetch`, link
previews and Cue feeds.
`FermixCore.Timeouts` names the non-HTTP deadlines.

Architecture Invariant: core boot aborts if `auth.json` exists with a mode other
than 0600. `Net.TimeoutPolicy` has no default, so an unknown request kind raises.

Architecture Invariant: no connector in the BEAM chooses its own way out. Every
`Req` request is routed by `Net.Egress.attach/3` at its adapter, once per hop, and
a transport that cannot tunnel (the WebSocket clients, the pinned remote MCP
connector, the APNs socket) asks `Net.Egress.ensure_direct/2` and refuses a proxied
route. A proxied request whose proxy fails is an error, never a direct dial.
`Net.EgressSurfaceTest` reads the source of every app to hold this. Processes
Fermix spawns (the browser, coding agents, sidecars, the agent's shell) make their
own connections and are outside it.

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

Architecture Invariant: `Capability.execute/3` is the one invoke boundary (the
agent loop and the realtime voice bridge), and it asks
`Capabilities.AccessGate.admit/3` before the executor. A capability whose plugin
manifest marks it `access_sensitive` runs there only on an attended owner turn,
not from a shared Buzz channel (`Acp.Identity.multi_principal?/1`), that read no
outside content (`:outside_sources`, seeded by `TurnRunner` from
`UntrustedContent.message_sources/1` with a forwarded message and the message's
attachments, a voice note aside, and a Recent Activity note that rendered, then
folded per call by the agent loop from `UntrustedContent.outside_source/3`), or
on a scheduled run whose job names it; otherwise the call is parked in
`AccessGate.Pending` for one owner confirmation, or refused. A built-in marked
`host_command?` meets the same rule where the kernel does not hold commands,
once its turn read outside content. While a parked call waits, the turn (or
Realtime call) that parked it runs nothing else: the loop stamps
`:access_waiting` from the held result itself (the rest of that step included),
the Realtime session from `AccessGate.waiting?/1`, and the gate refuses every
call under it. Every other capability returns on its metadata.

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
`model_routing_config`); memory (`memory_store`, `memory_forget`,
`memory_recall`, `memory_sources_list`, `recall_activity`); scheduled jobs;
dated events and
reminders (`event_*`, `reminder_snooze`); messaging (`send_attachment`,
`react`, and `send_to_channel` to the owner's own inbox on a channel they name);
`generate_image`, `request_directory_access`, and `tool_help`.
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
skill usage and curation, the companion timeline, computer-history rows, and
the inbound channel event ids `Gateway.Idempotency` keeps for 24 hours
(`channel_event_ids`, migration 53, M75), so a provider's retry, or a
Telegram update sent again, that arrives after a restart, or on the new host
after the home moved, is still a duplicate.

Durable memory has two writers, and both end by having `PromptFiles` rebuild
`USER.md` and `MEMORY.md` under `FERMIX_HOME/memory/<agent>/`. `Memory.Reviewer`
is a time-gated background review (daily by default) of the owner's recent
messages that applies add, replace, and archive operations through
`ReviewTools`. `Memory.LongTerm` is the foreground path behind the
`memory_store` and `memory_forget` tools: a save under a category, a correction
by row id, or a forget, applied at once and reported with what actually
happened. `Admission` holds the category and scope policy both writers share,
`Compactor` summarizes long conversations, and `Search` runs FTS5 lookups.

Architecture Invariant: SQLite is canonical for durable memory. Prompt memory
files are derived prompt artifacts, not the source of truth.

Architecture Invariant: memory review runs after the reply is delivered, in a
supervised task. A failed review records backoff state and never turns a
delivered reply into a failed turn.

Architecture Invariant: the owner's memory is the owner's. A guest's turn is
never sent `USER.md` or `MEMORY.md`, never starts a review, and what a guest
says is stored marked as theirs, so no review reads it, in a shared chat
included. A request the owner asked aloud on a Live call is stored marked
spoken, and no review reads it either.

### `FermixCore.Prompt`

Bootstrap files live in `FERMIX_HOME/bootstrap/<agent_id>/`: `IDENTITY.md`,
optional `SOUL.md`, `FERMIX.md` (operating rules; `BootstrapRename` renames a
legacy `AGENTS.md` at boot), `REALTIME.md` for realtime voice sessions,
`LIVE.md` for the Live voice frontend, and `GROK.md` for the Grok one.

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
browser, journals, realtime, mobile, traces, logs, and `memory.db`); it keeps
`mobile` at 0700, the only mode the phone's trust store reads. Secrets live in
the OS keychain, named by profile rather than by home. Every write of
`config.toml` (a settings save, the web port, an MCP server write) holds one
cross-VM lockfile from its read to its write, and the `[mcp.servers.*]` blocks
are read, edited and checked by `Capabilities.MCP.Config` and rendered back by
the same renderer, so no save drops an operator's servers.

`Setup.Wizard` is the shared setup engine. `fermix setup` and `mix fermix.setup`
(through `Setup.Runtime`), the setup LiveView, and the management protocol's
`settings.*` methods all persist through it. `Readiness` reports which required
setup is missing, with the gating and pane keys the setup surfaces use. `Health`
combines cached readiness (`Setup.BootReport`), channel, provider, and realtime
status, restart state, and the version into the runtime health report.

Architecture Invariant: setup logic belongs in core. The CLI, web, and app
surfaces collect answers and call core.

### `FermixCore.Home`: the primary, its epoch, roles and moves

A home is the one primary copy of Fermix, and `FermixCore.Home` holds what
makes it movable. `Home.Epoch` is the primary epoch (`mobile/primary_epoch`):
1 from the home's first boot as the primary, one more on every move or
restore; both handshakes announce it and a client that has seen a higher one
is refused as `stale_primary`. `Home.Moved` is the marker (`moved.json`) that
retires a home as the primary. `Home.Role` is the role: `[fermix_core.engine]
role` (`primary`, the default when absent, or `device`), resolved by
`Role.remember!/2` as the first call of `start_supervision_tree`, before
anything writes to the home; a marked home refuses to boot as the primary by
name. `Role.children/2` filters both supervision trees from one named list
(`Role.primary_only_reasons/0`), and `Role.admit/1` is the one refusal for
turns, provider calls, token refresh and memory writes in the device role,
with `Role.admit_configured/1` answering the same question tree-less for the
sign-in verbs. `Home.DesktopLink` is a moved desktop's link to its primary
(`device/desktop.json`, `device/desktop_key`): the move worker writes it, the
desktop relay reads it, and `DesktopLink.linked?/2` decides once per boot
whether the daemon forwards primary-class management requests
(`Management.Placement`, the one table of device-class methods and settings
sections; the home's recovery, enrollment and move are primary-class) through
`Home.Link` and whether the companion socket tunnels. `home.status` and
`settings.sections` are composed (`Placement.composed?/1`): the device answers
its own part and the router adds the primary's through the daemon's
`:primary_forward` (`Placement.primary_part/2`, within 5 s), or the sentence
in `primary_missing` while it is missing; the primary answers a forwarded one
as its own. `Placement.forward_deadline_ms/1` is the one table of how long a
desktop waits for a forwarded answer (8 s; 60 s for `home.move.readiness` and
`home.move.start`, which walk the whole home first), and a forwarded
`home.move.start` the primary had whose answer was lost is `unconfirmed`
(`Placement.unconfirmed/2`), never a failure.
`Epoch.initialise/1` runs after `ConfigStore.ensure_workspace`
on a primary boot and is the only writer of the first epoch. `Home.Archive`
seals a stopped home (manifest, PBKDF2 key, AES-256-GCM) minus
`Home.DeviceLocal`, the single list both export exclusion and restore refusal
read; `Archive.RestoredConfig` rebases the old home path, resets coding-harness
consent and moves a keyring-mode home to the file store on a keyring-less host
in the restored `config.toml` through `Archive.ConfigText`, `Archive.ScreenHistory`
clears computer-history rows from the restored database, and a restore writes
the archived epoch plus one. `Home.Snapshot` is the streaming twin of the
archive: `write/4` captures a running home (`Snapshot.Capture`: the archive's
`collect/2` set, each file copied once while hashed, `memory.db` by
`VACUUM INTO`, never the live WAL) and streams the stage-1 manifest and the
files through `Snapshot.Format` (`FXSNAP1`: X25519 to a `Snapshot.Recipient`,
HKDF, AES-256-GCM in 1 MiB chunks with the index and the last-chunk flag in
the associated data) into a file or a function; `restore/4` decrypts into a
private staging directory inside the empty root and hands the verified files
to `Archive.install/5`, the one restore path both share. The recipient is the
public half of a key derived from the recovery passphrase (PBKDF2, as the
seal); the passphrase is never stored. `Snapshot.Scheduler` (primary only,
`Role`) runs `Snapshot.Run` every `[fermix_core.snapshots] interval_hours` to
each `Snapshot.Target` (`Snapshot.S3`: SigV4 `PutObject` with
`x-amz-checksum-sha256`, streamed through `Net.HttpClient`; then the targets
`:snapshot_targets` injects, `FermixChannels.Desktop.SnapshotTarget`, the
connected desktops over the rail) and is the one
writer of `snapshots/status.json` (`Snapshot.Status`: per attempt the
recovery key it was written for, and `waiting` for a target that takes it at
a later run, a sleeping desktop), which
`Management.Home` (`home.*`, answered locally in every role) and
`fermix home status` read. A capture needs about twice the home free
(`Home.Disk`, which reads `df -Pk`'s available column so that a space in a
filesystem's name or mount point moves nothing) and is refused by number
otherwise. `Home.Disk.usage/2` reads how full the home's filesystem is (used
over used plus available) and whether it reached 85%, where the disk warning
of M75 L14 starts. The
companion request store settles a request another boot started, or anything
in flight after the epoch changed, as `uncertain` rather than re-running it.

The Always On move (M75 §7) adds a third role, `candidate`: a fresh server
that `fermix home enroll` (`Home.Candidate.enroll/3`, tree-less) made one from
an enrollment code (`Home.EnrollmentCode`, `fxenroll1.`), with its own keys,
facts and phase under `<home>/candidate/`. `Role.children/2` keeps only
`Role.candidate_keeps/0` for it (the command host, which the offer's `df` and
the restore's keyring probe run under, task supervisor, trace, the daemon socket
and its stop path, `FermixChannels.Home.CandidateSupervisor`, and the web app's
endpoint-less children; `CandidateTreeTest` runs a move's candidate side in a
VM holding only those); `start_supervision_tree` writes nothing into its home
and initialises no epoch, and the router answers it `hello` and `home.status`
alone. The primary opens the window through `Home.Link` and keeps candidates
in `mobile/candidates.json` (`Home.Candidates`, at most four, 24 hours);
`Management.HomeMove` answers `home.enroll.open`, `home.candidates.list`,
`home.move.readiness`, `home.move.start` and the `enrollment`, `candidates`
and `move` places of `home.status`. `Home.MoveReadiness` is the report the
owner reviews (keychain secrets, a secret it cannot read named as its
settings row labels it, `Management.Settings.secret_names/1`, the one reading
of those labels, never by its id; engine versions, free disk, the S3 upload
bound, the plugins the catalog has no build of for the server, what stops:
those of iMessage, voice calls and meetings the home has turned on
(`MoveReadiness.stays_here/3`, which the summary's `off` line reads too),
WhatsApp, and Slack without Socket Mode;
coding agents asking for approval again, read from `config.toml`; the
cutover gap) and
`Home.Move.start/5` refuses while an item blocks; the review is kept in
`.move/readiness.json` and a start within 15 minutes of a ready one takes it
(`Move.review/3`), so a move reads the keychain in the review and once more in
its capture, never a third time. `Home.Move` is the source's
`.move/` (request, phase, the kept review) and writes the device role with
`ConfigStore.put_engine_role/2` (one line of `config.toml`, under the config
lock) before the restart, which is the daemon's deliberate self-restart
(`Lifecycle.restart_self/0`: on a systemd user unit the start budget is reset
first, then the one stop path) that launchd or systemd brings back; the boot
after it records the move's ending (`Move.finish_at_boot/2`; a write that
fails there is tried again at each `home.status` read, whose sentence says why
until it is recorded, `Move.view/3`, only in the engine whose boot left it
unrecorded), never the engine about to stop. `Home.MoveSecrets` reads the
keychain's value of every `@keyring` reference before the move's capture and
hands them to it as file store entries that exist only inside the encrypted
stream; on the candidate
`Home.Candidate.Activation` restores the stream into `candidate/staging`,
turns each carried reference into `@file`, and later renames it into place,
`config.toml` last, asking the new primary's first boot for a snapshot at
once. Its staging names the plugins the stream brought from another system
(`Plugins.Dist.Reinstall.request/2`, `plugins/reinstall.json`, device-local),
and the new primary's first boot installs each again at its locked version
through `Dist.Installer.run_install/2` (`Dist.Reinstall`, a `:temporary`
primary-only child right after the installer, so a crash restarts nothing
under `:rest_for_one`); one it could not install is the plugin status
`reinstall_failed`, one with no build there `incompatible`, until an install
records another build. `Dist.Index.target_artifact/2` is the one rule for
which build a host installs, shared by the installer and the readiness.
`Home.MoveTelemetry` emits the move's bookends. `home.status`'s
`secrets_missing` names the references that did not resolve on the primary
(`MoveSecrets.missing/1`). The channels half
(`FermixChannels.Home`) is described under `fermix_channels`.

`Home.Provision` is the contract every cloud provider Fermix creates the
Always On server on implements (M75 lean v1 §4.3), and the place a new
provider plugs in: a module of its `@callback`s (`id/0`, `display/0` with
the name, token label, How to get one steps, console URL, docs anchor,
locations and the proper nouns its words use, `type_name/1`,
`check_token/2`, `reaches/3`, `options/2`, `create/3`, `power/3`,
`reconcile/2`, `delete/2`, `delete_replaced/2`) listed in
`Provision.Registry`, a compile-time list. `Provision.Hetzner` is the one
provider today: Req over the Hetzner Cloud API through `Net.HttpClient`,
and everything of Hetzner's (endpoints, label rules, price parsing, error
codes, locations and cities, the image, the 32 KiB user data limit, the
root-password drop) lives there only. A provider answers its own refusals
as one of the contract's closed shared kinds (`:unauthorized`,
`:read_only_token`, `:account_limit`, `{:unavailable, capacity}` with the
next location in stock, `{:rate_limited, _}`, `{:unreachable, _}`,
`:other_project`, or `{:other, sentence}`, the provider's own plain
message), and `Provision.error_sentence/2` words every reason in the
provider's display data, so the shared code (`Provision`, the ledger, the
job, `HomeSummary`, `Copy`, `Management.Provision`, the router) names no
provider, which `provider_contract_test.exs` holds by scanning every lib
file and by running the shared code on an invented second provider.
`Provision.current/2` is the one resolver of which provider Always On
speaks of: the one whose ledger holds what Fermix created (or cannot be
read), else the one whose token was given last, else the first the registry
offers. A provider's token and the ledger of what was created on it live in
its own file, `device/provision/<id>.json` (`Provision.Ledger`, `0600`,
device-local, never `config.toml` or the keyring, so a move never carries
it), which is how the ledger records which provider each resource belongs
to, written before each call that creates or deletes and updated after it.
Every write is `Ledger.update/3`, which holds the file's lock across its
read, change, write and rename (never across a call to the provider); `Provision.Ledger.Lock`, one supervised owner in the
primary's and a desktop's tree, serves writers in the order they asked, each
the moment the one before is done or exits, with no retry or backoff, and
refuses only a writer whose turn has not come in 30 s. `Provision.FirstBoot` embeds `packaging/cloud/first-boot.sh`
at compile time and wraps it, gzip and base64 with its SHA-256, as the
server's cloud-init user data, the enrollment code in `FERMIX_ENROLL_CODE`,
refused past the limit its provider passes in.
A create checks the type against the live stock, makes the firewall (the
first write, where a read-only token fails before anything costs money),
opens a provisioned enrollment window (24 hours; `home.enroll.open` is
refused while it is open, and while the server it enrolled is held as a
candidate), creates the server named and labelled by the
ledger's ref, and polls each action with a bound; a create whose answer was
lost is found again by its labels in `reconcile/2`, which also marks a
resource deleted outside Fermix gone. `Management.Provision` answers
`home.provision.*` (device-class in `Placement`: the computer that created
the server manages it and never forwards the request):
`home.provision.providers` answers each provider's display data, so the apps
draw the token and choose screens from it; connect, options and create name
the provider; power, resources and delete act on `Provision.current/2`'s;
connect, create, power and delete are owner decisions in the daemon, a new
token replaces the kept one only when it reaches the ledger's server or
firewall (one read by id, the same account), a create is refused while any
provider holds a server, and create, power and delete run as one
`home_provision` management job at a time; delete refuses while a move to the server runs
and once this engine is its linked desktop (or the home carries the moved
marker). `Ledger.state/3` is the one reading of the provisioner for `home.status`'s
summary: none, connected, creating, created, deleting, gone, failed (with the
reason) or unreadable, beside whether the token is still accepted. The apps
poll `home.status`, so everything it reads on each poll (the ledger, the
settings its summary reads, `MoveReadiness.stays_here/3`, the primary's
disk, the last review of the move and each copy a desktop stores) logs a
failure to read it through `Home.UnreadableFiles`, a supervised memory in
every role's tree: once when it stops being readable and once, with the
failed reads counted, when it reads again; a verb with no engine tree passes
no memory and logs its one read.

A provider served by an external plugin is not built. It would be one more
module of the contract in the engine, listed in the registry, that forwards
each callback to the plugin; what the engine keeps for every provider stays
in the engine: the token's custody (read from the provider's ledger and
passed with each call, never stored by the plugin or seen by a command, as
`device/` is denied to the sandbox), the owner's decisions over connect,
create, power and delete (the daemon), the enrollment code's window, the
display data the apps draw (answered from the plugin's manifest, held to the
copy rules), and the ledger. Since `create/3`, `reconcile/2` and the deletes
write the ledger themselves today, their write-ahead steps would first move
out of the provider module into a shared driver, so the plugin answers
single steps (create the firewall, create the server, read one resource,
delete one, power one) with the shared error kinds, and no plugin ever
writes a ledger.

`Management.HomeSummary` is that summary (M75 lean v1 §7): `gather/5` reads
the provider in use and its ledger, the last kept review (`Move.last_review/1`) and a desktop's stored
copies beside the record `Management.Home.status/1` already holds (the role,
the move's phase, the candidates, the rail's window and link, the snapshots,
the primary's disk, `Home.Disk.usage/2`, and a linked desktop's composed
`primary_home`, or `Placement.primary_part/2`'s `too_old` when the server
refused this engine's protocol), and the pure `summary/1` answers `{state,
sentence, action, detail}` in `Management.Copy`'s words and the provider's
display data, which `CopyTest`
holds to the copy rules and to `Copy.summary_violations/1` (no internal word,
no backticked code), as it does every sentence the summary prints as it is
from elsewhere: it sweeps the provisioner's refusals, the ledger's, the
readiness items and the code refusals a create keeps as its failure (the
enrollment window's and `Home.Link`'s), each template and `<>`-joined
sentence rendered whole. The two times it
counts are awake time on the monotonic clock: how long the created server's
window has been held (`Enrollment`'s `awake_ms`, 30 minutes) and how long the
desktop relay has had no session (`Relay`'s `down_ms`, 10 minutes). On a
linked desktop a replace of the server (`Ledger.state/1`'s `replace`) leads
while it runs, read with the old server's own window and candidates from
`primary_home` (the new server's 30 minutes count from its creation, since
its code lives on the old server, which never sleeps); until the move is
done the old server is the one the home lives on, and the power actions,
which reach the new one, are not offered for it. The snapshot scheduler tells the paired phones, once per occurrence (the point
kept in `snapshots/status.json`'s `stale_notice`), when the newest verified
snapshot passes 7 days, through the phones' own path: a message in the
owner's phone chat (`ChannelSend` to `mobile`, its proactive key the point).

Replace the server (`home.provision.create {replace: true}`) runs on the
linked desktop whose ledger holds the server the home lives on. The job sets
that server aside in the ledger (`Ledger.begin_replace/3`: the old set and
the primary epoch it held, from `desktop.json`), then creates the new server
as any create does, under another ref (`Provision.fresh_ref/2`), with a
provisioned window the old server opens for a request the desktop forwards
(`home.enroll.open {kind: provisioned}`, served only to a desktop's forward;
`home.enroll.withdraw` releases it when the new server will not exist). The
move is the existing one, forwarded; beside the forward of `home.move.start`
the daemon records that the move started (`Provision.move_forwarded/3`),
because the old server serves nothing while it runs. The desktop relay
reports every primary epoch a session reaches (`Provision.primary_reached/2`,
in a task): one above the old server's is the move to the new one done, the
desktop's link names the new server from then on (`Home.Link`'s
`rename_primary/1`, the relay writing it with `DesktopLink.record_name/3`, so
the relay stays the one writer of `desktop.json`), and the old server is
deleted, once, as a `home_provision` job
(`Provision.delete_replaced/2`, the same order as any delete, refused unless
the move is done); a failed delete stays in the ledger with its sentence for
`home.provision.delete` to try again, and the old server answering at its own
epoch after the move started is a move it undid. `Ledger.state/1`'s `replace`
says where it stands: creating, waiting, moving, deleting, done, failed (with
which server holds the home) or cancelling.

Architecture Invariant: one role gate, one epoch writer, one marker, one
device-local list, one placement table; a linked device's request takes one
path, here or the primary, never both. A device-role engine makes no provider call and refreshes
no token. One restore path (`Archive.install/5`) for an archive and a
snapshot, and one writer of the snapshot status. A candidate never activates
without `move_commit`, and a source sends `move_commit` only after its moved
marker is written: at every crash and lost message at most one engine serves
as the primary (`tla/specs/home_move`). A move is aborted only while the
marker is absent; after it, it is only ever resumed. A candidate takes only an
offer later than the move it holds (move ids ordered by start, then the
attempt), so a late offer never un-stages a home its source retired for. The
move's ending (`done`, `aborted`) is written only by the engine that came
back after the restart. A move's keychain values exist only in memory and
inside the stream encrypted to the candidate's one-time key. The
provisioner's tokens never leave the computer that pasted them, and a
provider's root password for a created server (Hetzner's) is read for nothing. A replace deletes the
old server only once a primary of a higher epoch answered this desktop, never
the server that holds the home.

### `FermixCore.Trace` and Telemetry

`Trace` writes one `<type>.jsonl` file per UTC day under
`FERMIX_HOME/traces/YYYY-MM-DD/`. `Trace.TelemetryHandler` bridges telemetry
events into those files. `FermixCore.Telemetry` owns correlation IDs and content
capture, which is on unless `FERMIX_TRACE_CONTENT=0`. Tools emit through
`Tools.Telemetry.exec/5` and provider calls through
`Providers.Telemetry.emit_call/3`; `docs/TELEMETRY_CONTRACT.md` is the contract.
The local Doctor reads the `llm_call` rows back: `Setup.ProviderHealth` judges
the primary provider from its recent calls, and finds them through
`FermixCore.Application.trace_dir/0`, the resolver the `Trace` child starts with.
`Trace.Retention` keeps the store bounded on every machine (M75 L14): when `Trace`
starts and every hour, after closing the files of earlier days, it removes whole
day folders older than 14 days, then the oldest until the rest fit in 1 GiB, at
most 32 a pass, never today's or a later day's, and nothing but a folder named as
a date that holds only `.jsonl` files (and hidden ones).
The bounds are constants, not settings. On an Always On server (M75 L20;
`Home.AlwaysOn`: the primary of a home that moved or was restored onto a host
running the Linux package with no Fermix app, decided at boot) `Trace` starts
with `separate_bodies: true` and writes a record that carries a body
(`Trace.body_keys/0`) twice: without its bodies to `<type>.jsonl` and whole to
`<type>.bodies.jsonl`. Each pass first removes the bodies files of every day
before yesterday (`Retention.prune_bodies/3`), so a server keeps bodies about a
day (through the previous UTC day) and the records 14. Readers of trace rows (`Setup.ProviderHealth`, the Doctor's
sandbox check, `FermixOpik.TraceFile`) read `<type>.jsonl` and need no body.

Architecture Invariant: trace writes are best-effort. `Trace` is an early child of
core's `:rest_for_one` supervisor, so it never raises on its I/O: an entry it
cannot encode, open or write (a full disk's `:enospc`) is dropped, a failure to
open or write is logged once when it starts and once when a later entry is written
again, with the count dropped, and each new entry tries again.

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
owner's inbox, the first one or the one on a named platform (a transport only
the owner reaches names its own through its adapter's `owner_inbox/0`).

Architecture Invariant: a delivery destination is resolved once, at acceptance,
and stored on the row; send time resolves only the adapter. A send watched by
`ChannelSend.with_timeout` is linked to its caller, so it never outlives it.

Architecture Invariant: a job is `running` only while one of its runs is queued
or running. The claim takes the job and inserts the run in one transaction, and
`Repo.settle_job_run` writes the run's final row and releases the job in
another; owner edits write only the columns they own.

### `FermixCore.Cues`: Cues and Watchers

`Cues` turns push input into agent work. Its tree starts at boot only when
`[fermix_core.cues] enabled` and memory are on (`Cues.enabled?/0`); everything
that asks at runtime (a tool's advertisement, the scheduler's admission) asks
`Cues.running?/0`, whether the tree is alive, so a live flip of the switch
changes nothing until a restart. `enabled` and `door_port` are boot-bound
(`Setup.RestartState` says so); sources are reconciled on every config apply
(`Cues.SourceManager.reconcile/0`), and mandates and the routing `filter_*`
keys are read at each call. The path of one item:

1. A feed, a webhook or a local push hands items to `Cues.Ingest.accept/3`: the
   door (`Cues.Door`, Bandit on `127.0.0.1:door_port`, routes in
   `Cues.Door.Router`: local-push CloudEvents on `/cues/v1/:ref`, webhooks on
   `/cues/hooks/:ref/:random`, verified by `Cues.Webhook`), or
   `Cues.Source.Feed`, a worker under `Cues.SourceSupervisor` that polls with
   each hop pinned to the address `Net.Guard` checked (`Net.PinnedUrl`) and
   feeds the body to a `Cues.FeedParser` reader as it inflates, XML read one
   item at a time by `Cues.FeedXml`, so a feed's length bounds its work but not
   its memory. An X accounts feed (`Cues.XAccounts`) builds its search address
   from its handles, signs in with the X plugin's token and reads X's answer as
   one JSON document. A stream takes the path below instead. `Cues.SourceManager`
   starts and stops the workers to match the config. A JSON API feed, a webhook
   and the general stream read messages by the same dot paths
   (`Cues.JsonPath`).
2. Accept and route are one Repo transaction: the identity check, the cue row,
   one `cue_deliveries` row per enabled watcher the item is routed to, inbox
   eviction with its gap, and the wake-ups after the commit. Routing is by
   words (`Cues.ListenFor`): a `none` watcher gets every item (`passed`), an
   `llm` watcher only one its words to listen for match (`pending`), and an
   item no watcher took is a receipt (identity and hashes, no payload). The
   transaction is bounded: a Repo that does not answer in time is an error, a
   failed poll for a feed and a `503` with `Retry-After` at the door, never an
   exit.
3. `Cues.Filters` claims at most one delivery per `llm` watcher (four calls in
   all) and runs `Cues.Filter.Llm` under `Cues.FilterSupervisor` on the one
   Cues filter model (`[fermix_core.routing] filter_*`), else the main route at
   low effort; each call writes its own fenced settle.
4. `Jobs.Scheduler` admits passed deliveries through `Jobs.CueAdmission`:
   `Repo.claim_cue_run/4` claims the job and the delivery and inserts the run in
   one transaction, at most three cue runs at once, oldest eligible delivery
   first, and a delivery waits behind every older live delivery of its watcher
   with the same subject. `Jobs.Runner` runs it as a cue run (`Jobs.CueRun`, on
   the surface `Jobs.CueSurface` names), and `Repo.settle_cue_run/3` writes the
   run, releases the job and moves the delivery in one transaction.
5. A mandated tool call meets `Cues.MandateGate`, the first `AccessGate.admit/3`
   clause for a cue run: switches, freshness, the hourly limit, the pins
   (`Cues.Pins` holds the owner's approvals), `pin_args`, then the owner's
   validator (`Cues.Validator`, whose answer is the last line of its standard
   output). Approve mode goes through `Cues.Proposals` and the gateway's
   `/confirm`.
6. `Cues.Sweeper` expires, prunes and reports (retention, the 48-hour counts,
   proposal expiry, unknown proposal outcomes, gap notices); `Cues.Notices`
   tells the owner once per episode.

A stream's item is judged before it is stored (M60_CUE_INTAKE_AT_SCALE.md).
`Cues.Source.Stream` holds a WebSocket through a transport behind
`Cues.Source.Stream.Transport`, reading it with `Cues.JsonStream`, the general
source that signs in with the owner's key and secret and cannot rewind. It
never calls `Cues.Ingest`: each item goes through the words of the source's
`llm` watchers (an item none matched is counted `unmatched`; a stream routes
nothing to a `none` watcher), then through the rate buckets and the daily
budget, and is offered to `Cues.LiveFilters` with the watchers it matched. The
worker reads its watchers and what a live call needs at connect and on its 10 s
flush, which also writes its counts (`Cues.Counts`, into `cue_counts` as the
hour's absolute totals per incarnation) and the source's row; a row write that
fails closes the connection, which is dialled again. `Cues.LiveFilters` keeps a
live queue of at most 250 items per watcher in memory and runs at most four
calls (never two for one watcher's subject) under
`Cues.LiveFilterSupervisor`. It makes no synchronous Repo call: each call's
task writes its own result, a pass as one transaction (`CuesSql`'s
`{:pass_live, …}`: the cue if its identity is new, this watcher's `passed`
delivery, the call's ledger row) that wakes the scheduler, a drop or a failure
as the call's ledger row (`delivery_id` null) and the watcher's backoff, so the
filter budget and the hold count live calls as they count stored ones. Drops,
overflow and failures become counts; the last 50 drops per watcher stay in
`Cues.RecentDrops` (ETS) for labelling. From the `passed` delivery on, a
stream's item takes steps 4 to 6 like any other.

`Cues.Supervisor` is the last child of the core tree, so a crash of the job
scheduler or anything before it restarts the cue tree, which re-reads its rows,
and a crash inside it restarts nothing outside. It is `one_for_one` over four
children: the live group (`rest_for_one`: the live task supervisor, then
`Cues.LiveFilters`, first so a stream's watchers always reach it), the intake
group (`rest_for_one`: `Cues.Buckets`, the ETS owner for
token buckets, door slots and secret fingerprints, then the source supervisor,
the source manager and the door), the filtering group (`rest_for_one`:
`Cues.Filters`, then the filter task supervisor, so a dispatcher crash ends its
calls) and `Cues.Sweeper`. The door is in core, not in `fermix_web`, so it exists
under `--no-web` and in eval homes; a port in use leaves it `unavailable`, never
a crashed tree. Rows are the truth: every durable fact is a row in `memory.db`,
a process holds only timers and work in flight (a stream's live queues, recent
drops and the counts since the last flush are such work, lost with their
process by design), and the boot sweeps put a
`filtering` delivery back to `pending` without spending an attempt and reap the
runs a stop interrupted. No GenServer callback makes a provider call or a
channel send: filter calls run as supervised tasks and sends go through the
delivery layer with their timeouts.

Architecture Invariant: no text from outside reaches a notice, a source's
status or a source row. A stream service's error message goes to the log and,
behind the content gate, the trace; the source's status and notices are
Fermix's own sentences, so `list_cues` reads sources without tainting a turn.
A stream's secrets are read at each connection and kept in no process state.

Architecture Invariant: a cue is data, never an owner message. It never enters a
conversation, and its text reaches a model only framed as outside text
(`UntrustedContent`, label `cue:<source>`).

Architecture Invariant: a cue run is tainted from its first token: its context
carries the cue as an outside source, so the access gate refuses every
access-sensitive command outside an approved mandate, and no consent check
passes in it.

Architecture Invariant: nothing a cue run reads reaches the owner's memory. A
cue run writes no memory review input, profile or job summary; task notes are
their own rows (`source_type` `cue_task`) that only that task reads.

Architecture Invariant: every delivery transition is fenced. `CuesSql.transition/6`
compares the row's state and its fence (`filter_call_id` or `claimed_run_id`);
zero rows changed is `{:error, :stale}`, so a late write after a sweep or a
restart is refused, never retried blindly.

Architecture Invariant: a proposal runs at most once and only on the owner's
confirm: one update matches `waiting`, the token's digest, the chat and user it
was sent to, and an unexpired time. A call is proposed at most once per cue (the
proposal's idempotency key, over the mandate, tool, arguments and cue, is
unique), so a denied, expired or unreachable proposal is final for that cue. A cue run whose `job_runs.tools_started_at`
is set (an allowed mandate call or a proposal) is never retried.

### `FermixCore.Checklists`: the owner's lists

A list (M85) is the owner's own record of things to tick off: a list per
project in a folder such as Projects, sections inside, items with an optional
note. Its rows live in `memory.db` (`checklists` and `checklist_items`,
migration 56, `Memory.Repo.ChecklistsSql`), and `Checklists.Registry` is
their one writer, a module over the Repo, never a process. The model sees a
list only as markdown: `checklist_read` renders it (`Checklists.Render`, each
row with its `[n]`), and `checklist_edit` takes a call of changes, a list
each with its ops, which the Registry checks in the caller, `Checklists.Parse`
reading a `replace`'s markdown back into rows, and hands to the Repo whole,
where `Checklists.Ops`, pure, applies it to the rows the transaction loaded.
`Checklists.Note` is the per-turn rules line and the line naming the lists,
which `TurnRunner` appends beside the date note, and `ReplyBlocks` keeps the
lists a turn touched for its reply's `checklists` block.

Architecture Invariant: one `checklist_edit` call is one transaction: every
change lands or none does, each list it changed moves its `rev` once, and a
row's `n` is never reused within its list.

Architecture Invariant: the lists are the owner's. `Checklists.Access` admits
only the owner's private turn or voice call, and a scheduled job whose allowed
tools name the tool; the tools are left out of the cached capability catalog,
which an owner's group chat shares, so a shared turn sees no list tool, line
or name. After a turn read outside content, rows it writes are stamped and
framed when read back, and its removals, replaces and moves to another list
are refused.

### Sandbox and Command Execution

`FermixCore.Sandbox` is an in-process policy gate over paths, working
directories, and shell plans. Modes (`strict`, `standard`, `open`) expand to root
sets, command profiles (`bare`, `assistant`, `extended`) pick the allowed
commands, and `Hardline` refuses catastrophic commands. `Sandbox.Env` resolves
`[sandbox.env] allow` one name at a time, and `EnvHealth` records misses for
readiness. The owner-gated `request_directory_access` tool plus `/confirm
<token>` can grant a denied directory. `Sandbox.OsSandbox` also wraps every
command a turn runs (the shell tool, the command tool, the git tools) so the
kernel holds it to the mode and keeps Fermix's home, secrets and keys out of
its reach; `Sandbox.confine/4` is the one entry point and `OsSandbox.unreadable/1`
the one read-deny list (every entry write-protected too; nothing on it sits in a
temp folder, which Landlock could not close without closing it whole, so the
Secret Service writer stages a key being saved in `secrets/.staging-N/`). On macOS that is
`sandbox-exec` with a Seatbelt profile built from the same roots. On Linux it is
the `fermix_landlock` exec shim (`apps/fermix_nif/c_src`, built like `disclaim`:
strict flags in lockstep with `ci.yml`, zig per release target through the
Burrito target's `LANDLOCK_TARGET`), which checks the Landlock ABI (below 3
refuses, since ABI 2 cannot refuse a truncate), starts a session of its own
(an Erlang port's child already leads one), sets `no_new_privs`, adds one rule
per argument and execs the command. ABI 5's device ioctls (granted to the
terminals only) and ABI 6's signal and abstract-socket scopes are asked only
of a kernel that has them. `Sandbox.Landlock` carves the rules folder by folder around the
protected paths, since Landlock only grants, and the shim refuses every command
by name on a kernel that cannot hold them. Doctor's `os sandbox` row checks
either kernel. Where `OsSandbox.enforced?/1` is false (another system, or Linux
without Landlock ABI 3), a built-in marked `host_command?`
(`shell`, `git_write`, a declared command) in a turn that read outside content
goes through `Capabilities.AccessGate` like an access-sensitive plugin command.
One that runs unconfined everywhere
(`host_command_confined?` false: the `codex`/`claude_code` presets and the
coding runs `codex_run`/`claude_code_run`) goes through it on every platform;
the next run a finished coding run's follow-up turn starts with the same coding
agent in that run's own starting folder (both read from its ledger row), once
per finished run (the admit links the child to it in
`harness_run_continuations`, beside `harness_runs`, and refuses a second
chained child in the same transaction) and with
only its task, folder, model, effort and limits, dispatches
there labelled `chained`. A request re-run after the owner's `/confirm` (a
directory grant, a vendor-config acknowledgment) carries what its parked turn
had read through the gateway's resume intent, and the resumed turn starts from
it. A chain's metadata (`harness_continuation`, its depth, the finished run) is
kept only on what the continuation dispatcher or the grant resume ingests
(`keep_chain_metadata`); the gateway drops it from every other message, as it
names the conversation.

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
those servers and the operator's own `[mcp.servers.*]` in isolated subtrees.
An operator stdio server runs over `Capabilities.MCP.StdioTransport`, which
reads its secrets in its own process, builds its environment, finds its program
on the login shell's `PATH` (`Capabilities.MCP.LoginPath`) and is its
`RuntimeStatus` owner; a plugin's `local_stdio` server runs over Anubis's own.
An operator `http` server runs on the same remote rail as a `remote_mcp`
plugin, one `Remote.Owner` and `Remote.Session`, with its endpoint from the URL
the owner typed (`Remote.Endpoint.operator/1`, checked under `Net.Guard`'s
owner policy) and its headers from `Capabilities.MCP.Secrets`; with no signed
contract, its tools register as a stdio server's do.
The owner manages operator servers over `daemon.sock` (`mcp.servers.*`,
`Management.McpServers`): every write goes through the one `ConfigStore` MCP
writer, and `Management.McpServers.Row` is the one owner of a server's row,
composed from its block, its stored values, its `RuntimeStatus` entry (which
keeps what its last discovery found, the server's `serverInfo` and its tools
described) and whether its subtree still runs. What the owner pastes into the
add form (a URL, a command line, another app's configuration block) goes
through one translator, `Management.McpServers.Interchange`, which takes text
and never reads a file; the values a paste carried are held in memory only, by
`Management.McpServers.DraftValues`, under a boot-bound `draft_id` an add
redeems. An import reads other apps' settings files only when the owner asks
(`Management.McpServers.ImportSources`, fixed paths under the home folder,
each bounded and parsed whole), translates each server it finds with the same
translator, and adds it through the same add path.
Fermix is only ever an MCP client: it does not expose its own tools as an MCP
server.

Architecture Invariant: MCP clients are keyed by source (`{:plugin, name}` or
`{:operator, name}`), and a `remote_mcp` plugin loads only from a
cosign-verified install.

### `FermixCore.ComputerUse`, `ComputerHistory`, and `Browser`

`ComputerUse` controls the desktop through the `compux` sidecar (macOS arm64
and Linux x86_64). `ready?/0` (enabled and sidecar installed) is the one gate for
both the `computer_use` tool and `ComputerUse.Supervisor`. `SidecarInstaller`
fetches a sha256-pinned binary into `FERMIX_HOME/plugins/compux/`, and `Safety`
refuses state-changing actions under strict access and host sessions outside an
attended chat or voice turn. `SessionManager.ensure/3`, the one door a session
opens through, also refuses a turn from a shared Buzz channel
(`Acp.Identity.multi_principal?/1`) before the Stop hold and the registry lookup.

`ComputerHistory` is an opt-in, macOS-only recorder. It captures interaction
events through the same sidecar and summarizes them on the device into memories
that `recall_activity` reads. `ComputerHistory.Gate` decides where history may
flow, and `MainAgent` snapshots it per turn.

`Browser` runs the `browser` tool: managed Chrome over the DevTools protocol,
without compux. `Browser.Supervisor` holds a `ProfileManager`, which caps live
Chrome instances, and one `ProfileServer` per owner key and profile, where
`Browser.Scope` keys every operator-trust conversation, scheduled run and
worker to the one `owner` key and each guest conversation to its own; a
context without a trust fact is refused. The server is
the backend-neutral half (lazy lifetime, idle reaping, one request at a time,
the mode's capability refusals); everything that talks to a browser sits behind
the `Browser.Backend` behaviour, whose CDP implementation (`CDP.Backend`)
launches Chrome lazily and shuts it down on every exit path. On macOS, Chrome
launches only through the `disclaim` shim from `fermix_nif`; on Linux, through
`/bin/sh`, which raises its own `oom_score_adj` to 1000 and execs Chrome, so out
of memory the kernel stops a Chrome process before the engine.

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

### Companion Protocols: `Management`, `Realtime`, and `Companion`

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
`priv/realtime/`). The configured model picks the engine, and
`SessionControl` the session that owns the call. `SessionServer` runs OpenAI
Realtime with tools through `ToolBridge` and optional screen perception. The
two task engines execute no tools and hand every task to an agent turn through
the `VoiceBridge` behaviour, implemented in channels by `Voice.Bridge`:
`LiveSessionServer` runs OpenAI Live, and `GrokSessionServer` runs SpaceXAI's
Grok Voice behind its one `fermix_task` function (`GrokTaskCall`), with
`GrokTurn` the one arbiter of a continuation, client-reported playback
(`GrokPlayback`, wire v3) and its own ledger (`GrokLedger`). Each speaks its
own provider wire (`OpenAILiveClient`, `XAIRealtimeClient`); what their tasks
share, admission, the request built from the call's transcript, results said
and shown, hand-over at the end, the call's record and gist, is one
`CallTasks`, which answers what the voice must be told and never names a
wire. A Live call's instructions are `LIVE.md` (Grok's `GROK.md`) with what
`LivePrompt` generates around it
(the assistant's name, the owner's details, the date, the memory files in the
`<memory-context>` frame `PromptComposer` owns), and a call in the chat starts
with the chat's newest messages as provider input, read through the bridge
before the call has a handle and shaped by `LiveChat`, which masks Computer
History content against the call's own voice provider. A call in the chat
leaves a gist: its settle closes the `voice_calls` record (`CallRecord`) with
the settled cost and what the call owes the chat, then `CallGist` makes the
gist in a task the session never waits on and writes the call's one chat row
through the bridge, rendered from the record by `CallRow`. An owner's turn is
told the last gists (`RecentCalls`).

`Companion.Protocol` owns the chat vocabulary, served to the Mac app on
`FERMIX_HOME/companion.sock` (newline-delimited JSON with the Realtime socket's
handshake, exported in `priv/companion/`) by `FermixChannels.Companion`; the
mobile wire validates the chat events it shares through the same module. A
server event names the version that brought it, and a connection is never sent
one newer than the version its hello declared.
`Companion.Timeline` is the durable timeline the phone and the Mac share
(profile `main`), paged in both directions and searched through an FTS5 index
its own writes maintain. Its media index and link previews live in side
tables beside `mobile_timeline` (the index kept by SQLite triggers, so every
writer keeps it), and that table's columns stay the ones every released
engine decodes, so an older release still reads a newer database.

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
`plugins`, `memory`, `sandbox`, `grant`, `revoke`, `home`), and companion surfaces
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

### `packaging/cloud`: Always On servers

`packaging/cloud/first-boot.sh` is the root half of a server that becomes the
owner's primary (M75 step 6). It runs once as root, from cloud-init user data
(the code in `FERMIX_ENROLL_CODE`) or as
`curl -fsSL https://fermix.ai/always-on | sudo sh` (the code read from the
terminal without echo). It refuses, before it installs anything, any host but
Debian 12, Debian 13 or Ubuntu 24.04 and, deciding, any kernel below Landlock
ABI 3 (asked through `perl`'s `syscall`; a stock Debian 12 is one), where the
engine would refuse every command; then in order: writes the enrollment code
to
`/run/fermix/enroll.code` (tmpfs, 0600); installs an nftables table that drops
every packet to the metadata addresses (`169.254.169.254`,
`100.100.100.200`, `fd00:ec2::254`, `fd20:ce::254`) from every uid but 0,
except DNS and time (udp and tcp 53, udp 123), accepted first because some
clouds serve them from the same address (the `output` hook: the
host's own processes, which is why the server runs no containers), with a root
unit that loads it before the network at every boot and a `user@<uid>` drop-in
that will not start the engine account's service manager without it; gives a
host with no swap a 2 GB `/swapfile`; installs the Linux package through
`https://fermix.ai/install --no-setup`; turns on Debian's daily
unattended-upgrades and installs `fermix-update.timer`, a root timer that at
04:00 UTC runs the installer again, `fermix restart` as the engine account
when `fermix service status` says the running engine is behind the installed
one (not while `fermix home status` shows a pending move phase, nor when
either read fails), and `systemctl reboot` when `/run/reboot-required`
exists, which a move may defer at most two nights in a row (a root-owned
count under `/var/lib/fermix-update`), stopping before both when the
installer ran and failed (one that could not be downloaded changed nothing,
so both are still decided); creates
the engine account `fermix` (home `/home/fermix`, no login, lingering); runs
`fermix home enroll` and `fermix service install` as `fermix`; installs the
distribution's Chromium on Debian (Ubuntu's is a snap: it says to install a
browser by hand); and waits up to 5 minutes for the primary to accept the
candidate, ending with one sentence on
stderr and a non-zero exit at any step that fails. `--restore` takes no code
and enrolls nothing: the same server, then the exact steps that import a
snapshot and start the service. Everything networked after that (dialling the
primary, the move) is the engine's own candidate role.
`packaging/cloud/test/first_boot_test.sh` runs the script in throwaway Debian
containers against stand-ins for systemd, curl, apt and `fermix`, and once
with the real apt and Chromium.

Architecture Invariant: no engine process reaches the instance metadata
service. The enrollment code reaches the engine only as a file, never in an
argument, an environment the engine inherits, or the console output. A failed
nightly update leaves the running engine as it was, and nothing the engine
account answers holds a security reboot off for more than two nights.

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
runs the one attachment pipeline, runs slash commands unless the channel
disables them, and hands the turn to `Gateway.Queue`. Channels only declare
what their platform gave them; `Gateway.Attachments` fetches each attachment,
names its kind from the bytes (`FermixCore.Attachments.Kind`), renders it (a
picture as it came; a GIF or video as frames read by an installed `ffmpeg`,
`FermixCore.Attachments.Frames`, else as one still; a PDF or text file as its
bytes; audio and a video's sound through `Gateway.Transcription`) and answers a
message whose attachments are all unreadable itself. An operator turn keeps
the attachments under the workspace's `media/inbound/`
(`FermixCore.Attachments.Workspace`, 14 days and 1 GiB), then composes the
`[attachments]` manifest, with each saved path, into the persisted user text
(`FermixCore.Attachments.Manifest`) and the content parts the encoders read.
`FermixChannels.Dispatcher` remains only as a thin alias for `Gateway.ingest/2`,
used by tests.

Current channels:

- `Telegram` uses long polling through `Telegram.Poller`, with albums coalesced
  by `Gateway.AlbumBuffer`; webhook transport is intentionally unsupported.
  The first poll takes everything Telegram still holds (it keeps an update 24
  hours until a later call confirms it), so a message sent while Fermix was
  stopped is answered (M75). Each update's id (`<bot id>:<update_id>`) is
  recorded in `Gateway.Idempotency` before hand-off, so the batch Telegram
  sends again after a stop is not answered twice; an update the store cannot
  record halts the batch there, unconfirmed, for the next poll.
- `WhatsApp` uses Cloud API webhook ingress and Graph API replies, with audio,
  image, and document download.
- `Slack` uses Web API replies and takes events one of two ways
  (`[fermix_channels.slack] mode`): signed Events API webhooks (`webhook`, the
  default), or Socket Mode (`socket`, M75), where `Slack.SocketMode` opens a
  WebSocket with the app-level token so a host with no inbound port runs Slack.
  It asks `apps.connections.open` for a fresh address on every connection,
  dials it through `Cues.Source.Stream.Socket` (the engine's client WebSocket),
  acknowledges an event's envelope by its id once `Gateway.WebhookIngress` has
  taken it (a failed hand-off is left unacknowledged for Slack to resend, as a
  webhook answers 503), reconnects on `disconnect` and on a dropped or silent
  connection (1 s doubling to 60 s after a failure), and publishes its posture
  for `FermixCore.Health` and Doctor in Slack's own words, only while its
  process runs. It is a primary-only child (`Home.Role`), started by the registry
  only in Socket Mode.
- `Discord` uses a supervised Gateway connection and REST replies.
- `Signal` polls `signal-cli receive` once a second and sends through
  subprocesses.
- `IMessage` (macOS only) speaks NDJSON over stdio (`transport: :subprocess`)
  to **Fermix Messages**, a signed, self-disclaiming helper app
  (`io.tezra.fermix.messages`) installed by `FermixCore.IMessage.HelperInstaller`.
  The helper holds Full Disk Access and Automation → Messages, reads
  `chat.db` read-only, sends through Messages, and keeps the confirmed
  recipient policy in its own keychain item, changed only through a dialog it
  shows on screen. Invariant: the BEAM never opens `chat.db` and never sends an
  Apple Event.
- `Acp` exposes Fermix as an Agent Client Protocol agent on
  `FERMIX_HOME/acp.sock` (`Acp.Endpoint`, one `Acp.Peer` per connection);
  `fermix acp` pipes stdio to that socket. Client identities are kept by
  `FermixCore.Acp.Identity`.
- `Companion` serves the Mac app's chat on `FERMIX_HOME/companion.sock`
  whenever the daemon runs (`Companion.Endpoint`, one `Companion.Connection` per
  client). Its trust is the 0600 socket, so it runs as the local operator. A
  delivery it writes (a job's result, `send_to_channel`), unlike a reply, is
  pushed to the phones while their channel runs, as the phone's own deliveries
  are, since the two draw one timeline.
- `Mobile` serves the iOS companion on its own Bandit TLS listener (port 4031,
  Noise sessions, a pairing window, APNs push). It is on by default, its
  listener dormant until the first pairing window creates the identity and
  its mDNS announcement off unless `advertise_mdns` is set, and
  `FermixCore.Companion.Timeline` keeps each profile's synced timeline apart from
  conversation history. Its turns run in the Mac's chat conversation
  (`Mobile.joined_conversation/1`, the one `Gateway.Channel` callback that
  names another transport's conversation, which the gateway puts on every
  message it ingests through the adapter), so the one timeline both transports
  draw has one agent history and one queue lane, while the channel stays
  `mobile` for the phone's authorization, approval cards, stream and push.
  `Mobile.Supervisor` (`:rest_for_one`) starts, in order,
  the device store and registry, `PairManager`, the APNs
  dispatcher when push is configured (it connects on the first push, never at
  boot, and a push waits for that connect only until its deadline), the
  transport's `RequestCoordinator`, `Desktop.Supervisor` (the connected
  desktops' peers), `Mobile.Discovery` (a cached list of the
  addresses a phone can reach), the `Listener` and the mDNS advertiser. The
  `Listener` binds through `Mobile.TlsTransport`, ThousandIsland's TLS
  transport with a bounded handshake and with every read before the WebSocket
  upgrade bounded by one upgrade deadline; before that upgrade a connection
  gets one HTTP/1.1 request with bounded headers. A bind that fails leaves the
  `Listener` `unavailable` and retrying rather than stopping the subtree.
  Admission refuses the whole subtree for the boot, with a named class, when
  memory is off or the identity, attachment manifest or trust store cannot be
  read. Whether the channel runs has one answer, `Mobile.Supervisor.running?/1`
  (the supervisor's name is registered): the management verbs and a delivered
  row's push read it, so a job delivered while the channel is off is only a
  row of the shared timeline.
- The phone wire's sessions have kinds (M75 §3, §5). A paired device's row in
  `devices.toml` (`Mobile.DeviceStore`) names `kind`: a `phone` (a row that
  names none, as every row before desktops) or a `desktop` engine with no
  push or attestation field, which `Mobile.Management`'s one revoke path
  refuses to forget (`:desktop_device`: this version cannot link it again);
  `DeviceRegistry`
  carries the kind and keeps the phones' audience (`broadcast/3`,
  `connected/2`) to phones. `Mobile.Peers` is the one table of kind × event
  (`phone`, `desktop`, and the enrollment and move sessions wave two serves):
  the session answers a known event its kind may not send
  `error{code:"unsupported_event"}` and stays open, and drops a server event
  its kind may not be sent. The fields of the M75 events are
  `Mobile.PeerEvents`' declarative table, which `Mobile.Protocol` consults
  for them alone. `Mobile.Chunks` is pure: it cuts a payload into `index` and
  `last` frames of at most 60 KiB and reassembles one in order within its
  event's bound, refusing a gap, a repeat or a payload past it; both sides of
  a desktop's session use it. When a `desktop` session completes `hello` it
  starts its `Desktop.Peer` under `Desktop.Supervisor`'s `PeerSupervisor`
  and hands it every desktop-family event; the peer reassembles chunked
  payloads and dispatches each complete one to the module its family names in
  the peer's one `@families` map (a `Desktop.Family` behaviour: `init`,
  `handle_event`, `handle_info`, `terminate`), registers in the
  `Desktop.Peers` registry by device id with when it connected
  (`Desktop.Peer.connected/1`), and sends through the session with
  `Desktop.Peer.send/4`, which chunks and checks every frame in the caller.
  The session and its peer end together (`1011` when the peer fails first or
  does not start). A desktop's session has no one-hour lifetime on either side
  (the 2^20-frame rekey still bounds its keys); an `IK` key with no row is
  closed `4003 device unknown` at the handshake. The peer holds at most 32
  open payloads and 64 MiB across them.
- Remote reach is the iroh rail (M62), `Mobile.Iroh`, the last child of
  `Mobile.Supervisor` (`:rest_for_one`: the bridge's connections, `Iroh.Bridge`
  on `mobile/bridge.sock`, then `Iroh.Helper`). `Iroh.Helper` owns the
  `fermix-iroh` port and holds it to `Iroh.HelperProtocol` (helper protocol 3,
  `priv/iroh_helper/PROTOCOL.md`, which the helper repository vendors): it
  refuses any other `protocol_version`, and a helper that fails is reported
  and retried, never allowed to stop the daemon. The helper copies each
  accepted iroh stream to one bridge connection, where
  `Iroh.BridgeConnection` runs a `Session` as for a WebSocket. The helper runs
  in one of two modes: `:listen` (the home's `mobile/iroh_key` and the bridge,
  a phone's route) or `:dial` (M75: no key and no bridge, a key the helper
  holds in memory, every incoming connection refused). Either mode dials:
  `Iroh.Helper.dial/3` listens on a fresh `mobile/dial-<id>.sock` (0600,
  device-local like every socket), sends `dial`, accepts the helper's
  connection once `dialed` arrives and hands the caller that socket, with the
  listening socket and its file gone on every path; at most 8 dials at once,
  the helper's answer within its 20 s deadline. `Mobile.Rail` is the one
  initiator-side session client every engine-to-engine path uses (the desktop
  relay, the move worker, a candidate's enrollment): `Rail.open/3` dials a
  route through the helper, writes the prelude and runs the Noise handshake
  for `:ik`, `:ikpsk2_enroll` or `:ik_move` as initiator, then carries the
  mobile wire as a phone does (carrier frames, Noise transport with its
  2^20-frame rekey, `Mobile.Protocol`'s codec from the initiator's side,
  `seq`, `event_part` reassembly, pings inside the 150 s idle bound, the
  one-hour session), handing its owner each server event; consumers
  reassemble `Mobile.Chunks` payloads themselves.
- After a move (M75 §6, B1, B12) the desktop's device-role engine reaches its
  primary through `Desktop.DeviceSupervisor`, the one device-only child
  (`Role`'s device-only list; its children are one list with each start
  condition: the dial-only `Iroh.Helper`, then `Desktop.Relay`, both when
  `device/desktop.json` exists). The relay reads
  `FermixCore.Home.DesktopLink` (`device/desktop.json` and the 0600
  `device/desktop_key`, refused by name otherwise), opens one `IK` session
  through `Mobile.Rail` from a linked connector process (the rail's owner, so
  the relay keeps answering during a 40 s open), sends `hello` with the
  highest primary epoch seen and its relay revision, treats a lower epoch
  (or none) as a stale primary, records a higher one and a newer route, and
  reconnects from 1 s doubling to 60 s on injected timers; a session the
  primary ends normally (`1000`) is renewed quietly after the first step,
  once in a row (a renewed session ended normally again within a minute is
  an outage, `renewed_again`, on the ordinary backoff), and a revoked desktop
  (`4003`) stops dialing until the engine restarts. Its posture is
  `emit_transport(:desktop_relay, …)` and `home.status`'s `primary`, whose
  `status` word (`connected`, `renewing`, `unreachable`, `revoked`, `stale`;
  set at each transition, so a redial during an outage keeps `unreachable`)
  lets an app draw a quiet renewal apart from an outage; a revoked desktop's
  companion channels are refused `desktop_revoked`, not `primary_unreachable`.
  A forwarded call is answered within its method's deadline
  (`Placement.forward_deadline_ms/1`, or its caller's shorter one), and a move
  start the primary had and never answered is `unconfirmed`. It clamps
  the primary's `caps.max_media_bytes` to 64 MiB and holds at most 32 open
  payloads. It is
  the session's one writer, and `@inbound` is its one map of who serves each
  event the primary sends: the companion channels, the forwarded calls'
  `manage_result`, and the media fetches. In tunnel mode (the application
  decides at boot, `DesktopLink.linked?/2`) `Companion.Endpoint` hands each accepted
  `companion.sock` connection to a `Desktop.Tunnel` instead of a
  `Connection`: it places the client with `SocketPeer` and carries only the
  owner's app (`unattended_client` otherwise), sends each line as one
  `companion_line` of its channel (at most 4), answers `media_fetch` locally
  (the relay stages the blob, `Desktop.Relay.Media`, and the same
  `Companion.MediaGrants` grants it), and ends with `primary_unreachable`,
  naming the primary, when the session is down. On the primary,
  `Desktop.Companion` (the `companion` family) runs one
  `Desktop.CompanionPump` per channel under `Desktop.TunnelSupervisor`: a
  private Unix socket under `<home>/mobile` whose accepted end must name the
  engine itself as its peer, an ordinary `Companion.Connection` started with
  `Companion.Endpoint.connection_opts/1` on it (its `SocketPeer` places the
  engine itself as independent, the trust the desktop already checked), and
  the lines moved both ways. `Desktop.Manage` (the `manage` family) answers
  each forwarded call in a task, at most 8 per desktop, through
  `Fermix.CLI.Daemon.serve_forwarded/3` (the daemon's own router options,
  actor `{:desktop, device_id}`), as `manage_result`.
  `Desktop.LoopbackForward` (the `loopback` family, M75 D17) subscribes its
  peer to `FermixCore.Auth.LoopbackRegistry`, sends the desktop
  `loopback_open` for each listener a sign-in it started holds open (again on
  reconnect) and `loopback_close` when it closes, replays each
  `loopback_request` against the primary's own `127.0.0.1` port in a task
  (`Desktop.LoopbackHttp`, bounded HTTP/1.1) and answers `loopback_response`,
  at most 8 per loopback, and turns `loopback_failed` into the sign-in's
  failure. `Desktop.SnapshotCopies` (the `snapshots` family) hands
  `snapshot_stored` and `snapshot_refused` to the run waiting on them;
  `Desktop.SnapshotTarget` (a `Snapshot.Target`) streams the encrypted file to
  each connected desktop in 60 KiB `snapshot_chunk`s, waiting every 16 for the
  session to have written them (`{:mobile_sync, from, ref}`), and counts the
  copy verified when the desktop answers the same SHA-256.
  On the desktop, `Desktop.DeviceServices` (a line of
  `Desktop.DeviceSupervisor`, before the relay) runs the two the relay's
  `@inbound` hands the primary's events to: `Desktop.Loopback` (listens on
  `127.0.0.1` on each port for as long as the primary says, only a port
  nothing else listens on (no `SO_REUSEADDR` but for a port only closed
  connections hold), never below 1024 or one of the engine's own, at most 8
  loopbacks, forwards each browser request, reports a port it cannot open),
  and `Desktop.SnapshotStore`
  (`snapshots/<name>.partial` at 0600, verified and renamed, the newest 3
  kept, refused under a 2 GiB free-space floor). Each answers the primary from its own process or a
  task, never from inside the relay's call.
- Enrollment and the move (M75 §7, B4, B5): `FermixChannels.Home`. The phone
  session's prelude parse is the one branch to M75's own preludes
  (`Session.begin_handshake/2`): a mode a `Home.Responder` serves right now
  (`responders`, default the enrollment prelude) hands the whole stream to it
  on the same carrier, every other stream is a phone's or a desktop's in
  `phone_modes`. On the primary, `Home.Enrollment` (primary only) holds the one
  window and its secret (thirty minutes, kept in `mobile/enrollment.json`
  across a restart; the file drops the secret once a candidate is recorded or
  the window expired), `Home.EnrollmentResponder` runs `IKpsk2` with it and
  burns the window at the first frame that decrypts (the PSK proves itself
  only there; the candidate that burned it is answered again with the same
  id when its acceptance was lost, while the window lasts), and records the candidate
  (`FermixCore.Home.Candidates`). A
  candidate engine runs `Home.CandidateSupervisor` alone: its own
  `Iroh.Bridge` (move prelude only) and `Iroh.Helper` in listen mode rooted at
  `<home>/candidate`, then `Home.Candidate`, the one writer of its phase file,
  which enrolls through `Mobile.Rail` and answers `Home.MoveResponder`'s
  steps (offer, refused without room for the stream and the restored home;
  stage in a task; commit, an activation that fails part-way retried on a
  timer while a resume is refused; resume). On the source,
  `Home.MoveWorker` (a line of `Desktop.DeviceSupervisor`, started while
  `Home.Move.pending?/1`) holds the computer awake for its whole run
  (`FermixCore.Home.MoveAwake`: `caffeinate -i -w <BEAM pid>` through the
  disclaim shim on macOS, `systemd-inhibit … tail --pid=<BEAM pid>` on
  Linux, each ending with the engine; a holder under the core task
  supervisor that monitors the worker ends the inhibitor's process group on
  release, on the worker's death or after 26 hours), adds the desktop's key
  and row, captures once to
  `.move/<id>.fxsnap` for the candidate's one-time recipient (every attempt
  sends that capture; a move session, `:ik_move`, has no lifetime), streams
  it, and commits only after `moved.json`; after the marker it only resumes:
  `move_resume` on the candidate, and once the candidate no longer answers
  (it activated and restarted), the moved identity's own `hello_ack` at the
  ready epoch or later. The responders hold the wire's frame rules with
  `Home.ResponderWire`, the initiators with `Mobile.Rail`.
- The timeline's media and its link previews belong to both companion
  transports, so the channels application starts them on every real boot,
  whether or not the phone channel runs: `Mobile.MediaStore` (a phone's
  attachments, the Mac's own uploads and every preview's picture; a manifest it
  cannot read starts no store, `MediaStore.start_admitted/1`) and the bounded
  task supervisor `LinkPreviews` resolves under. Once a row is durable,
  `LinkPreviews.schedule/4` previews the links `FermixCore.ReplyBlocks.links/2`
  reads from it (a reply's, less the ones its blocks draw, and a phone user's
  own message's, never the Mac user's), the first four through `Mobile.Unfurl`,
  stores each card on its row with the link it was read for, and announces it,
  to the phones as `link_preview` and to the Mac as `row_updated`.
- The two companion transports share one request path (`Companion.Requests`:
  the durable `client_msg_id` claim, the attempt fence, ingest, history, search,
  read state and cancel) and one set of turn outputs (`Companion.Output`); each
  transport's `Mobile.RequestCoordinator` instance reruns only its own
  unfinished requests at boot. `Companion.Turns` is the Gateway agent and
  settlement owner of both transports and runs on every real boot, whether or
  not this boot serves `companion.sock`. A request's hand-off reaches it as a
  cast; once ingest returns, the request's worker moves the coordinator's
  fence onto it and casts the request's settlement behind the hand-off, and
  `Turns` completes a request no turn was handed off for (a slash command
  answered inline), in mailbox order. A turn it tracks settles from the
  Queue's outcome: a companion turn's replies are held and written, with
  `text_done`, only on `{:completed}`, while a phone turn streams and writes
  its own rows and is only settled. Both transports' turns run in the chat's
  one queue lane, so each waits for the other, and a stop names its own
  turn's message id there. A `cancel` from either transport
  (`Requests.cancel`) is recorded on the request (`cancelled_at`) before
  `Turns`, which owns the hand-off to the queue, reads that mark as it enqueues
  and sends any `Queue.stop_turn/3` itself, so a cancel is never lost between
  claim and queue and boot recovery never reruns a cancelled request; a
  revoked phone's requests are marked the same way, by `Turns`, so the device
  registry that revoked it never waits on the store. A store call inside
  `Turns` that exits (a Repo timeout or restart) is logged as that request's
  error, a stop waits on its queue however busy it is and leaves a queue that
  is gone to its `:DOWN`, and a settlement that fails, in the store or by a
  raise in the request path's settle code, fails the request and sends its
  client `request_failed`, so none of these crashes `Turns`; a raise in its
  own code or store calls is a defect and crashes it to `Companion.Supervisor`.
- `Companion.Fanout` is the one way a logical chat event reaches everyone
  watching a profile: the `companion.sock` connections and, while the mobile
  subtree runs, every connected phone, each wire getting only the events in
  its own catalog. Every timeline row, whichever transport or job writes it,
  and every `read_state` reach both transports (a row built once, by
  `Companion.Output.row/2`, in the phone's history-message shape, and
  projected to the Mac's `row` fields); a turn's stream and ending stay with
  the transport that ran it, and the other one learns the reply as a `row`.
- `Companion.Approvals` keeps the approval cards still waiting for the owner,
  each for the transport whose turn raised it, the only one its token resolves
  from. It announces each card and, when it resolves or expires, its
  `approval_resolved`, through one announce, to the connections open then; it
  re-sends the cards after a phone's `hello_ack` and a Mac client's
  `server_hello` with the time each has left, and holds at most 64.
  A card that ended while a client was away is never withdrawn, so both wires'
  clients drop every card they show at that handshake and keep only the ones
  sent after it. It runs on every boot, after the registry and `Turns` in
  `Companion.Supervisor`.
- `Voice` turns Live-voice delegations into `voice`-channel turns
  (`Voice.Bridge`). Unless the call is private, they run in the chat's own
  conversation (`Companion.chat_conversation_key/0`), which the bridge names
  in the trusted `voice_call` map, so a hand-off and a turn typed on the Mac
  or the phone share one history and one queue lane; a cancel or a hang-up
  stops only the call's own turns, by message id (`Queue.stop_turn/3`). A
  private call keeps a conversation of its own, keyed by the call's UUID. A
  hand-off runs on the operator surface less what a call cannot deliver, one
  list per mode read by the voice model's prompt and the hand-off alike
  (`VoiceCall.excluded_categories/1`): a call in the chat may start a coding
  run, which reports back into the chat, and a private call may not. While a
  call in the chat is up, `Companion.Turns` tells it each chat turn it hands off and that turn's
  answer (`Voice.ChatMirror`), finding the call in Core's `CallRegistry`, and
  each such turn is told the call is up (`Voice.Bridge.chat_call/2`): it can
  read the call (`voice_call_context`) and may end with no reply, which its
  runner tells the companion stream and `Companion.Turns` ends with
  `turn_done`, offered only to a turn the Mac runs while every companion
  client attached reads it (the phone's wire has no such ending).
  What a hand-off's answer cannot say aloud is shown in the chat: the Live
  session writes it through `VoiceBridge.show/2`, which `Voice.Bridge`
  answers with `Companion.write_call_row/3`, the one write for a call's rows
  (deduplicated per task revision, and once per call for the row a call
  leaves when it ends; `metadata.call` validated by `Companion.Protocol`); a
  reply its runner told the voice adapter is drawn from Computer History is
  shown and never said unless OpenAI may carry it. A call's row a dead daemon
  left owed is written at the next boot by `Voice.CallRowSweep`, started after
  the companion subtree. A task still running when a call in the chat ends
  finishes into the chat: the session hands it to `Voice.Detached`, one
  process under the voice supervisor that outlives every session, in an
  order the registry's ownership makes necessary (the record marks it
  detached, the owner registers a route of its own, then the session
  releases the call's), and the adapter resolves a reply by the session's
  route first and the owner's second. The owner writes the task's running and
  done rows through the same call-row write, pushes the phone, records the
  end, bounds each task by a wall clock and holds at most eight; a companion
  `cancel` with `task_ref` stops one through it (`Companion.Requests`), and
  the boot pass ends the ones a restart orphaned.
- `CLI` is the channel behind `fermix ask` and `fermix chat`.

`outbound/` holds pure long-form text helpers, and `harness/` re-ingests
coding-harness completion notices.

`Gateway.WebhookIngress` is the one path a verified webhook payload takes: the
adapter parses it, `Gateway.Idempotency` drops the ids it has seen, and the rest
go to `Gateway.ingest/2` in a task under `FermixCore.TaskSupervisor` (WhatsApp's
through its album buffer). The web routes call it after their signature check,
and Slack's Socket Mode calls it with each `events_api` payload, so both Slack
transports share idempotency, authorization and the turn. A hand-off that
fails forgets the ids it recorded, so the provider's retry is fresh.
`Gateway.Idempotency` answers a known id from ETS and records an unknown one in
`memory.db` once (`Memory.Repo`, pruned at most 1,000 expired rows a sweep);
with memory turned off the ids live in the process only. Outbound media claims
stay in memory.

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
- `/setup` (`SetupLive`); it and `/` sit behind `SetupAuth`: a one-time launch
  token, then a session cookie, which each LiveView's mount checks again for
  its socket; `embed=1` serves the macOS app
- `/health` and `/health/ready` for the readiness status alone, and
  `/health/live` for a static liveness payload; the full report stays with
  `fermix health --json`
- `GET`/`POST /webhook/whatsapp` and `POST /webhook/slack`; Slack over Socket
  Mode needs none of them

`WebhookController` verifies the request and hands the payload to
`Gateway.WebhookIngress`, which parses it, drops duplicates and dispatches it
asynchronously; a failed handoff returns 503 with the duplicate record rolled
back, and a device-role engine answers every webhook route 503. `HealthController` reports `FermixCore.Health`'s status.
`SetupLive` drives `Setup.Wizard` and the core setup modules. Its Always On tab
(`SetupLive.AlwaysOn`, M75 B14) is read-only: the summary every surface
prints (`home.status.summary`), drawn from `Management.Home.status/1` in the
page's own process when the tab opens and on Refresh, its action named as
the app's to take; setting Always On up is the apps'. On a device-role
engine the page leads with a notice that Fermix-wide settings live on the
server and draws every tab whose request
`Management.Placement` places on the primary as unavailable. Not all ingress is
Phoenix: the mobile listener, the OAuth loopback listener, and the Unix sockets
(`daemon.sock`, `realtime.sock`, `acp.sock`, `companion.sock`) live in core and
channels.

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
under `apps/fermix_core/priv/{management,realtime,companion,mobile}/`. When a milestone is
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
to and answers the prompt as a failed turn. `Companion.Turns` watches the
Queue it handed each turn of either companion transport to, ends the turn as
`interrupted` when that Queue dies, and holds the request's fence itself, so
the request is failed once rather than released for a rerun. Voice does not
watch (accepted: a call is bounded and the operator can cancel it); a task
that outlived its call is bounded by its owner's wall clock instead, so one
whose Queue died ends there as timed out.

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
