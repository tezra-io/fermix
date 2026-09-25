# harness_delivery: how a coding run's outcome reaches the owner

Models one local coding-harness run from the moment it ends until its outcome is
delivered. The spec covers:

- the `Harness.Run` reporting its end, or crashing;
- the `Harness.Manager` writing the one terminal ledger row, which also leases
  the row to its own inline first attempt, running the memory write-back, and
  handing the outcome off: a continuation turn, an inline text, or a dead
  letter;
- the `DeliveryWorker`'s 30 s outbox tick;
- a Manager crash at any step, with its `:rest_for_one` restart and boot
  reconciliation;
- the owner's cancel of an active row the Manager no longer tracks;
- sends and dispatches that fail, or that time out after the platform had
  already accepted them.

One run is enough. The Manager handles runs one callback at a time, and the
worker handles due rows one at a time. A second run would only widen the
windows below: the Manager is blocked inside one run's hand-off while other
reports queue, and a tick sends later rows long after it selected them. It
adds no new interleaving.

**The Manager's steps** (`mpc`):

```
idle --report/DOWN/cancel--> [terminal write] --ok--> writeback --> handoff --> idle
                               | error or :already_terminal -> idle
crash --> reconcile --> reconciling --> [terminal write] --ok--> writeback --> ...
```

The terminal write and the write-back are separate Repo calls. The UPDATE comes
first; `MemoryWriteback.write` then calls `Repo.upsert_memory` for a completed
run (`manager.ex:1066`, `memory_writeback.ex:46-52`, `:159`). A crash between
them, or during the write-back, leaves a terminal pending row and no sender.

**The hand-off lease** (`leased`): the terminal UPDATE also writes
`next_delivery_at = now + @handoff_lease_ms` (120 s; `terminalize_and_notify/4`,
`manager.ex:1035-1047`, `:83-95`), and the worker selects only due rows
(`repo.ex:6461`). So the row is terminal and leased in one statement, and the
worker cannot select it until the lease ends. The lease clock starts before
the terminal write is served (`manager.ex:1036`), so the lease must outlast that write
and the Manager's own hand-off: the terminal write, at most two write-back Repo
calls, the inline watchdog (60 s for a text, 15 s for a dispatch), and the
mark, each Repo call bounded by `GenServer.call`'s 5 s. That is at most 80 s.
**TLC does not check the lease length.** `LeaseEnds` waits for the Manager to leave its hand-off, which stands
for that budget, and the ExUnit test "the lease outlasts the longest inline
hand-off" (`manager_test.exs`) locks the budget against
`Delivery.deliver_timeout_ms/0` and `Continuation.dispatch_timeout_ms/0`. A
lease that ends early anyway (sleep, clock jump) is the environment switch
`LeaseCanLapse`.

**A sender's life** (`ChannelSend.with_timeout`, `channel_send.ex:219-300`):
spawn, linked and monitored in one call (`:224`) → `flying` → `landed` (the
platform or gateway accepted) → resolved by its caller (`:ok`), or refused, or
killed by the watchdog (before or after landing). If its caller dies first, the
link kills a sender still `flying`; one that `landed` has already been seen.
With `SendsDieWithCaller` off, a flying sender instead becomes an orphan that
may still land (the code before the link).

**Origins** (`Origins`, the hand-off chosen by `hand_off_outcome`,
`manager.ex:1108-1113`):
- `chat`: a chat origin inside the chain cap. The outcome goes out as a
  continuation dispatch.
- `text`: a scheduled origin, a depth-capped chain, an owner halt, or no
  dispatcher configured, on a framework channel. The outcome goes out as one
  inline text.
- `client`: a client-owned (ACP) origin inside the chain cap. The outcome goes
  out as a continuation; if that fails, the row is dead-lettered with its named
  cause. The worker's text to it is refused inside its sender before anything
  is sent: `acp` has no `ChannelSend` adapter (`config/config.exs:117-125`,
  `channel_send.ex:312-321`).

A row the owner cancelled is an owner halt whatever its origin
(`not_continuable_reason/1`, `manager.ex:1134`): a framework origin gets the
inline text, and a client-owned one is dead-lettered as `:owner_halt` with no
send (`manager.ex:1186-1192`).

