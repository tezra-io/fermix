# In-loop context overflow: preserve, budget, compact, recover

**Status: rev 3, 2026-09-24. Slice 1 implemented on
`feat/in-loop-context-overflow` (uncommitted); see §10.** Supersedes the plan
in `MESSAGE_GATEWAY_ARCHITECTURE.md` §17.12. Slice 1 is everything below
except the level-2 checkpoint fold (§3.3), which is deferred.

Revision history. Rev 1 dropped older tool output; the owner ruled that out
(lost data makes the final answer wrong). Rev 2 replaced results with
digests and claimed nothing was lost; a review showed that claim false and
found four more defects: results were admitted at any size with no
source-side filtering, digests accumulated with no second level so a long
run still overflowed, the summarizer could overflow itself on small
windows and single-line results, and digest calls inherited the user's
streaming callback. Rev 3 answers each.

## 1. The problem, as the code has it

A turn is one `AgentLoop.run/1`: LLM call, tool calls, tool results, repeat,
up to `IterationLimits` (100 for chat, subagents and scheduled jobs). Every
adapter re-sends the whole transcript on every step (`provider_state` holds
the message or item list; no surface uses `previous_response_id`), so tool
results accumulate for the length of the loop.

Nothing shrinks that transcript inside the loop:

- Auto-compaction runs only around a chat turn: preflight in
  `TurnRunner.run_message_loop` when the previous turn's peak
  `context_tokens / context_window >= 0.85`, and after delivery in
  `TurnRunner.commit/4`. A scheduled job is compacted at neither point; it
  starts from its prompt and grows for up to 100 steps.
- The continuation retry (`AgentLoop.continue_with_retry/3`) re-issues only
  measured pre-response timeouts, pool-checkout failures, transport cuts and
  provider-declared unavailability. Overflow is none of these, so the loop
  returns `{:error, :context_length_exceeded}` on the spot.
- Failover happens only on the initial call, and overflow is not an eligible
  kind anyway (`Failover.eligible?/1`).
- The job runner's whole-loop retry (`Jobs.Runner.retry_or_fail/6`) refuses
  once any tool ran, and overflow is not in its transient set.

What the user sees:

- Chat: "This conversation has grown larger than the model's context window …
  Send /new … or /compact …, then resend" (`TurnRunner.error_reply/1`). The
  advice is wrong for this case: the history was fine, the turn's own tool
  results overflowed, and resending repeats the failure.
- Scheduled job: `Scheduled job "X" finished with error. Run ID: … Error:
  :context_length_exceeded` (`Jobs.Runner.failure_delivery_text/3` renders
  `inspect(reason)`). Tools already ran, their side effects stand, the answer
  is lost.

Size of a single tool result today (bytes):

| Tool | Cap | Where |
|---|---|---|
| file_read | 100,000; takes `offset`/`limit` line ranges | `Tools.FileRead` |
| subagent result | 60,000 | `Tools.Subagents` |
| shell | 1,048,576 | `CommandRunner` default `max_output_bytes` |
| web_fetch | 1,048,576 (body); takes only `url` | `Tools.WebFetch` |
| MCP tool result | none at the context seam | `Mcp.Capability.format_result/1` (remote transport caps 2 MiB) |
| browser, content_search | shape-bounded, no byte cap | |

One shell or web_fetch result at its cap is roughly 260k tokens: larger than
a 200k window on its own. Catalog windows run from 128k to 1M; an unknown
model is assumed to have 100k, and a local Ollama model may really have far
less.

Overflow detection is uneven: Anthropic (`messages.ex`), OpenAI Responses,
xAI and Codex (`responses_shared.ex`) map it to `:context_length_exceeded`;
the Chat Completions adapter maps nothing, so OpenRouter, Ollama, Venice and
Hugging Face routes surface overflow as a generic API error.

## 2. Contract

1. **Summaries may be lossy; captured evidence stays retrievable.** Every
   tool result is stored for the life of the run the moment it arrives. A
   result that is later compressed in the transcript can be searched and
   read from that store by its call id, through a tool. A missing detail is
   recovered by reading the stored snapshot, never by running the original
   tool again (a rerun can repeat a side effect or return different data).
2. **Exact answers come from deterministic processing, not from a
   summarizer remembering every row.** A total, a count, an exhaustive list
   over large output is computed with `content_search`, `file_read` ranges,
   `shell` or the recall tool over the stored snapshot. The digest frame
   says so to the model.
3. **The transcript is kept under the route's budget before each call.**
   The provider's refusal is the backstop, not the trigger.
