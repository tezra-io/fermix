# Harness vendor-stream fixtures

Recorded JSONL streams from the two coding-harness vendor CLIs, used by
`FermixCore.Harness.EventStreamTest` to pin line-reassembly, framing, and the
terminal-outcome matrix against real vendor output.

## Files

| Fixture | Vendor stream | Process exit |
|---------|---------------|--------------|
| `codex_exec_success.jsonl`  | `codex exec --json`             | 0 |
| `codex_exec_failure.jsonl`  | `codex exec --json` (bad model) | 1 |
| `claude_stream_success.jsonl` | `claude --output-format stream-json` | 0 |
| `claude_stream_failure.jsonl` | `claude --output-format stream-json` (bad model) | 1 |
| `codex_0_166_0_not_signed_in.jsonl` | `codex exec --json` (no sign-in at all) | 1 |
| `codex_0_166_0_refresh_failed.jsonl` | `codex exec --json` (a sign-in it could not refresh) | 1 |

## Recorded from

- **codex-cli 0.144.4**
- **claude 2.1.215**
- **codex-cli 0.166.0** for the `codex_0_166_0_*` sign-in fixtures (M98 D10), in
  a throwaway `CODEX_HOME` with invented values: one with no `auth.json`, one
  with invented, expired ChatGPT tokens. The file name carries the CLI version
  because the words `CodexExec.signed_out?/1` pins are checked against them at
  every bump; a new version's words get fixtures of their own.

## Re-record commands

Run each CLI from a throwaway scratch directory, capturing stdout as JSONL (the
harness merges stderr into the same byte stream; the recordings capture stdout
only, which is where the JSONL lines live). Success uses the default model; the
failure fixtures were produced by requesting a non-existent model so the CLI
emits a real error/terminal sequence and exits non-zero.

```sh
# codex (JSON experimental line stream)
codex exec --json -C "$SCRATCH" 'reply with the single word ok' > codex_exec_success.jsonl
codex exec --json -C "$SCRATCH" -m nonexistent-model-xyz 'hi' > codex_exec_failure.jsonl

# claude (streaming JSON)
claude -p 'reply with the single word ok' --output-format stream-json --verbose \
  > claude_stream_success.jsonl
claude -p 'hi' --model nonexistent-model-xyz --output-format stream-json --verbose \
  > claude_stream_failure.jsonl
```

The sign-in fixtures were made the same way, in an empty scratch folder:

```sh
CODEX_HOME="$EMPTY_CODEX_HOME" codex exec --json -C "$SCRATCH" 'hi' \
  > codex_0_166_0_not_signed_in.jsonl
CODEX_HOME="$EXPIRED_CODEX_HOME" codex exec --json -C "$SCRATCH" 'hi' \
  > codex_0_166_0_refresh_failed.jsonl
```

Claude Code's sign-in failure ("Not logged in · Please run /login") has no
fixture yet: on a Mac its sign-in is in the Keychain, so the tests use the
`result` event's documented shape from the 2026-07-26 incident.

## Sanitization

Structure and keys are byte-faithful. The only edit replaces the recording
operator's macOS username with `operator` everywhere (covers both the `/Users/...`
paths and the dash-encoded project-directory form). No account ids, emails, or org
ids appear in the raw recordings; ephemeral thread/session UUIDs are kept as-is.

## Protocol facts these recordings establish (asserted by the tests)

- **A codex SUCCESS stream contains `item.completed` items whose `item.type` is
  `"error"`** (e.g. the skills-budget warning). An error *item* is not a failed
  *run* — the exit code plus the `turn.completed` event decide the outcome.
- **codex failure** emits a top-level `{"type":"error", ...}` event, then
  `turn.failed`, then exits 1.
- **claude's `result` event is NOT reliably the last line** — operator hook events
  (`hook_response`) can trail it. Terminal detection must be position-independent:
  any `type=result` event marks the terminal as seen.
- **claude `result` can carry `subtype: "success"` together with `is_error: true`**
  (invalid-model run). `subtype` is unreliable; the process exit code stays
  authoritative for the outcome.
- **codex with no sign-in** calls the API with no credential and retries (each
  retry a top-level `error` event), then ends on `turn.failed` with the API's
  `401 Unauthorized: Missing bearer or basic authentication in header`; it
  never prints "Not logged in" (that is `codex login status`'s wording).
- **codex with a sign-in it cannot refresh** ends on an `error` event and a
  `turn.failed` carrying the same sentence, "… Please log out and sign in
  again." Both are `signed_out` runs (`Harness.Run`, `CodexExec.signed_out?/1`).
- **claude streams include the operator's hook events** (`system/hook_started`,
  `hook_response`, `hook_progress`) and other unknown types (`rate_limit_event`) —
  realistic noise the vendor-agnostic parser passes through as events untouched.
