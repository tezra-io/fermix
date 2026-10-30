# Fermix management socket protocol

The wire contract between the Fermix daemon and the Fermix macOS application.

**Source of truth:** `FermixCore.Management.Protocol`
(`lib/fermix_core/management/protocol.ex`). This file, `protocol.schema.json`,
and `fixtures/*.jsonl` are the machine-readable export of that module.
`protocol_contract_test.exs` asserts they never drift from it. A downstream
consumer (`fermix-macos`) **vendors the schema and fixtures pinned by checksum**
rather than hand-copying the shapes — that is the single coordination point
across the two independently-released repos.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/daemon.sock`
  (default `~/.fermix/daemon.sock`), mode `0600`, owned by the daemon. There is
  no per-request authentication; the trust boundary is the socket file's mode
  and ownership.
- **Framing:** Erlang `{:packet, 4}` — one big-endian 32-bit byte length
  followed by exactly that many bytes of UTF-8 JSON. A frame arrives whole or
  not at all, so a decode failure means malformed JSON, never truncation.
- **Frame ceiling:** `max_frame_bytes` = `4194304` (4 MiB), enforced on both
  ends via `{:packet_size, ...}`. A client rejects an oversized request before
  sending it rather than failing on an opaque `emsgsize`.
- **Exchange:** one request, one response, then the daemon closes the
  connection. There are no server-initiated frames and no streaming; Doctor runs
  and log pages are polled, which is why `doctor.start` returns immediately with
  a session id instead of holding the request open.

## Versioning

The protocol is versioned by a single integer, `protocol_version`, carried on
every request. The daemon accepts the inclusive range `{minimum, maximum}`. The
range is an **N/N-1 window**: `maximum` is the current version and `minimum` is
the previous one (or the same value when only one version has ever existed), so
a daemon that has moved to `N+1` still serves an app speaking `N` for one
release.

Current values (see the schema's `x-protocol-version` /
`x-supported-version-range`):

| Field | Value |
|---|---|
| `protocol_version` (app declares) | `2` |
| daemon `minimum_version` | `1` |
| daemon `maximum_version` | `2` |

`hello` returns the same range, so a client learns the window without having to
provoke an error.

### Per-method minimum versions

A single integer is not enough once the window is wider than one version. Each
method declares its own `min_protocol_version`, published whole in the schema as
`x-method-minimum-versions` and in `hello` as `capabilities.minimum_versions`.
The daemon gates on the version the **request** declares, not on its own: a
v1-negotiated session calling a v2 method is refused with `method_not_found` and
`details.requires`, so the wire's meaning never depends on the client's honesty.

A client computes its negotiated version as the highest version both halves
speak, stamps it on every request, and refuses a method whose published minimum
exceeds it *before sending*. That refusal is not a boot failure: it means the
running daemon cannot serve those surfaces, and the client says so rather than
showing an empty pane.

The consequence, stated as the guarantee: `hello`, `overview.get`, `logs.query`,
`lifecycle.prepare` / `commit` / `cancel`, `doctor.*` and `diagnostics.build`
work against a daemon one release behind, so a client can always read the state,
explain it, and restart that daemon onto a newer engine. Only the v2-only
surfaces refuse until then.

Fields a v2 daemon adds to a v1-minimum method are **optional**, with a defined
absent rendering, because the direction that breaks is a new client talking to
an old daemon. `overview.get`'s `health.restart_reasons` absent means "restart to
apply" with no reason list; a Doctor check's `remediation` absent means the
summary renders with no action button.

## Request envelope

```json
{
  "request_id": "req-1",
  "protocol_version": 1,
  "method": "hello",
  "params": {}
}
```

- `request_id` — required, `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`. Echoed on
  every response; a client that receives a different id must discard the frame.
- `protocol_version` — required integer, negotiated against the window above.
- `method` — required, from the catalog below.
- `params` — optional object, defaulting to `{}`.

Unknown top-level fields are refused with `invalid_request`, naming the field.
Every method declares its own parameter set: input-free methods refuse any
params at all, and params-carrying methods refuse an unknown key rather than
ignoring it.

## Response envelope

A response carries **exactly one** of `result` or `error`, never both and never
neither.

```json
{ "request_id": "req-1", "result": { } }
```

```json
{
  "request_id": "req-1",
  "error": {
    "code": "unknown_session",
    "message": "The Doctor session is not retained by this daemon.",
    "details": { "session_id": "doctor:9Fj2mQ" }
  }
}
```

`code` is from the stable catalog below, `message` is a fixed operator-facing
sentence owned by the daemon, and `details` is a bounded object of public
scalars. No `inspect(reason)` output, internal term, filesystem path, or Setup
token ever crosses this boundary. `request_id` is `null` only when the request
was so malformed that no valid id could be recovered from it.

## After a move: requests the primary answers

When the owner moves Fermix to another host (M75), the computer it moved from
keeps its engine in the device role and keeps this socket, so the app changes
nothing. That engine answers a request about this computer itself and sends
every other one to the primary over its encrypted session, after this
socket's own placement of the caller (an owner decision from a process the
engine started is refused here, as above, and never sent). The answer is the
primary's, exactly as its own socket would give it.

- **Answered on this computer** (device-class): `hello`, `lifecycle.*`,
  `diagnostics.build`, `logs.query`, `doctor.*`, `setup.session.create`,
  `setup.detect`, `computer_use.*`, `imessage.*`, `browser.install.start`,
  `capabilities.install.start`, and `settings.get` and `settings.apply` for a
  section that configures only this computer: `sandbox`, `computer_use`,
  `computer_history` and `channels.imessage`.
- **Composed** (answered here, with the primary's own part): `home.status`
  answers this computer's facts and adds `primary_home`, the primary's own
  `home.status`; `settings.sections` lists this computer's own sections and
  the primary's others. The primary's part is asked within 5 s; while it is
  missing (unreachable, or no answer in time) this computer's part is still
  answered and `primary_missing` holds the sentence that says why. The primary
  answers a composed request a desktop forwards as its own.
- **Answered by the primary** (primary-class): every other method, the
  home's recovery, enrollment and move included (`home.snapshots.*`,
  `home.enroll.open`, `home.candidates.list`, `home.move.readiness`,
  `home.move.start`): after a move the server holds them.
- While the primary cannot be reached, a primary-class request is answered
  `primary_unreachable`, `details.primary` naming it and `details.sentence`
  saying so: `The server <name> is unreachable. Fermix keeps your message until
  it is back.` One the primary did not answer within its forward deadline
  (below; work longer than that is a job on the primary, answered at once) is
  answered the same way, with the sentence that it did not answer in time. A
  desktop the primary revoked says so instead, and one whose session the
  primary ended normally (a daemon stopping) says the link was renewed; a
  primary that ends the renewed session normally again within a minute is an
  outage from then on, redialed with the backoff.
- **The link's state in one word.** `home.status`'s `primary.status` is one
  of `connected` (a session is up), `renewing` (a session opening with
  nothing known to be wrong: the first since the engine started, or the quiet
  renewal above; draw it quietly, not as an outage), `unreachable` (an
  outage, the renewal loop included, retried with the backoff; also a link
  this engine refused to use), `revoked` (the primary no longer knows this
  computer; not retried until the engine restarts) and `stale` (the primary
  answered as an older copy; retried). A redial during an outage keeps the
  outage's word until a session is up; `sentence` says the rest.
- **Forward deadlines.** How long the computer waits for the primary's answer
  to a forwarded request:

  | Method | Deadline | A client's own timeout for it |
  |---|---|---|
  | `home.move.readiness` | 60 s | at least 65 s |
  | `home.move.start` | 60 s | at least 65 s |
  | every other forwarded method | 8 s | the usual 10 s |

  The two move calls walk the whole home on the primary before they answer
  (60 s holds a home at the archive's 100,000-file bound walked at the slowest
  rate measured). A client gives them at least 65 s on every engine, a primary
  included, where the same walk runs in the call itself.
- **A move's start whose answer was lost is `unconfirmed`, never a failure.**
  When the primary had a forwarded `home.move.start` and its answer did not
  arrive (the deadline passed, or the session ended under it, as it does when
  the primary restarts into the move right after answering), the computer
  answers `unconfirmed`, `details.method` `home.move.start`, `details.primary`
  naming the server and `details.sentence` `The server <name> did not confirm
  in time whether the move started. Its state shows once the server answers
  again, and starting it again never starts a second move.` The client then
  reads what happened from `home.status` (`primary_home`, missing while the
  server restarts into the move); a second start is refused while one runs.
- The primary refuses a device-class request that reaches it anyway with
  `device_class_method`, `details.method` naming it.

A computer that runs in the device role without having moved this way (no
link to a primary) forwards nothing, and refuses as before.

An engine in the **candidate role** (a fresh host enrolled with `fermix home
enroll`, waiting for the move that makes it the primary) answers `hello` and
`home.status` and nothing else. Every other method is `unavailable`, with
`details.capability` `candidate` and `details.sentence` `This engine is a
candidate primary waiting for its move; it answers home.status and nothing
else until the move makes it the primary.` Its `home.status` reports `role`
`candidate`, `move` with `candidate` null, and `snapshots` that say they are
the primary's.

## v0 compatibility window

The daemon also serves the historical **unversioned** control protocol as v0 for
one migration release — that is what `fermix stop`, mobile pairing, and the
remaining introspection verbs (`health`, `agents`, `capabilities`, `skills`,
`plugins`, `observability`) speak today. Classification is structural and has no
fallback:

1. A frame carrying **either** `request_id` or `protocol_version` is an
   attempted v1 request. If it is not a valid one it is refused with a v1 error
   envelope and **never** retried as v0.
2. A frame carrying neither marker, with a string `method`, is v0.
3. Anything else — non-object JSON, undecodable bytes, a v0 frame without a
   `method` — is refused as an invalid v0 request.

New application code sends v1 only and never retries through v0. A v0 method is
deleted, not deprecated in place, when its verb moves onto v1: `status` and
`overview` were removed when `fermix status` moved onto `hello` plus
`overview.get`, and a daemon asked for either now answers the ordinary v0
`unknown method` reply.

## Direction of an unsupported version

A version outside the window is refused before routing, with the range attached
so the app can tell the user which component to update without re-deriving it:

- `client_too_old` — the app declared a version below the daemon's floor →
  **update the app**.
- `daemon_too_old` — the app declared a version above the daemon's ceiling →
  **update Fermix**.

Both carry `details: {"minimum_version": N, "maximum_version": M}`.

## Rollout / rollback order

Because the daemon and the app ship from separate repos on independent cadences,
a version bump must land in a fixed order so the two are never mutually
unintelligible:

1. **Daemon first.** Ship a daemon that *adds* support for `N+1` while keeping
   `N` (the N/N-1 window). Never remove support for a version a released app
   still requires.
2. **App second.** Only after that daemon is released, ship an app that speaks
   `N+1`. An app must never require a version the released daemon lacks.
3. **Rollback** is the reverse: roll the app back to `N` before dropping `N`
   from the daemon.

The window is what makes step 3 survivable rather than a coordinated outage: a
daemon serving `{N-1, N}` answers both the app being rolled back to and the one
being rolled back from, so the two halves are never simultaneously
unintelligible at any point in either direction. What must never happen is a
release that widens `maximum` and lifts `minimum` in one step, because that
leaves no version both halves speak and no call the app can make to restart the
daemon onto anything else.

## Method catalog

| `method` | Params | Result |
|---|---|---|
| `hello` | none | Supported range, method catalog, immutable engine identity, PID, and the loopback Setup endpoint. |
| `overview.get` | none | Typed projection of readiness, health, daemon, provider, channels, memory, jobs, agents, realtime, and capability counts. |
| `setup.session.create` | none | A one-use Setup URL and its absolute expiry. The durable token is never returned. |
| `doctor.start` | `scope` (`local` \| `network`, default `local`) | A session view; the run continues in the background. |
| `doctor.get` | `session_id` | The session view with the checks that have landed so far. |
| `doctor.cancel` | `session_id` | The terminal session view. Cancelling a finished session is a no-op, not an error. |
| `logs.query` | `limit`, `level`, `subsystem`, `search`, `direction`, `cursor` | A bounded page of redacted entries plus the opaque cursor for the next page in the same direction. |
| `lifecycle.prepare` | none | `lease_id` and the relative `ttl_ms` of the single drain window. |
| `lifecycle.commit` | `lease_id` | Runs the daemon's shutdown path and answers before the VM stops. |
| `lifecycle.cancel` | `lease_id` | Releases the window with the daemon untouched. |
| `diagnostics.build` | none | A bounded, field-allowlisted, scrubbed diagnostic object for user-selected export. |
| `setup.state.get` | none | Everything a setup surface reads before it renders: readiness with its gating split, restart state with the daemon's own reason sentences, one row per provider and per channel, the personalization presence summary, feature switches, the profile, and the coexistence facts. Minimum version `2`. |
| `settings.sections` | none | The ordered inventory of every section this daemon can serve, each with the pane it renders under, as `{sections, primary_missing}`. The one enumerator: a section reachable through `settings.get` and absent here fails the daemon's own contract test. On a linked desktop it is composed (see *After a move*): this computer's own sections (`sandbox`, `computer_use`, `computer_history`, `channels.imessage`) and the primary's others, and `primary_missing` the sentence while the primary's are missing; null everywhere else. Minimum version `2`. |
| `settings.get` | `section` | One section's rows. Exactly one section per call, which is what keeps every result inside the published depth budget. Minimum version `2`. |
| `settings.apply` | `section`, `values` | Applies the changed keys of one section and answers with what landed, the restart state, a readiness summary, and the changes the operator did not type. Minimum version `2`. |
| `settings.reload` | none | Re-reads the settings file, pushes it into the running configuration, and re-records the baseline. The one action behind `Reload settings from disk`. Minimum version `2`. |
| `secret.set` | `id`, `value` | Stores one secret and answers with its presence, never its value, and the environment variable that overrides it, if any. Minimum version `2`. |
| `secret.clear` | `id` | Forgets one secret: the keyring item, the reference that reads it, and the value in force. Answers with the environment variable still in use, if any. Minimum version `2`. |
| `setup.detect` | `targets` | One row per target asked for: whether this Mac already has it, and a short detail where there is one. The harness target also reports vendor installation, version and authentication status, with guidance. The `meetbot` target reports whether both halves of the meeting notetaker are installed, its detail carries the state of the notetaker's Google sign-in as a sentence, and `signed_in` carries the same state as a boolean, null while the notetaker is absent. Never a credential value. Minimum version `2`. |
| `providers.set_primary` | `provider` | Makes one configured provider the primary and answers with the restart state and any change the operator did not type. Minimum version `2`. |
| `providers.models.list` | `provider`, `live`, `query`, `cursor`, `limit` | One page of models, from the catalog this build ships or from the provider's own live listing, with the cursor for the next page. Minimum version `2`. |
| `providers.probe.start` | `provider` | Starts a metered call against the provider. A job; the result carries the model and the latency. Minimum version `2`. |
| `job.get` | `job_id` | One job's uniform view. Minimum version `2`. |
| `job.cancel` | `job_id` | Stops a running job and answers its terminal view. Cancelling a finished job is a no-op, not an error. Minimum version `2`. |
| `job.list` | none | Every job this daemon retains, oldest first. What lets a reopened surface find a run it started rather than starting a second one. Minimum version `2`. |
| `auth.start` | `provider` | Starts a browser sign-in and answers with the job plus the authorize url and its lifetime, returned once. `openai_codex` signs in with ChatGPT: a sign-in that leaves ChatGPT plan usage off fails the job with its sentence, and a completed one first makes sure the default model is one the account lists. When that check cannot be made (the account's model list could not be read, or the model could not be saved), the sign-in still completes and its result carries `model_warning`, the daemon's sentence saying the default model was not checked and why, beside `account_label`. The field is optional: absent means the check was made, and a client that does not know it shows the sign-in as completed. `mcp:<name>` signs in one MCP server the owner added, a remote one whose `auth` is `auto`, and is refused with `invalid_params` on `provider` and a sentence for a name no server has, a server on this Mac, one that sends a key and one set to need no sign-in. Minimum version `2`. |
| `auth.import.start` | `source` | Adopts a sign-in this Mac already has, from Claude Code. A job, because reading the keychain can prompt. `codex_cli` is still accepted as a source and refused with `invalid_params` and a sentence: a Codex CLI sign-in is no longer adopted, and `openai_codex` signs in with ChatGPT through `auth.start`. Minimum version `2`. |
| `auth.logout` | `provider` | Forgets one provider's local session and reverts the route it fed. Nothing is revoked upstream, except for `openai_codex`: its sign-out revokes the ChatGPT session and keeps the registration, so the next sign-in reuses it. `mcp:<name>` forgets one MCP server's sign-in, revokes nothing upstream, and starts the server again without it; a client its sign-in registered is kept for the next one. Minimum version `2`. |
| `plugins.list` | none | Every integration this daemon can show, installed or not, in one row shape, plus one entry per sign-in client a published plugin needs, each carrying the account region it is bound to and the regions this daemon offers for it. Every word on a row is the daemon's. Minimum version `2`. |
| `plugins.install.start` | `name` | Fetches, verifies and activates one catalog plugin. A job. Minimum version `2`. |
| `plugins.check.start` | `name` | Runs one plugin's own health check, live probe included. A job. Minimum version `2`. |
| `plugins.workspaces.discover.start` | `name` | Lists the workspaces a hosted plugin's stored credential can reach. A job; what it finds is republished on the plugin's row rather than in the job result. Minimum version `2`. |
| `plugins.workspace.select.start` | `name`, `profile`, `workspace_id`, `label` | Binds one hosted plugin to one workspace under one access profile, and answers only once the replacement client is connected and contract-checked. A job. Minimum version `2`. |
| `plugins.enable` | `name` | Turns one installed plugin on and answers with its row. Minimum version `2`. |
| `plugins.disable` | `name` | Turns one plugin off and answers with its row. Minimum version `2`. |
| `plugins.disconnect` | `name` | Forgets the credential behind one plugin, locally: an OAuth session is deleted, a stored token is removed from the keyring, and neither is revoked upstream. Minimum version `2`. |
| `plugins.oauth_client.set` | `provider`, `client_id`, `redirect_port`, `region` | Registers one sign-in client. The client secret is not a parameter: it arrives through `secret.set`. `region` is required exactly where the client row publishes a non-empty `regions`, and refused where it publishes none; it is optional on the wire, like `secret_present`, so an older engine is unaffected. Minimum version `2`. |
| `plugins.setting.set` | `name`, `key`, `value` | Writes one manifest-declared setting and answers with the plugin's row. `value` is always a string, and a setting whose `kind` is `boolean` takes only `true` or `false`. Minimum version `2`. |
| `capabilities.install.start` | `target` | Installs the computer use helper, the meeting notetaker, the on-device speech backend, or the iMessage helper (`imessage_helper`). A job. Minimum version `2`. |
| `meetings.signin.start` | none | Starts the notetaker's one-time interactive sign-in. A job, because it waits for a person. Minimum version `2`. |
| `computer_use.grant.start` | none | Raises the OS permission prompts and answers with what was granted. A job, and only ever on an explicit ask. Minimum version `2`. |
| `computer_use.permissions.get` | none | The current, non-prompting permission state: whether the helper is installed, which grants it holds, and when they were read. Minimum version `2`. |
| `mobile.status` | none | The phone channel as it stands: whether it is enabled, whether it started, whether it was refused this boot and the class of that refusal, whether it is held until setup is finished, the listener (`status`, `reason`, `port`, `bind`, `candidates`), the local-network announcement, detected tailnet addresses, the gateway identity's presence and fingerprint, remote reach, push credentials and delivery, the paired-phone count, the mobile protocol version this daemon serves, and the pairing session open or newest retained. Answers with the channel off. Minimum version `2`. |
| `mobile.pair.start` | none | Opens the pairing window and answers with the pairing session view plus, once, the pairing link as `uri`. `busy` while a window is open. Minimum version `2`. |
| `mobile.pair.get` | `session_id` | The pairing session as it stands. The pane polls it until the session is terminal. Minimum version `2`. |
| `mobile.pair.decide` | `session_id`, `approved` (boolean) | Approves or denies the phone waiting in the session and answers the terminal view. Minimum version `2`. |
| `mobile.pair.cancel` | `session_id` | Closes the window and answers the terminal view. Cancelling a finished session is a no-op, not an error. Minimum version `2`. |
| `mobile.devices.list` | none | Every paired device, oldest first, at most 64, read from the paired-device file while the channel is not running. Each row names its `kind`, `phone` or `desktop` (a desktop engine a move paired). Minimum version `2`. |
| `mobile.devices.revoke` | `device_id` | Forgets one paired device, a phone or a desktop, and closes its live connection, and answers with the id and `revoked: true`. While the channel is not running it forgets the device in the paired-device file. Minimum version `2`. |
| `browser.install.start` | none | Downloads a browser for tasks: the meeting notetaker's helper, then the Chromium build it is pinned to, and completes with the name of the browser tasks now run in. A job. Minimum version `2`. |
| `imessage.permissions.get` | none | The Fermix Messages helper's non-prompting state: whether it is installed, its version, Full Disk Access, the Messages database, Automation, whether Messages runs and is signed in, the user session, the confirmed recipient policy, whether that policy is exactly the saved settings, and when it was read. Minimum version `2`. |
| `imessage.grant.start` | `service` (`automation` or `full_disk_access`) | Asks for one grant: `automation` raises the one system prompt, `full_disk_access` registers the helper, opens the Full Disk Access pane and reveals the helper for drag-in. A job that completes with the permissions view. Minimum version `2`. |
| `imessage.policy.confirm` | none | Asks the helper to confirm the saved recipients; when they differ from the ones it holds, the helper shows its own dialog naming every handle. A job that completes with the permissions view plus `outcome`. Minimum version `2`. |
| `mcp.servers.list` | none | Every MCP server the owner added, imported or wrote by hand in `config.toml`, as rows without their tools, plus `limits` (`max_servers`) and `can_add`. Minimum version `2`. |
| `mcp.servers.get` | `name` | One server's row with its `tools`, at most 256, in the server's order. Minimum version `2`. |
| `mcp.servers.draft` | `text` | Reads what the owner typed or pasted into the add form (a URL, a command line, an `mcpServers` or `servers` JSON map, one server object, a `claude mcp add` line or a Codex `[mcp_servers.<name>]` block), writes nothing, and answers `{drafts}`: at most 32, each a server as the form takes it, with the `draft_id` that holds the values it carried. Minimum version `2`. |
| `mcp.servers.add` | `name`, `transport`, `command_line` or `url`, `cwd`, `env_names`, `auth`, `key_header`, `header_names`, `oauth_client_id`, `draft_id` | Writes one server and answers `{server, job_id}`: its row, and the `mcp_check` it started, or a null `job_id` where the server waits for a value and so did not start. With a `draft_id`, the values that draft carried are stored for the names the form still declares. Minimum version `2`. |
| `mcp.servers.update` | `name` and any field `add` takes but `draft_id` | Changes the fields given and answers `{server}`. The name and transport cannot change, and a value the server no longer declares is deleted. Minimum version `2`. |
| `mcp.servers.remove` | `name` | Removes one server, every value it declares and its live status, and answers `{name, removed: true}`. Minimum version `2`. |
| `mcp.servers.enable` | `name` | Turns one server on and answers `{server}`. Minimum version `2`. |
| `mcp.servers.disable` | `name` | Turns one server off and answers `{server}`. Minimum version `2`. |
| `mcp.servers.tool.set` | `name`, `tool`, `enabled` (boolean) | Switches one tool on or off for the agent and answers `{server}`. The server's program keeps running. Minimum version `2`. |
| `mcp.servers.check.start` | `name` | Connects one server and lists its tools once. A job, kind `mcp_check`, whose result carries `tool_count` and `latency_ms`. Minimum version `2`. |
| `mcp.servers.import.scan` | none | Reads the MCP servers in Claude Desktop's, Claude Code's, Cursor's, VS Code's, Windsurf's and Codex's settings on this Mac, now and only now, and answers `candidates`, each with its `source`, `source_label`, name, transport, summary, command line or URL, consent sentence, resolved program and `secret_names` (never a value), and `skipped`, what could not be offered with the daemon's sentence. Minimum version `2`. |
| `mcp.servers.import` | `servers` (`[{source, name}]`, at most 32) | Reads those settings again and adds each server named through the add path, with the values its settings held stored in the Keychain and `origin` `imported:<source>`, and answers `{servers, refused}`: the new rows, and each server not added with its sentence. Minimum version `2`. |
| `cues.status` | none | The cue subsystem as it stands: `available` (always `true`: every build has cues), the switches (`enabled`, `mandates_enabled`), whether the cue tree is `running`, `memory_enabled`, a `state` (`off`, `needs_memory`, `needs_restart`, `running`) with its `status_sentence`, the `door` (`state` `listening`, `unavailable` or `not_running`, `port`, `reason`, `sentence`), and `counts` (`sources`, `sources_attention`, `watchers`, `watchers_held`, `mandates`, `mandates_attention`, `proposals_waiting`). Answers on every build. Minimum version `2`. |
| `cues.sources.list` | none | Every source as a row, at most 64, plus `can_add` and `limits` (`max_sources`). Minimum version `2`. |
| `cues.sources.get` | `ref` | One source's row, its editable fields as settings rows (`values`), its open gaps (at most 20, each with the daemon's sentence) and its refused requests by reason (`rejected`). Minimum version `2`. |
| `cues.sources.form` | `kind`, `preset`, `verify` (each optional) | The add form for that choice, and writes nothing: `choices`, `requirement`, `kinds`, `presets`, `rows` (the name first, then the fields of that kind, preset and verification method, a secret field as a `secret` row with `present: false`), `consent_sentence` and `notes`. `choices` is the same on every answer: what the owner can watch, in the order a client lists them, each `{id, label, sentence, kind, preset, featured}` (`preset` null where the choice has none); a client draws the featured ones first and the rest under "Something else", and asks for a choice's form by its `kind` and `preset`. `requirement` is null except for X accounts: `{state, sentence, plugin: "x"}`, `state` `ready` ("Signed in to X.") or `needs_sign_in` ("Connect X to read these accounts."), read from the X plugin's sign-in the source reads with; it never stops the add. Only the rows a choice needs are open; the rest, the name first among them, are `advanced`. The name row is empty, with an `example` of the name Fermix would make. GitHub's form has no secret row: Fermix makes that secret when the source is added. Its `notes` are the tunnel note, then GitHub's three steps in order (where the secret and the source's address go in GitHub's webhook form); every note is plain text, shown as written. A stream has no preset; it is the general WebSocket source: each of its field rows but the name and the daily budget carries an `info` and an `example` (no row of the form carries a `footer`), and two `secret` rows, `key` (API key) and `secret` (API secret), follow its address. `kinds` and `presets` are as they were, for the edit form and older apps. Minimum version `2`. |
| `cues.sources.add` | `ref` (optional), `kind` or `preset`, `values` | Saves a new source and answers `{source, token, secret}`: its row, under the name given or, with `ref` absent or empty, one Fermix makes (a feed's or stream's site, such as `ycombinator` for `news.ycombinator.com`; `x-` and the first handle; `github`; `scripts` for a local push; `webhook`), with `-2`, `-3` and so on when the name is taken. `source.ref` is the name in force, and a client stores typed secrets under it. `token` is a new local push source's first token and `secret` the secret Fermix makes for a new GitHub source, each returned once and null otherwise. Minimum version `2`. |
| `cues.sources.update` | `ref`, `values` | Changes the fields `values` names and answers `{source}`. The name, kind and preset cannot change. Minimum version `2`. |
| `cues.sources.remove` | `ref` | Removes a source and its stored secrets, and answers `{ref, removed: true, left, watchers}`: any secret that could not be deleted, as sentences, and the watchers that listened to it. Minimum version `2`. |
| `cues.sources.enable` | `ref` | Turns a source on and answers `{source}`. Minimum version `2`. |
| `cues.sources.disable` | `ref` | Turns a source off and answers `{source}`. Minimum version `2`. |
| `cues.sources.token.new` | `ref` | A fresh token for a local push source, returned once, as `{ref, token}`. The old one stops working within a minute. Minimum version `2`. |
| `cues.sources.url.get` | `ref` | A webhook source's address, `{ref, url, path}`: made on the first call and the same on every later one. Minimum version `2`. |
| `cues.watchers.list` | none | Every watcher as a row, oldest first, at most 200, with `window_s` (86400) and `truncated`; a row carries its task (for a watcher with only a follow-up, that follow-up's job, so never null) and its follow-up (null when it has none). Minimum version `2`. |
| `cues.watchers.get` | `name` | One watcher's row plus its `purpose`, its words to listen for (`listen_for`), its `instructions` and how many of its examples are marked each way. Minimum version `2`. |
| `cues.mandates.list` | none | Every mandate as a row, at most 64, plus `can_add` and `limits` (`max_mandates`). Minimum version `2`. |
| `cues.mandates.choices` | none | What a mandate form offers: the jobs that run on cues, each with the watcher that wakes it and the mandate that names it, and the installed, enabled `http` plugin tools. Minimum version `2`. |
| `cues.mandates.add` | `name`, `values` | Saves a new mandate and answers `{mandate}`. Durations travel as whole seconds (`approve_within_s`, `max_cue_age_s`). Minimum version `2`. |
| `cues.mandates.update` | `name`, `values` | Changes the fields `values` names and answers `{mandate}`. Its approval covers the section, so the row then says `changed` until approved again. Minimum version `2`. |
| `cues.mandates.remove` | `name` | Removes a mandate and answers `{name, removed: true}`. Minimum version `2`. |
| `cues.mandates.enable` | `name` | Turns a mandate on and answers `{mandate}`. Minimum version `2`. |
| `cues.mandates.disable` | `name` | Turns a mandate off and answers `{mandate}`. Minimum version `2`. |
| `cues.mandates.approve` | `name` | Records the owner's approval of a mandate as it is now, from the Fermix app, and answers `{mandate}`. An inactive mandate is refused with its load sentence. Minimum version `2`. |
| `cues.proposals.list` | `state` (`waiting`, the default, or `recent`) | Fermix's record of each waiting proposal (oldest first, at most 100) or of the last 7 days (at most 50), and `waiting`. No arguments and no cue text. Minimum version `2`. |
| `cues.proposals.get` | `proposal_id` | `{proposal}`: the record plus the card, the outside text apart. Minimum version `2`. |
| `cues.proposals.decide` | `proposal_id`, `decision` (`confirm` or `deny`) | Answers a waiting proposal and returns `{proposal}` once the decision is recorded: `denied`, or `confirmed` with a null `result_status` while the call runs. Minimum version `2`. |
| `home.status` | none | The one picture of this home every surface draws: `role` (`primary`, `device` or `candidate`), `epoch` (null before the home's first boot as the primary), `moved` (`{to, moved_at, epoch}` or null), `snapshots` (as `home.snapshots.status`), `primary` (in the device role after a move, the primary this desktop reaches: `{name, connected, status, since, epoch, sentence}`, `status` one of `connected`, `renewing`, `unreachable`, `revoked` or `stale` (see *After a move*), `since` null while not connected and `epoch` the highest primary epoch this desktop has seen; null otherwise), `desktops` (on the primary, each desktop that holds a session to it: `{device_id, name, connected, since}`, `since` null while not connected; empty otherwise), `enrollment` (on the primary, the enrollment window opened since the engine started: `{state, expires_at}`, `state` `open`, `used` or `expired`, never the code; null otherwise), `candidates` (on the primary, the candidate primaries it holds, as `home.candidates.list` answers them; empty otherwise), `move` (the move this home started or, on a candidate, the one it waits for: `{phase, candidate, sentence}`; null when there is none), `secrets_missing` (on the primary, the ids `secret.set` takes of the secret references in its settings that did not resolve on this host, each one to enter again; empty otherwise), `primary_home` (on a linked desktop, the primary's own `home.status`, asked within 5 s; null otherwise) and `primary_missing` (on a linked desktop, the sentence while `primary_home` is missing; null otherwise). Answered locally in every role; composed on a linked desktop (see *After a move*), whose own `snapshots` list no target, its status file being a retired copy. Minimum version `2`. |
| `home.snapshots.status` | none | The snapshots view: `configured`, `recipient_set`, `interval_hours`, `running`, `next_run_at`, one row per target (`id`, `label`, `configured`, `destination`, `last_attempt_at`, `last_result` (`verified`, `failed`, `waiting` or null), `last_verified` `{at, name, epoch, size, sha256, location, key_id}` or null, `last_error`, `waiting`) and one `sentence`. Minimum version `2`. |
| `home.snapshots.run` | none | Starts a snapshot now and answers `{started: true, snapshots}`. `busy` while one runs; `unavailable` {`capability`: `snapshots`} with the daemon's sentence when nothing is configured, in the device role, or with no scheduler. Minimum version `2`. |
| `home.snapshots.passphrase` | `recovery_passphrase` (12 to 1024 bytes) | Derives the recovery key from the passphrase and keeps only its public half as `[fermix_core.snapshots] recipient`; answers `{recipient, key_id, snapshots, sentence}`, the sentence saying that snapshots written before now open only with the earlier passphrase. The passphrase is never stored, logged or answered. A shorter one is `invalid_params` with a sentence; the device role answers `unavailable`. Minimum version `2`. |
| `home.enroll.open` | none | On the primary only: opens the one enrollment window, for thirty minutes and replacing an open one, kept across an engine restart, and answers `{code, expires_at}`. The code (`fxenroll1.` and base64url, at most 2,048 characters) is single use and answered once: it is never logged, and `home.status` shows the window's `state` and `expires_at` and never the code. `unavailable` {`capability`: `home`} with the daemon's sentence in any other role, or while the rail cannot open a window. Minimum version `2`. |
| `home.candidates.list` | none | The candidate primaries this home holds, oldest first: `{candidates}`, each `{candidate_id, name, os, arch, version, node_id, instance, snapshots, enrolled_at, expires_at}` and never its keys. A candidate is held for 24 hours after it enrolled, at most four at once. `instance` (`{provider, instance_id, region}`, with `account_id` when the host gave one) is what the host said of itself, which nobody verified, and `snapshots` (`{s3_bucket, s3_region}`) the bucket it was told to keep snapshots in; either is null when the host gave none. `unavailable` {`capability`: `home`} with the daemon's sentence when the list cannot be read. Minimum version `2`. |
| `home.move.readiness` | `candidate_id` | On the primary only: what the owner reviews before moving this home to a held candidate, answered `{ready, items}`, each item `{id, status, sentence}` with `status` `ok`, `warn` or `block` and `ready` false while any item blocks. The items, in order: `keychain_secrets` (the secrets this computer keeps in its keychain move with the home, into the server's secret files; one the keychain will not give blocks, named by its id, never its value; checking reads each value, which opens the keychain and can raise its prompt, and the sentence says so), `engine_version` (a server that runs an older Fermix blocks), `disk` (the capture needs about twice the home free here; short of it blocks, with the numbers), `s3_size` (a home over one S3 upload, 5 GiB, warns where the server keeps snapshots in S3), `plugins` (plugins installed for another OS or architecture warn, named), `stays_here` (voice calls and meetings, and iMessage on a Mac, stop after the move), `cutover_gap` (Telegram messages sent during the move wait until it is done; a recurring job more than an hour late is skipped) and `serves_nothing` (this computer serves nothing during the move). A client that does not know an id shows its sentence as it is. The engine keeps the review for the start that follows it; one it cannot keep is `unavailable` {`capability`: `home`}. A candidate this home does not hold is `invalid_params` on `candidate_id`; another role is `unavailable` {`capability`: `home`}. It walks the whole home first: a client gives it at least 65 s, and a desktop forwarding it waits 60 s (*Forward deadlines*). Minimum version `2`. |
| `home.move.start` | `candidate_id`, `recovery_passphrase` (12 to 1024 bytes), `keep_as_desktop?` (boolean, true unless said) | On the primary only, and only while `home.move.readiness` has no item that blocks (otherwise `unavailable` {`capability`: `home`} with the sentence of each block). A ready review of the same candidate at most 15 minutes old is taken as it was shown, so the keychain is not read again before the move's capture reads it; with none, the engine checks now. It writes the move to a held candidate, hands this home to the device role, answers `{move_id, candidate, recovery_recipient, key_id, keep_as_desktop, sentence}`, and then restarts the engine through the daemon's one stop path; the service manager brings it back in the device role, which carries the move out. The recovery passphrase derives the key a restore of this home needs; the passphrase is never stored, logged or answered. A candidate this home does not hold is `invalid_params` on `candidate_id` and a passphrase under 12 bytes `invalid_params` on `recovery_passphrase`, each with a sentence; another role, a move already under way, or a home that never started as the primary is `unavailable` {`capability`: `home`} with the daemon's sentence. It may walk the whole home first: a client gives it at least 65 s, and a desktop forwarding it waits 60 s, answering `unconfirmed` when the primary had it and its answer was lost (*After a move*). Minimum version `2`. |

Notes that the shapes alone do not carry:

- A **Doctor session** is one of the three management operation families that are
  *runs*: it has its own session id, a whole-run budget (`local` 10000 ms,
  `network` 30000 ms), and cancellation. At most 2 sessions run concurrently
  (`busy` beyond that) and at most 8 finished sessions are retained, none older
  than 300000 ms.
- A **job** is another, and covers every long operation that is not Doctor.
  One shape serves all of them, so a client writes one poller, one progress row
  and one failure sentence rather than one per operation. Each kind carries its
  own budget: `provider_probe` 15000 ms, `auth` 300000 ms, `auth_import`
  60000 ms, `plugin_install` 600000 ms, `plugin_check` 30000 ms,
  `plugin_workspaces_discover` 60000 ms, `plugin_workspace_select` 60000 ms,
  `capability_install` 900000 ms, `meetings_signin` 660000 ms,
  `computer_use_grant` 120000 ms, `browser_install` 900000 ms, `imessage_grant`
  120000 ms, `imessage_policy_confirm` 180000 ms, `mcp_check` 75000 ms. At most 4 jobs run at once, at most one per
  kind and name (`busy` beyond either), and at most 16 finished jobs are
  retained, none older than 600000 ms. A `job_id` this daemon does not retain
  answers `unknown_job`.
- **`phase` is display copy, never a state.** It names the current step from a
  closed per-kind vocabulary — `provider_probe`: `calling`; `auth`: `binding`,
  `discovering`, `registering`, `awaiting_browser`, `verifying` (an MCP server's
  sign-in discovers and registers before the browser opens, and binds nothing
  first); `auth_import`: `reading_keychain`,
  `verifying`; `plugin_install`: `downloading`; `plugin_check`: `probing`;
  `plugin_workspaces_discover`: `listing`; `plugin_workspace_select`: `binding`;
  `capability_install`: `sidecar_downloading`, `downloading`,
  `verifying`; `meetings_signin`: `awaiting_signin`; `computer_use_grant`: none;
  `browser_install`: `sidecar_downloading`, `downloading`; `imessage_grant`: none;
  `imessage_policy_confirm`: none; `mcp_check`: `connecting`, `listing`.
  `status` is the state a client switches on. A terminal job clears its phase
  unless it `failed` or `timed_out`, where the step it stopped in is part of the
  diagnosis. A run that reports a phase outside its vocabulary fails the job:
  a client has no sentence for it and would draw nothing.
- **A job's `failure` carries the daemon's own sentence**, and its `code` is one
  of `unavailable`, `refused`, `timed_out` and `internal_error`. A terminal
  status word is not a diagnosis, so a refusal that has an operator-facing
  reason is answered as a job failure rather than as a bare capability name: the
  meeting sign-in that has no notetaker installed says so in the job.
- **`auth.start` returns the authorize url once**, on the call that starts the
  flow, together with the lifetime it is good for. A later read of the same job
  carries the job view alone. The url is never logged, never traced and never
  retained.
- A **pairing session** is the third, and it is polled rather than a job: its
  view grows while it runs, and the operator decides mid-run. `mobile.pair.start`
  opens the one pairing window and answers at once, the pane reads
  `mobile.pair.get` (every 1000 ms is the recommended cadence) until the session
  is terminal, and `mobile.pair.decide` or `mobile.pair.cancel` ends it. One
  session is open at a time (`busy` {`operation`: `mobile.pair`} for a second
  start), and at most 8 finished sessions are retained, none older than
  300000 ms; a `session_id` this daemon does not retain answers
  `unknown_pairing_session`. There is no connection lease: an abandoned window
  closes on the daemon's own 120000 ms window and on nothing else, so the one
  clock is the daemon's. `ttl_ms` is relative, like `lifecycle.prepare`'s, and
  null once the session is terminal.
- **A pairing session's `state` is the switch.** It is one of `awaiting_scan`,
  `awaiting_decision`, `approved`, `denied`, `expired`, `cancelled` and `failed`.
  `request` fills in once a phone has completed the handshake and stays on the
  terminal view, so a pane can say who was approved or denied. `outcome` is set
  on `approved` (`device_id`) and on `denied`, `expired` and `cancelled`
  (`reason`: `denied`, `timeout` or `cancelled`); `failure` is set on `failed`,
  with the daemon's own sentence and a `code` of `unavailable`, `refused` or
  `internal_error`. A start refused for a reason the operator can act on (the
  channel is off, it could not start this boot, it was turned on and has not
  started yet, the gateway identity is incomplete, the paired-device list could
  not be read, the listener could not start) answers a `failed` view with a null
  `session_id` and a null `uri`: nothing was opened and there is nothing to
  poll.
- **`mobile.pair.start` returns the pairing link once**, as `uri`, on the call
  that opens the window. It carries the one-time secret the phone pairs with, so
  it is never logged, never traced and never retained, and no later read
  repeats it. The pane draws the QR code from it.
- **Only a phone whose secure hardware the daemon verified reaches the
  owner.** The phone's key attestation is verified before a request appears
  (see *Attestation* in the mobile protocol), so a request's
  `attestation.status` is `verified`, with the daemon's sentence, `build_role`
  is the role of the key the app is signed with, and `boot_state` is
  `{verified: true, locked: true}`. A request's `platform` is the phone's own
  word. A refused proof never reaches the owner: the session ends `failed`
  with `request` null, a `refused` failure whose sentence names the check that
  failed, or an `unavailable` failure when Google's attestation service could
  not be reached. A device paired with a verified attestation carries
  `platform`, `signer_role` and `boot_state`; one paired before the daemon
  verified attestation carries them null and keeps working.
- **`mobile.status`, `mobile.devices.list` and `mobile.devices.revoke` answer
  with the channel off**, so a pane can always read the state and the owner
  can always forget a phone: while the channel is not running the paired
  phones are read from, and forgotten in, the paired-device file. The switch
  is live: a `settings.apply` or a reload that moves it starts or stops the
  channel at once, and a write says in `side_effects` when the channel did not
  follow it. `enabled` is the switch and `started` whether the channel runs;
  they differ when the channel could not start (`refused`), or when setup was
  not complete at boot, until the next start. Every verb goes by `started`,
  never by the switch. A boot whose setup was not finished starts no channel,
  so while setup still is not finished `hold` is `setup`, the pairing verbs
  are refused with "The phone channel starts once setup is finished.", and a
  restart would start nothing. Once setup is finished `hold` is null and,
  while the switch is on, the restart reasons carry a `channels` reason,
  because the next start runs it.
  `refused` is true when the channel could not start this boot, and
  `refusal` names the class: `memory_disabled` (the conversation lives in the
  memory store, which is off), `identity`, `attachment_manifest` or
  `trust_store`; the daemon log says what to repair. `paired_devices` counts
  the running channel's phones and is 0 while it is not running.
  `identity.fingerprint` is the SHA-256 of the gateway public key a phone
  pins, lowercase hex in groups of four, null until the first pairing creates
  it. A decide with no phone waiting and a revoke of an id no phone has are
  `invalid_params` with the daemon's sentence. `unavailable`
  {`capability`: `mobile`} with no `sentence` means the phone channel could
  not answer at all: `mobile.pair.get`, `mobile.pair.decide` and
  `mobile.pair.cancel` answer it while the channel is not running.
- **A running channel that cannot listen stays up.** `listener.status` is
  `unavailable` when the channel runs but cannot listen on its address, with
  `listener.reason` one of `address_unavailable` (the address is not up yet,
  such as a tailnet address at login), `address_in_use` (another program holds
  the port), `permission_denied` or `listen_failed`. The channel retries on
  its own, from one second doubling to a minute, and stops retrying after a
  day until the next restart. `listener.reason` is null in every other state.
- **Push connects when there is something to send.** `apns.delivery` is
  `ready`, `degraded` while a connection to Apple is being made or when the
  last one failed or was lost (`apns.reason`: `connecting`, `connect_failed`
  or `connection_lost`; the next push reconnects), or `down` when no push
  dispatcher runs: the channel is not running, push is off, or its
  settings did not resolve (a key the keychain could not give, one that is
  not a P-256 key, a missing or invalid field), when `apns.credentials` reads
  `missing` and the rest of the channel runs. A connect is given up after ten
  seconds, and the status answers while one runs.
- **Remote reach lets a paired phone reach this daemon from any network**,
  through Fermix's relays (M62). `remote.state` is `off` (its switch is off,
  or the channel is not running), `dormant` (no phone has been paired yet;
  relay contact starts with the first pairing window), `helper_missing` (this
  build carries no `fermix-iroh`; the daemon log names the path),
  `starting`, `ready` or `failed`. While `ready`, `endpoint_id` is the
  daemon's iroh endpoint id, `relay` the URL of the relay it is reached
  through, `connected` whether it is connected to that relay right now, and
  `relay_error` the relay connection's last error, at most 512 bytes; while
  `failed`, `failure` is why, in the helper's own words where it gave them.
  Both have control characters removed, so a client shows them as written.
  Each is null, and `connected` false, in every other state. `refused` counts the remote
  connections the helper turned away by reason: `busy` (64 already
  connected), `alpn` (not a Fermix phone) and `bridge_unreachable` (the
  daemon was not taking them). A rail that fails is retried on its own, from
  one second doubling to a minute, and given up after a day until the next
  restart; a helper that disagrees with this daemon's protocol, iroh version
  or key is not retried.
- **Pairing and forgetting a device are the owner's decisions.**
  `mobile.pair.start`, `mobile.pair.decide`, `mobile.pair.cancel` and
  `mobile.devices.revoke` answer `unavailable` {`capability`: `mobile`,
  `sentence`: "Only the owner can pair or forget a phone; run this from your
  own terminal."} to a process the daemon itself started (a shell command the
  agent ran, a coding harness), to a detached process nobody is watching, and
  to a caller the daemon cannot place, and the daemon log says so. The
  sentence is what tells this refusal from a channel that is not running.
  Reading a session and the status stay open to every caller.
- **Cue writes, the two values handed out and a proposal's answer are the
  owner's decisions too.** `cues.sources.add`, `.update`, `.remove`,
  `.enable`, `.disable`, `.token.new`, `.url.get`, `cues.mandates.add`,
  `.update`, `.remove`, `.enable`, `.disable`, `.approve` and
  `cues.proposals.decide` answer `unavailable` {`capability`: `cues`,
  `sentence`: "Only the owner can change cues: use the Fermix app or your own
  terminal."} to the same callers. So do the two cue writes that ride a
  generic method: `secret.set` and `secret.clear` on a `cue_source:` id, and
  `settings.apply` on the `cues` section, whatever its values, since turning
  `cues_mandates_enabled` back on undoes the owner's stop of every watcher action. The
  capability and the sentence are the request's family's. This raises the bar
  and authenticates nobody: it stops a model's own command from approving a
  mandate, answering a proposal or switching mandates back on. Every cue read
  stays open, and so does every other secret and settings section.
- **Opening an enrollment code, reviewing and starting a move, and setting
  the recovery passphrase are the owner's decisions (M75).**
  `home.enroll.open`, `home.move.readiness` (it reads every keychain secret
  the move would carry), `home.move.start` and `home.snapshots.passphrase`
  answer `unavailable`
  {`capability`: `home`, `sentence`: "Only the owner can move Fermix or set
  its recovery passphrase: use the Fermix app or your own terminal."} to the
  same callers, so a command the agent ran can neither hand this home to a
  server nor replace the key its snapshots are encrypted to. `home.status`,
  `home.candidates.list`, `home.snapshots.status` and `home.snapshots.run`
  stay open.
- **`channels.mobile` is the phone channel's settings section**: the enable
  switch and the remote-reach switch `mobile_iroh` (on by default), each
  applied the moment it is written (their rows' `restart` is false), and the
  port, the address it listens on and the local-network announcement, which
  are read when the channel starts, are boot-bound and are `advanced`. Neither
  the address nor the announcement reaches remote reach: only its own switch
  keeps a phone to the home network and Tailscale. Remote reach is
  switched within a running channel: with the channel off it is read when the
  channel starts, and a write says in `side_effects` when the rail did not
  follow it. It is a section of its own rather than a
  channels-inventory entry, because the phone channel has no credential.
  `setup.state.get` carries a `mobile` channel row after the inventory
  channels, always `configured`, with mode `listener` while it is enabled.
- **`browser` is the managed task browser's section**, under pane `browser`,
  published on every install. Its first row, `browser_executable`, is read-only
  and says which browser the launcher would start for a task: `value` is that
  browser's name (`Google Chrome`, `Chromium`, `Google Chrome Canary`, `Chrome`,
  `Google Chrome for Testing` for the Chromium Fermix downloads, or `The
  configured browser` for one set by path), and null when there is none, with
  the daemon's sentence in `footer`: `No Chrome or Chromium is installed.`, or
  the refusal of a browser configuration the launcher would not start, which a
  download does not clear. A path never crosses the wire. The other three rows
  are the `[fermix_core.browser]` keys a person sets. `browser_default_profile`
  is how tasks run, and its options are the managed profile names, which is how
  that section already spells it: `fermix` (automatically: in a window where
  there is a display, otherwise in the background), `fermix_headless` and
  `fermix_visible`. `browser_max_tabs` is a whole number from 1, with no
  ceiling. `browser_allowed_hosts` replaces the whole list, and its value is the
  list in force: the shipped default until the file names one. Every row
  carries `restart: false`, because a call reads the section when it runs; a
  browser already running takes a new tab cap when it next starts.
  `settings.apply` refuses a value the browser would refuse at launch, in the
  browser's own sentence.
- **`web_search` also carries place search's backend.** After
  `web_search_backend`, the row `place_search_backend` (a choice, `Place
  search`) is `[fermix_core.tools.place_search] backend`, and its `value` is the
  backend in force: the one the file names, or the build's default when it
  names none (`apple_maps` in the Fermix Mac app's engine, which carries the
  Apple Maps helper, `brave` in the Homebrew and Linux builds). Its options are
  the ones this build can run: `apple_maps` (`Apple Maps`, hint `Needs no key`)
  and `brave` (`Brave`) where the build carries the helper, `brave` alone
  everywhere else, where `settings.apply` refuses `apple_maps` as a value the
  row does not publish. The `brave_api_key`
  row stands whenever web search or place search uses Brave, its footer
  `Also powers place search.` when both do and `Powers place search.` when only
  place search does; with neither on Brave it is not published. A call reads
  the section when it runs, so the row carries the section's usual `restart`.
- **`browser.install.start` completes only once the launcher finds a
  browser.** It runs the meeting notetaker's own install step (the notetaker's
  helper, then the Chromium build that helper is pinned to, about 150 MB, and a
  fast no-op when it is already there) and then asks the launcher which browser
  tasks now run in. It completes with `result` {`installed`: true, `browser`:
  that browser's name}. A machine the notetaker has no build for, a Chromium
  step that fails, and a download the launcher still cannot find each fail the
  job with the daemon's sentence. One download runs at a time (`busy`
  {`operation`: `browser_install`}).
- **A live model listing never degrades to the catalog.** The two answer
  different questions, so a live fetch that fails answers `unavailable`
  {`capability`: `model_listing`} and `source` always names where the rows on
  the wire came from. A provider with no live listing of its own, whose models
  ship in the catalog, answers `live` true with that catalog and `source`
  `catalog`, since there is no live fetch to fail.
- **`default_model` is the model in force, never the config value alone.** A
  provider row in `setup.state.get`, the Model row of that provider's settings
  section and `provider.model` in `overview.get` carry the model the daemon
  calls the provider with: the one chosen in Settings, or the catalog default
  until one is. A sign-in that has just completed therefore names its model at
  once, and Doctor probes the same one. Engines before this published `null`,
  or an empty value, until a model was chosen, so a client keeps accepting both.
- **`computer_use.permissions.get` never prompts**, and `installed` comes from
  the installer rather than from the probe: the feature being switched off says
  nothing about whether the helper is on disk, and that is exactly what decides
  whether a surface offers "install it" or "turn it on".
- **iMessage exists only on a Mac.** The three `imessage.*` methods answer
  `unavailable` {`capability`: `imessage`} anywhere else, `settings.sections`
  publishes no `channels.imessage` there, and `settings.get` refuses that
  section. On a Mac, `channels.imessage` carries three boot-bound rows:
  `imessage_owner_user_id` (`text`); `imessage_allowed_sender_ids`, the guests
  (`list`); and the `imessage_enabled` switch. There is no account row: the
  helper derives the account when it confirms the recipients. Saving the owner
  or the guests never turns the channel on: only its switch does.
  `capabilities.install.start` {`target`: `imessage_helper`} installs Fermix
  Messages: it checks the download's sha256, extracts the bundle, verifies its
  signature and Team ID, places it and registers it with LaunchServices, and a
  refusal names the check that stopped it.
- **`imessage.permissions.get` never prompts.** With `installed: false` every
  other field is null. `full_disk_access` is `granted` or `denied`; `db` is
  `readable`, `missing`, `unreadable` or `schema_unexpected`; `automation` is
  `granted`, `denied`, `not_determined` or `unknown` (Messages is not running);
  `signed_in` is null while Automation is not granted, because the helper cannot
  ask Messages without it; `policy` is `confirmed`, `unconfirmed` or `absent`.
  `policy_matches_config` is true only when the confirmed recipients are exactly
  the saved ones; anything else is the state "Awaiting confirmation", cleared by
  `imessage.policy.confirm` and never by the engine rewriting the helper's
  record. A probe that cannot run answers `unavailable` {`capability`:
  `imessage_permissions`}.
- **An iMessage grant or confirmation waits on a person**, so each is a job
  whose `result` is the permissions view. A confirmation's `result` adds
  `outcome`: `confirmed`, or `policy_refused` when the owner pressed Cancel on
  the helper's dialog. Cancel is a decision, so it completes the job rather than
  failing it. A confirmation with no saved owner, with an owner that is not a
  handle of the Messages account on this Mac, or with an owner that is the
  address Messages on this Mac is signed in as, fails `refused` with the
  daemon's sentence; the last one names the fix, signing Messages in with a
  separate Apple ID for Fermix. One of each runs at a time (`busy` {`operation`:
  `imessage_grant`} or `imessage_policy_confirm`).
- A **check status** is one of `passed`, `warning`, `failed`, `not_applicable`,
  `unavailable`, `skipped`, `cancelled`, `timed_out`. `not_applicable` means
  this distribution does not have the check (the two distribution rows under
  `macos_app`); `unavailable` means the check itself could not answer. A session
  `summary` carries one count per status.
- **Readiness is split into gating and advisory.** A failure carries `gating`,
  the `pane` that can clear it, and a closed-set `detail_key`. Provider
  failures gate; personalization, the channels, realtime, and allowed
  sandbox environment variables the daemon cannot read (`sandbox:env_missing`,
  `sandbox:env_helper_failed`, pane `sandbox`, one failure per cause naming
  every affected variable, with `component` `sandbox:env:missing` or
  `sandbox:env:helper_failed`) are advisory. `status` is `ready` exactly
  when no gating failure remains, and every advisory failure stays in the list,
  so a surface never needs a second definition of ready. Personalization is
  advisory because the daemon's first boot seeds it from the machine (the
  system time zone, the account's full name, a default style), so its row
  fires only where the machine could not answer; engines before this gated on
  it, so a client keeps reading `gating` rather than assuming it.
- **Restart truth has one owner.** `restart.required` and `restart.reasons` come
  from the daemon's two baselines: the application environment captured at boot,
  and the parsed settings file as this daemon last saw it. The sentence for each
  reason is the daemon's; a client renders it and never composes its own.
- **`coexistence.config_state`** is `clear`, `external_change` (the settings file
  was edited by something else, and every write refuses until it is read again),
  or `config_unreadable` (the file cannot be parsed, which is never answered with
  a reload).
- **`coexistence.secret_acl_restricted.present` is `null` until Doctor has run.**
  Deciding whether a stored key is readable means reading it, which costs one
  keychain subprocess per key and prompts on exactly the keys the row exists to
  name. `setup.state.get` never does that: it publishes the last measurement the
  `secret_acl_restricted` Doctor check took, and `null` means "not measured",
  which is not the same answer as `false`.
- **A settings row is a fixed record.** Every field is present on every row,
  `null` where it does not apply, so a client decodes one shape rather than
  probing for keys. `kind` is one of `toggle`, `choice`, `text`, `number`,
  `secret` and `list`; `unit` and `format` are meaningful on a number row only;
  `present` is meaningful on a secret row only, and a secret row never carries a
  value.
- **`options` is the value space unless `suggestions` says otherwise.** On a
  choice row with `suggestions: false`, `settings.apply` refuses a value that is
  not among the options; render a closed menu. On a choice row with
  `suggestions: true` — the time zone row, the communication style row and the
  four model rows — the options are only what a client may offer inline, an
  off-list value is accepted wherever the key's own validator takes it, and a
  native picker may send any zone the database knows or any model the vendor
  ships. `suggestions` is `false` on every non-choice kind.
- **A text value that names something is one line.** `settings.apply` trims the
  ends of a text, suggestion or list value, so a pasted trailing line break
  saves, and refuses one with a control character left inside it (`This setting
  takes a single line of text.`). The two prose rows, the meeting announcement
  and the communication style, take line breaks and keep them as sent.
- **A `disabled` option is shown and cannot be chosen.** Its `hint` is never
  null and says why: show the option unselectable, with its hint inline or on
  hover, rather than hiding it. `settings.apply` refuses a disabled value with
  that same sentence. Today the two transcription backend rows publish one:
  `local`, on a machine this build has no on-device speech engine for.
- **`restart` on a row is derived, never declared.** A row is flagged exactly
  when its own configuration section is one the daemon compares against the
  values it read at boot, so a row can never deny a restart the next
  `overview.get` asks for. A section can have a part that is read on every use
  instead: the sandbox environment policy (the allowed names, the deny list and
  where each value comes from) is read by every command, so the allowed
  environment variables row and every name row below it carry `restart: false`,
  while the sandbox mode and command profile rows still carry `true`.
- **`read_only` marks a row `settings.apply` will not take**, rendered as a plain
  labelled row rather than a control whose save always refuses.
- **`info` is the longer explanation, kept behind an info control.** `footer` is
  the one short line under the control and is always shown; `info` is a
  paragraph a client puts behind an `(i)` beside the row and reveals on demand.
  It is `null` on every row with nothing more to say, which is most of them.
  A row carries one when its choice has a consequence its label cannot say,
  such as the Venice model row, where the privacy tier in each model's label is two
  words that mean materially different things; the secrets section's store
  row, where the choice trades a keyring password for a file that is not
  encrypted; and the phone channel's reach-from-anywhere switch, which says
  what turning it off keeps the phone to.
- **`example` is a sample value for an empty field.** A client shows it in an
  empty text or list field, in place of its own empty prompt ("Not set", "New
  entry"), so the field shows what goes in it. It is never a default: nothing
  is saved from it, and a client never sends it. It is `null` on every row of
  another kind and on every row with nothing to show; today the fields of a
  stream source carry one.
- **`advanced` marks a row most people never need to change.** A client draws
  a section's advanced rows after its other rows, under one disclosure that
  starts closed; a section with none draws no disclosure. It says nothing about
  how the row applies, which is `restart`'s job. Today the phone channel's
  port, listen address and local-network announcement carry it.
- **The secrets section chooses where a new secret is kept.** Section
  `secrets`, pane `secrets`, publishes one closed choice row, `secret_store`:
  `keyring` (the default, and what a home that never chose reads as) or `file`,
  one `0600` file per secret under the Fermix home's `secrets/` directory. It
  exists for a Linux desktop that logs in with a fingerprint or automatically,
  where the login keyring stays locked and every save asks for its password.
  `settings.apply` records the choice in `[fermix_core] secret_store` and applies
  it at once, so the very next `secret.set` writes to the chosen store and the
  row carries `restart: false`. Choosing moves nothing: a secret already saved
  stays in the store it was saved to and is read back from there, and `fermix
  setup --migrate-secrets` is what moves them. `secret.set` refusing a locked
  keyring (`secret_store_failed`, reason `locked`) is unchanged.
- **The sandbox section publishes one row per environment variable name.**
  After `sandbox_env_allow` come the allowed names in allow-list order, then
  the names Fermix still stores but no longer allows, sorted. Each row's key is
  `env:<NAME>` and its label is the name itself. A stored name is a `secret`
  row with `present: true`, and one no longer allowed says in its footer that
  commands do not get it until the name is allowed again. An allowed name with
  nothing stored is a `secret` row with `present: false`, whose footer says
  commands get it only if Fermix was started with it. A name whose value comes
  from a helper command or from another variable, and a name Fermix cannot
  store, is a read-only `text` row whose footer says where the value comes from;
  for another variable, `value` is that variable's name. `present` is read from
  the settings file alone, like every other secret row. Removing a name from
  the allow list keeps its stored value, so its row stays reachable: allowing
  the name again reuses the value, and `secret.clear` removes it.
- **The voice section's model row selects its engine.** `realtime_model`
  publishes every model the engines ship, in one list, each option labelled
  with the engine it selects: `openai_realtime` (the Realtime API, which runs
  tools inside the voice session), `openai_live` (the Live API, which
  delegates every tool call, memory read and reasoning step back to the Fermix
  agent and bills by the minute) or `xai_realtime` (Grok Voice on SpaceXAI,
  which delegates the same way and bills by the minute). `openai_live` and
  `xai_realtime` are the task engines. There is no engine row; the engine is
  derived from the model and stored as `realtime.engine`, with the provider it
  dials as `realtime.provider` (`openai` or `xai`), and `settings.apply` refuses
  `realtime_engine` as a key this section does not have. The rest of the section
  is scoped to the engine that model implies: `realtime_voice` publishes the
  voices of that engine and nothing else, `realtime_reasoning_effort` is a
  Realtime session setting with no task-engine equivalent and is absent under
  both task engines, and `realtime_backend` is present only under a task engine,
  is read-only, and names the primary provider and model that answer while the
  engine speaks. `realtime_conversation` ("Voice calls join the chat") is present
  only under a task engine too, a choice of `chat` or `private` stored as
  `realtime.conversation`: `chat`, the value in force while the key is unset,
  runs a call's hand-offs in the chat's own conversation, and `private` keeps
  them in one of the call's own. The key row is the voice provider's own slot:
  `openai_api_key` under both OpenAI engines and `xai_api_key` under Grok, which
  takes an API key only (a SpaceXAI sign-in does not authorize voice). Applying a
  model of another engine therefore moves the engine and its provider with it,
  adds or removes the reasoning effort, moves a voice the new engine does not
  ship to that engine's default, drops a chosen `realtime_conversation` on the
  way to Realtime, and on the way to Grok turns off screen sharing during calls,
  which Grok does not support. The result names every key the daemon derived in
  `applied` — including `realtime_engine`, which is a derived key rather than a
  row — with a sentence for each in `side_effects` (screen sharing has a
  sentence and no row); reload the section when one of those keys appears,
  because its row list has changed. `overview.get` reports the same selection as
  `realtime.engine`, null while voice is disabled.
- **Secrets travel inbound only, in `secret.set`, one per call.** Every other
  method reports presence as a boolean. "Present" means a reference or a value
  sits at that key's own path, never "the keyring holds an item": a key stored
  without its reference is never read back, so calling it present would describe
  a credential the runtime cannot use.
- **A stored value is not always the value in use.** For the provider API
  keys, the WhatsApp, Discord and Slack channel secrets and the APNs key, a
  nonblank environment variable of the key's own name (`ANTHROPIC_API_KEY`,
  `DISCORD_BOT_TOKEN`, …) in the daemon's environment overrides the stored value
  at every start. `secret.set` and `secret.clear` name that variable in
  `environment_override` (null when the stored value is the one in use, and
  null for every other family), so storing a value the daemon will not use
  still succeeds and says so. The field is optional: an older daemon omits it,
  which a client renders as no override reported.
- **`id` names one of seven families.** A bare registry key (`openai_api_key`,
  `telegram_bot_token`, …), `plugin:<name>` for a plugin's own token,
  `oauth_client:<provider>` for a sign-in client's secret,
  `anthropic_setup_token`, `env:<NAME>` for a sandbox environment variable,
  `mcp:<name>/…` for a value an MCP server declares, and `cue_source:<ref>:…`
  for what the owner types for a cue source.
  The first three take the same keychain-first write.
  The fourth is a different mechanism and is documented as such: a
  `claude setup-token` value is a long-lived subscription credential, so it is
  stored in the auth store rather than the keychain, storing one also selects
  the Anthropic sign-in route that reads it (a stored token the runtime never
  calls is not a connection), and clearing one is the same operation as
  `auth.logout anthropic`. Its `present` is "a setup token is stored", not "an
  Anthropic sign-in exists": an adopted Claude Code login lives under the same
  profile and is reported by `setup.state.get`'s account row instead.
- **`env:<NAME>` stores a value every sandboxed command receives as `NAME`.**
  It is the key of the sandbox section's name rows, and the family is open:
  `NAME` is any name matching `^[A-Za-z_][A-Za-z0-9_]{0,127}$` exactly, except
  `PATH`, `HOME`, `USER`, `LANG`, `SHELL`, `TMPDIR`, `FERMIX_HOME` and any name
  starting `LC_`, which Fermix sets itself. The value is one line of 1 to 8,192
  bytes of printable ASCII, space to `~` (so no NUL, CR, LF, tab or non-ASCII
  character), and at most 64 names are stored. `secret.set`
  stores the value in the OS secret store in a namespace of its own (a skill's
  `OPENAI_API_KEY` never touches the OpenAI provider's key), reads it back to
  verify it, and then allows the name, removes it from the deny list and points
  the name at the stored value in one settings write. It refuses a name whose
  value already comes from a helper command or another variable, because
  storing would silently change where the value comes from. `secret.clear`
  deletes the stored value first and then the reference, so a refused delete
  changes nothing; the name stays allowed and reads the environment Fermix was
  started with. Neither ever asks for a restart. Where no OS secret store
  exists, `secret.set` answers `secret_store_failed` with reason `unavailable`.
  `present` is "the settings file points this name at a stored value".
- **`mcp:<name>/env/<NAME>`, `mcp:<name>/header/<Header-Name>` and
  `mcp:<name>/client_secret` store the values an MCP server declares**: a local
  server's `env_names`, a remote server's headers (`header_names` and its
  `key_header`), and the secret of its `oauth_client_id`, which is optional: a
  client ID with no secret is a pre-registered public client, so a server
  never waits for it, and `oauth_client.secret_present` says whether one is
  stored. The family is open,
  like `env:`: an id is accepted only when the server exists and declares that
  name, and the server's block in `config.toml` is the reference, so storing
  writes nothing else and `present` is "the store reads the value back". The
  value is one line of 1 to 8,192 bytes; an `Authorization` key is sent as
  `Bearer <value>`, so a pasted `Bearer …` is stored as what follows it.
  Storing the last value a server needs starts it, storing a new one
  restarts it, and clearing one it runs with stops it. Both answer the shape
  `env:` answers, with `environment_override` null. A value pasted into the
  add form never travels back: `mcp.servers.draft` holds it under a
  `draft_id`, and `mcp.servers.add` stores it. A server whose name was
  written by hand outside the name rule holds no values, and the refusal says to
  add it again under a lowercase name.
- **`cue_source:<ref>:key` and `cue_source:<ref>:secret` store what the owner
  types for a cue source.** An id is accepted only when the source exists and
  its kind declares the field (a webhook's signing or shared secret, a feed's
  or a stream's key and secret). The value is one line of 1 to 8,192 bytes.
  Storing writes the value and the reference that names it in one settings
  write, so storing the last secret a source waits for starts it; clearing
  deletes the value first, then the reference, and a source that needs that
  secret waits for it again. `present` is "the settings file points this
  field at a stored value". `cue_source:<ref>:token` and
  `cue_source:<ref>:path_secret` are Fermix's to make and are refused with
  `invalid_params` and a sentence: a new token comes from
  `cues.sources.token.new`, an address from `cues.sources.url.get`. On a build
  without cues the family answers `unavailable` {`capability`: `cues`}. Both
  methods on this family are the owner's decisions, as every cue write is: a
  caller the daemon does not place as the owner (a process it started, a
  detached one, or one it cannot place) is answered `unavailable`
  {`capability`: `cues`, `sentence`: "Only the owner can change cues: use the
  Fermix app or your own terminal."}, and nothing is stored or cleared.
- **A plugin row is one shape for two halves.** An installed plugin and a
  catalog entry that has never been fetched publish the same fields, so a client
  decodes one record rather than two. `installed` is what separates them.
- **`consent_sentence` is always present, and it names where the code runs.**
  `remote_mcp` runs on the plugin's own servers, `local_stdio` runs on this Mac
  as a separate process, and a plugin with no runtime block runs inside Fermix
  itself. There is no absent case and no default: a hosted plugin rendering the
  local-process line is the one defect this field exists to prevent, and
  `remote_disclosure` names what leaves this Mac wherever the runtime is hosted.
- **The status vocabulary and the verb vocabulary stay on this side.** A row
  carries the daemon's `status_sentence` and its `primary_verb`; the `status`
  atom is published for logs and support, and nothing on the far side is
  expected to have words for it. `primary_verb` is `null` where the next step is
  not a button this surface owns, and a client then uses its own word for
  whatever control it drew.
- **A word is not a routing key: `primary_action` and `actions` are.** Every
  verb is published twice — `verbs` carries the words to draw, `actions` carries
  one closed id per word IN THE SAME ORDER saying which method that button runs,
  and `primary_verb`/`primary_action` are the same pair for the verb the row
  leads with. The ids are `install`, `enable`, `disable`, `sign_in`,
  `add_token`, `replace_token`, `set_up_client`, `choose_workspace`, `check` and
  `disconnect`; `primary_action` is `null` exactly when `primary_verb` is.
  Paint `verbs[i]`, route on `actions[i]`, and draw no buttons at all when
  `verbs` is empty. Deriving the method from `status` instead is what put a
  button labelled "Choose workspace" onto the health check, and one labelled
  "Set up the sign-in client" onto a sign-in the daemon refuses. Two words share
  one id: "Sign in" and "Sign in again" are the same method with different copy.
- **A setting names the control it is, and a switch has exactly two words.**
  Every entry in `settings` carries a `kind`: `text` is a free-text field, and
  `boolean` is a switch whose value is the string `true` or `false` and nothing
  else. `plugins.setting.set` refuses any other value for a `boolean` setting
  with "This setting is a switch: send true or false.", and refuses a blank
  value for either kind; an unwritten setting is simply absent from the row's
  `value`, which is what off is. The daemon always publishes `kind`, but it is
  optional for older protocol-2 engines, and an absent one reads as `text`.
  The two words are the spelling a manifest's per-tool gate reads, so a switch
  drawn as a text field is how an operator turns a tool on by typing `TRUE` and
  finds it still off.
- **`credential_present` is published rather than inferred.** A plugin that
  authenticates with a typed token never has an `account_label`, so reading
  presence off that field would hide the token that is actually stored.
- **A discovery is republished on the row, not in the job.** A job result is
  flat scalars only, so `plugins.workspaces.discover.start` records what it
  found and `plugins.list` carries it in `workspaces`. It is boot-bound: a
  restart clears it, and a new discovery replaces the previous list.
- **Native driver features are not integrations.** Computer use, computer
  history and the meeting notetaker are settings sections with their own panes
  and their own switches, so they never appear as plugin rows even where the
  catalog carries an entry for their helper.
- **An MCP server row is the daemon's, like a plugin row.** One row shape
  serves every operator MCP server, whether the owner added it here, imported
  it, or wrote its `[mcp.servers.<name>]` block by hand (`origin` null). Every
  field is present on every row, null where the transport has none, except
  `tools`, which only `mcp.servers.get` carries: 32 servers of 256 described
  tools would pass the result bound, so the list carries `tool_count` and
  `tools_on` alone. `consent_sentence` always says where the code runs and what
  leaves this Mac: a local server runs on this Mac as a separate program with
  the owner's access, a remote one on the host its URL names.
- **The status is derived in one order, and the row switches on actions.** `off`
  (turned off), `failed` for a server that names nothing to start (a local one
  without its command, a remote one without its URL, which only a hand edit
  writes; its sentence says what to add, and it offers only `disable`),
  `needs_secret` (a value it needs is not stored, so the server does not start;
  the sentence names what it waits for), `needs_sign_in` (an `auto` server the
  server itself asked to sign in), `starting` (connecting, or no status yet for
  a server that runs), `connected`, `retrying` (the last connection failed and
  the daemon is starting it again), `failed` (it stopped trying). The first that
  holds wins. The status is published for logs and support; a client draws
  `status_sentence` and switches on `primary_action` and `actions`, which are
  `check`, `enable`, `disable`, `sign_in` and `sign_out`, in that order. `check`
  is offered while a server is `connected`, `retrying` or `failed`, and a
  `failed` server leads with it; an `off` server offers and leads with `enable`
  alone. `needs_sign_in` also covers an `auto` server that asked to be signed
  in again for more access. `last_error` is the daemon's sentence for the
  failure while a server is `retrying` or `failed`, and null otherwise.
- **An `auto` server's sign-in is on its row.** `auth.state` is `signed_in`
  with a grant the server can use, `expired` when its authorization server
  refused to refresh it, `signed_out` where the server asked for a sign-in and
  there is no grant, and `not_needed` otherwise; `account_label` (the
  account's email, user name or name, else the authorization server's host)
  and `issuer` (the authorization server) name the grant, and are null without
  one. `sign_in` is offered, and led with, where the server asks for a sign-in,
  where the grant expired, and where one of its tools asked for more access than
  the grant gives (`status_sentence` then says so beside its tools); `sign_out`
  is offered while signed in. A `header` or `none` server offers neither.
- **An MCP server signs in through `auth.start mcp:<name>`.** The job discovers
  the server's authorization server the way the MCP authorization
  specification orders it (the server's `401` challenge, its protected resource
  metadata, then its authorization server's metadata), with no redirect
  followed and every address held to the rule its own URL is. It registers
  with the server's `oauth_client_id` (and `mcp:<name>/client_secret` when
  stored; without one it is a public client), which stays bound to the
  authorization server it was signed in with: through a sign-out, and through
  a server that names another, where a sign-in with the same client ID fails
  the job with a sentence naming both before the secret is read or the browser
  opens, until the owner enters another client ID or removes and adds the
  server again; else with Fermix's client metadata document
  (`https://fermix.ai/oauth/mcp-client.json`) where the authorization server
  takes one, else by dynamic client registration, which names the exact
  loopback redirect the sign-in uses, port included; its client and port are
  kept for the next sign-in to the same authorization server, which uses that
  port again, or registers again where the port is taken. The browser sign-in uses PKCE
  and names the server as the resource; a reply from another authorization
  server is refused. A sign-in that completes starts the server once and its
  result carries `account_label`. The grant lives in the daemon's auth store,
  never in `config.toml` and never on the wire; it is refreshed before it
  expires and once when the server refuses it, is not used once the server
  names another authorization server, and is deleted with the server.