4. **Recovery retries the provider call only.** No tool is ever executed
   twice by recovery, and nothing is removed from the transcript, only
   replaced under the same call id, so tool-call pairing cannot break.
5. **A run that never nears its budget is byte-identical to today**: no
   digest call, no recall tool advertised, no added latency.

## 3. Design

### 3.1 Preserve: the result store and the recall tool

`FermixCore.Agents.ToolResultStore`: one ETS table per loop, owned by the
loop process (it dies with the run), holding
`{call_id, step, tool_name, bytes, text}` for every result the loop built
(`build_tool_result/3`), written before the result is handed to the
adapter. The table reference travels in the tool context.

`tool_result_recall` (built-in, category `:read_only`, so the scheduled-job
policy default admits it): arguments `call_id` plus either `query` (a
substring or regex; returns matching lines with line numbers, at most 200
matches) or `offset`/`limit` (a line range, at most 400 lines). Its own
output is bounded at 16,000 bytes so a recall can never re-fill the context;
the model narrows the query or range instead. `advertise?/1` offers it only
once the store holds at least one compressed result, so a short turn never
sees it. The executor reads the table reference from the context; with none
present it returns an error naming the situation.

A job's raw results are not written to the run's artifact directory in v1
(§9 lists it as a follow-up for post-run inspection).

### 3.2 The digest primitive

`FermixCore.Agents.ToolResultDigest.digest(text, task, route, opts)` →
`{:ok, digest} | {:error, reason}`.

- **Task-guided and role-fenced.** The prompt carries the task (the user's
  request for a chat turn, `task_prompt` for a job) and the instruction to
  keep every fact, number, identifier, URL, error line and quote the task
  could need, and to say which kinds of detail it left out. Fenced like
  `Memory.Compactor.summary_system_message/0`: it must not act as the
  assistant or answer the task.
- **Chunked against the route's window, not a fixed size.**
  `chunk_tokens = min(24_000, floor(0.4 × context_window))`, bytes at four
  per token. Text is split on line boundaries; a single line longer than a
  chunk is hard-split on a UTF-8 boundary. Each chunk is one call. The
  joined chunk digests are re-chunked and digested again while they exceed
  one chunk, at most three levels deep; past that, the call fails with
  `{:digest_failed, :too_deep}` rather than guessing.
- **Output allowance.** The summarizer is asked for a target of
  `@digest_target_bytes = 8_000` and the request's output limit is set to
  cover twice that, so a chunk's summary can never itself be the overflow.
- **Never larger than the input.** A digest at least as long as its input
  is discarded; the result is marked `not_compressible` and left for the
  fold (§3.3).
