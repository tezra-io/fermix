# harness_delivery: how a coding run's outcome reaches the owner

Models one local coding-harness run from the moment it ends until its outcome is
delivered. The spec covers:

- the `Harness.Run` reporting its end, or crashing;
- the `Harness.Manager` writing the one terminal ledger row, running the memory
  write-back, and handing the outcome off: a continuation turn, an inline text,
  or a dead letter;
- the `DeliveryWorker`'s 30 s outbox tick;
- a Manager crash at any step, with its `:rest_for_one` restart and boot
  reconciliation;
- sends and dispatches that fail, or that time out after the platform had
  already accepted them.

One run is enough. The Manager handles runs one callback at a time, and the
worker handles due rows one at a time. A second run would only widen the
windows below: the Manager is blocked inside one run's hand-off while other
reports queue, and a tick sends later rows long after it selected them. It
adds no new interleaving.

**The Manager's steps** (`mpc`):

```
idle --report/DOWN--> [terminal write] --ok--> writeback --> handoff --> idle
                         | error or :already_terminal -> idle
crash --> reconcile --> reconciling --> [terminal write] --ok--> writeback --> ...
```

The terminal write and the write-back are separate Repo calls. The UPDATE comes
first; `MemoryWriteback.write` then calls `Repo.upsert_memory` for a completed
run (`manager.ex:995`, `memory_writeback.ex:46-52`, `:159`). A crash between
them, or during the write-back, leaves a terminal pending row and no sender.

**A sender's life** (`ChannelSend.with_timeout`, `channel_send.ex:200-219`):
spawn → `flying` → `landed` (the platform or gateway accepted) → resolved by
its caller (`:ok`), or refused, or killed by the watchdog (before or after
landing). If its caller dies first, a flying sender becomes an orphan
(`spawn_monitor`, not linked, `:205`) that may still land.

**Origins** (`Origins`, the hand-off chosen by `hand_off_outcome`,
`manager.ex:1031-1036`):
- `chat`: a chat origin inside the chain cap. The outcome goes out as a
  continuation dispatch.
- `text`: a scheduled origin, a depth-capped chain, an owner halt, or no
  dispatcher configured, on a framework channel. The outcome goes out as one
  inline text.
- `client`: a client-owned (ACP) origin inside the chain cap. The outcome goes
  out as a continuation; if that fails, the row is dead-lettered with its named
  cause. The worker's text to it is refused inside its sender before anything
  is sent: `acp` has no `ChannelSend` adapter (`config/config.exs:117-125`,
  `channel_send.ex:237-243`).

**Not modelled:**
- admission and its refusals, and the cloud rail;
- owner cancel and `/stop`, and the rest of the client-owned "no continuation"
  arm. A client-owned row that is cancelled, tracking-stopped or depth-capped,
  or has no dispatcher, is dead-lettered with no send at all
  (`manager.ex:1046-1050`, `:1057-1061`, `:1109-1111`). HARNESS-1's overwrite
  reaches that arm too: a tick during the write-back selects the row, and the
  worker's refused send then reschedules it (`delivery_worker.ex:155-163`);
- the continuation depth cap itself, a pure per-row rule that ExUnit covers;
- `delivery_mode` `none` and `local`, which succeed with no channel send
  (`delivery.ex:101-103`);
- advisory notices and telemetry;
- the worker's backoff clock and its max-age rule;
- a failed delivery mark. It is logged and leaves the row pending, which gives
  the same resend a timeout does;
- the DeliveryWorker crashing on its own.

**Environment switches** (set per check):
- `RunsCanCrash`: the Run raises before it reports, so the Manager gets an
  abnormal DOWN.
- `ManagerCanCrash`: the Manager dies, up to `MaxManagerCrashes` times. Its
  supervisor restarts it, and the restart reconciles.
- `SendsCanFail`: a text send or a dispatch is refused, or the watchdog fires
  before the platform or gateway accepted it.
- `AcceptedSendsCanTimeOut`: the `with_timeout` watchdog fires after the
  platform or gateway had already accepted. The caller sees
  `{:error, :delivery_timeout}` and cannot tell the difference.
