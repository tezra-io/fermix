---------------------------- MODULE TurnQueue ----------------------------
(***************************************************************************)
(* FermixChannels.Gateway.Queue for ONE conversation: the FIFO of waiting *)
(* messages, the single active turn, the turn task's steps, /stop, a       *)
(* crashing turn task, and the Queue process itself crashing and being     *)
(* restarted by its supervisor.                                            *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the LLM and tools (one "loop" step), streaming drafts, typing;       *)
(*  - the empty-completion path (queue.ex:477-480, :642-653): it delivers *)
(*    a canned retry and commits nothing, leaving the user message        *)
(*    unanswered by design;                                                *)
(*  - the terminal_error_owner? branch (only who sends the error text);   *)
(*  - other conversations (independent: the Queue keys all state by       *)
(*    conversation).                                                       *)
(*                                                                         *)
(* One step = one indivisible thing in the code: one Queue callback, or   *)
(* one step of the turn task between two calls into another process.     *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue.ex @ 07ca052f784e
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/stopper.ex @ f4d827ced500
\* SOURCE: apps/fermix_channels/lib/fermix_channels/application.ex @ 2a280adf80c6
\* SOURCE: apps/fermix_core/lib/fermix_core/agents/turn_runner.ex#run_message_loop,persist_user_message,commit @ 281df102b636
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/conversation_store.ex @ 2664a9cfe3fe
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Msgs,               \* the user's messages, e.g. {m1, m2}
    None,               \* "no active turn"
    \* Environment switches: what may happen to the queue.
    UsersCanStop,       \* /stop (Stopper -> Queue.stop_all, stopper.ex:42) or a voice or
                        \* ACP cancel (Queue.stop_conversation); same per-conversation effect
    TasksCanCrash,      \* the turn task raises, exits or throws at any step
    QueueCanCrash,      \* the Queue GenServer dies and is restarted empty
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by exactly one check to show a property needs it.
    OneClaimant,        \* the closure is handed to the first claimant only (queue.ex:181-194)
    StartsWhenIdle,     \* a message starts only when no turn is active (queue.ex:253-261)
    CrashFiresOutcome,  \* a crashed turn's held closure fires {:failed, _} (queue.ex:811-819)
    \* Timing idealisation. TRUE is the real code; FALSE forbids a /stop or a
    \* crash in the gap between the task claiming the closure and invoking it
    \* (finish_turn, queue.ex:523-529). A check that sets it FALSE proves a
    \* property only for a Queue that does not have this gap.
    StopOrCrashInClaimGap

VARIABLES
    unsent,     \* user: messages not sent yet
    pending,    \* Queue state: FIFO of waiting messages
    active,     \* Queue state: message whose turn the Queue thinks is running
    held,       \* Queue state: it still holds active's turn_result_fn
    finalSent,  \* Queue state: active's final_reply_delivered? flag
    pc,         \* turn task (task-local): pc[m] is where m's task is
    holding,    \* turn task (task-local): the outcome m's task will invoke its
                \* claimed closure with, or "none" when it holds no closure
    outcomes,   \* channel-visible: turn results fired for m
    shown,      \* user-visible: what the user saw for m, "reply" and/or "error"
    history,    \* ConversationStore (SQLite): Seq of <<kind, msg>>
    dropped     \* bookkeeping: messages discarded without a turn

vars == <<unsent, pending, active, held, finalSent, pc, holding, outcomes, shown, history, dropped>>

(* Turn-task states. "idle" = no task yet; "gone" = the process ended.      *)
(* checkout_failed: MainAgent checkout failed, error sent (queue.ex:399-404) *)
(* committed / errored: about to claim the closure                          *)
(* invoking: claimed; about to run the closure in the task (queue.ex:526)   *)
TaskStates == {"idle", "start", "loop", "fresh", "shown", "delivered", "committed",
               "err_fresh", "err_shown", "errored", "checkout_failed", "invoking",
               "done", "gone"}
Alive == TaskStates \ {"idle", "gone"}
Outcomes == {"completed", "failed", "cancelled"}

TypeOK ==
    /\ unsent \subseteq Msgs
    /\ pending \in Seq(Msgs)
    /\ active \in Msgs \cup {None}
    /\ held \in BOOLEAN
    /\ finalSent \in BOOLEAN
    /\ pc \in [Msgs -> TaskStates]
    /\ holding \in [Msgs -> {"none", "completed", "failed"}]
    /\ \A m \in Msgs : outcomes[m] \in Seq(Outcomes)
    /\ \A m \in Msgs : shown[m] \subseteq {"reply", "error"}
    /\ history \in Seq({"user", "assistant", "marker"} \X Msgs)
    /\ dropped \subseteq Msgs

\* Whoever may invoke turn_result_fn right now: the holder of the closure.
\* Without the OneClaimant mechanism anyone who asks invokes it.
MayFire == held \/ ~OneClaimant

\* A /stop or crash may hit m's task now: always, except inside the claim
\* gap when the timing idealisation forbids it.
Hittable(m) == pc[m] /= "invoking" \/ StopOrCrashInClaimGap

-----------------------------------------------------------------------------
Range(s) == {s[i] : i \in 1..Len(s)}
InHistory(e) == e \in Range(history)
LastKind == IF history = <<>> THEN "none" ELSE history[Len(history)][1]

\* ConversationStore handle_call({:append_stopped_marker, ...})
\* (conversation_store.ex:173): appends only when the last message is the user's.
AppendMarker(h) ==
    IF h /= <<>> /\ h[Len(h)][1] = "user"
    THEN Append(h, <<"marker", h[Len(h)][2]>>)
    ELSE h

Fire(m, outcome) == outcomes' = [outcomes EXCEPT ![m] = Append(@, outcome)]
Show(m, what)    == shown'    = [shown    EXCEPT ![m] = @ \cup {what}]

\* maybe_start_next_request/2 + start_pending_request (queue.ex:253, :278):
\* pop the FIFO head, start and monitor its task, release it. p is the
\* pending queue after this callback's own update.
StartNext(p, pcNow) ==
    IF p = <<>>
    THEN /\ active' = None /\ held' = FALSE /\ finalSent' = FALSE
         /\ pending' = p /\ pc' = pcNow
    ELSE /\ active' = Head(p)
         /\ held' = TRUE
         /\ finalSent' = FALSE
         /\ pending' = Tail(p)
         /\ pc' = [pcNow EXCEPT ![Head(p)] = "start"]

\* handle_call({:fresh?, ...}) (queue.ex:199): fresh iff m's task is active.
\* After a Queue restart the task's calls go to the dead pid, exit, and are
\* caught as "not fresh" (fresh?/1 catch); the new Queue never holds m.
Fresh(m) == active = m

-----------------------------------------------------------------------------
(* The user and the Queue process *)

\* handle_cast({:enqueue, msg}) (queue.ex:151): enqueue, start if idle.
Send(m) ==
    /\ m \in unsent
    /\ unsent' = unsent \ {m}
    /\ IF active = None \/ ~StartsWhenIdle
       THEN StartNext(Append(pending, m), pc)
       ELSE /\ pending' = Append(pending, m)
            /\ UNCHANGED <<active, held, finalSent, pc>>
    /\ UNCHANGED <<holding, outcomes, shown, history, dropped>>

\* stop_one_conversation/2 and stop_all_conversations/1 -> stop_conversation_runtime/3
\* (queue.ex:176, :896-930): kill the task synchronously, fire {:cancelled}
\* if the Queue still holds the closure, write the stopped marker
\* (mark_stopped_turn, :963-966), drop every pending message. A task killed
\* while it holds a claimed closure takes the closure with it.
\* (While a message is pending a turn is always active, so the guard's
\* second disjunct only matters with StartsWhenIdle off.)
Stop ==
    /\ UsersCanStop
    /\ active /= None \/ pending /= <<>>
    /\ active = None \/ Hittable(active)
    /\ IF active /= None
       THEN /\ pc' = [pc EXCEPT ![active] = "gone"]
            /\ holding' = [holding EXCEPT ![active] = "none"]
            /\ IF MayFire THEN Fire(active, "cancelled") ELSE UNCHANGED outcomes
            /\ history' = AppendMarker(history)
       ELSE UNCHANGED <<pc, holding, outcomes, history>>
    /\ dropped' = dropped \cup Range(pending)
    /\ pending' = <<>>
    /\ active' = None
    /\ held' = FALSE
    /\ finalSent' = FALSE
    /\ UNCHANGED <<unsent, shown>>

\* The Queue GenServer dies; FermixChannels.Supervisor (:one_for_one,
\* application.ex:66) restarts it with empty state. Turn tasks run under
\* FermixCore.TaskSupervisor (queue.ex:141, :295), not linked to the Queue,
\* so they keep running.
QueueCrash ==
    /\ QueueCanCrash
    /\ active /= None
    /\ dropped' = dropped \cup Range(pending)
    /\ pending' = <<>>
    /\ active' = None
    /\ held' = FALSE
    /\ finalSent' = FALSE
    /\ UNCHANGED <<unsent, pc, holding, outcomes, shown, history>>

-----------------------------------------------------------------------------
(* The turn task for message m *)

MoveTo(m, s) == pc' = [pc EXCEPT ![m] = s]
QueueUnchanged == UNCHANGED <<unsent, pending, active, held, finalSent, dropped>>

\* MainAgent.checkout_turn_state fails (checkout_and_run, queue.ex:399-404):
\* deliver_checkout_error sends the error; no user message was persisted.
CheckoutFail(m) ==
    /\ pc[m] = "start"
    /\ MoveTo(m, "checkout_failed")
    /\ Show(m, "error")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* TurnRunner persist_user_message (turn_runner.ex:831), before AgentLoop.
PersistUser(m) ==
    /\ pc[m] = "start"
    /\ MoveTo(m, "loop")
    /\ history' = Append(history, <<"user", m>>)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* AgentLoop returned {:ok, ...}; deliver_response/3 asks fresh? (queue.ex:458).
\* Not fresh -> :stopped: no delivery, no commit, no claim (finish_turn :521).
LoopOk(m) ==
    /\ pc[m] = "loop"
    /\ MoveTo(m, IF Fresh(m) THEN "fresh" ELSE "done")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown, history>>

\* deliver_final/2 (queue.ex:483): the user now has the full reply.
Deliver(m) ==
    /\ pc[m] = "fresh"
    /\ MoveTo(m, "shown")
    /\ Show(m, "reply")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* mark_final_reply_delivered/1 -> handle_call({:final_reply_delivered, ...})
\* (queue.ex:484, :209): sets the flag only if m's task is still active.
MarkDelivered(m) ==
    /\ pc[m] = "shown"
    /\ MoveTo(m, "delivered")
    /\ finalSent' = IF active = m THEN TRUE ELSE finalSent
    /\ UNCHANGED <<unsent, pending, active, held, dropped, holding, outcomes, shown, history>>

\* runner.commit/4 (queue.ex:487 -> turn_runner.ex:143): persist the reply,
\* then synchronous auto-compaction; the claim comes only after it returns.
\* An orphan that passed fresh? before a Queue restart still commits here.
Commit(m) ==
    /\ pc[m] = "delivered"
    /\ MoveTo(m, "committed")
    /\ history' = Append(history, <<"assistant", m>>)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* AgentLoop returned {:error, ...}; deliver_turn_error/2 asks fresh? (queue.ex:503).
LoopErr(m) ==
    /\ pc[m] = "loop"
    /\ MoveTo(m, IF Fresh(m) THEN "err_fresh" ELSE "done")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown, history>>

\* turn.deliver.({:text, error_reply}) (queue.ex:507)
DeliverError(m) ==
    /\ pc[m] = "err_fresh"
    /\ MoveTo(m, "err_shown")
    /\ Show(m, "error")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* append_marker(turn, @stopped_turn_marker) (queue.ex:510)
MarkFailed(m) ==
    /\ pc[m] = "err_shown"
    /\ MoveTo(m, "errored")
    /\ history' = AppendMarker(history)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* finish_turn/2 part 1 -> handle_call({:claim_turn_result, ...}) (queue.ex:523-526,
\* :186-194): the Queue hands the closure to its first claimant and clears its
\* own copy (clear_turn_result_fn, :189); a later claimant, or a dead or
\* restarted Queue (claim_turn_result's catch, :531-535), gets nil.
Claim(m, from, outcome) ==
    /\ pc[m] = from
    /\ MoveTo(m, "invoking")
    /\ IF active = m /\ MayFire
       THEN /\ holding' = [holding EXCEPT ![m] = outcome] /\ held' = FALSE
       ELSE UNCHANGED <<holding, held>>
    /\ UNCHANGED <<unsent, pending, active, finalSent, dropped, outcomes, shown, history>>

\* finish_turn/2 part 2 -> invoke_turn_result/2 (queue.ex:526, :829-837), in the
\* task: run the claimed closure, if any. It rescues exceptions only; an exit
\* or throw from the channel's closure crashes the task (a Crash step here).
Invoke(m) ==
    /\ pc[m] = "invoking"
    /\ MoveTo(m, "done")
    /\ IF holding[m] = "none" THEN UNCHANGED outcomes ELSE Fire(m, holding[m])
    /\ holding' = [holding EXCEPT ![m] = "none"]
    /\ QueueUnchanged /\ UNCHANGED <<shown, history>>

\* The task exits :normal -> handle_info({:DOWN, ...}) (queue.ex:219) clears
\* the active slot and starts the next message. Only the Queue that
\* monitors the task hears it.
Exit(m) ==
    /\ pc[m] = "done"
    /\ LET pcNow == [pc EXCEPT ![m] = "gone"] IN
       IF active = m
       THEN StartNext(pending, pcNow)
       ELSE /\ pc' = pcNow /\ UNCHANGED <<active, held, finalSent, pending>>
    /\ UNCHANGED <<unsent, holding, outcomes, shown, history, dropped>>

\* The task raises -> abnormal DOWN -> clear_active_request/4 (queue.ex:768):
\* maybe_fail_turn_result fires {:failed, _} if the Queue still holds the
\* closure (:811-819); maybe_reply_on_crash sends the generic error unless the
\* final reply was marked delivered (:795). No stopped marker is written.
\* A closure the task had already claimed dies with it.
\* Both callbacks run in spawned processes (invoke_turn_result_async,
\* send_error_reply_async); they are folded into this step because no
\* property depends on their timing relative to the next turn.
Crash(m) ==
    /\ TasksCanCrash
    /\ pc[m] \in Alive \ {"done"}
    /\ Hittable(m)
    /\ holding' = [holding EXCEPT ![m] = "none"]
    /\ LET pcNow == [pc EXCEPT ![m] = "gone"] IN
       IF active = m
       THEN /\ IF MayFire /\ CrashFiresOutcome THEN Fire(m, "failed") ELSE UNCHANGED outcomes
            /\ IF finalSent THEN UNCHANGED shown ELSE Show(m, "error")
            /\ StartNext(pending, pcNow)
       ELSE /\ pc' = pcNow
            /\ UNCHANGED <<active, held, finalSent, pending, outcomes, shown>>
    /\ UNCHANGED <<unsent, history, dropped>>

TaskStep(m) ==
    \/ CheckoutFail(m) \/ PersistUser(m) \/ LoopOk(m) \/ Deliver(m)
    \/ MarkDelivered(m) \/ Commit(m)
    \/ LoopErr(m) \/ DeliverError(m) \/ MarkFailed(m)
    \/ Claim(m, "committed", "completed") \/ Claim(m, "errored", "failed")
    \/ Claim(m, "checkout_failed", "failed")
    \/ Invoke(m) \/ Exit(m)

-----------------------------------------------------------------------------
Init ==
    /\ unsent = Msgs
    /\ pending = <<>>
    /\ active = None
    /\ held = FALSE
    /\ finalSent = FALSE
    /\ pc = [m \in Msgs |-> "idle"]
    /\ holding = [m \in Msgs |-> "none"]
    /\ outcomes = [m \in Msgs |-> <<>>]
    /\ shown = [m \in Msgs |-> {}]
    /\ history = <<>>
    /\ dropped = {}

\* The legitimate end: every message sent, no turn task alive, nothing
\* queued. Deadlock checking is on, so any other state where nothing can
\* happen is reported as a wedge.
Done ==
    /\ unsent = {}
    /\ active = None
    /\ pending = <<>>
    /\ \A m \in Msgs : pc[m] \in {"idle", "gone"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs : Send(m) \/ TaskStep(m) \/ Crash(m)
    \/ Stop
    \/ QueueCrash
    \/ Terminated

\* A running turn task always makes progress, and the Queue always handles
\* its DOWN (both Fermix processes). The user, /stop and crashes get no
\* fairness.
Fairness == \A m \in Msgs : WF_vars(TaskStep(m))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* queue.ex moduledoc: turn_result_fn is "invoked exactly once per turn";
\* claim handler (queue.ex:181-185): "The first claimant gets the closure;
\* every later one gets nil". Safety half: never twice.
AtMostOneOutcome == \A m \in Msgs : Len(outcomes[m]) <= 1

\* Liveness half: every started turn eventually gets its one outcome.
EveryTurnGetsAnOutcome ==
    \A m \in Msgs : (pc[m] = "start") ~> (Len(outcomes[m]) = 1)

\* queue.ex:315-316: "a turn-result consumer must never be left waiting".
\* Read as: every message the user sent eventually gets an outcome, whether
\* or not its turn ever started.
EverySentMessageGetsAnOutcome ==
    \A m \in Msgs : (m \notin unsent) ~> (Len(outcomes[m]) = 1)

\* queue.ex moduledoc: "Each conversation runs at most one active turn".
\* Read as: never two live turn tasks for one conversation.
SingleFlight == Cardinality({m \in Msgs : pc[m] \in Alive}) <= 1

\* Proposed rule: a reply the user received stays in history, so the next
\* turn's model knows it already answered (the stopped marker says the
\* opposite: "stopped before I finished it").
DeliveredReplyIsInHistory ==
    \A m \in Msgs :
        ("reply" \in shown[m] /\ pc[m] = "gone") => InHistory(<<"assistant", m>>)

\* Proposed rule: a channel told {:cancelled} did not already show the full reply.
CancelledMeansNotAnswered ==
    \A m \in Msgs :
        (outcomes[m] /= <<>> /\ outcomes[m][1] = "cancelled") => "reply" \notin shown[m]

\* queue.ex:498-502: a failed turn closes its user message with the marker
\* so a retry "must not reach a model with no record of what the failed turn
\* already did". Read as: when no turn task is alive, no user message is
\* left unanswered in history. (The empty-completion path, not modelled,
\* leaves one unanswered by design.)
NoDanglingUserMessage ==
    (\A m \in Msgs : pc[m] \in {"idle", "gone"}) => LastKind /= "user"

\* maybe_reply_on_crash (queue.ex:792-794): "If the final reply was already
\* delivered, do not send a second generic error".
NoErrorAfterReply == \A m \in Msgs : ~({"reply", "error"} \subseteq shown[m])

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The window the exactly-once claim exists for: the task is about to claim
\* while the Queue still holds the closure, so a stop or crash can race it.
Witness_ClaimRaceWindow ==
    ~(\E m \in Msgs : active = m /\ held /\ pc[m] \in {"committed", "errored", "checkout_failed"})

\* After a Queue restart, an orphan that already passed fresh? commits its
\* reply while the new Queue runs another turn for the same conversation.
Witness_OrphanCommitsBesideNewTurn ==
    ~(\E a, b \in Msgs :
        /\ a /= b
        /\ active = b /\ pc[b] \in {"start", "loop"}
        /\ pc[a] = "committed")

=============================================================================
