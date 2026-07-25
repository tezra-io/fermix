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

## Recorded from

- **codex-cli 0.144.4**
- **claude 2.1.215**

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
- **claude streams include the operator's hook events** (`system/hook_started`,
  `hook_response`, `hook_progress`) and other unknown types (`rate_limit_event`) —
  realistic noise the vendor-agnostic parser passes through as events untouched.
