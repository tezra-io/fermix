# Observability: logs, traces, Opik

## Where to look

| Question | Mac app | Linux and standalone |
|---|---|---|
| Why no reply, or a crash | sidebar **Logs** (**Search**, **Level**, **Pause**, **Copy visible**, **Export…**, **Load older**) | `fermix logs -f` (`-n LINES`, default 100) |
| The service will not start | the app's start-up screen (`macos_app` reference) | `journalctl --user -u fermix` (`journalctl -u fermix` for a `--system` unit): a failure before the log opens is only there |
| Is it healthy | **Doctor**; **Run network checks** probes providers and channels | `fermix doctor`; `--full` adds the network checks |
| What the agent or a tool did | trace files | trace files |
| A bug report | **Doctor** > **Export support bundle** (menu: **Export Support Bundle…**) | `fermix diagnostics export --offline --json > fermix-diagnostics.json` |

On an app-managed Mac the bundled `fermix logs` returns one bounded page and refuses `-f`. The support bundle holds engine identity, Doctor results and up to 500 re-scrubbed log lines, never messages, transcripts, databases, traces, audio or browser data; it is built locally and never uploaded.

## Logs

`~/.fermix/logs/fermix.log` (`FERMIX_LOG_FILE` moves it), rotated at 10 MB, 5 files. All log output, file and console, crash reports included, passes a redaction formatter: credential-shaped tokens (OpenAI and Anthropic `sk-…`, GitHub, Slack, SpaceXAI, Google, Telegram bot tokens, AWS key ids, bearer headers, JWTs such as OAuth access tokens) and whole PEM, OpenSSH and PGP private-key blocks become `[REDACTED:<vendor>]`. A marker means the redactor caught a secret, not that data was lost.

## Trace files

- `~/.fermix/traces/<date>/<type>.jsonl` (`FERMIX_TRACE_DIR` moves them). Folders are named by the **UTC** date: "today" is `$(date -u +%F)`, and in the evening in the Americas the local date names the wrong folder. Nothing prunes them.
- Types written: `llm_call`, `tool_exec`, `agent_event`, `channel_msg`, `sandbox_event`. Nothing writes `error.jsonl`. Failures are `status: "error"` rows in `llm_call` (with `error_kind`, `error_code`, `error_status`, `error`), `success: false` rows in `tool_exec`, `event: "turn_error"` or `"job_run_error"` in `agent_event`, and the log.
- A trace file is not a run: bucket rows by run window before counting error kinds. There is no `fermix traces` verb.

| Run | `session_id` |
|---|---|
| main turn | `main-<n>` |
| sub-agent | 32 hex characters, linked to its parent by `parent_session` events |
| scheduled job | `cron_<job>_<ts>` |
| coding run | `harness_<run_id>`, linked to the turn that started it by `origin_session_id` |
| reminder follow-up | `followup_<reminder_id>` |
| memory review | `memory_review:<agent>:<channel>:<chat>:<thread>:<max_message_id>` |
| Realtime voice call | `session:<n>` |
| GPT-Live call | `voice_live:<n>`; each delegated task is its own run with the call as `parent_session` |
| computer-use session | `cua_<id>` |
| meeting | `meeting_<id>_<ts>` |

## Content capture

- On by default. Traces sit under the `0700` Fermix home, so bodies stay on the machine unless the Opik exporter sends them to a remote Opik or `FERMIX_TRACE_DIR` moves them.
- Capture on: input and output bodies are attached whole (no truncation), and a failed browser action carries the page's recent console and JS-exception buffer, so the trace is the one place to debug. Capture off: bounded, body-free rows.
- `FERMIX_TRACE_CONTENT=0` in the daemon's environment is the one switch; `FERMIX_OPIK_ENABLED` controls the exporter only. The Mac app has no setting for either.
- Adapters record the cache split their vendor reports; Opik gets `cached_input_tokens` and `cache_creation_input_tokens` beside a blended `prompt_tokens`, and a count the vendor did not report is dropped rather than written as zero.
- Reminders: `[:fermix, :reminder, :lifecycle]` phases `materialized`, `claimed`, `delivered`, `retry_scheduled`, `failed`, `expired`, `superseded`, `cancelled`, `event_completed`, `scheduler_error`, `followup_skipped`; a follow-up run has `followup_start`, `followup_complete` and `followup_error` bookends with outcome `sent`, `declined`, `empty`, `delivery_failed`, `timeout` or `error`.
- Mobile pairing and push write `channel_pair` and `channel_push` rows to `agent_event` (counts, duration, channel and status only).

## Opik export

Off unless `FERMIX_OPIK_ENABLED` (`1`/`true`/`yes`) reaches the daemon; `FERMIX_OPIK_BASE_URL` and `FERMIX_OPIK_PROJECT` pick the target, and `FERMIX_OPIK_API_KEY` and `FERMIX_OPIK_WORKSPACE` serve Opik Cloud or any authenticated Opik. A shell export never reaches a service.

1. **Foreground run** (`fermix run`): set the variables in the shell that starts the daemon.
2. **Standalone service**: export them, then `fermix service install`, which snapshots `FERMIX_OPIK_ENABLED`, `FERMIX_OPIK_BASE_URL`, `FERMIX_OPIK_PROJECT` and `FERMIX_TRACE_CONTENT` (plus the `FERMIX_HOME` baseline) into the unit; reinstall after changing them. The API key and workspace are never written to a unit.
3. **Linux package**: put them in `~/.config/fermix/env`, then `fermix restart`.
4. **Mac app**: not available; the exporter stays off.

- `fermix doctor`'s `opik export` row asks the daemon whether the exporter is off, enabled but not bundled, or ready, with the endpoint and project.
- A Realtime call reassembles into one Opik trace: its lifecycle events (`[:fermix, :realtime, :call_start|session_created|session_updated|provider_error|reconnect|call_stop]`, written to `agent_event`), the model turn and its tool calls share one `session_id`. On GPT-Live (`[:fermix, :voice_live, …]` events) each delegated task is a child run of the call.
- Batch uploads retry a transient failure twice (500 ms, 1 s) with the same ids; a permanent or exhausted failure is a logged error. A turn can succeed while its upload failed, so read the daemon log before widening trace filters. Restart after any exporter change.

## What a restart or crash loses

| What | After a restart |
|---|---|
| Conversation history | kept (written through to SQLite) |
| A running turn, `/background` work | ended |
| A parked access-sensitive command | forgotten; the owner is asked again |
| A pending `/confirm` token | lost (held in memory); ask again |
| An in-flight scheduled run | marked `reaped: no live runner (daemon or scheduler restart, or a memory store that answered too late)` |
| An active meeting | marked failed, `daemon_restarted`; not rejoined |
| A local coding run | finalized `interrupted`, with resume guidance in its delivery |
| A mobile or companion request accepted but unfinished | runs again at the next start |