- **Isolated from delivery.** The call uses the loop's route and
  `state.adapter_opts` with `stream_callback` removed and `agent` set to
  `tool_result_digest`, which is what its provider-call events carry (the
  failover executor's own event adds `surface: :tool_result_digest`).
  `:provider_start` activity is still
  emitted so a job's inactivity watchdog counts the call as progress. It
  runs through `Failover.run_chain/3` pinned to the route with the standard
  transient retry and no failover, the same shape as
  `TurnRunner.run_auto_compaction/5`, at `CompactionConfig.reasoning_effort/1`.
- **Provenance.** The digest of an untrusted result is wrapped in the same
  `UntrustedContent` frame as the original; a digest of a tainted result is
  tainted.

### 3.3 Compact: two levels, substitution only

Digests and stubs are a map `call_id => text` passed to the adapters as
`adapter_opts[:tool_result_substitutions]`. Each adapter's `continue/3`
replaces, in its replayed history, the text of any tool-result carrier
whose id has an entry: `tool_use_id` on Anthropic, `call_id` on the
Responses surfaces (OpenAI, xAI, Codex), `tool_call_id` on Chat
Completions. `ScreenshotRetention.keep_last/4` stays as it is for images;
the text pass is a sibling helper, `ToolResultRetention.substitute/3`.

**Level 1, per-result digest.** A result older than the last
`@raw_steps = 2` steps and larger than `@digest_target_bytes` is replaced by:

    [digest of a 48,213-byte result from web_fetch (call_id c_17), compressed to keep the context within budget. Facts, numbers, ids, URLs and error lines were kept; for anything else, or for exact totals, use tool_result_recall on c_17.]
    <digest>

**Level 2, checkpoint fold.** When the material older than
`@digest_steps = 6` steps (digests, small raw results, results marked
`not_compressible`) exceeds `@fold_share = 0.25` of the working budget, it is
folded into one running task checkpoint: constraints, decisions, actions
completed, work still open, and evidence references (call ids with one line
each on what they hold). The checkpoint is written into the slot of the
newest folded result; every other folded slot becomes a one-line stub
naming its call id and tool. A later fold digests the prior checkpoint
together with the newly aged material, the way `Memory.Compactor` feeds the
prior checkpoint summary into the next one. Folding is the digest primitive
applied to a concatenation, so it inherits the chunking bound.

Both levels are substitution: the list keeps every item and every id.

**What still grows.** The model's own assistant text between steps is not
folded. It is small per step and bounded by the iteration cap; if traces
show it mattering, level 2 can fold it by substituting assistant content
the same way. Codex reasoning items are already excluded from replay.

**Chat Completions detection.** Map overflow to `:context_length_exceeded`
in `chat_completions.ex` with the same message markers the other adapters
use, so the backstop fires on every route.

### 3.4 Budget: before every continuation

    estimate = last prompt_tokens + last completion_tokens
               + Σ (new result bytes) / 4 + frame overhead
    budget   = CompactionConfig.threshold (0.85) × context_window

Current usage, not the run's peak: the provider reported `prompt_tokens`
for the request just answered, the assistant's reply becomes part of the
next prompt, and the new results are the only unmeasured part. Images are
not estimated; screenshot retention already bounds them.

While `estimate > budget`, apply reductions in order and re-estimate after
each: level 1 on the oldest eligible results, one step at a time; then
level 2. Stop when the estimate fits or nothing is eligible. A run on an
unknown or mis-catalogued window may still be refused; that is what §3.5 is
for.

### 3.5 Recover: on provider refusal

When `continue_with_retry/3` returns `:context_length_exceeded` and nothing
has streamed for this call (the existing `emitted_before` guard):

1. Apply the next reduction that has candidates: level 1 on everything
   older than two steps; else level 2; else level 1 on the step being
   answered (the model has not read those results yet, and their raw text
   is in the store).
2. Re-issue the same `adapter.continue(provider_state, tool_results, opts)`
   with the updated substitutions. Never a tool.
3. Repeat at most three rounds per step. When no reduction has candidates,
   or the third round is refused, return
   `{:error, :context_overflow_after_compaction}`. A failed digest call
   returns `{:error, {:context_recovery_failed, reason}}` with the
   provider's reason inside.

Each round is smaller than the last by construction: a reduction is applied
only when it has candidates, and a substitution is applied only when it is
shorter than what it replaces.

### 3.6 Retrieve: fetching less at the source

The cheapest fix for context pressure is not fetching what the task does not
need. `file_read` already takes `offset`/`limit`, and `content_search`
narrows before reading. `web_fetch` takes only a URL and returns the whole
page. This document does not change tool surfaces: each is its own change
with its own eval, and MCP tool schemas belong to their servers. §9 lists
the follow-ups (web_fetch paging and section selection first). Rev 2's
alternative of cutting results at entry stays rejected.

### 3.7 Say what happened in plain words

- **Scheduled job.** The delivered text and the run's `error.md` carry a
  sentence first and the raw reason after it, so the ledger loses nothing:

      Scheduled job "X" finished with error.
      The run's tool results grew larger than the model's context window, even after earlier results were compressed. Narrow the task or split it into smaller jobs.
      Run ID: …
      Detail: :context_overflow_after_compaction

  The sentence comes from `TurnRunner.error_reply/2` gaining a `surface:`
  option (`:chat` | `:job`): one mapping from reason to sentence, with the
  surface choosing the closing advice ("/new or /compact" vs "narrow the
  task"). The `error` column keeps `inspect(reason)`.
- **Chat.** `:context_overflow_after_compaction`: "That request produced
  more tool output than the model's context window can hold, even after I
  compressed earlier results. Ask for a narrower slice, or split the
  request." `{:context_recovery_failed, reason}`: "The context filled and I
  couldn't compress earlier results: <provider sentence>." The existing
  history-overflow sentence stays for the initial-call case.

## 4. Not in scope

- Summarizing the whole transcript mid-loop (§17.12) — replaced by
  per-result digests and a folded checkpoint, which cannot overflow the
  summarizer and keep call pairing by construction.
- Tool-surface changes for source-side filtering (§3.6, §9).
- Persisting a job's raw results as run artifacts (§9).
- Ollama silently truncating at `num_ctx` — not an error the adapter can
  see; the budget uses the catalog window, so an unknown local model relies
  on §3.5.
- Compacting scheduled-job history between runs — jobs start fresh by
  design (`session_mode: "isolated"`).

## 5. Telemetry

- `[:fermix, :agent_loop, :context_compaction]`, measurements
  `%{count: 1, results, bytes_before, bytes_after}`, metadata
  `%{session_id, iteration, level, trigger}` (`level` 1 or 2; `trigger` in
  `:budget | :recovery`), one per reduction applied.
- `[:fermix, :agent_loop, :context_recovery]`, measurements `%{count: 1}`,
  metadata `%{session_id, iteration, round, outcome}` (`outcome` in
  `:recovered | :refused_again | :nothing_left | :digest_failed`), one per
  round.
- Every digest call is a normal provider call whose `agent` is
  `tool_result_digest`; `tool_result_recall` is a normal tool call through
  `Tools.Support.run/3`.
- `fermix_opik` maps both new events as spans on the loop's session.

## 6. Proof

ExUnit, failing first. Digest calls reach the `MockAdapter` as `chat/3`
calls tagged `:tool_result_digest`, so a test can count and inspect them.

Digest primitive:
- a 350 KB input on a 200k route makes four chunk calls and one join; on a
  128k route the chunk is smaller and the count higher; a 20 KB input makes
  one call; the summarizer never receives more than one chunk;
- a 1 MB input with no newline is hard-split on UTF-8 boundaries and every
  chunk is under the limit;
- a join that still exceeds a chunk is digested again, and a fourth level
  fails with `{:digest_failed, :too_deep}`;
- a digest longer than its input is discarded and the result is marked
  `not_compressible`;
- the call carries no `stream_callback`, carries the task and the role
  fence, and emits `:provider_start`.

Store and recall:
- every result is in the store before its continue call; `query` returns
  numbered matching lines; `offset`/`limit` returns the range; output is
  capped at 16,000 bytes with a note; a planted fact absent from a digest is
  found by `query` on the call id;
- the tool is not advertised until a substitution exists, and never on a
  turn that made none.

Budget and compaction:
- a scripted 100-step run whose every step returns 60 KB stays under the
  budget on a 200k route with zero provider refusals, level 1 fires as
  results age past two steps, level 2 folds at the share, and the fold runs
  more than once with the prior checkpoint fed into the next;
- results under the target are never digested at level 1;
- after each reduction the substituted list has the same length and the
  same ids as before (one test per adapter: Anthropic, Responses, Codex,
  Chat Completions), and an empty map yields a byte-identical request.

Recovery:
- refusal once → one reduction and one re-issue, the loop ends with the
  final answer; refusal with nothing eligible →
  `:context_overflow_after_compaction` with no re-issue; three refusals →
  the same error after exactly four continue calls; a failing digest call →
  `{:context_recovery_failed, reason}`; streamed content suppresses the
  re-issue;
- a mutating tool in the refused step executes exactly once across the
  recovery (the tool's executor counts calls).

Detection and messaging:
- `chat_completions` maps the overflow body to `:context_length_exceeded`;
- `Jobs.RunnerTest`: a loop failing with each new reason delivers its
  sentence and persists `error` as the inspected reason.

Live, owner-run, because a real overflow is not reproducible at nightly
eval cost on a 1M-window route:
- a scheduled job on a 200k route fetches six 200 KB fixtures carrying
  planted facts (ids, totals, one error line each) and must report every
  fact and the exact totals. Pass: the run delivers, the trace shows
  `context_compaction` at both levels, and every planted fact and total in
  the answer is right. Judged on correctness, not on the absence of a
  failure sentence.
- `@tag :live` ExUnit: digest one 300 KB fixture with twelve planted facts;
  assert which survive, and that `tool_result_recall` finds every one that
  did not.

Eval: `benchmark/suites/files_read.yaml` gains the `host_readonly` scenario
`large_result_planted_facts` over a 450 KB ledger fixture
(`suites/fixtures/context/ledger_large.txt`): one case asks for the planted
FLAGGED invoice and ERROR line, one for a vendor count and the ERROR line's
date. Both gate on the exact planted values and the judge rubric requires
them; `reply_not_matches` the product's own overflow sentence.

## 7. Change list

- `agents/tool_result_store.ex` (new), `tools/tool_result_recall.ex` (new,
  seeded in `Capabilities.BuiltinSeeder` with `advertise?/1`).
- `agents/tool_result_digest.ex` (new): the primitive.
- `agent_loop.ex`: store writes, the budget check before each continuation,
  level 1, the recovery ladder in `continuation_call`, telemetry.
- `providers/tool_result_retention.ex` (new): `substitute/4`;
  `screenshot_retention.ex` is untouched.
- `anthropic/messages.ex`, `openai/responses.ex`, `openai/codex.ex`,
  `openai/responses_shared.ex`, `openai/chat_completions.ex`,
  `xai/responses.ex`: the substitution pass; Chat Completions overflow
  mapping.
- `trace/telemetry_handler.ex`: the two events as JSONL `agent_event` rows.
- `agents/turn_runner.ex`: `error_reply/2` with `surface:`; two sentences.
- `jobs/runner.ex`: delivered failure text. Pinned by `tla/specs/job_runs`;
  text-only change, so after commit the spec is re-read and re-pinned with
  no behaviour change.
- `fermix_opik`: the two events and the `:tool_result_digest` surface.
- `priv/skills/self_knowledge/SKILL.md`: the turn-flow line, the compaction
  sentence, and the new tool (when a turn's tool results near the context
  budget, earlier results are compressed in place and stay readable through
  `tool_result_recall`; nothing is dropped). No numbers that read as
  versions.
- `MESSAGE_GATEWAY_ARCHITECTURE.md` §17.12: one line pointing here.

## 8. Decisions for the owner

1. Constants, not config: `@raw_steps = 2`, `@digest_steps = 6`,
   `@digest_target_bytes = 8_000`, `@fold_share = 0.25`, recall caps of 200
   matches, 400 lines, 16,000 bytes. None is a user decision.
2. Digest calls run on the loop's own route at medium effort, like
   compaction. The alternative is a cheaper fixed model, which is a new
   routing surface and a new place for a credential to be missing.
3. A successful compaction is visible in the trace only; the reply and the
   job notice say nothing unless recovery fails.
4. The recall tool's name and whether it also lists the stored results
   (a `list` mode) for a model that lost track of call ids.

## 9. Follow-ups, not in this change

- `web_fetch` paging (`offset`, `max_bytes`) and section selection, with its
  own eval; then the same review for `browser` snapshots and shell output.
- Persist a job's raw results under the run's artifact directory for
  post-run inspection.
- Fold assistant text at level 2 if traces show it growing.
- A threshold-free budget for routes with no catalog entry (Ollama): read
  the model's real window from the server instead of assuming 100k.

## 10. Slice 1: what was built, and where it departs from the text above

Built: §3.1 store and recall tool, §3.2 digest primitive, §3.3 level 1,
§3.4 budget, §3.5 recovery, §3.7 messages, §5 telemetry (Opik and the JSONL
trace), Chat Completions overflow detection, the substitution pass on all
five surfaces, ExUnit for each, the eval scenario, the `self_knowledge`
update. Deferred: §3.3 level 2 (the checkpoint fold) and the §9 follow-ups.

Departures, each a decision the owner can reverse:

1. **The recall tool is advertised on every loop that owns a store**, not
   only once a substitution exists. Advertisement is resolved once at loop
   start (`Advertisement.prepare/2` in `build_state`) and the adapters carry
   a fixed tool list in `provider_state`, so a tool cannot appear mid-loop
   without an adapter change. Its description says when it is useful; a
   call on a run with nothing compressed returns a clear error. Cost: one
   short schema per request.
2. **No wire-level output limit on digest calls.** Only the Anthropic
   adapter takes `max_tokens`, and it runs adaptive thinking under the same
   cap, so a small cap could truncate the digest itself. The target length
   is stated in the prompt only.
3. **Recovery round 2 digests the raw window** (the two steps before the
   one being answered) instead of level 2, which is deferred. Round 3 is
   the step being answered, as written.
4. **Digest-call tokens count toward the run's `total_tokens`**, so a run's
   reported spend includes its compaction.
5. **Search in `tool_result_recall` is a literal, case-insensitive phrase**,
   not a regex: one input shape, no invalid-pattern path. The `list` mode
   (§8.4) is not built.
6. **The substitution helper is `substitute/4`** (list, map, `id_of`,
   `replace`), matching `keep_last/4`, rather than the `/3` pair form.
7. **Job notices carry the sentence only for status `error`**; a timeout
   keeps today's text, since the timeout reason is already a sentence.
8. **The loop's context window comes from the catalog at route binding**,
   with an explicit `context_window` loop option (tests, callers that know
   better) taking precedence. An unknown model gets the catalog's default.
9. **Review fixes folded in:** a digest failure returns
   `{:context_recovery_failed, <provider reason>}` on both the budget and the
   recovery path (the summarizer's own refusals stay atoms and get their own
   sentence); the "never larger" rule is checked on the framed substitution,
   not the bare digest; the digest frame names `tool_result_recall` only on
   a run that can call it; the loop reads store metadata without copying
   bodies; the catalog lookup at route binding is quiet for unknown models;
   the three new UTF-8 cuts share `FermixCore.Text.truncate_utf8/2`.