**Not modelled:**
- admission and its refusals, and the cloud rail;
- the owner's cancel of a tracked run, and `/stop`, and the rest of the
  client-owned "no continuation" arm. A client-owned row that is
  tracking-stopped or depth-capped, or has no dispatcher, is dead-lettered
  with no send at all (`manager.ex:1123-1128`, `:1134-1139`, `:1186-1192`).
  The cancel of an untracked row is modelled (`OwnerCancelUntracked`);
- the continuation depth cap itself, a pure per-row rule that ExUnit covers;
- `delivery_mode` `none` and `local`, which succeed with no channel send
  (`delivery.ex:108-110`);
- advisory notices and telemetry;
- the worker's backoff clock and its max-age rule, and the lease's length (see
  above);
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
- `ReconcileScanCanFail`: the restarted Manager's boot scan
  (`Ledger.active_runs`) returns an error. It is only logged
  (`manager.ex:1344-1349`, `:1439-1442`), so an active row stays active and
  untracked.
- `LeaseCanLapse`: the lease ends while the Manager is still inside its
  hand-off. A laptop sleep or a wall-clock jump mid-send moves the wall clock
  past `next_delivery_at` while BEAM timers pause.
- `OwnerCancels`: the owner cancels (`cancel_coding_run`) a run the Manager no
  longer tracks. An owner action gets no fairness.

**Mechanism switches** (`TRUE` is the real code; each is switched off by at
least one check):
- `CleanDownDropsOnly`: a `:normal` or `:shutdown` DOWN only drops the monitor
  (`manager.ex:1017`).
- `IgnoresUntrackedRun`: every way a terminalization ends calls `drop_run`
  (`manager.ex:1068`, `:1083`, `:1088`, `:1245-1261`), and a report or DOWN for
  a run no longer tracked is ignored (`:997-999`, `:1006-1012`, `:1015-1016`,
  `:1023-1024`). The spec's `tracked` variable is the Manager's `runs` and
  `run_monitors` entry. It is `TRUE` at start and `FALSE` after a crash, because
  the restarted Manager begins with empty maps (`manager.ex:1507-1508`).
- `GuardedTerminalUpdate`: the terminal UPDATE only matches an active row
  (`repo.ex:6329-6334`), and `:already_terminal` is dropped (`manager.ex:1040`,
  `:1079-1084`).
- `RestForOne`: a Manager crash also restarts the `RunSupervisor` and the
  `DeliveryWorker`, killing every live Run first (`supervisor.ex:38-44`).
- `ReconcilesAtBoot`: the restarted Manager finalizes active local rows as
  `interrupted` (`manager.ex:235-236`, `:1344-1354`).
- `CrashDownTerminalizes`: an abnormal DOWN terminalizes the row as
  `failed/run_crashed` (`manager.ex:1014-1027`).
- `MarksDelivered`: a successful hand-off marks the row `delivered`
  (`manager.ex:1143`, `:1148-1155`, `:1223`, `:1228-1238`).
- `ClientDeadLetters`: a failed client-owned dispatch dead-letters the row with
  its named cause (`manager.ex:1162-1168`, `:1196-1211`).
- `WorkerDrainsOutbox`: the worker selects terminal rows that are still pending
  (`delivery_worker.ex:101-123`, `repo.ex:6452-6464`).
- `DeadLetterCap`: the worker dead-letters a row at `MaxAttempts`
  (`delivery_worker.ex:129-141`).
- `LeasesFirstAttempt`: the terminal write leases the row to the Manager's
  inline first attempt (`manager.ex:1035-1047`, `:83-95`; see above).
- `SendsDieWithCaller`: a `with_timeout` sender is linked to its caller
  (`channel_send.ex:219-224`), so a caller that dies takes a sender still in
  flight with it.
- `CancelsStrandedRow`: an owner cancel of an active local row the Manager does
  not track terminalizes it `cancelled` (`cancel_untracked/3`,
  `manager.ex:977-992`). Off, it is the code before the fix:
  `terminal_cancel_reply/2` answered `:already_terminal` for any row it found.

## What holds

