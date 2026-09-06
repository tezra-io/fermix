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
| `setup.detect` | `targets` | One row per target asked for: whether this Mac already has it, and a short detail where there is one. The harness target also reports vendor installation, version and authentication status, with guidance. Never a credential value. Minimum version `2`. |
| `providers.set_primary` | `provider` | Makes one configured provider the primary and answers with the restart state and any change the operator did not type. Minimum version `2`. |
| `providers.models.list` | `provider`, `live`, `query`, `cursor`, `limit` | One page of models, from the catalog this build ships or from the provider's own live listing, with the cursor for the next page. Minimum version `2`. |
| `providers.probe.start` | `provider` | Starts a metered call against the provider. A job; the result carries the model and the latency. Minimum version `2`. |
| `job.get` | `job_id` | One job's uniform view. Minimum version `2`. |
| `job.cancel` | `job_id` | Stops a running job and answers its terminal view. Cancelling a finished job is a no-op, not an error. Minimum version `2`. |
| `job.list` | none | Every job this daemon retains, oldest first. What lets a reopened surface find a run it started rather than starting a second one. Minimum version `2`. |
| `auth.start` | `provider` | Starts a browser sign-in and answers with the job plus the authorize url and its lifetime, returned once. Minimum version `2`. |
| `auth.import.start` | `source` | Adopts a sign-in this Mac already has, from Claude Code or the Codex CLI. A job, because reading the keychain can prompt. Minimum version `2`. |
| `auth.logout` | `provider` | Forgets one provider's local session and reverts the route it fed. Nothing is revoked upstream. Minimum version `2`. |
| `plugins.list` | none | Every integration this daemon can show, installed or not, in one row shape, plus one entry per sign-in client a published plugin needs. Every word on a row is the daemon's. Minimum version `2`. |
| `plugins.install.start` | `name` | Fetches, verifies and activates one catalog plugin. A job. Minimum version `2`. |
| `plugins.check.start` | `name` | Runs one plugin's own health check, live probe included. A job. Minimum version `2`. |
| `plugins.workspaces.discover.start` | `name` | Lists the workspaces a hosted plugin's stored credential can reach. A job; what it finds is republished on the plugin's row rather than in the job result. Minimum version `2`. |
| `plugins.workspace.select.start` | `name`, `profile`, `workspace_id`, `label` | Binds one hosted plugin to one workspace under one access profile, and answers only once the replacement client is connected and contract-checked. A job. Minimum version `2`. |
| `plugins.enable` | `name` | Turns one installed plugin on and answers with its row. Minimum version `2`. |
| `plugins.disable` | `name` | Turns one plugin off and answers with its row. Minimum version `2`. |
| `plugins.disconnect` | `name` | Forgets the credential behind one plugin, locally: an OAuth session is deleted, a stored token is removed from the keyring, and neither is revoked upstream. Minimum version `2`. |
| `plugins.oauth_client.set` | `provider`, `client_id`, `redirect_port` | Registers one sign-in client. The client secret is not a parameter: it arrives through `secret.set`. Minimum version `2`. |
| `plugins.setting.set` | `name`, `key`, `value` | Writes one manifest-declared setting and answers with the plugin's row. Minimum version `2`. |
| `capabilities.install.start` | `target` | Installs the computer use helper, the meeting notetaker, or the on-device speech backend. A job. Minimum version `2`. |
| `meetings.signin.start` | none | Starts the notetaker's one-time interactive sign-in. A job, because it waits for a person. Minimum version `2`. |
| `computer_use.grant.start` | none | Raises the OS permission prompts and answers with what was granted. A job, and only ever on an explicit ask. Minimum version `2`. |
| `computer_use.permissions.get` | none | The current, non-prompting permission state: whether the helper is installed, which grants it holds, and when they were read. Minimum version `2`. |

Notes that the shapes alone do not carry:

