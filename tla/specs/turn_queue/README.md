# turn_queue: the per-conversation turn queue

Models `FermixChannels.Gateway.Queue` for one conversation: the FIFO of waiting
messages, the one active turn, the turn task's steps (including a failed
MainAgent checkout), and how each turn's result reaches its channel through
`turn_result_fn`. That callback matters to ACP, mobile and voice, which attach
one and wait on it. Other conversations are independent by construction, so
one conversation with two messages covers the interleavings that matter.

**Environment switches** (set per check):
- `UsersCanStop`: `/stop` (through `Stopper` to `Queue.stop_all`), or a voice
  or ACP cancel (`Queue.stop_conversation`). Both have the same effect on one
  conversation.
- `TasksCanCrash`: the turn task raises, exits or throws at any step,
  including an exit or throw from the channel's own callback, which
  `invoke_turn_result` does not rescue.
- `QueueCanCrash`: the Queue GenServer dies and its supervisor restarts it with
  empty state.

**Mechanism switches** (`TRUE` is the real code; each is switched off by
exactly one check):
- `OneClaimant`: the Queue hands the callback to its first claimant only and
  clears its own copy (`queue.ex:181-194`).
- `StartsWhenIdle`: a message starts only when no turn is active
  (`queue.ex:253-261`).
- `CrashFiresOutcome`: a crashed turn's callback, if the Queue still holds it,
  fires `{:failed, _}` (`queue.ex:811-819`).

**Timing idealisation:** `StopOrCrashInClaimGap`. `TRUE` is the real code. A
turn finishes in two steps (`finish_turn`, `queue.ex:523-529`):
1. The turn claims the callback from the Queue.
2. The turn invokes that callback, inside its own task.

`FALSE` forbids a `/stop` or a crash between those two steps. A check that sets
it `FALSE` proves a property only for a Queue without that gap.

## What holds

**Check 01** holds with `/stop` and crashes allowed anywhere, including the gap:
- No turn's result ever fires twice. This rests on `OneClaimant`; check 02
  shows the rule breaks without it.
- There are never two live turn tasks for one conversation. This rests on
  `StartsWhenIdle` (check 03).

**Check 04** (idealised): every started turn gets its result, with `/stop` and
crashes allowed everywhere except the claim gap. This rests on
`CrashFiresOutcome` (check 05).

In the real code the gap exists, so this rule does not hold; see QUEUE-6.
Witness 06 shows that a stop or crash can land exactly when the turn is about
to claim.

The checks use two messages. Checks 01 and 04 were also run once by hand with
three messages. Both still hold (42,701 and 27,670 states).

## Not modelled

- The LLM and tools (one "loop" step), streaming drafts, and typing.
- The `terminal_error_owner?` branch, which only changes who sends the error
  text.
- The empty-completion path (`queue.ex:477-480`, `:642-653`). It delivers a
  canned retry, commits nothing and claims `{:completed}`. It leaves the user
  message unanswered by design, so that the owner can retry.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `make -C tla check SPECS=turn_queue` and open
`tla/out/turn_queue/<check>.txt`.

### QUEUE-1: a Queue restart orphans the running turn
- **Severity:** medium. The trigger is rare, but the outcome is bad.
- **Status:** open.
- **Checks:**
  - 07 (4 states).
  - 08 (a liveness lasso; its length is not pinned).
  - Witness 09.
- **Counterexample:** m1's turn starts, then the Queue crashes and restarts. m2
  arrives and starts while m1's task is still alive.
- **Code:**
  - Turn tasks run under `FermixCore.TaskSupervisor` (`queue.ex:141`, `:295`),
    which is not linked to the Queue.
  - The Queue is a `:one_for_one` child (`application.ex:56`, `:66`).
  - The orphan keeps the dead Queue's pid.
- **What the orphan does next** depends on where it was:
  - **Before it asked `fresh?`:** the call exits and is caught as "not fresh"
    (`queue.ex:610-613`). It delivers nothing and commits nothing.
  - **After it passed `fresh?`:** it delivers its reply and commits it
    (`queue.ex:483-487`) while the new Queue's turn runs. Commit assumes the
    conversation is single-flight (`turn_runner.ex:125-131`). Witness 09
    shows this.
  - **Either way:** its claim exits and returns nil (`queue.ex:531-535`), so
    its result never fires (check 08). The new Queue has no record of it, so
    `/stop` cannot reach it.
