# The typed Fermix CLI contract

The `--json` verbs of `fermix` are a wire. A graphical client drives the
background service through them the way the macOS application drives the daemon
through `priv/management/PROTOCOL.md`, so they get the same discipline: this
document, one golden per published result under `fixtures/`, and
`apps/fermix_core/test/fermix/cli/contract_test.exs`, which rebuilds every
golden from the code that prints it and fails on drift.

A client **vendors this directory** and decodes against it. A change here that a
client has not re-vendored is a drift its own tests refuse, not a silent
mismatch. Nothing in this document is advisory: every sentence below is the
sentence the CLI prints, byte for byte.

## The envelope

Every `--json` verb prints exactly one JSON object on stdout and nothing else.
Progress, prose and warnings go to stderr, so a caller decodes one line without
stripping anything first.

```json
{"schema_version": 1, "ok": true, "result": { }}
```

```json
{"schema_version": 1, "ok": false, "error": {"code": "…", "sentence": "…"}}
```

`schema_version` is this envelope's own version and is not the management
protocol's. It changes only when a field is removed or its meaning changes;
adding a field does not change it, so a client must ignore fields it does not
know.

Exit status: `0` when `ok` is true, `1` when the verb refused, `2` on a usage
error. A usage error prints its message to stderr and **no envelope** — argv was
never understood well enough to know an envelope was wanted.

`sentence` is written for the person the client is speaking to. It names what
they can do, carries no internal vocabulary, and names a path only when they
have to act on that path. A client renders `sentence` and switches on `code`; it
never parses the sentence.

## Verbs

| Verb | Result |
|---|---|
| `fermix service status --json` | the service result below |
| `fermix service install --json [--home PATH] [--port N]` | the service result below, for a packaged engine; the action result for an engine that writes its own unit |
| `fermix service uninstall --json` | the action result |
| `fermix restart --json [--when-idle]` | the restart result |
| `fermix diagnostics export --offline --json` | the diagnostics result |
| `fermix home mark-moved --to TEXT --json` | the moved result |
| `fermix home status --json` | the home result |
| `fermix home snapshots status --json` | the snapshots result |
| `fermix home snapshots run --json` | the management `home.snapshots.run` result |
| `fermix home snapshots passphrase --passphrase-file PATH --json` | the management `home.snapshots.passphrase` result |
| `fermix home enroll-code --json` | the management `home.enroll.open` result |
| `fermix home candidates --json` | the candidates result |
| `fermix home move --to ID [--recovery-passphrase-file PATH] [--retire] --json` | the move result |

`fermix service run` is the systemd vendor unit's launch entry point. It is not
a machine-mode verb: it becomes the daemon and never returns an envelope.

## The action result

`fermix service uninstall`, and `fermix service install` on an engine that writes
its own unit file, answer with what was done rather than with a service state:

```json
{"action": "installed", "scope": "user"}
```

- `action` — string, `installed` or `uninstalled`.
- `scope` — string, `user` or `system`. A packaged engine owns one user service
  and takes no scope flag.

Goldens: `service_install/unit.json`, `service_uninstall/ok.json`.

## The service result

`fermix service status --json`, and `fermix service install --json` on a packaged
engine, answer with the same object. It is available with no daemon running,
which is the state it most has to answer in.