- A **Doctor session** is one of the two management operation families that are
  *runs*: it has its own session id, a whole-run budget (`local` 10000 ms,
  `network` 30000 ms), and cancellation. At most 2 sessions run concurrently
  (`busy` beyond that) and at most 8 finished sessions are retained, none older
  than 300000 ms.
- A **job** is the other, and covers every long operation that is not Doctor.
  One shape serves all of them, so a client writes one poller, one progress row
  and one failure sentence rather than one per operation. Each kind carries its
  own budget: `provider_probe` 15000 ms, `auth` 300000 ms, `auth_import`
  60000 ms, `plugin_install` 600000 ms, `plugin_check` 30000 ms,
  `plugin_workspaces_discover` 60000 ms, `plugin_workspace_select` 60000 ms,
  `capability_install` 900000 ms, `meetings_signin` 660000 ms,
  `computer_use_grant` 120000 ms. At most 4 jobs run at once, at most one per
  kind and name (`busy` beyond either), and at most 16 finished jobs are
  retained, none older than 600000 ms. A `job_id` this daemon does not retain
  answers `unknown_job`.
- **`phase` is display copy, never a state.** It names the current step from a
  closed per-kind vocabulary — `provider_probe`: `calling`; `auth`: `binding`,
  `awaiting_browser`, `verifying`; `auth_import`: `reading_keychain`,
  `verifying`; `plugin_install`: `downloading`; `plugin_check`: `probing`;
  `plugin_workspaces_discover`: `listing`; `plugin_workspace_select`: `binding`;
  `capability_install`: `sidecar_downloading`, `downloading`,
  `verifying`; `meetings_signin`: `awaiting_signin`; `computer_use_grant`: none.
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
- **A live model listing never degrades to the catalog.** The two answer
  different questions, so a live fetch that fails answers `unavailable`
  {`capability`: `model_listing`} and `source` always names where the rows on
  the wire came from.
- **`computer_use.permissions.get` never prompts**, and `installed` comes from
  the installer rather than from the probe: the feature being switched off says
  nothing about whether the helper is on disk, and that is exactly what decides
  whether a surface offers "install it" or "turn it on".
- A **check status** is one of `passed`, `warning`, `failed`, `not_applicable`,
  `unavailable`, `skipped`, `cancelled`, `timed_out`. `not_applicable` means
  this distribution does not have the check (the two distribution rows under
  `macos_app`); `unavailable` means the check itself could not answer. A session
  `summary` carries one count per status.
- **Readiness is split into gating and advisory.** A failure carries `gating`,
  the `pane` that can clear it, and a closed-set `detail_key`. Provider and
  personalization failures gate; the five channels and realtime are advisory.
  `status` is `ready` exactly when no gating failure remains, and every advisory
  failure stays in the list, so a surface never needs a second definition of
  ready.
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
- **`restart` on a row is derived, never declared.** A row is flagged exactly
  when its own configuration section is one the daemon compares against the
  values it read at boot, so a row can never deny a restart the next
  `overview.get` asks for.
- **`read_only` marks a row `settings.apply` will not take**, rendered as a plain
  labelled row rather than a control whose save always refuses.
- **Secrets travel inbound only, in `secret.set`, one per call.** Every other
  method reports presence as a boolean. "Present" means a reference or a value
  sits at that key's own path, never "the keyring holds an item": a key stored
  without its reference is never read back, so calling it present would describe
  a credential the runtime cannot use.