Check 01 switches on run and Manager crashes, failed sends, sends that time out
after acceptance, and a lease that lapses mid-hand-off. Under all of these:
- **Reconciliation only finalizes dead runs.** This rests on `RestForOne`
  (check 02).
- **Every run that ends gets a terminal row** (a proposed rule). This rests on
  `ReconcilesAtBoot` (check 03) and `CrashDownTerminalizes` (check 04).
- **The outbox ends delivered or dead-lettered.** This rests on
  `WorkerDrainsOutbox` (check 05) and `DeadLetterCap` (check 06), and on the
  lease ending, which is the clock (weak fairness on `LeaseEnds`).
- **No send outlives its caller** (`channel_send.ex:98-105`), apart from the
  few instructions between the watchdog's unlink and its kill, which are below
  the spec's step granularity (see Assumptions). This rests on
  `SendsDieWithCaller` (check 28): unlinked, a Manager crash mid-send orphans
  its sender.

**A run is terminalized once**, and its outcome is handed off once. This is
checked per layer because three layers each keep it on their own. Checks 07, 09
and 11 each run check 01's environment with only one layer on:
- 07: only the clean-DOWN filter;
- 09: only the runs-map lookup;
- 11: only the guarded UPDATE.

Each holds. Checks 08, 10 and 12 switch that last layer off too, and the run's
clean DOWN is terminalized a second time. The real code, with all three layers
on, was also run once by hand with this rule added to check 01, and it holds
(1,347 distinct states). The runner cannot carry it in check 01: no single
switch breaks it there. The guard's `:already_terminal` branch is never taken
with the other layers on. It is the backstop the moduledoc calls it
(`manager.ex:22`).

Check 13 runs the real timing with the lease, run crashes and failed sends, but
no accepted send timing out and no Manager crash (both notify twice by design,
see "Designed behaviour"):
- **The owner hears each outcome once** (a proposed rule). This rests on
  `MarksDelivered` (check 14).
- **No text follows a confirmed continuation.** This rests on `MarksDelivered`
  (check 15).
- **A client dead letter keeps its named cause.** This rests on
  `ClientDeadLetters` (check 16).

**The hand-off lease** (HARNESS-1, fixed). Checks 17, 18 and 19 are the three
races HARNESS-1 found, with nothing failing: a worker tick during the inline
text hand-off (17), during the continuation dispatch (18), and during a failing
client-owned dispatch (19). All three hold, and each rests on
`LeasesFirstAttempt` (checks 25, 26, 27: without the lease the worker races the
hand-off again). `NoTextAfterConfirmedContinuation` was also run once by hand
in check 01's environment with `LeaseCanLapse = FALSE`, and it holds under
Manager crashes and accepted-send timeouts too (737 distinct states); with a
lapsing lease it breaks, as witness 33 shows.

**The owner's cancel of a stranded row** (HARNESS-4, mitigated). Check 29 adds
failed terminal writes, failed boot scans and the owner cancelling to check
01's environment:
- **A cancel never answers `:already_terminal` for an active row**
  (`manager.ex:162-170`). This rests on `CancelsStrandedRow` (check 30).
- **Only a row whose Run is gone is cancelled that way.** The cancel reads only
  what the Manager can see (idle, run not tracked, row active), so this is
  checked rather than assumed. It rests on `RestForOne` (check 31): without it,
  a crash leaves a live, stale Run, a failed boot scan leaves its row untracked,
  and the owner's cancel finalizes the row of a run that is still executing.

The checks use `MaxAttempts = 2` and `MaxManagerCrashes = 1`. Every `holds`
check was also run once by hand with `MaxAttempts = 3` and
`MaxManagerCrashes = 2`, and all still hold:
- checks 01, 07, 09 and 11: 3,598 distinct states each;
- check 13: 132 distinct states;
- checks 17 and 18: 9 distinct states each; check 19: 13;
- check 29: 5,712 distinct states.

All three origins are in checks 01 to 16 and 29. The run count is fixed at one
(see above).

## Plan hypotheses