| Field | Type | Meaning |
|---|---|---|
| `binding` | object | Which home this account's service runs from. |
| `binding.state` | string | `bound`, `unbound` or `invalid`. |
| `binding.home` | string, null | The bound home. Null unless `state` is `bound`. |
| `binding.reason` | string, null | Why the binding could not be read. Null unless `state` is `invalid`. |
| `unit` | object | Which service file is in force. |
| `unit.effective_path` | string, null | The unit file the service manager loaded. Null when it loaded none. |
| `unit.vendor` | boolean | Whether `effective_path` is the package's own unit, `/usr/lib/systemd/user/fermix.service`. |
| `unit.legacy_generated` | boolean | Whether a unit an earlier Fermix wrote is present in the user unit directory. |
| `unit.foreign` | boolean | Whether a unit Fermix did not write is present there. Fermix never rewrites one. |
| `unit.need_daemon_reload` | boolean | Whether the unit on disk changed since the service manager read it. |
| `enabled` | boolean | Whether the unit starts at login. |
| `active` | boolean | Whether the unit is running now. |
| `sub_state` | string, null | The service manager's own sub-state, such as `running` or `dead`. |
| `pid` | integer, null | The main process id. Null when nothing is running. |
| `invocation_id` | string, null | The service manager's id for this run of the unit. |
| `restart_count` | integer | How many times the manager has restarted the unit. |
| `linger` | string | `enabled`, `disabled` or `unknown` — whether the account's services survive logout. |
| `path_source` | string | Where the daemon's `PATH` comes from. Always `engine_baseline`: the engine applies the shared baseline itself. |
| `listener` | object | The web listener the setup page is served on. |
| `listener.port` | integer, null | The port. Null when it cannot be established. |
| `listener.origin` | string, null | The origin a browser opens. Null when the port is. |
| `listener.source` | string | `daemon` (a running daemon's own published origin), `config` (the bound home's setting), `default`, or `unknown`. |
| `installed` | object | The engine identity compiled into the `fermix` on disk. |
| `installed.engine_id` | string | Always `fermix-core`. |
| `installed.product_version` | string | The released version, for display. |
| `installed.build_id` | string, null | The generation a published engine is stamped with. Null on an engine built without one. |
| `installed.source_commit` | string, null | The full commit the artifact was built from. |
| `installed.distribution_identity` | string | `linux_package`, `macos_app` or `standalone`. |
| `installed.artifact_target` | string, null | The build target, such as `linux_x86_64`. |
| `installed.architecture` | string | The CPU architecture, such as `x86_64` or `arm64`. |
| `installed.integrity` | string | `verified`, `mismatched` or `unreadable` — the compiled identity against the manifest the package installed at `/usr/share/fermix/engine.json`. |
| `running` | object, null | The same identity fields as `installed`, plus `pid`, reported by the daemon that answered. Null when none did. |
| `alignment` | string | Whether the daemon answering is the installed engine. See below. |

### `alignment`

One typed comparison, published as one word. A package manager changes files on
disk and does not restart the daemon, so "installed" and "running" are two
facts.

- `aligned` — the daemon is the installed engine.
- `pending_restart` — the daemon is an older generation; a restart loads the
  installed one.
- `not_running` — no daemon answered, so there is nothing to compare.
- `unknown` — the daemon reported no generation, so the question cannot be
  answered. It is never read off the product version.
- `ownership_conflict` — the daemon answering is another distribution or another
  architecture, so this install does not own it.

Goldens: `service_status/fresh.json`, `bound_disabled.json`,
`active_aligned.json`, `pending_restart.json`, `unknown_identity.json`,
`ownership_conflict.json`, `legacy_unit.json`, `foreign_unit.json`,
`invalid_binding.json`, and `service_install/packaged.json`.

## The restart result

```json
{"previous_pid": "4711", "pid": "4822", "alignment": "aligned"}
```

- `previous_pid` — string, null. The generation that was replaced. Null when no
  daemon was answering, which is the recovery case rather than a refusal.
- `pid` — string. The generation that answered afterwards. Always different from
  `previous_pid`: an answer alone is not a new generation, because the restart
  job replies before the old process stops.
- `alignment` — string, as above, for the generation that came back.

`--when-idle` is refused with `idle_restart_unavailable` until the management
protocol publishes an idle lease. The interrupting restart is never run in its
place.

Goldens: `restart/ok.json`, `restart/recovered.json`.

## The diagnostics result

`fermix diagnostics export --offline --json`. `--offline` is required: a live
export is collected from a running daemon by a client that has one, and this verb
refuses rather than answering that request with a smaller bundle under the same
name.

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | The bundle's own version, `1`, which is not the envelope's and not the management protocol's. |
| `generated_at` | string | When collection ran, ISO 8601. |
| `mode` | string | Always `offline`. |
| `sources` | object | One entry per source, named below. |

Every source is `{"status", "observed_at", …}`:

- `status` — `available` (with a `data` object), `unavailable` (with a `reason`
  string) or `not_applicable` (with a `reason` string). Nothing omitted is read
  as healthy.
- `observed_at` — when that source was read, ISO 8601.

| Source | Carries |
|---|---|
| `engine` | `installed` (the identity fields above plus `integrity` and `pid`), `running` (always null offline) and `running_status`. |
| `service` | The service result's facts minus every absolute path and account name: the binding's state, the unit's ownership booleans, and the listener's port and source. |
| `doctor` | Always unavailable: its checks reach the daemon, and running them offline would report a broken engine as a broken host. |
| `logs` | `file_status`, `journal_status`, `journal_reason`, `count` and `entries`. Each entry carries `source`, `file` or `journal`. |
| `secret_backend` | `tool` and `present`. Presence only: an export never opens a keyring. |
| `desktop_session` | Always unavailable: session facts are supplied by the graphical client, never reconstructed from a daemon's environment. |