- **`id` names one of four families.** A bare registry key (`openai_api_key`,
  `telegram_bot_token`, …), `plugin:<name>` for a plugin's own token,
  `oauth_client:<provider>` for a sign-in client's secret, and
  `anthropic_setup_token`. The first three take the same keychain-first write.
  The fourth is a different mechanism and is documented as such: a
  `claude setup-token` value is a long-lived subscription credential, so it is
  stored in the auth store rather than the keychain, storing one also selects
  the Anthropic sign-in route that reads it (a stored token the runtime never
  calls is not a connection), and clearing one is the same operation as
  `auth.logout anthropic`. Its `present` is "a setup token is stored", not "an
  Anthropic sign-in exists": an adopted Claude Code login lives under the same
  profile and is reported by `setup.state.get`'s account row instead.
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
- **Harness detection reports bounded public status.** Only the `harness_vendors`
  target can add `vendors` and `guidance` to its existing `target`, `present` and
  `detail` fields. Both additions are optional for older protocol-2 engines.
  `vendors` contains at most one row each for `claude` and `codex`, with required
  `vendor`, `installed`, `version` and `auth` fields. Version is nullable and at
  most 512 characters; auth is `authenticated`, `unverified` or `absent`.
  Guidance is nullable and at most 512 characters. Neither binary paths nor
  credential values are returned.
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
| `unavailable` | The named capability could not answer. `details.capability` names it. |
| `busy` | Another operation of this kind is already running. |
| `lease_expired` | The lifecycle lease's window elapsed and the daemon resumed. |
| `unknown_lease` | The lease was never issued by this daemon, or was already consumed. |
| `unknown_session` | The Doctor session is not retained by this daemon. |
| `unknown_job` | The job is not retained by this daemon. `details.job_id` names it. |
| `cursor_expired` | The log cursor predates a rotation and cannot be resumed. |
| `secret_store_failed` | The OS keyring refused the write. `details.reason` is `unavailable`, `locked` or `timeout`. |
| `external_change` | The settings file was changed outside Fermix. `details.section` names the section the refused write targeted; `settings.reload` clears the state. |
| `config_unreadable` | The settings file could not be read or parsed. `details.sentence` is the parser's own message, and no reload is offered for it. |

`lease_expired` and `unknown_lease` are deliberately distinct: the first lets
the app tell the operator the transaction timed out, the second says the id was
never valid here. The elapsed memory is bounded, so an ancient id honestly
degrades to `unknown_lease`.

### Where the refusal sentence lives

`message` is a fixed per-code string and never varies with the request; it names
the CLASS of failure. The daemon's own sentence about THIS request, when it has
one, is `details.sentence`. Two codes carry one:

- `invalid_params` — every request-path refusal that has something to say to the
  operator. `details.field` names the parameter and `details.sentence` says why:
  "This provider has no browser sign-in.", "This setting cannot be cleared.",
  "A secret cannot be empty.", "Install this plugin before using it.", "Add this
  provider's sign-in client secret first.", and every settings validation
  refusal. A refusal with nothing to add carries `field` alone.
- `config_unreadable` — `details.sentence` is the parser's own message.

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
a `diagnostics.build` object carries at most 500 log entries.

## Vendoring into `fermix-macos`

The macOS repository must not hand-copy these shapes. It vendors
`protocol.schema.json` and `fixtures/*.jsonl` with a checksum pin and runs its
own client tests against the same golden frames the daemon is tested against.

- `fixtures/requests.jsonl` — one well-formed v1 request per method, plus
  parameter variants. Each record declares the classification the daemon owes
  it.
- `fixtures/success.jsonl` — one full success envelope per method, and for
  `settings.get` one per section, because a section with no golden result is a
  pane whose row keys nothing on the far side is held to.
- `fixtures/errors.jsonl` — one full error envelope per published code,
  including the fixed `message` text. `method_not_found` appears twice: once
  for a method this daemon does not serve at all, and once as
  `method_requires_newer_engine`, which carries `details.requires`.
- `fixtures/compatibility.jsonl` — the v0 window and the negotiation matrix: v0
  requests, partial-marker rejects that must never fall through to v0, both
  `client_too_old` and `daemon_too_old`, an N-1 client calling a v2 method
  (`expect: refused_by_router`, answered by the router with `method_not_found`
  and `requires`, once for a settings method and once for the plugin surface),
  and one golden response (`expect: response`) showing every optional field of
  a plugin row absent at once, which is the rendering a client owes a daemon
  that knows less than it does.

Re-vendor whenever `protocol_version` changes, a method or error code is added,
or a bound moves. The daemon ships first; see *Rollout / rollback order*.