- **A freshly terminalized row is at once selectable by the worker:** confirmed
  on the code the spec was written against, and the cause of HARNESS-1. It is
  no longer true: the terminal UPDATE now writes the lease with the status.
  - `admit_attrs` writes neither `delivery_status` nor `next_delivery_at`
    (`manager.ex:395-425`), so the insert stores `'pending'` and `NULL`
    (`repo.ex:502-505`, `:6770-6772`).
  - The terminal UPDATE writes the status, the outcome's ledger fields,
    `completed_at` and, since the fix, `next_delivery_at` (`repo.ex:6322-6334`;
    the fields come from `manager.ex:1036`, `:1265-1308`).
  - The worker's query takes any non-active row that is `pending` with a
    `NULL` or past `next_delivery_at` (`repo.ex:6452-6464`).
- **A tick during the inline hand-off sends the outcome twice:** confirmed,
  then fixed. See HARNESS-1 (checks 17 and 25).
- **A tick during the hand-off sends a text on top of the continuation turn:**
  confirmed, then fixed. See HARNESS-1 (checks 18 and 26). A dispatch that was
  accepted but not confirmed is still followed by the text, by design: see
  HARNESS-2.
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
  outcome is a duplicate notification, and three code claims were broken.
- **Status:** fixed (d514e149). The terminal write leases
  the row to the Manager's inline first attempt.
- **Checks:** 17, 18 and 19 now hold; 25, 26 and 27 show each breaks without
  the lease (7, 8 and 7 states).
- **Counterexample (before the fix):**
  1. The Run reports.
  2. The Manager writes the terminal row, runs the write-back, and starts its
     inline hand-off.
  3. The worker's tick selects the same row, which is still `pending`, and
     starts its own send.
  4. Both sends land.

  The outcome depended on the origin:
  - Check 17 (text origin): the owner gets the same `[run <id>]` message twice.
  - Check 18 (chat origin): the owner gets the continuation turn and the text.
  - Check 19 (client-owned origin): the dispatch fails and the Manager
    dead-letters the row with its named cause. The worker's refused send to
    `acp` then fails, and `reschedule/5` overwrites `last_delivery_error` with
    `unsupported_delivery_platform`. The client-owned arm that dead-letters
    with no send was exposed the same way.
- **Code (before the fix):**
  - The terminal UPDATE left the row due for the worker (see the first plan
    hypothesis).
  - `post_terminal/5` then runs telemetry, the memory write-back (a second Repo
    call) and the inline hand-off (`manager.ex:1064-1069`). A text send can
    take up to 60 s (`delivery.ex:49`, `:280-293`), and a dispatch up to 15 s
    (`continuation.ex:54`, `:154-166`). Only then does the Manager mark the row
    (`manager.ex:1228-1238`).
  - Meanwhile `run_tick/1` selected the row (`delivery_worker.ex:101-108`), and
    `process_row/3` sends from that snapshot without re-reading the row
    (`:118-123`). Nothing claims the row between the select and the send.
  - Both sides mark the row with an unguarded `UPDATE ... WHERE id = ?`
    (`repo.ex:6363-6370`). `reschedule/5` writes `last_delivery_error` without
    checking `delivery_status` (`delivery_worker.ex:160-168`).
- **Fix:** `terminalize_and_notify/4` passes
  `next_delivery_at = now + @handoff_lease_ms` (120 s) to `Ledger.terminalize`,
  so the guarded UPDATE writes the status and the lease in one statement
  (`manager.ex:1035-1047`, `:83-95`). Every terminal write goes through it:
  report, crash DOWN, launch failure, scheduled blocks, cloud terminals,
  reconciliation and the owner's cancel of a stranded row. No Repo, schema or
  worker change. A successful hand-off marks the row delivered and a failed
  client-owned one dead-letters it, so the worker never sees either. A failed
  attempt or a Manager death leaves the row pending, and the worker takes it
  over when the lease ends: today's outcome, only later.
- **Cost:** after a failed inline attempt, the worker's first retry arrives at
  lease end (about 2 to 2.5 min) instead of within 30 s.
- **Tests:** `manager_test.exs`, describe "hand-off lease (HARNESS-1)": a tick
  during the text hand-off, the dispatch, and a failing client-owned dispatch
  (`delivery_attempts == 0`, the lease still set), and the budget invariant.
  "a failed dispatch leaves delivery pending so the worker delivers the text"
  now shows a real-clock tick sending nothing and a tick past the lease
  delivering.
