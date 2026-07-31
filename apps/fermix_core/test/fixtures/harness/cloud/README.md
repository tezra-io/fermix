# Codex cloud-rail fixtures

Text fixtures for `FermixCore.Harness.Adapters.CodexCloud` — the pure submit /
status parser for the `codex cloud` surface. Each file is the **merged
stdout/stderr** a `codex cloud exec` / `codex cloud status` invocation prints;
the parser also takes the process exit code, supplied by the test per the table
below (fixtures cannot carry an exit code).

## Source-derived (D15)

These are **not live recordings**. They are reconstructed verbatim from the
pinned CLI's source — **openai/codex, Rust, tag `rust-v0.144.4`** (the same
pin as the vendor-stream fixtures in the parent directory). The owner-gated
live smoke (a real cloud env spends quota and needs an env id browsable only
through the interactive TUI) validates them against real output; any drift found
there updates these fixtures and the parser together.

Format strings derived from the pinned CLI (spec §P):

- **exec success** — exactly one line, the task URL
  `https://chatgpt.com/codex/tasks/{task_id}` (`task_id` = last path segment),
  exit 0. Colors are off when piped; no `--json` exists on the cloud
  subcommands.
- **exec / status auth gate** — the verbatim line
  `Not signed in. Please run 'codex login' to sign in with ChatGPT, then re-run
  'codex cloud'.`, exit 1 (all cloud subcommands).
- **exec / status errors** — a single `Error: …` line on stderr (env not
  found / ambiguous / none available / HTTP error chains), exit 1.
- **status** — exactly three lines: `[{STATUS}] {title}` /
  `{env_label}  •  {relative_time}` (the env line is omitted entirely when
  unknown) / summary = `no diff` or `+{adds}/-{dels} • {files} file{s}`.
  `STATUS ∈ PENDING | READY | APPLIED | ERROR`. Note the distinct separators:
  the env line uses a double-space bullet (`  •  `), the diff summary a
  single-space bullet (` • `). The `error.log` debug side effect the CLI appends
  is written to a file, never this stream.

**Exit-code trap (status):** the pinned CLI exits `0` **only** for `READY`;
`PENDING`, `APPLIED`, and `ERROR` all exit `1` with valid stdout. Classification
is therefore output-driven (the status line decides); the exit code is consulted
only when no status line parsed.

## Files

### Submit (`parse_submit/2`)

| Fixture | Exit | Parses to |
|---------|------|-----------|
| `submit_success.txt`               | 0 | `{:ok, %{task_id: "task_i_abc123def456", task_url: …}}` |
| `submit_error_env_not_found.txt`   | 1 | `{:error, {:command_failed, "environment 'proj-web' not found"}}` |
| `submit_error_http.txt`            | 1 | `{:error, {:command_failed, …}}` |
| `submit_not_signed_in.txt`         | 1 | `{:error, :cloud_auth}` |
| `submit_unparseable.txt`           | 2 | `{:error, {:submit_parse, …}}` |

### Status (`parse_status/2`)

| Fixture | Exit | State | Notes |
|---------|------|-------|-------|
| `status_pending.txt`        | 1 | `:pending` | env line + `no diff` → `:nonterminal` |
| `status_ready.txt`          | 0 | `:ready`   | the only exit-0 state → `completed` |
| `status_applied.txt`        | 1 | `:applied` | exit 1 with valid stdout → `completed` (applied note) |
| `status_error.txt`          | 1 | `:error`   | → `failed`/`:cloud_failed` |
| `status_no_env_line.txt`    | 0 | `:ready`   | env line omitted → `env_label`/`relative_time` nil |
| `status_no_diff.txt`        | 0 | `:ready`   | `no diff` summary → `diff: :none` |
| `status_files_plural.txt`   | 0 | `:ready`   | `+120/-45 • 7 files` → `%{adds: 120, dels: 45, files: 7}` |
| `status_files_singular.txt` | 0 | `:ready`   | `+1/-0 • 1 file` (singular) → `%{files: 1}` |
| `status_not_signed_in.txt`  | 1 | —          | `{:error, :cloud_auth}` |
| `status_http_error.txt`     | 1 | —          | `{:error, {:command_failed, …}}` |