- **`server_info` and the tools are what the server last said.** Both come from
  the server's last connection, so a server that is off or starting again still
  shows them; `server_info` is null before a server first connects. A tool's
  `read_only` and `destructive` are the server's own `readOnlyHint` and
  `destructiveHint` as it declared them, an absent hint being false; they inform
  the owner and decide nothing. This is not the MCP specification's default,
  which takes a tool that declares nothing as destructive, and a tool declared
  read-only is never destructive. `enabled` is false for a tool the owner hid
  from the agent, and `tools_on` counts the rest. Only a tool whose name is at
  most 128 bytes is described, so a tool with a longer name is counted in
  `tool_count`, not listed in `tools`, and counted as on in `tools_on`.
- **A form writes a server as fields, and a refusal names the field.**
  `command_line` is one line, split as a shell splits one simple command: blanks
  separate words, quotes and `\` keep what they cover, and a line that needs a
  shell (a pipe, a redirection, a list, `$`, a leading `NAME=value`) is refused
  rather than run as something else. The one expansion is a shell's `~`: an
  unquoted `~` that starts a word, alone or before a `/`, is the home folder, in
  `command_line` and in `cwd`, and the server is written with the absolute path
  that runs, which the row's `location` shows; a quoted `~` stays as it is, and
  `~name` is refused. A local server takes `command_line`, `cwd` and
  `env_names`; a remote one `url`, `auth` (`auto`, the default, `header` or
  `none`), `key_header`, `header_names` and `oauth_client_id`; the other
  transport's fields are refused. `header_names` are the headers besides the
  key's own, which `key_header` names and the row reports as `auth.key_header`.
  A URL is `https`, or `http` only to this Mac. On an update a null clears a
  nullable field (`cwd`, `key_header`, `oauth_client_id`) and a list replaces
  the one it names. Every refusal is `invalid_params` with the daemon's
  `sentence` and the `field` a form marks, named as the form names it. Values
  never ride these methods: they follow through `secret.set mcp:<name>/…`, or
  an add's `draft_id`, and the server starts once the last one is stored. Every write applies to the one
  server it names, with no restart, and refuses with `external_change` while the
  settings file was changed outside Fermix.
- **A draft fills the add form, and writes nothing.** `mcp.servers.draft`
  reads one `text` of at most 65536 bytes: a URL (`https`, or `http` only to
  this Mac), a command line (split as `command_line` is, with its refusals and
  its `~`), JSON (an `mcpServers` map as Claude Desktop, Claude Code, Cursor and
  Windsurf write it, a `servers` map as VS Code writes it, a bare map of names to
  servers, or one server object, with `command`, `args`, `env` and `cwd`, or
  `url` or `serverUrl` with `headers`, and `type` or `transport` of `stdio`,
  `http`, `streamable-http` or `sse`), a `claude mcp add` line (`--transport`,
  `--scope`, `-e`, `-H`, a name, then a URL or `--` and a command) or a `claude
  mcp add-json` line, or a Codex block of `[mcp_servers.<name>]` tables. It
  answers at most 32 drafts, in the text's order (a Codex block's by name).
  Every field of a draft is present, null where the transport has none.
  `command_line` is the words that will run, a leading `~` written out;
  `resolved_command` is the program a local command runs and `command_sentence`
  says `Runs <program>` or the row's own sentence for a program this Mac does
  not have. The first draft after the daemon starts may begin reading the login
  shell's PATH and waits for it only briefly, so a bare command's
  `resolved_command` and `command_sentence` may be null, and the next draft has
  them. A server keeps the name its source gives it where a new server may take
  that name; otherwise the name comes from the URL's host, the label before its
  public suffix (`mcp.linear.app` is `linear`, `eu.mcp.sentry.io` is `sentry`),
  or the command's package (`uvx mcp-server-fetch` is `fetch`).
  `conflict` is true where an MCP server here already has the name, or one that
  gives its tools the same names. `summary` is `Remote, <host>`, or the program
  and the package it starts.
- **A pasted value is held, never returned.** A variable's or a header's
  value in the text is held in the daemon's memory, and `env` and `headers` say
  which names it carried (`present`); the key's header is among `headers`, and
  `key_header` names it. A placeholder (`${input:…}`, `${env:…}`, `${NAME}`,
  `${NAME:-default}`, an empty value, a Codex variable name, and in a `claude
  mcp add` line, written for a shell, `$NAME` or anything the shell would fill
  in, `Bearer $NAME` included) declares its name and carries no value, so the
  server waits for it. In such a line a `$` in the name, the address or the
  command needs a shell and is refused, as in a command line.
  `Authorization: Bearer <token>` is the key, sent as `Bearer <value>`, its value the token; otherwise
  a remote server's first header is its key and the rest its other headers, and
  a remote server with no header signs in by itself (`auto`). Each draft that
  carried a value has its own `draft_id`, null for one that carried none, so
  one paste may give two servers one name with two values. A `draft_id` is
  opaque, belongs to this boot, expires 10 minutes after its draft, is used
  once, and at most 64 are held, a newer one dropping the oldest. An add with it
  stores, under the name the form chose, the values for the names the form
  still declares, and drops the rest; the server starts once, with all of them,
  and its row then waits only for what the paste did not carry. A refused add
  stores nothing and leaves the `draft_id` for the next try. An unknown,
  expired or used `draft_id` is `invalid_params` with `field` `draft_id`.
- **A paste Fermix cannot add as given is refused whole.** Text that is none of
  the shapes, and a placeholder inside a command, its arguments, a working
  folder or an address (nothing there is filled in), are `invalid_params` with
  `field` `text` and a sentence; in a paste of several servers the sentence
  names the server, and the paste answers no drafts.
- **Import reads another app's settings only when asked.** `mcp.servers.import.scan`
  and `mcp.servers.import` each read the settings files then, and nothing is
  kept between them, so an import adds what the files hold when it runs. The
  sources are fixed files under the home folder: Claude Desktop's
  `claude_desktop_config.json`, Claude Code's `~/.claude.json` (its user
  servers, not a project's), Cursor's `~/.cursor/mcp.json`, VS Code's user
  `mcp.json`, Windsurf's `mcp_config.json` and Codex's `~/.codex/config.toml`,
  each read whole up to 8 MiB, its servers taken out and translated one by
  one as a paste is. VS Code's is read as VS Code reads it, JSON with `//` and
  `/* */` comments and trailing commas; the others as JSON, as their apps read
  them. A missing file holds no servers; one that cannot be
  opened, is too large, does not parse or holds its servers in another shape
  is one `skipped` entry with `name` null, and a server that could not be added
  as it is written (a placeholder in its command, say) is one with its name;
  neither hides the rest. At most 32 servers are read from one file. A
  candidate is named as a draft is, and `conflict` says the name, or its
  tools' names, is taken here. Neither method ever carries a value: an import
  stores what the file held under `mcp:<name>/…` as a paste's values are
  stored, a placeholder declares a name the server waits for, and the other
  app's file is never written. One refused server leaves the others; a
  settings file changed outside Fermix refuses the whole import with
  `external_change` before anything is added.