- `TerminalWriteCanFail`: the terminal UPDATE returns an error (SQLite busy,
  I/O or full).

**Timing idealisation** (`TRUE` is the real code):
- `TicksDuringHandOff`: the worker's free-running 30 s tick
  (`delivery_worker.ex:80-92`) can fire between the Manager's terminal write
  and its delivery mark. `FALSE` is not an environment event. It restricts the
  scheduler, and it lets the worker's step read the Manager's `mpc`, which the
  real worker cannot see. Only check 13 and the HARNESS-2/3/4 checks set it
  `FALSE`, to isolate other causes.

**Mechanism switches** (`TRUE` is the real code; each is switched off by exactly
one check):
- `CleanDownDropsOnly`: a `:normal` or `:shutdown` DOWN only drops the monitor
  (`manager.ex:958`).
- `IgnoresUntrackedRun`: every way a terminalization ends calls `drop_run`
  (`manager.ex:997`, `:1013`, `:1017`, `:1168-1184`), and a report or DOWN for
  a run no longer tracked is ignored (`:938-940`, `:947-953`, `:956-957`,
  `:964-965`). The spec's `tracked` variable is the Manager's `runs` and
  `run_monitors` entry. It is `TRUE` at start and `FALSE` after a crash, because
  the restarted Manager begins with empty maps (`manager.ex:1423-1424`).
- `GuardedTerminalUpdate`: the terminal UPDATE only matches an active row
  (`repo.ex:6045-6050`), and `:already_terminal` is dropped (`manager.ex:973`,
  `:1008-1013`).
- `RestForOne`: a Manager crash also restarts the `RunSupervisor` and the
  `DeliveryWorker`, killing every live Run first (`supervisor.ex:38-44`).
- `ReconcilesAtBoot`: the restarted Manager finalizes active local rows as
  `interrupted` (`manager.ex:196-197`, `:1260-1270`).
- `CrashDownTerminalizes`: an abnormal DOWN terminalizes the row as
  `failed/run_crashed` (`manager.ex:955-968`).
- `MarksDelivered`: a successful hand-off marks the row `delivered`
  (`manager.ex:1066`, `:1071-1078`, `:1146`, `:1151-1161`).
- `ClientDeadLetters`: a failed client-owned dispatch dead-letters the row with
  its named cause (`manager.ex:1085-1091`, `:1119-1134`).
- `WorkerDrainsOutbox`: the worker selects terminal rows that are still pending
  (`delivery_worker.ex:96-118`, `repo.ex:6168-6180`).
- `DeadLetterCap`: the worker dead-letters a row at `MaxAttempts`
  (`delivery_worker.ex:124-136`).

## What holds

Check 01 switches on run and Manager crashes, failed sends, sends that time out
after acceptance, and ticks during a hand-off. Under all of these:
- **Reconciliation only finalizes dead runs.** This rests on `RestForOne`
  (check 02).
- **Every run that ends gets a terminal row** (a proposed rule). This rests on
  `ReconcilesAtBoot` (check 03) and `CrashDownTerminalizes` (check 04).
- **The outbox ends delivered or dead-lettered.** This rests on
  `WorkerDrainsOutbox` (check 05) and `DeadLetterCap` (check 06).

**A run is terminalized once**, and its outcome is handed off once. This is
checked per layer because three layers each keep it on their own. Checks 07, 09
and 11 each run check 01's environment with only one layer on:
- 07: only the clean-DOWN filter;
- 09: only the runs-map lookup;
- 11: only the guarded UPDATE.

Each holds. Checks 08, 10 and 12 switch that last layer off too, and the run's
clean DOWN is terminalized a second time. The real code, with all three layers
on, was also run once by hand with this rule added to check 01, and it holds
(1,600 distinct states). The runner cannot carry it in check 01: no single
switch breaks it there. The guard's `:already_terminal` branch is never taken
with the other layers on. It is the backstop the moduledoc calls it
(`manager.ex:22`).