- **Residual (by design):** a lease that lapses mid-hand-off (sleep, clock
  jump) still lets a tick race the resumed send; witness 33. The duplicate is
  the at-least-once notification every message's `[run <id>]` prefix exists
  for.

### HARNESS-4: a failed terminal write strands the run until the next restart
- **Severity:** low. It needs a SQLite write error. The outcome was silent and
  holds the run's locks.
- **Status:** mitigated (d514e149). The owner's cancel now
  recovers a stranded row; automatic recovery happens only at the next restart
  (accepted residual). Checks 23 and 32 stay `violated HARNESS-4`, because
  `EveryRunEndsTerminal` needs someone to act and an owner action gets no
  fairness: the owner may never cancel.
- **Checks:** 23 (a failed terminal write) and 32 (a failed boot scan after a
  Manager crash), both liveness violations whose lasso length is not pinned.
  Check 29 holds for the cancel itself.
- **Counterexample:**
  - Check 23: the Run reports; `Ledger.terminalize` returns an error; the
    Manager logs and drops the run, then ignores its `:normal` DOWN. The row
    stays active, and nothing runs for it unless the owner cancels.
  - Check 32: the Manager crashes and `:rest_for_one` kills the Run; the
    restarted Manager's boot scan returns an error and is only logged. The row
    stays active and untracked the same way.
- **Code:**
  - `after_terminalize_error/4` re-arms only a cloud run. A local run is dropped
    (`manager.ex:1049-1062`, `:1086-1089`, "has no live poll to re-arm and is
    dropped").
  - `reconcile/1` only logs a scan error (`manager.ex:1344-1349`,
    `:1439-1442`), and the restarted Manager tracks nothing.
  - The worker never selects an active row (`repo.ex:6460`).
  - Only the next Manager start with a working scan reconciles the row, as
    `interrupted` (`manager.ex:1351-1354`).
- **Impact before the fix:**
  - The owner was never told.
  - `list_coding_runs` showed the run as running, yet `cancel_coding_run` on it
    answered `{:error, :already_terminal}`: the run was no longer in `runs`, and
    `terminal_cancel_reply/2` treated any row it found as terminal. The owner
    could not cancel it.
  - Its workspace lock roots and capacity slot stay held, because admission
    counts active rows (`repo.ex:6224-6252`). Later runs in that worktree are
    refused `workspace_locked`.
- **Fix:** an owner cancel of a run absent from the runs map now reads the row
  (`cancel_untracked/3`, `manager.ex:977-992`). An active local row has no live
  Run: every live local run is tracked in the callback that launches it, and a
  restart sweeps the Runs first. So the Manager replies `:ok` first (the
  terminal write runs the inline hand-off, which can outlast the caller's 5 s
  call) and then terminalizes the row `cancelled` through
  `terminalize_and_notify/4`, so the lease applies, the locks and capacity slot
  are released, and `post_terminal` emits the missing `run_error` bookend. An
  untracked active cloud row answers `{:error, {:vendor_cancel_unsupported,
  task_url}}`, as a tracked one does; a terminal row answers
  `:already_terminal`; a read error is returned as itself, no longer mapped to
  `:not_found`.
- **Tests:** `manager_test.exs`, describe "cancel": a stranded local row is
  cancelled (`:ok`, row `cancelled`, the text delivered, `active_runs` empty);
  an untracked active cloud row answers `vendor_cancel_unsupported`.
- **Residual:** automatic recovery is still the next restart. A bounded retry
  of the failed terminal write was considered and not taken: the Repo already
  waits 5 s on a busy lock, so an error that surfaces is usually persistent.

## Designed behaviour

These were findings of the first pass. The code chooses them; the checks that
showed them are now `reachable` witnesses.

### HARNESS-2: a continuation the Manager could not confirm is followed by a text
- **Status:** accepted by design. Notification is at-least-once and execution
  at-most-once (design §23.2). The code's claim covers a CONFIRMED dispatch
  only (`manager.ex:1091-1103`), and that claim holds: check 18,
  `NoTextAfterConfirmedContinuation`.
- **Checks:** witnesses 20 and 21 (`Witness_TextAfterUnconfirmedTurn`).
- **Paths:**
  - Check 20: `Gateway.ingest` casts the continuation to the agent queue, and
    the 15 s watchdog kills the sender before it can report back. The Manager
    sees `{:error, :delivery_timeout}` and leaves the row `pending`; when the
    lease ends the worker sends the text. `Gateway.ingest` does nothing after
    its cast but emit telemetry and return (`gateway.ex:36-44`, `:455-468`), so
    the 15 s must elapse *before* the cast, and the kill must land in the few
    instructions between the cast and the sender's reply.
  - Check 21: the dispatch lands, and the Manager dies before it reads the
    answer. The row stays `pending`, and the restarted worker sends the text
    when the lease ends. With the sender now linked to its caller
    (`channel_send.ex:219-224`), a Manager that dies while its sender is still
    in flight takes the sender with it, so the turn lands only if the gateway
    cast already happened: the crash must fall between the cast and the
    Manager's `MgrResolve`.
- **Why by design:** `continuation.ex:148-152` says "a timeout/crash is an
  `{:error, _}` dispatch, so the row stays `pending` and the `DeliveryWorker`
  delivers the outcome as text"; the core behaviour doc says the caller "treats
  an expiry as a failed dispatch" (`continuation_dispatcher.ex:51-52` in core).
  Treating an unconfirmed dispatch as delivered would silently lose the outcome
  whenever the dispatch really failed before the gateway accepted it. The
  continuation, which executes work, is never re-dispatched: the worker only
  sends text.

### HARNESS-3: a Manager stop with a report still queued records the finished run as interrupted
- **Status:** accepted and documented (owner default: accept). The Manager
  moduledoc (`manager.ex:40-44`) says an interrupted local row may belong to a
  finished run whose report was lost in a restart, and that its result stays
  readable through `get_coding_run`.
- **Check:** witness 22 (`Witness_ReportLostOnRestart`).
- **Path:**
  1. The Run sends its report and exits `:normal`.
  2. The Manager dies before handling the report.
  3. The restarted Manager's reconciliation finds the row still active and
     terminalizes it `interrupted`.
- **Code:**
  - The report is only a message in the Manager's mailbox (`run.ex:634`,
    `manager.ex:285-286`), and the mailbox dies with the process.
  - `reconcile_row/2` finalizes every active local row as `interrupted`
    (`manager.ex:1351-1354`, `:1299-1301`).
  - The Manager blocks for up to 60 s in each inline hand-off, so reports can
    queue behind it.
  - Triggers: an orderly shutdown (a daemon restart or upgrade: the supervisor
    stops the DeliveryWorker, then the RunSupervisor, then the Manager, which
    does not trap exits), or a restart of any earlier child of the core
    `:rest_for_one` tree (`application.ex:188-259`), such as `Memory.Repo`,
    `MainAgent`, `JobScheduler` or the Temporal supervisors. Every trigger
    needs a report queued behind a busy Manager at that moment.