- **A check connects, then lists once.** `mcp.servers.check.start` waits for a
  server that is starting, starts again one that is not running or has failed,
  then asks it for its tools; `tool_count` is what it listed and `latency_ms`
  how long that took. Its wait for a connection outlasts a first start's own
  60 s, so a server that downloads its package on first run ends the job with
  how that start ended. A server the daemon does not run (off, naming nothing to
  start, or waiting for a value) is refused with its own row's sentence, and a
  connection that fails ends the job with that sentence. After an add or an
  update, `mcp.servers.get` reads the row as it connects.
- **The cue methods are on every build**, and so is the `cues` section of
  `settings.sections`. They are minimum version `2` with no protocol bump, so a
  client finds them in `hello.capabilities.methods`. With memory
  off, `cues.status` says `needs_memory`, the source and mandate lists are drawn
  from the settings file, and the reads that need rows (`cues.watchers.*`,
  `cues.mandates.choices`, `cues.proposals.*`) answer `unavailable` with the
  daemon's sentence. An unknown source, watcher, mandate or proposal is
  `invalid_params` with the field and a sentence ("There is no source named
  home-alerts.").
- **`cues` is the cue section**, under pane `cues`: `cues_enabled` (the cue tree
  starts at boot, so `restart` is true), `cues_mandates_enabled` ("Let watchers
  act", read at every mandate call and every follow-up trigger), `cues_screen_provider` (how items are screened, read at every
  accept and filter call), `filter_provider` and `filter_model` (the Cues
  filter model, the one every watcher's filter uses, read at every filter call)
  and `cues_door_port` (`advanced`, 1024 to 65535, always on 127.0.0.1). The rows
  carry their explanations in `info` and no `footer`; the filter model's says
  a smaller, faster model works well. `filter_provider` offers `""`, the
  default, labelled with the main model it resolves to ("Default: your main
  model (Anthropic · claude-sonnet-5-5)"), then only the providers that are set
  up; a saved provider that is no longer set up stays, disabled with its hint,
  so the value is always an option. `filter_model` offers the chosen provider's
  catalog as suggestions. With neither set, every filter runs on the main
  model. The two are applied together in one `settings.apply`, both or `""`
  for both; either alone is refused with "Pick a provider and a model, or
  clear both." `cues_screen_provider` is how items are screened before the
  filter model reads them: `""` ("Words"), the watcher's words to listen for,
  then one option for the decision model of each provider that is set up and
  serves one ("OpenAI · gpt-6-luna", "OpenRouter · Jev", "Venice · Jev"). A
  decision model checks each item by meaning, with the watcher's purpose,
  instructions and words as hints, and only an item it lets through reaches
  the filter model. A saved provider that is no longer set up stays, disabled
  with its hint, and its watchers are held until it is set up again or
  another screen is picked.
- **Every cue write goes through the setup page's own path**, so the outside
  edit refusal (`external_change`), the baseline re-record, the secret
  take-back and the source workers' reconcile apply identically from either
  door, and a source or a mandate written here reads back from `config.toml`
  as a hand edit would hold it, with no secret value in it. At most 64 sources
  and 64 mandates are added; past that the add is refused with a sentence.
  A form's refusal is `invalid_params` with `field` (the value's key, or `ref`
  or `name`) and the daemon's sentence; a name that breaks the rule is
  refused under `ref` with the rule in its sentence.
- **A source row is the daemon's.** `state` is `off`, `needs_secret`,
  `not_running` (cues off, or on and not yet restarted), then the status the
  source last wrote: `idle`, `polling`, `connected`, `reconnecting`,
  `auth_failed`, `over_budget`, `stopped` or `unavailable`. A client draws
  `status_sentence` and switches on `primary_action` and `actions` (closed:
  `enable`, `disable`, `set_secret`, `new_token`, `get_url`); edit and remove
  are always available and are the client's controls. `secrets` reports each
  field's presence and nothing else. Never on the wire: a payload, an item's
  text or snapshot, a cursor, a secret's value, or a webhook's address.
- **A source can wait for its secret.** A source that needs a secret (a
  webhook's signing secret, a local push's token, or the `key` and `secret` a
  stream with no preset signs in with, by a header or a placeholder in its
  sign-in message) and has one not stored loads as `needs_secret` with
  `missing_secret` naming the first such field (key before secret), for a
  hand-edited file as much as for a socket write: the door refuses its
  requests and no worker runs until each is stored. So `cues.sources.add`
  saves a webhook or a stream first and the client stores its secrets with
  `secret.set` after, one per secret row, under the `source.ref` the add
  answered; `secrets` lists each field the source needs with its own
  presence. A GitHub source never waits: `cues.sources.add` stores the secret
  Fermix makes for it, and `secret.set` replaces it later.
- **Three values are handed out.** A new local push source's first token
  (`cues.sources.add`) and a fresh one (`cues.sources.token.new`), and the
  secret Fermix makes for a new GitHub source (`cues.sources.add`, as
  strong as a token and stored as a typed secret is), are returned once:
  never logged, never traced, never retained, and no later read repeats them.
  A webhook's address is returned by `cues.sources.url.get` alone, on every
  ask, and is never on a list.
- **A watcher row is read-only**: watchers are made and changed in a chat with
  Fermix, and every `llm` watcher filters with the one Cues filter model.
  `state` is `on`, `paused`, `needs_update` or `held` (its filter cannot reach
  its model). `needs_update` is a watcher saved before a rule every save now
  keeps, which gets nothing until a change in chat: one that filters needs
  words to listen for ("Needs words to listen for: update it in chat."), and
  one with no filter cannot listen to a stream ("Passes everything, so it
  can't listen to a stream: give it a filter in chat."). `counts` cover
  `window_s`: `offered` is every item the watcher's words let through, kept or
  not; a stream keeps only what passes, so its watchers' `offered`, `dropped`
  and `failed` are counted by the hour rather than stored. `purpose`,
  `listen_for` and `instructions` are the owner's own words and are on
  `cues.watchers.get` alone; examples are counted, never shown; reasons and
  hints never cross. A watcher has a task, a follow-up or both. `task` is the
  job a passing item starts: its task, or for a watcher with only a follow-up,
  that follow-up's job (then `follow_up.job_id` names the same job), so `task`
  is never null and a client that predates follow-ups still reads every row.
  `follow_up` is null for one with none, else the job a passing item sets off, which Fermix hands nothing from the
  item: its `job_id`, `name`, `mode` (`approve`, asking first on a card for
  each run, or `auto`, running on its own within the daily cap once approved),
  `approved` (whether an automatic one is approved for what it runs now; null
  for one that asks first), `state` (`ready`, or `held` while it cannot run:
  "Let watchers act" is off, or a tool or the channel it needs is not set up)
  and `status_sentence`, which while it is held says what is missing and where
  to fix it. It is made and changed in chat like the rest. A daemon older than
  follow-ups omits `follow_up`, which a client draws as no follow-up.
- **A mandate row carries its load and its approval.** `load` is `active`, or
  `inactive` with the check's sentence; `approval.state` is `unapproved`,
  `approved`, `changed` or `disabled`, null where memory is off. A client
  switches on `primary_action` (`approve` or null) and `actions` (closed:
  `approve`, `enable`, `disable`); `consent_sentence` says what the mode lets
  the task do. `cues.mandates.approve` records the approval as from "Fermix
  app".
- **A proposal is Fermix's record, and its card keeps the outside text
  apart.** A record carries ids, names from the owner's configuration, times,
  `decided_from` (`telegram`, `signal`, `whatsapp`, `imessage`, `companion`,
  `mobile` or `management`) and Fermix's `status_sentence`, never an argument or
  cue text. `cues.proposals.get` adds `received_at`, `summary` (Fermix's
  sentence) and `outside`: `args_text` (the recorded call's arguments, at most
  3,500 characters) and `cue` (`type`, `subject`, `text`, `occurred_at`) or
  null, all outside text a client draws only as such. `cues.proposals.decide`
  answers by id with no token; the first answer from any surface wins, and a
  later one is refused with the daemon's sentence and runs nothing.
- **A sign-in client appears only where a plugin needs one.** `oauth_clients` is
  derived from the providers the published rows name, so a client row for a
  family this Mac has no plugin for is never drawn. `client_id` is the public
  identifier, or null when unset. `secret_present` reports the stored secret
  independently of `configured`, which requires both identifier and secret.
  These two fields are optional for older protocol-2 engines. The secret value
  is never returned. A null `redirect_port` means the daemon's own default is in
  force, not that no port is used.
- **The region is chosen before connecting, because it selects the token
  audience.** Some providers serve one account region per host and refuse every
  call from another, so the region is part of the sign-in client rather than
  something a first call discovers. `regions` lists the choices with the
  daemon's own labels and is empty for a provider that serves one region;
  `region` is the chosen one, or null while nothing is chosen. Both are optional
  for older protocol-2 engines, and an absent `regions` reads as a provider with
  one region, never as a picker that failed to arrive. A plugin whose provider
  offers regions and whose client has none is `needs_client_config`, the same as
  one missing its identifier.
- **A grant minted for the wrong region is `wrong_region`.** Right after a
  sign-in the daemon asks the provider which region the account is in, and
  records a disagreement on the grant. The status is its own word because the
  fix is the region on the sign-in client, not a renewed sign-in: the row leads
  with `set_up_client` and keeps `sign_in` beside it, and the status sentence
  names the account's own region wherever the provider gave one. No token is
  served for such a grant, so a plugin holding one refuses its tools rather than
  calling the wrong host.
- **Harness detection reports bounded public status.** Only the `harness_vendors`
  target can add `vendors` and `guidance` to its existing `target`, `present` and
  `detail` fields. Both additions are optional for older protocol-2 engines.
  `vendors` contains at most one row each for `claude` and `codex`, with required
  `vendor`, `installed`, `version` and `auth` fields. Version is nullable and at
  most 512 characters; auth is `authenticated`, `unverified` or `absent`.
  Guidance is nullable and at most 512 characters. Neither binary paths nor
  credential values are returned.
- **Notetaker detection is both halves plus the sign-in.** The `meetbot` target
  is present only when the notetaker's sidecar and its browser are both
  installed: half an install can neither sign in nor join a meeting. Its
  `detail` is `Signed in to Google` or `Not signed in to Google`, which is the
  one notetaker fact a client cannot read for itself — the marker lives beside a
  browser profile nothing on the wire exposes. With the notetaker absent there
  is nothing to be signed in to, so `detail` is null rather than a
  not-signed-in sentence. No profile path and no credential is returned.
- **`settings.reload` is the one write-family method allowed while an external
  change stands**, because it is the action that clears it. Every other write
  answers `external_change`; a file that cannot be parsed answers
  `config_unreadable` and is never answered with a reload, because the reload
  would re-run the read that just failed.
- A **prepared daemon auto-resumes.** The drain lease is finite: if the app
  crashes or the machine reboots between prepare and commit, the lease expires
  and the daemon keeps serving.
- **`lifecycle.prepare` quiesces nothing.** It takes the single-flight window
  and nothing else: in-flight agent turns and tool runs continue, and new work
  is still accepted. `busy` means another lease is open, never "this daemon has
  work in flight". A client that must not interrupt work has to establish that
  itself before committing.
- **`ttl_ms` is relative, deliberately.** The expiry timer runs on monotonic
  time, which is frozen across sleep and never stepped by NTP, so a wall-clock
  deadline would disagree with it. Clients start their own timer on receipt.
- A **log cursor** is opaque and carries the rotation fingerprint it was minted
  against. After the log set rotates the cursor answers `cursor_expired` rather
  than silently returning a different window.
- **`subsystem`** matches a leading `[tag]` the log message itself wrote; the
  engine's on-disk log format carries no module or subsystem field, so a line
  without such a tag is excluded whenever a subsystem filter is supplied.
- **The home family is answered locally in every role** (M75). `home.status`
  is one fixed record from its first release: the places the desktop relay,
  the desktop peers, enrollment and the move fill are present in every role,
  as `null` or `[]` where they hold nothing, so a client decodes the same keys
  in every role. A candidate answers `home.status` alone of the family. A device
  reports its own role, epoch and marker; its `snapshots` say they are the
  primary's (`configured` false, `recipient_set` false, `next_run_at` null, no
  target, the sentence saying so). A linked desktop adds the primary's own
  picture as `primary_home`, or says in `primary_missing` why it is missing;
  the rest of the family is the primary's there (see *After a move*).
- **Replacing the server runs through the same move** (M75). A desktop
  forwards `home.enroll.open` and `home.move.start` to the server; with
  `keep_as_desktop` false the server being replaced keeps no desktop key, row
  or link and serves nothing once the move commits. Moving Fermix back to a
  desktop is not part of this release: to bring it back to a computer, restore
  the newest snapshot into a fresh home there.
- **Enrollment and the move are the primary's** (M75). `home.enroll.open`
  opens one window at a time; a host that enrolls with its code becomes a
  candidate the primary holds for 24 hours. `home.move.start` answers before
  the engine restarts, so the same socket then answers from the device role;
  the move runs on its own from there, and `home.status`'s `move` follows it:
  `requested`, `streaming`, `committing`, `committed` (restarting as a
  desktop) and `done`, or `aborting`, `undoing` (restarting as the primary)
  and `aborted` when it was undone before the candidate was ready, which
  leaves this home the primary. `done` and `aborted` are written only by the
  engine that came back after the restart, so a client that reads either
  reads it from the engine that stays, with a desktop's `primary` already
  beside it; `committed` and `undoing` mean the engine is about to restart.
  An engine that came back but could not write its ending keeps answering
  `committed` or `undoing`, with a `sentence` that says the ending and why it
  is not recorded; each read tries the write again, and the ending follows
  once it is written.
  A move session has no one-hour lifetime, and its attempts send one capture. On a candidate, `phase` is `enrolling`, `enrolled`,
  `receiving`, `staged`, `activating`, `expired` or `failed`, and `candidate`
  is null. A candidate's `instance` is what the host said of itself: a client
  shows it as unverified.
- **A snapshot target row is the daemon's.** There are two targets, in
  order: `s3` (label `S3`) and `desktop` (label `your desktop`: every desktop
  connected to this primary over the rail, on while it has a desktop row).
  `last_verified` is the newest snapshot the target proved it holds (S3
  accepted its SHA-256 checksum; a desktop answered the same SHA-256) and
  outlives later failures; `last_error` is the newest failure's sentence,
  carrying the storage service's own words, and clears at the next verified
  or waiting run. A desktop asleep or offline is no failure: `last_result` is
  `waiting` and `waiting` holds the sentence
  (`Your <name> is not connected; the snapshot waits for the next run.`),
  null otherwise. Each point names the recovery key it was written for
  (`key_id`, as `home.snapshots.passphrase` answers it). The first boot of a
  primary a move activated runs its first snapshot at once. `destination` is where the target puts
  snapshots (`s3://<bucket>/<prefix>/<profile>/`, or `snapshots/ on <names>`
  for the desktops), null while it is off.
- **`snapshots` is the snapshot section**, under pane `always_on`:
  `snapshots_recipient` (read-only: it changes only through
  `home.snapshots.passphrase`), `snapshots_interval_hours` (1 to 168, format
  `hours`), `snapshots_s3_bucket`, `snapshots_s3_region`, the two secret rows
  `snapshot_s3_access_key_id` and `snapshot_s3_secret_access_key` (stored with
  `secret.set` under those ids), and, `advanced`, `snapshots_s3_prefix` and
  `snapshots_s3_endpoint` (an S3-compatible host, addressed path-style). None
  needs a restart: the scheduler reads the section at every run and plans
  again when it is saved.

## Error codes

| `code` | Meaning |
|---|---|
| `invalid_request` | The envelope is malformed. `details.field` names the offending field. |
| `invalid_params` | The parameters are malformed, unknown, or oversized for this method. `details.field` names the offending field. `details.sentence`, when present, is the daemon's own refusal sentence for it. |
| `method_not_found` | The method is not in this daemon's catalog. |
| `client_too_old` | The declared version is below the daemon's floor. |
| `daemon_too_old` | The declared version is above the daemon's ceiling. |
| `internal_error` | The daemon failed to complete the request. Details are always empty. |
| `unavailable` | The named capability could not answer. `details.capability` names it. `details.sentence`, when present, is the daemon's own sentence for this refusal. |
| `busy` | Another operation of this kind is already running. |
| `lease_expired` | The lifecycle lease's window elapsed and the daemon resumed. |
| `unknown_lease` | The lease was never issued by this daemon, or was already consumed. |
| `unknown_session` | The Doctor session is not retained by this daemon. |
| `unknown_job` | The job is not retained by this daemon. `details.job_id` names it. |
| `cursor_expired` | The log cursor predates a rotation and cannot be resumed. |
| `secret_store_failed` | The OS keyring refused the write. `details.reason` is `unavailable`, `locked` or `timeout`. |
| `external_change` | The settings file was changed outside Fermix. `details.section` names the section the refused write targeted; `settings.reload` clears the state. |
| `config_unreadable` | The settings file could not be read or parsed. `details.sentence` is the parser's own message, and no reload is offered for it. |
| `unknown_pairing_session` | The pairing session is not retained by this daemon. `details.session_id` names it. |
| `primary_unreachable` | After a move, the primary this computer forwards to cannot be reached, or did not answer in time. `details.sentence` says so, and `details.primary` names it when it is known (see *After a move*). |
| `device_class_method` | The primary refused a request that configures the computer that forwarded it. `details.method` names it and `details.sentence` says why. |
| `unconfirmed` | After a move, the primary had a forwarded request whose effect may stand though its answer did not arrive (`home.move.start`). `details.method` names it, `details.primary` names the primary when known, and `details.sentence` says where its outcome shows (see *After a move*). Not a failure: read `home.status`. |

`lease_expired` and `unknown_lease` are deliberately distinct: the first lets
the app tell the operator the transaction timed out, the second says the id was
never valid here. The elapsed memory is bounded, so an ancient id honestly
degrades to `unknown_lease`.

### Where the refusal sentence lives

`message` is a fixed per-code string and never varies with the request; it names
the CLASS of failure. The daemon's own sentence about THIS request, when it has
one, is `details.sentence`. Six codes carry one:

- `invalid_params` — every request-path refusal that has something to say to the
  operator. `details.field` names the parameter and `details.sentence` says why:
  "This provider has no browser sign-in.", "This setting cannot be cleared.",
  "A secret cannot be empty.", "Install this plugin before using it.", "Add this
  provider's sign-in client secret first.", "This setting is a switch: send true
  or false.", "No phone is waiting for a decision.", "No paired phone has that
  id.", and every settings validation refusal. A refusal with nothing to
  add carries `field` alone.
- `config_unreadable` — `details.sentence` is the parser's own message.
- `unavailable` — when a caller that is not the owner asks for an owner's
  decision: the phone's, "Only the owner can pair or forget a phone; run this
  from your own terminal.", the cues', "Only the owner can change cues: use
  the Fermix app or your own terminal.", and the home's, "Only the owner can
  move Fermix or set its recovery passphrase: use the Fermix app or your own
  terminal." And when the cues cannot reach their records, with the cues'
  sentence for why: memory is off, or the records could not be read.
- `primary_unreachable` — "The server <name> is unreachable. Fermix keeps your
  message until it is back.", or why this computer does not reach it.
- `device_class_method` — "This request configures the computer it came
  from, so the server does not answer it."
- `unconfirmed` — "The server <name> did not confirm in time whether the move
  started. Its state shows once the server answers again, and starting it
  again never starts a second move."

**A client that renders `message` alone renders "Request parameters are
invalid." for that whole family**, which is the one sentence in the catalog that
tells an operator nothing. Render `details.sentence` when it is present and
`message` otherwise. Both are plain text, bounded, and safe to show: no
credential, no path, no internal term reaches either.

## Bounds

Every bound is published in the schema's `x-limits` and pinned to
`FermixCore.Management.Protocol.limits/0`.

| Bound | Value | Applies to |
|---|---|---|
| `max_frame_bytes` | `4194304` | One transport frame, request or response. |
| `max_params_bytes` | `65536` | The encoded `params` object. |
| `max_result_bytes` | `1048576` | The encoded `result` object. |
| `max_error_details_bytes` | `4096` | The encoded `error.details` object. |
| `max_json_depth` | `6` | Nesting depth of `params`, `result`, and `error.details`. |
| `max_json_collection_items` | `500` | Items in any one array or keys in any one object. |

Operation-specific bounds, owned by the operation rather than the envelope: a
`logs.query` page defaults to 200 entries and is capped at 500 entries and
262144 encoded bytes, with a 256-character search and a 64-character subsystem;
a `diagnostics.build` object carries at most 500 log entries; `mobile.devices.list`
carries at most 64 devices, each string a phone sends in a pairing request is
at most 128 bytes, and a pairing `uri` is at most 2048 bytes.

## Vendoring into `fermix-macos`

The macOS repository must not hand-copy these shapes. It vendors
`protocol.schema.json` and `fixtures/*.jsonl` with a checksum pin and runs its
own client tests against the same golden frames the daemon is tested against.

- `fixtures/requests.jsonl` — one well-formed v1 request per method, plus
  parameter variants. Each record declares the classification the daemon owes
  it.
- `fixtures/success.jsonl` — one full success envelope per method, for
  `settings.get` one per section, because a section with no golden result is a
  pane whose row keys nothing on the far side is held to, for
  `mobile.pair.get` one per session state, and for `job.get` a browser download
  both completed and failed.
- `fixtures/errors.jsonl` — one full error envelope per published code,
  including the fixed `message` text. `method_not_found` appears twice: once
  for a method this daemon does not serve at all, and once as
  `method_requires_newer_engine`, which carries `details.requires`.
- `fixtures/compatibility.jsonl` — the v0 window and the negotiation matrix: v0
  requests, partial-marker rejects that must never fall through to v0, both
  `client_too_old` and `daemon_too_old`, an N-1 client calling a v2 method
  (`expect: refused_by_router`, answered by the router with `method_not_found`
  and `requires`, once for a settings method, once for the plugin surface, once
  for the phone pairing surface and once for the browser download),
  and one golden response (`expect: response`) showing every optional field of
  a plugin row absent at once, which is the rendering a client owes a daemon
  that knows less than it does.

Re-vendor whenever `protocol_version` changes, a method or error code is added,
or a bound moves. The daemon ships first; see *Rollout / rollback order*.