The bundle is capped at 1048576 bytes encoded and at ten seconds of collection.
Exceeding either is an error, never a truncated bundle with a reassuring name.

Goldens: `diagnostics_export/ok.json`, `diagnostics_export/degraded.json`.

## The moved result

`fermix home mark-moved --to TEXT --json` retires the home it runs against as
the primary: it writes the moved marker, and the home then refuses to start as
the primary and runs only in the device role. It refuses while the engine runs
from that home. It answers with the marker as written:

```json
{"epoch": 4, "moved_at": "2026-10-27T09:30:00Z", "to": "hetzner fermix-home 48151623"}
```

- `epoch` — integer. The home's primary epoch when it moved.
- `moved_at` — string, ISO 8601 in UTC, whole seconds. When it was marked.
- `to` — string. Where the primary went, as the person named it: 1 to 128
  bytes of printable text. A `--to` outside that is a usage error.

Golden: `home_mark_moved/ok.json`.

## The home result

`fermix home status --json` answers with the record the management method
`home.status` answers (`priv/management/PROTOCOL.md`), whether or not Fermix
runs: from the engine over its control socket when it runs, and from the
home's own files when it does not (the role its settings configure, a device
when it carries the moved marker, the epoch, the marker, the snapshot section
and the snapshot status file, and the candidates it holds and where its move or
its enrollment stands).

| Field | Type | Meaning |
|---|---|---|
| `role` | string | `primary`, `device` or `candidate` (a fresh host enrolled with `fermix home enroll`, waiting for its move). |
| `epoch` | integer, null | The home's primary epoch. Null before its first start as the primary. |
| `moved` | object, null | `to`, `moved_at`, `epoch`: the moved marker, or null. |
| `primary` | object, null | In the device role after a move, the primary this desktop reaches: `name` (string, null), `connected` (boolean), `since` (string, null while not connected), `epoch` (integer, null; the highest primary epoch this desktop has seen) and `sentence` (string). Null on any other engine, and while Fermix is stopped. |
| `desktops` | array | On the primary, each desktop that holds a session to it: `device_id`, `name`, `connected` (boolean) and `since` (string, null while not connected). Empty on any other engine, and while Fermix is stopped. |
| `snapshots` | object | The snapshots result below. |
| `enrollment` | object, null | On the primary, the enrollment window opened since Fermix started: `state` (`open`, `used` or `expired`) and `expires_at`, never the code. Null when none was opened, in every other role, and while Fermix is stopped. |
| `candidates` | array | On the primary, the candidate primaries it holds, each as the candidates result below draws it. Empty in every other role. |
| `move` | object, null | The move this home started or, on a candidate, the one it waits for: `phase`, `candidate` (the name of the host it moves to; null on a candidate) and `sentence`. On the home that moves, `phase` is `requested`, `streaming`, `committing`, `committed` (restarting as a desktop), `done`, `aborting`, `undoing` (restarting as the primary) or `aborted`, `done` and `aborted` written only by the start after the restart; on a candidate, `enrolling`, `enrolled`, `receiving`, `staged`, `activating`, `expired` or `failed`. Null when there is none. |
| `secrets_missing` | array | On a running primary, the ids (as `fermix setup` and `secret.set` take them) of the secret references in its settings that did not resolve on this host: each needs entering again. Empty in every other role, and while Fermix is stopped. The human output names them on a line of its own. |
| `primary_home` | object, null | On a running linked desktop, the primary's own record (this table's fields, as the primary answers them), asked within 5 s; its recovery, enrollment, candidates and move are the server's. Null on any other engine, while it is missing, and while Fermix is stopped. |
| `primary_missing` | string, null | On a running linked desktop whose primary is unreachable or did not answer within 5 s, the sentence that says why `primary_home` is missing. Null otherwise. |
| `summary` | object | Where Always On stands, as every surface prints it: `state`, `sentence`, `action` (`{id, label}` or null) and `detail`, as the management `home.status` answers it (`priv/management/PROTOCOL.md`, "The Always On summary"). With Fermix stopped it is worked out from the home's own files, so the link, the window and the server's own part read as absent. The human output leads with its sentence and, on a line of its own, its action as the Fermix app names it. |
| `disk` | object, null | On the primary, how full its disk is: `used` (a fraction from 0 to 1) and `nearly_full` (from 0.85). Null in every other role and when it cannot be read. |
| `version` | string | This engine's version. |