Check 13 does **not** describe the real code. It sets `TicksDuringHandOff`
`FALSE`, and switches off accepted-send timeouts and Manager crashes. Only under
that idealisation:
- **The owner hears each outcome once** (a proposed rule), and **no text follows
  a continuation turn**. Both rest on `MarksDelivered` (checks 14 and 15).
- **A client dead letter keeps its named cause.** This rests on
  `ClientDeadLetters` (check 16).

With the real timing (`TRUE`), all three rules break: see HARNESS-1. A timeout
after acceptance or a Manager crash breaks the second: see HARNESS-2.

Witness 24 shows the designed at-least-once resend: a text that times out after
the platform accepted it is sent again by the worker. Every message carries
`[run <id>]` for this reason (`delivery.ex:24`). With a send that times out
after acceptance on every attempt, the owner can receive up to
1 + `delivery_max_attempts` copies (21 by default).

The checks use `MaxAttempts = 2` and `MaxManagerCrashes = 1`. Every `holds`
check was also run once by hand with `MaxAttempts = 3` and
`MaxManagerCrashes = 2`, and all still hold:
- checks 01, 07, 09 and 11: 5,795 distinct states each;
- check 13: 114 distinct states.

All three origins are in every `holds` check. The run count is fixed at one
(see above).

## Plan hypotheses

- **A freshly terminalized row is at once selectable by the worker:**
  confirmed. This precondition had to be checked first.
  - `admit_attrs` writes neither `delivery_status` nor `next_delivery_at`
    (`manager.ex:356-386`), so the insert stores `'pending'` and `NULL`
    (`repo.ex:470-473`, `:6486-6488`).
  - The terminal UPDATE writes only the status, the outcome's ledger fields and
    `completed_at` (`repo.ex:6038-6050`; the fields come from
    `manager.ex:1188-1224`).
  - The worker's query takes any non-active row that is `pending` with a
    `NULL` `next_delivery_at` (`repo.ex:6168-6180`).
- **A tick during the inline hand-off sends the outcome twice:** confirmed,
  see HARNESS-1 (check 17).
- **A tick during the hand-off sends a text on top of the continuation turn:**
  confirmed, see HARNESS-1 (check 18). The same double notification also
  follows a dispatch that was accepted but not confirmed, with no tick overlap:
  see HARNESS-2.
- **Continuation chains stop at depth 3** (plan §4.5): not modelled.
  `continuable?/1` is a pure check on one row (`continuation.ex:99-102`), and
  ExUnit is the right tool for it.

## Findings

Every finding below was confirmed by walking the counterexample through the code
on `dev`. None has been reproduced on a running daemon. To see a counterexample,
run `tla/bin/check.py harness_delivery` and open
`tla/out/harness_delivery/<check>.txt`.

### HARNESS-1: a worker tick during the Manager's hand-off notifies the owner twice
- **Severity:** medium. The trigger is ordinary timing, not a failure. The
  outcome is a duplicate notification, and three code claims are broken.
- **Status:** open.
- **Checks:** 17 (7 states), 18 (7 states), 19 (7 states).
- **Counterexample:**
  1. The Run reports.
  2. The Manager writes the terminal row, runs the write-back, and starts its
     inline hand-off.
  3. The worker's tick selects the same row, which is still `pending`, and
     starts its own send.
  4. Both sends land.

  The outcome depends on the origin:
  - Check 17 (text origin): the owner gets the same `[run <id>]` message twice.
  - Check 18 (chat origin): the owner gets the continuation turn and the text.
  - Check 19 (client-owned origin): the dispatch fails and the Manager
    dead-letters the row with its named cause. The worker's refused send to
    `acp` then fails, and `reschedule/5` overwrites `last_delivery_error` with
    `unsupported_delivery_platform`. The client-owned arm that dead-letters
    with no send (see Not modelled) is exposed the same way.