- **Impact:**
  - The orphan's tools keep running, with their side effects, beside the new
    turn.
  - Two commits can interleave in one conversation.
  - ACP, mobile or voice never get an answer for that turn.

### QUEUE-2: a `/stop` just after delivery drops the reply from history
- **Severity:** low.
- **Status:** open.
- **Check:** 10 (6 states).
- **Counterexample:** the reply is delivered (`deliver_final`, `queue.ex:483`).
  `/stop` then arrives before `runner.commit` persists it (`:487` →
  `turn_runner.ex:143`).
- **Code:**
  - `stop_conversation_runtime` kills the task and writes the stopped marker
    (`queue.ex:926`, `:963-966`).
  - The marker is written because the last stored message is still the
    user's (`conversation_store.ex:173`).
- **Impact:** the user saw a full answer, but history says "stopped before I
  finished it". The next turn's model does not know it already answered.

### QUEUE-3: `cancelled` is reported for a turn the user saw answered
- **Severity:** low.
- **Status:** open.
- **Check:** 11 (6 states).
- **Counterexample:** the reply is delivered, then `/stop` arrives before the
  task claims its result.
- **Code:** `commit/4` runs auto-compaction synchronously (`queue.ex:487` →
  `turn_runner.ex:122`). The claim happens only after that returns
  (`finish_turn`, `queue.ex:455`), so the window lasts as long as a
  compaction call.
- **Impact:** the channel gets `{:cancelled}` after the full reply. ACP reports
  stop reason `cancelled` for an answered prompt.

### QUEUE-4: a crashed turn leaves its user message unanswered
- **Severity:** low. It happens on crash paths only.
- **Status:** open.
- **Check:** 12 (4 states).
- **Counterexample:** the user message is persisted, then the task raises.
- **Code:**
  - `clear_active_request` (`queue.ex:768`) sends the generic error and fails
    the turn result, but writes no stopped marker.
  - The stop and error paths both write one (`:510`, `:963-966`).
- **Impact:** the next turn replays an unanswered request. For failed turns,
  the comment at `queue.ex:498-502` says this must not happen. The
  empty-completion path leaves the message unanswered on purpose, so this
  finding is about crashes only.

### QUEUE-5: a crash between delivery and marking it sends an error after the reply
- **Severity:** low. It happens on crash paths only.
- **Status:** open.
- **Check:** 13 (6 states).
- **Counterexample:** `deliver_final` succeeds, then the task raises before
  `mark_final_reply_delivered` (`queue.ex:483-484`).
- **Code:** `maybe_reply_on_crash` (`queue.ex:795`) checks the flag that the
  second call would have set.
- **Impact:** the user gets "Sorry, I encountered an error…" after the full
  reply.

### QUEUE-6: a `/stop` or crash between claiming the result and invoking it loses the result
- **Severity:** low to medium. The window is microseconds on the `/stop` path,
  but the waiting channel hangs.
- **Status:** open.
- **Checks:** 14 (crash), 16 (`/stop` alone); both are liveness lassos.
- **Counterexample (check 16):** the reply is committed. The task claims its
  callback, and the Queue clears its own copy (`queue.ex:186-194`). A `/stop`
  then kills the task before `invoke_turn_result` runs (`queue.ex:526`).
- **Code:**
  - The stop finds no callback to fire (`active_turn_result_fn`, `:932`).
  - It drops the monitor with the conversation (`:918`, `:935`).
  - The same happens if the channel's callback exits or throws, because
    `invoke_turn_result` rescues exceptions only (`:829-837`). The resulting
    `:DOWN` then finds no callback (`maybe_fail_turn_result`, `:811-819`).
- **Impact:** the exactly-once claim in the Queue's moduledoc becomes "at
  most once". An ACP prompt, a mobile request or a voice delegation waits for
  a result that never comes.

### QUEUE-7: a `/stop` drops waiting messages without ever answering them
- **Severity:** low. ACP allows only one outstanding prompt per session, so
  it is unaffected; mobile and voice can queue a second message.
- **Status:** open.
- **Check:** 15 (a liveness lasso).
- **Counterexample:** m1 is running and m2 waits in the queue. `/stop` cancels
  m1 and drops m2.
- **Code:**
  - `stop_one_conversation` and `stop_all_conversations` fire only the active
    turn's callback (`queue.ex:896-930`).
  - Pending messages are discarded with the conversation.
  - A Queue restart drops them the same way.
  - `queue.ex:315-316` states the rule this breaks: "a turn-result consumer
    must never be left waiting".
- **Impact:** a queued mobile request or voice delegation never settles.
