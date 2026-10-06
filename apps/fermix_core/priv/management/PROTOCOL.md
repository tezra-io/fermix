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
| `settings.sections` | none | The ordered inventory of every section this daemon can serve, each with the pane it renders under. The one enumerator: a section reachable through `settings.get` and absent here fails the daemon's own contract test. Minimum version `2`. |
| `settings.get` | `section` | One section's rows. Exactly one section per call, which is what keeps every result inside the published depth budget. Minimum version `2`. |
| `settings.apply` | `section`, `values` | Applies the changed keys of one section and answers with what landed, the restart state, a readiness summary, and the changes the operator did not type. Minimum version `2`. |
| `settings.reload` | none | Re-reads the settings file, pushes it into the running configuration, and re-records the baseline. The one action behind `Reload settings from disk`. Minimum version `2`. |
| `secret.set` | `id`, `value` | Stores one secret and answers with its presence, never its value. Minimum version `2`. |
| `secret.clear` | `id` | Forgets one secret: the keyring item, the reference that reads it, and the value in force. Minimum version `2`. |
| `setup.detect` | `targets` | One row per target asked for: whether this Mac already has it, and a short detail where there is one. The harness target also reports vendor installation, version and authentication status, with guidance. The `meetbot` target reports whether both halves of the meeting notetaker are installed, its detail carries the state of the notetaker's Google sign-in as a sentence, and `signed_in` carries the same state as a boolean, null while the notetaker is absent. Never a credential value. Minimum version `2`. |
| `providers.set_primary` | `provider` | Makes one configured provider the primary and answers with the restart state and any change the operator did not type. Minimum version `2`. |
| `providers.models.list` | `provider`, `live`, `query`, `cursor`, `limit` | One page of models, from the catalog this build ships or from the provider's own live listing, with the cursor for the next page. Minimum version `2`. |
| `providers.probe.start` | `provider` | Starts a metered call against the provider. A job; the result carries the model and the latency. Minimum version `2`. |
| `job.get` | `job_id` | One job's uniform view. Minimum version `2`. |
| `job.cancel` | `job_id` | Stops a running job and answers its terminal view. Cancelling a finished job is a no-op, not an error. Minimum version `2`. |
| `job.list` | none | Every job this daemon retains, oldest first. What lets a reopened surface find a run it started rather than starting a second one. Minimum version `2`. |
| `auth.start` | `provider` | Starts a browser sign-in and answers with the job plus the authorize url and its lifetime, returned once. `openai_codex` signs in with ChatGPT: a sign-in that leaves ChatGPT plan usage off fails the job with its sentence, and a completed one first makes sure the default model is one the account lists. Minimum version `2`. |
| `auth.import.start` | `source` | Adopts a sign-in this Mac already has, from Claude Code. A job, because reading the keychain can prompt. `codex_cli` is still accepted as a source and refused with `invalid_params` and a sentence: a Codex CLI sign-in is no longer adopted, and `openai_codex` signs in with ChatGPT through `auth.start`. Minimum version `2`. |
| `auth.logout` | `provider` | Forgets one provider's local session and reverts the route it fed. Nothing is revoked upstream, except for `openai_codex`: its sign-out revokes the ChatGPT session and keeps the registration, so the next sign-in reuses it. Minimum version `2`. |
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
| `mobile.status` | none | The phone channel as it stands: whether it is enabled, whether it started, whether it was refused this boot and the class of that refusal, the listener (`status`, `reason`, `port`, `bind`, `candidates`), the local-network announcement, detected tailnet addresses, the gateway identity's presence and fingerprint, push credentials and delivery, the paired-phone count, the mobile protocol version this daemon serves, and the pairing session open or newest retained. Answers with the channel off. Minimum version `2`. |
| `mobile.pair.start` | none | Opens the pairing window and answers with the pairing session view plus, once, the pairing link as `uri`. `busy` while a window is open. Minimum version `2`. |
| `mobile.pair.get` | `session_id` | The pairing session as it stands. The pane polls it until the session is terminal. Minimum version `2`. |
| `mobile.pair.decide` | `session_id`, `approved` (boolean) | Approves or denies the phone waiting in the session and answers the terminal view. Minimum version `2`. |
| `mobile.pair.cancel` | `session_id` | Closes the window and answers the terminal view. Cancelling a finished session is a no-op, not an error. Minimum version `2`. |
| `mobile.devices.list` | none | Every paired phone, oldest first, at most 64, read from the paired-device file while the channel is not running. Minimum version `2`. |
| `mobile.devices.revoke` | `device_id` | Forgets one paired phone and closes its live connection, and answers with the id and `revoked: true`. While the channel is not running it forgets the phone in the paired-device file. Minimum version `2`. |
| `browser.install.start` | none | Downloads a browser for tasks: the meeting notetaker's helper, then the Chromium build it is pinned to, and completes with the name of the browser tasks now run in. A job. Minimum version `2`. |
| `imessage.permissions.get` | none | The Fermix Messages helper's non-prompting state: whether it is installed, its version, Full Disk Access, the Messages database, Automation, whether Messages runs and is signed in, the user session, the confirmed recipient policy, whether that policy is exactly the saved settings, and when it was read. Minimum version `2`. |
| `imessage.grant.start` | `service` (`automation` or `full_disk_access`) | Asks for one grant: `automation` raises the one system prompt, `full_disk_access` registers the helper, opens the Full Disk Access pane and reveals the helper for drag-in. A job that completes with the permissions view. Minimum version `2`. |
| `imessage.policy.confirm` | none | Asks the helper to confirm the saved recipients; when they differ from the ones it holds, the helper shows its own dialog naming every handle. A job that completes with the permissions view plus `outcome`. Minimum version `2`. |

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
  120000 ms, `imessage_policy_confirm` 180000 ms. At most 4 jobs run at once, at most one per
  kind and name (`busy` beyond either), and at most 16 finished jobs are
  retained, none older than 600000 ms. A `job_id` this daemon does not retain
  answers `unknown_job`.