- **Impact:**
  - The owner's text reads "`[run <id>] interrupted`", with the completed result
    shown as if it were the vendor's error text, and a resume hint. The text is
    re-read from `result.txt` (`delivery.ex:359`, `:442-446`).
  - A chat continuation carries no result body. It closes with "This run ended
    without reporting a result ... check the working tree before redoing
    anything" (`continuation.ex:88`, `:219`), so the agent finds the finished
    changes before it redoes anything.
- **If the owner wants it closed:** make the report durable before it is sent.
  The Run writes its status and ledger fields to `<artifacts_dir>/terminal.json`
  before it sends its report, and `reconcile_row/2` terminalizes a local row
  from that file when it exists; an absent or malformed file still means
  `interrupted`. The spec would then split `RunReports` into a file write and a
  send, and `Witness_ReportLostOnRestart` would become a holds check.

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
  harness subtree. A sender still in flight dies with its caller. The one gap
  is below the spec's step granularity: a caller killed in the few instructions
  between the watchdog's unlink and its kill (`channel_send.ex:284-287`) leaves
  that sender unlinked. On a full daemon stop every sender dies with the VM.
- **The owner's cancel:** it is a `GenServer.call`, served only between
  callbacks and never before `handle_continue(:reconcile)` has run, so the spec
  lets it fire only when the Manager is idle.