- **Code:**
  - The terminal UPDATE leaves the row due for the worker (see the first plan
    hypothesis).
  - `post_terminal/5` then runs telemetry, the memory write-back (a second Repo
    call) and the inline hand-off (`manager.ex:993-998`). A text send can take
    up to 60 s (`delivery.ex:49`, `:273-286`), and a dispatch up to 15 s
    (`continuation.ex:54`, `:147-159`). Only then does the Manager mark the row
    (`manager.ex:1151-1161`).
  - Meanwhile `run_tick/1` selects the row (`delivery_worker.ex:96-103`), and
    `process_row/3` sends from that snapshot without re-reading the row
    (`:113-118`). Nothing claims the row between the select and the send.
  - Both sides mark the row with an unguarded `UPDATE ... WHERE id = ?`
    (`repo.ex:6079-6086`). `reschedule/5` writes `last_delivery_error` without
    checking `delivery_status` (`delivery_worker.ex:155-163`).
  - The code claims otherwise:
    - `delivery_worker.ex:18-20`: the worker "naturally sees a row only because
      the Manager marks delivered only on success".
    - `manager.ex:1021-1023`: "no text push, no double-notify".
    - `manager.ex:1080-1084`, `:1117-1118`: the named cause must not be
      overwritten.
- **Impact:**
  - For a scheduled, capped or halted run, a duplicate message. Each such run
    is exposed with a chance of roughly the write-back plus the send's
    duration, divided by 30 s (an estimate, not measured).
  - For a chat run, a raw text beside the agent's own report. The dispatch is a
    cast, so its window is short, but it includes the write-back.
  - For an ACP run, the operator reads `list_coding_runs` and sees the useless
    word instead of the cause they can fix. A related effect, not modelled
    because there is no clock: a racing worker whose send fails after the row
    has aged past `delivery_max_age_hours` writes `dead_letter` over the
    Manager's `delivered` (`delivery_worker.ex:127-153`).

### HARNESS-2: a continuation the Manager could not confirm is followed by a text
- **Severity:** low. It needs a Manager crash mid-dispatch, or a watchdog kill
  in a microsecond window.
- **Status:** open.
- **Checks:** 21 (8 states) is the realistic route; 20 (8 states) is the narrow
  one. Both run with no tick during the hand-off, so they do not depend on
  HARNESS-1.
- **Counterexample:**
  - Check 21: the Manager crashes during the dispatch. The unlinked sender
    finishes the ingest, so the agent turn runs, and the restarted worker sends
    the outcome as text.
  - Check 20: `Gateway.ingest` casts the continuation to the agent queue, and
    the 15 s watchdog kills the sender before it can report back. The Manager
    sees `{:error, :delivery_timeout}` and leaves the row `pending`, and the
    next tick sends the text.

    `Gateway.ingest` does nothing after its cast but emit telemetry and return
    (`gateway.ex:36-44`, `:455-468`). So the 15 s must elapse *before* the
    cast, and the kill must land in the gap between the cast and the sender's
    `send(parent, ...)` (`channel_send.ex:205`, `:215-216`).
- **Code:**
  - `with_timeout` kills the sender and reports a timeout, whatever the sender
    already did (`channel_send.ex:200-219`). The sender is `spawn_monitor`ed,
    not linked (`:205`), so it outlives a crashed caller.
  - `continuation.ex:141-145` chooses "a timeout/crash is an `{:error, _}`
    dispatch, so the row stays pending and the DeliveryWorker delivers the
    outcome as text". That assumes an error means no ingest.
  - The dispatcher guarantees only the converse: `:ok` means accepted
    (`continuation_dispatcher.ex:44-46` in core,
    `fermix_channels/.../continuation_dispatcher.ex:15-20`).
- **Impact:** the owner gets the agent's continuation reply and the raw outcome
  text. This breaks the claim at `manager.ex:1021-1023`.
- **Confidence:** confirmed in code. Check 20's path needs both a slow ingest
  and a kill in a very narrow gap.

### HARNESS-3: a Manager stop with a report still queued records the finished run as interrupted
- **Severity:** low. It needs the Manager to stop while a report waits. The
  outcome is finished work reported as unfinished.
