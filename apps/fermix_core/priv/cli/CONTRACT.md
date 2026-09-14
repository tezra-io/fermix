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