- **`phase` is display copy, never a state.** It names the current step from a
  closed per-kind vocabulary — `provider_probe`: `calling`; `auth`: `binding`,
  `awaiting_browser`, `verifying`; `auth_import`: `reading_keychain`,
  `verifying`; `plugin_install`: `downloading`; `plugin_check`: `probing`;
  `plugin_workspaces_discover`: `listing`; `plugin_workspace_select`: `binding`;
  `capability_install`: `sidecar_downloading`, `downloading`,
  `verifying`; `meetings_signin`: `awaiting_signin`; `computer_use_grant`: none;
  `browser_install`: `sidecar_downloading`, `downloading`; `imessage_grant`: none;
  `imessage_policy_confirm`: none.
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
- **Attestation ships in its final shape and is empty for now.** Until the
  daemon verifies a phone's secure hardware, `platform`, `build_role` and
  `boot_state` are null on a request and on a device, and `attestation.status`
  is `unavailable` with the daemon's sentence.
- **`mobile.status`, `mobile.devices.list` and `mobile.devices.revoke` answer
  with the channel off**, so a pane can always read the state and the owner
  can always forget a phone: while the channel is not running the paired
  phones are read from, and forgotten in, the paired-device file. Every row
  of the channel's settings is boot-bound: the switch reaches the daemon at
  once but the channel starts and stops only at boot, so `enabled` is the
  switch and `started` whether the channel runs, and the two differ until a
  restart. Every verb goes by `started`, never by the switch: a channel
  switched off keeps serving, pairing and revoking until the restart.
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
  credentials did not resolve. A connect is given up after ten seconds, and
  the status answers while one runs.
- **Pairing and forgetting a phone are the owner's decisions.**
  `mobile.pair.start`, `mobile.pair.decide`, `mobile.pair.cancel` and
  `mobile.devices.revoke` answer `unavailable` {`capability`: `mobile`,
  `sentence`: "Only the owner can pair or forget a phone; run this from your
  own terminal."} to a process the daemon itself started (a shell command the
  agent ran, a coding harness), to a detached process nobody is watching, and
  to a caller the daemon cannot place, and the daemon log says so. The
  sentence is what tells this refusal from a channel that is not running.
  Reading a session and the status stay open to every caller.