- **Status:** open.
- **Check:** 22 (5 states).
- **Counterexample:**
  1. The Run sends its report and exits `:normal`.
  2. The Manager dies before handling the report.
  3. The restarted Manager's reconciliation finds the row still active and
     terminalizes it `interrupted`.
- **Code:**
  - The report is only a message in the Manager's mailbox (`run.ex:634`,
    `manager.ex:246-247`), and the mailbox dies with the process.
  - `reconcile_row/2` finalizes every active local row as `interrupted`
    (`manager.ex:1267-1270`, `:1222-1224`).
  - The Manager blocks for up to 60 s in each inline hand-off, so reports can
    queue behind it.
  - An orderly shutdown (a daemon restart or upgrade) loses the report the same
    way, and is likely the most common trigger. The supervisor stops its
    children in reverse order: the DeliveryWorker, then the RunSupervisor, then
    the Manager, which does not trap exits. A report still in the Manager's
    mailbox is lost, and the next boot's reconciliation writes `interrupted`.
  - A restart of an earlier child of the core `:rest_for_one` tree
    (`application.ex:259`), such as `Memory.Repo`, restarts the harness subtree
    the same way.
- **Impact:**
  - The owner's text reads "`[run <id>] interrupted`", with the completed result
    shown as if it were the vendor's error text, and a resume hint. The text is
    re-read from `result.txt` (`delivery.ex:352`, `:435-439`).
  - A chat continuation carries no result body. It closes with "This run ended
    without reporting a result ... run it again if the cause looks transient"
    (`continuation.ex:88`, `:212`), which invites the agent to redo finished
    work.
- **Confidence:** confirmed in code. This is a proposed rule, not a code claim.

### HARNESS-4: a failed terminal write strands the run until the next restart
- **Severity:** low. It needs a SQLite write error. The outcome is silent and
  holds the run's locks.
- **Status:** open.
- **Check:** 23 (a liveness violation; its lasso length is not pinned).
- **Counterexample:**
  1. The Run reports.
  2. `Ledger.terminalize` returns an error.
  3. The Manager logs and drops the run, then ignores its `:normal` DOWN.
  4. The row stays active, and nothing ever runs for it again.
- **Code:**
  - `after_terminalize_error/4` re-arms only a cloud run. A local run is dropped
    (`manager.ex:978-991`, `:1015-1018`, "has no live poll to re-arm and is
    dropped").
  - The worker never selects an active row (`repo.ex:6176`).
  - Only the next Manager start reconciles the row, as `interrupted`
    (`manager.ex:1267-1270`).
- **Impact:**
  - The owner is never told.
  - `list_coding_runs` shows the run as running, yet `cancel_coding_run` on it
    answers `{:error, :already_terminal}`: the run is no longer in `runs`, and
    `terminal_cancel_reply/2` treats any row it finds as terminal
    (`manager.ex:215-218`, `:927-933`). The owner cannot cancel it.
  - Its workspace lock roots and capacity slot stay held, because admission
    counts active rows (`repo.ex:5940-5968`). Later runs in that worktree are
    refused `workspace_locked` until the daemon restarts.
- **Confidence:** confirmed in code. It depends on a Repo write error, which
  the code handles as a return value.

## Assumptions

- **Message order:** BEAM delivers the Run's report before its DOWN (same
  sender). A Repo request the dying Manager already sent is served before the
  restarted Manager's reconciliation scan (single node; the old process enqueued
  it before the new one existed). The spec therefore treats each Repo call as
  atomic with respect to a Manager crash.
- **Continuation turns:** a gateway cast counts as a turn the owner will see.
  Whether the queue later drops it (for example on `/stop`) is `turn_queue`'s
  scope.
- **Sends and fairness:** a send's landing and a platform refusal get no
  fairness. The caller's own watchdog does, so every liveness check runs with
  `SendsCanFail = TRUE`.
- **Manager crashes:** a Manager crash also stands for any restart of the
  harness subtree. The spec keeps orphaned senders alive, which is right for a
  subtree restart. On a full daemon stop they die with the VM, which only
  removes behaviours.