## The snapshots result

`fermix home snapshots status --json` answers with the `snapshots` object
alone.

| Field | Type | Meaning |
|---|---|---|
| `configured` | boolean | Whether a recovery key is set and at least one target is on. |
| `recipient_set` | boolean | Whether a recovery key is set. |
| `interval_hours` | integer | How often a snapshot is taken, 1 to 168. |
| `running` | boolean | Whether a snapshot is being written now. Always false with Fermix stopped. |
| `next_run_at` | string, null | When the next one is planned, ISO 8601 in UTC. Null while snapshots are off. |
| `targets` | array | One row per target: `id`, `label`, `configured`, `destination`, `last_attempt_at`, `last_result` (`verified`, `failed`, `waiting` for a target that takes it at a later run, such as a sleeping desktop, or null), `last_verified` (`at`, `name`, `epoch`, `size`, `sha256`, `location`, `key_id` (the recovery key it opens with, or null), or null), `last_error` (the newest failure's sentence, or null), `waiting` (why the last run left it waiting, or null). |
| `sentence` | string | One sentence for the state as a whole. |

`fermix home snapshots run --json` and `fermix home snapshots passphrase
--json` print the management result unchanged (`{started, snapshots}` and
`{recipient, key_id, snapshots, sentence}`, the sentence saying that
snapshots written before open only with the earlier passphrase); both need
Fermix running and refuse with
`engine_stopped` otherwise. The passphrase is read from `--passphrase-file`
or asked twice without echo, and never printed.

Goldens: `home_status/primary.json`, `home_snapshots_status/ok.json`.

## The enrollment and move results

`fermix home enroll-code --json` prints the management `home.enroll.open`
result unchanged (`{code, expires_at}`). The code is single use, valid for
thirty minutes (an engine restart in between keeps it), shown once and never
logged. It needs Fermix running on the primary
and refuses with `engine_stopped` otherwise; a refusal the engine answered is
`enrollment_refused`, carrying the engine's sentence.

`fermix home candidates --json` answers `{candidates}`, the candidate primaries
this home holds, from the engine when it runs and from the home's own file when
it does not. A candidate is held for 24 hours after it enrolled, at most four at
once, and its row is never its keys:

| Field | Type | Meaning |
|---|---|---|
| `candidate_id` | string | `cand-` and 16 hex digits: what `fermix home move --to` takes. |
| `name` | string | The name the host gave itself. |
| `os` | string | The host's operating system. |
| `arch` | string | The host's architecture. |
| `version` | string | The host's Fermix version. |
| `node_id` | string | The host's endpoint id, 64 hex digits. |
| `snapshots` | object, null | `s3_bucket` and `s3_region`: the bucket the host was told to keep snapshots in. Null when it was told none. |
| `enrolled_at` | string | When it enrolled, ISO 8601 in UTC. |
| `expires_at` | string | When the primary stops holding it, ISO 8601 in UTC. |

A refusal is `home_status_unavailable`.

`fermix home move --to ID --json` answers with the move as it was written:
`move_id` (`mv-` and 20 hex digits, ordered by when the move started), `candidate` (the row above),
`recovery_recipient` and `key_id` (the public half of the recovery key the
passphrase derived, as `home.snapshots.passphrase` answers them),
`keep_as_desktop` (true: this computer becomes a desktop of the new primary)
and `sentence`. With Fermix running this is the management `home.move.start`
result, and the engine then restarts in the device role and carries the move
out. With Fermix stopped the move is written here, and `sentence` says so: The
move to north-box is set up. Start Fermix: it starts in the device role and
moves this home. `--retire` is for a server that is itself the primary, being
replaced by another server and then destroyed: the move keeps no desktop here
(`home.move.start` with `keep_as_desktop` false), so `keep_as_desktop` is
false, the engine hands the home over and then serves nothing, and a move
written while Fermix is stopped says: The move to north-box is set up. Start
Fermix: it moves this home and then serves nothing here. The recovery passphrase is read from
`--recovery-passphrase-file` or asked twice without echo, and never printed. A
refusal is `move_refused`, carrying the engine's sentence or why the move could
not be written here, or each item of the move's readiness report
(`home.move.readiness`) that blocks it, after `The move cannot start yet.`

`fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]`
is not a machine-mode verb: it takes no `--json` and no running Fermix, and
makes a fresh home a candidate. It exits `0` with one line
on stdout once the home is a candidate and the code file is removed, `1` with
one sentence on stderr when it refused, leaving the home and the code file as
it found them, and `2` on a usage error. A home that holds a candidate which
never enrolled (its enrollment still trying, or refused) is replaced, the old
candidate kept until the new one is in place; one that enrolled and waits for
its move is refused, and so is any home while Fermix runs in it.

Goldens: `home_candidates/ok.json`, `home_move/ok.json`, `home_move/retired.json`.

## Error codes

Every refusal a `--json` verb can print, with the sentence it carries. Where a
sentence interpolates a fact, the example below is the golden's.

- `app_managed` — The Fermix application owns this engine's background service. Use the application's own background service controls.
- `user_manager_unreachable` — This session has no user service manager, so the background service cannot be inspected or changed from here. Log in to this machine and try again.
- `linger_denied` — The background service has to keep running after you log out, and this machine refused to allow that. Run sudo loginctl enable-linger operator, then try again. It said: Access denied
- `loginctl_absent` — This machine has no loginctl, so Fermix cannot keep the background service running after you log out. Run the daemon in the foreground with fermix run instead.
- `no_identity` — Fermix could not tell which account it is running as, and it will not guess one. Run this command from a normal login session.
- `invalid_home` — The service home must be an absolute path, and "fermix" is not.
- `home_change_refused` — The background service is running from /home/operator/.fermix. Stop it with fermix service uninstall before moving it to another home.
- `foreign_unit` — Fermix did not write the service file at /home/operator/.config/systemd/user/fermix.service, so it was left alone. Remove or rename it if you want Fermix to manage this service.
- `activation_timeout` — The background service was started but did not answer in time. Read what it said with journalctl --user -u fermix, then try again.
- `health_unavailable` — The background service is running, but its web address did not answer, so the setup page is not reachable yet. Read what it said with journalctl --user -u fermix.
- `foreign_distribution` — This Fermix was not installed from a Linux package, so there is no packaged background service for it to manage.
- `service_unbound` — No home is bound to the background service yet. Run fermix service install to choose one.
- `diagnostics_unavailable` — Fermix could not collect the diagnostic bundle. It said: collecting it took too long
- `idle_restart_unavailable` — This engine cannot restart when idle yet. Restarting now interrupts any work in progress.
- `lifecycle_refused` — The background service would not open a window to restart in. It said: the daemon returned no lease
- `invalid_port` — the web listener port must be a whole number from 1024 through 65535, and 22 is not
- `config_write_failed` — Fermix could not record the web listener port in the settings file. It said: permission denied
- `systemctl_failed` — The service manager refused the change. It said: Unit fermix.service not found.
- `binding_write_failed` — Fermix could not record which home the background service runs from. It said: permission denied
- `daemon_running` — Fermix is running from this home. Stop it, then try again.
- `epoch_absent` — The home has no primary epoch: it has never started as the primary.
- `already_moved` — This home already moved to hetzner cx22 on 2026-10-20 at epoch 3, and the first move stands.
- `mark_moved_failed` — Fermix could not mark this home moved. It said: could not tell whether Fermix is running (timeout)
- `engine_stopped` — Fermix is not running from this home, and this needs it. Start it, then try again.
- `snapshots_refused` — Fermix did not do that. It said: Snapshots are off: set a recovery passphrase to turn them on.
- `home_status_unavailable` — Fermix could not read this home's status. It said: The requested management method is not available. (method_not_found)
- `enrollment_refused` — Fermix did not open an enrollment code. It said: Only the primary enrolls candidates and starts a move.
- `move_refused` — Fermix did not start the move. It said: No server waiting for the move has the id cand-0f1e2d3c4b5a6978. A server waits 24 hours after it enrolls; after that, get a new code and enroll it again.

A sentence ending in `It said:` carries the words of whatever refused —
the service manager, the login manager, the filesystem. A client shows them and
never parses them.

Goldens: one per code under `errors/`.

## Changing this contract

The daemon ships first. Add a field, never remove or repurpose one, and leave
`schema_version` alone while the shapes a released client decodes still hold.
Regenerate the goldens in the same change: they are built by
`FermixTestSupport.CliContractCases`, and `contract_test.exs` prints the exact
replacement text for any golden that has drifted. Then re-vendor this directory
in the client repository, then release the client.