- **`channels.mobile` is the phone channel's settings section**: the enable
  switch, the port, the address it listens on and the local-network
  announcement, every row boot-bound. It is a section of its own rather than a
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
  the wire came from.
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
  Today two rows carry it: the Venice model row, where the privacy tier in each
  model's label is two words that mean materially different things, and the
  secrets section's store row, where the choice trades a keyring password for
  a file that is not encrypted.
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
  publishes every model both engines ship, in one list, each option labelled
  with the engine it selects: `openai_realtime` (the Realtime API, which runs
  tools inside the voice session) or `openai_live` (the Live API, which
  delegates every tool call, memory read and reasoning step back to the Fermix
  agent and bills by the minute). There is no engine row; the engine is derived
  from the model and stored as `realtime.engine`, and `settings.apply` refuses
  `realtime_engine` as a key this section does not have. The rest of the section
  is scoped to the engine that model implies: `realtime_voice` publishes the
  voices of that engine and nothing else, `realtime_reasoning_effort` is a
  Realtime session setting with no Live equivalent and is absent under Live, and
  `realtime_backend` is present only under Live, is read-only, and names the
  primary provider and model that answer while Live speaks.
  `realtime_conversation` ("Voice calls join the chat") is present only under
  Live too, a choice of `chat` or `private` stored as `realtime.conversation`:
  `chat`, the value in force while the key is unset, runs a call's hand-offs in
  the chat's own conversation, and `private` keeps them in one of the call's
  own. Applying a model of the other engine therefore moves the engine with it,
  adds or removes the reasoning effort, moves a voice the new engine does not
  ship, and drops a chosen `realtime_conversation` on the way to Realtime. The
  result names every key the daemon derived in `applied` — including `realtime_engine`,
  which is a derived key rather than a row — with a sentence for each in
  `side_effects`; reload the section when one of those keys appears, because its
  row list has changed. `overview.get` reports the same selection as
  `realtime.engine`, null while voice is disabled.
- **Secrets travel inbound only, in `secret.set`, one per call.** Every other
  method reports presence as a boolean. "Present" means a reference or a value
  sits at that key's own path, never "the keyring holds an item": a key stored
  without its reference is never read back, so calling it present would describe
  a credential the runtime cannot use.
- **`id` names one of five families.** A bare registry key (`openai_api_key`,
  `telegram_bot_token`, …), `plugin:<name>` for a plugin's own token,
  `oauth_client:<provider>` for a sign-in client's secret,
  `anthropic_setup_token`, and `env:<NAME>` for a sandbox environment variable.
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
  bytes with no NUL, CR or LF, and at most 64 names are stored. `secret.set`
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

`lease_expired` and `unknown_lease` are deliberately distinct: the first lets
the app tell the operator the transaction timed out, the second says the id was
never valid here. The elapsed memory is bounded, so an ancient id honestly
degrades to `unknown_lease`.

### Where the refusal sentence lives

`message` is a fixed per-code string and never varies with the request; it names
the CLASS of failure. The daemon's own sentence about THIS request, when it has
one, is `details.sentence`. Three codes carry one:

- `invalid_params` — every request-path refusal that has something to say to the
  operator. `details.field` names the parameter and `details.sentence` says why:
  "This provider has no browser sign-in.", "This setting cannot be cleared.",
  "A secret cannot be empty.", "Install this plugin before using it.", "Add this
  provider's sign-in client secret first.", "This setting is a switch: send true
  or false.", "No phone is waiting for a decision.", "No paired phone has that
  id.", and every settings validation refusal. A refusal with nothing to
  add carries `field` alone.
- `config_unreadable` — `details.sentence` is the parser's own message.
- `unavailable` — only when the phone channel refuses a pairing or forgetting
  decision from a caller that is not the owner: "Only the owner can pair or
  forget a phone; run this from your own terminal."

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
