---------------------------- MODULE TurnQueue ----------------------------
(***************************************************************************)
(* FermixChannels.Gateway.Queue for ONE conversation: the FIFO of waiting *)
(* messages, the single active turn, the turn task's steps, /stop, a stop *)
(* that names one message (the companion socket's cancel), a               *)
(* crashing turn task, and the Queue process itself crashing and being     *)
(* restarted by its supervisor; and one consumer that waits on each        *)
(* message's result, Acp.Peer, with its watch on the Queue.                *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - the LLM and tools (one "loop" step), streaming drafts, typing;       *)
(*  - the empty-completion path (queue.ex:528-531, :693-702): it delivers *)
(*    a canned retry and commits nothing, leaving the user message        *)
(*    unanswered by design;                                                *)
(*  - the terminal_error_owner? branch (only who sends the error text);   *)
(*  - other conversations (independent: the Queue keys all state by       *)
(*    conversation);                                                       *)
(*  - consumers other than Acp.Peer: mobile's RequestCoordinator releases  *)
(*    a request on the Queue's :DOWN instead of answering it; the          *)
(*    companion socket's Companion.Turns answers it the Peer's way (a      *)
(*    turn_error, interrupted); voice watches no Queue.                    *)
(*                                                                         *)
(* One step = one indivisible thing in the code: one Queue callback, or   *)
(* one step of the turn task between two calls into another process.     *)
(***************************************************************************)
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue.ex @ cdbd6e010924
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/queue_supervisor.ex @ 6bd48b7f67a7
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/stopper.ex @ 3f42aedf7399
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/typing.ex#with_indicator,stop_typing_loop @ 4e91ea3d2f7d
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway/draft_stream.ex#start_link @ c185d3d497b1
\* SOURCE: apps/fermix_channels/lib/fermix_channels/application.ex @ 0ba02e5ff33f
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/acp/peer.ex#@moduledoc,handle_info,start_prompt,hand_off,watch_queue,ingest,handle_ingest,apply_turn_result,cancel_prompt_request,stop_turn,settle_queue_down,close_turn,demonitor_queue,apply_if_open @ 363eb316106b
\* SOURCE: apps/fermix_channels/lib/fermix_channels/channels/acp/session.ex#start_turn,clear_turn,turn_open?,put_queue_ref,queue_ref @ 46da0e632d47
\* SOURCE: apps/fermix_channels/lib/fermix_channels/gateway.ex#ingest,do_deliver_to_agent @ a988106fa5ca
\* SOURCE: apps/fermix_core/lib/fermix_core/agents/turn_runner.ex#run_message_loop,persist_user_message,commit @ 281df102b636
\* SOURCE: apps/fermix_core/lib/fermix_core/memory/conversation_store.ex @ 2664a9cfe3fe
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Msgs,               \* the user's messages, e.g. {m1, m2}
    None,               \* "no active turn"
    \* Environment switches: what may happen to the queue.
    UsersCanStop,       \* /stop (Stopper -> Queue.stop_all, stopper.ex:44) or a voice or
                        \* ACP cancel (Queue.stop_conversation); same per-conversation effect
    UsersCanStopTurn,   \* a stop that names one message (Queue.stop_turn, queue.ex:172): the
                        \* companion socket's cancel, which one of several clients sharing
                        \* the conversation sends at any moment, even after its turn ended
    Named,              \* the message a named stop names (one of Msgs)
    TasksCanCrash,      \* the turn task dies at any step: its own code raises or exits, or a
                        \* linked helper (typing loop, typing.ex:24; DraftStream,
                        \* draft_stream.ex:172) exits, which can land anywhere
    QueueCanCrash,      \* the Queue GenServer dies and its supervisor restarts it empty
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by exactly one kind of check to show a property needs it.
    OneClaimant,        \* the closure is handed to the claimant only and the Queue
                        \* clears its copy (queue.ex:237-246, :1090-1094)
    StartsWhenIdle,     \* a message starts only when no turn is active (queue.ex:304-312)
    CrashFiresOutcome,  \* a crashed turn's held closure fires {:failed, _} (queue.ex:877-885)
    TurnsShareQueueFate,    \* turn tasks run under a Task.Supervisor that QueueSupervisor
                            \* (:one_for_all) terminates before it restarts the Queue
                            \* (queue_supervisor.ex:46-51, application.ex:60)
    CrashClosesUserMessage, \* a crashed turn's DOWN writes the stopped marker before the
                            \* next message starts (queue.ex:836, :850-856)
    StopSparesClaimedTurn,  \* a stop leaves a turn that claimed its outcome running
                            \* (queue.ex:1048-1050)
    StopCancelsPending,     \* a stop fires {:cancelled} for every message it drops
                            \* (queue.ex:1068-1074)
    StopTurnSparesClaimedTurn, \* a named stop leaves the named turn running once it has
                               \* claimed its outcome (queue.ex:1005-1011)
    StopTurnNamesTurn,      \* a named stop ends the named message's turn only
                            \* (stop_named_in, queue.ex:1005-1042); FALSE is the
                            \* conversation stop, the only stop the Queue had before
    ConsumerFencesQueue,    \* the consumer monitors the Queue process it handed the
                            \* message to and answers it as failed on that Queue's
                            \* :DOWN (Acp.Peer: peer.ex:558-566, :181-183, :889-894)
    \* Timing idealisation. TRUE is the real code; FALSE forbids a crash in
    \* the gap between the task claiming the closure and invoking it
    \* (finish_turn, queue.ex:574-580). There invoke_turn_result catches
    \* whatever the closure raises, exits or throws (:896-911), so only a
    \* linked helper's exit can land in the gap. A check that sets it FALSE
    \* proves a property only for a Queue without that gap.
    CrashInClaimGap

VARIABLES
    unsent,     \* user: messages not sent yet
    pending,    \* Queue state: FIFO of waiting messages
    active,     \* Queue state: message whose turn the Queue thinks is running
    held,       \* Queue state: it still holds active's turn_result_fn
    claimed,    \* Queue state: active's turn has claimed its outcome (claimed?)
    finalSent,  \* Queue state: active's final_reply_delivered? flag
    restarting, \* QueueSupervisor: the Queue is dead and not yet restarted
    pc,         \* turn task (task-local): pc[m] is where m's task is
    holding,    \* turn task (task-local): the outcome m's task will invoke its
                \* claimed closure with, or "none" when it holds no closure
    outcomes,   \* channel-visible: turn results fired for m
    shown,      \* user-visible: what the user saw for m, "reply" and/or "error"
    history,    \* ConversationStore (SQLite): Seq of <<kind, msg>>
    dropped,    \* bookkeeping: messages discarded without a turn
    watch       \* consumer (Acp.Peer): watch[m] is "down" while the :DOWN of the
                \* Queue m was handed to waits in its mailbox, ahead of any
                \* result for m; "settled" once it answered m from that :DOWN

vars == <<unsent, pending, active, held, claimed, finalSent, restarting, pc, holding,
          outcomes, shown, history, dropped, watch>>

(* Turn-task states. "idle" = no task yet; "gone" = the process ended.      *)
(* checkout_failed: MainAgent checkout failed, error sent (queue.ex:450-454) *)
(* committed / errored: about to claim the closure                          *)
(* invoking: claimed; about to run the closure in the task (queue.ex:577)   *)
(* done: the closure ran; the task is about to exit, but its typing loop    *)
(*   (until with_indicator returns, queue.ex:409) and DraftStream are still *)
(*   linked to it                                                           *)
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
    /\ claimed \in BOOLEAN
    /\ finalSent \in BOOLEAN
    /\ restarting \in BOOLEAN
    /\ pc \in [Msgs -> TaskStates]
    /\ holding \in [Msgs -> {"none", "completed", "failed"}]
    /\ \A m \in Msgs : outcomes[m] \in Seq(Outcomes)
    /\ \A m \in Msgs : shown[m] \subseteq {"reply", "error"}
    /\ history \in Seq({"user", "assistant", "marker"} \X Msgs)
    /\ dropped \subseteq Msgs
    /\ watch \in [Msgs -> {"idle", "down", "settled"}]

\* Whoever may invoke turn_result_fn right now: the holder of the closure.
\* Without the OneClaimant mechanism anyone who asks invokes it.
MayFire == held \/ ~OneClaimant

\* A crash may hit m's task now: always, except inside the claim gap when
\* the timing idealisation forbids it.
Hittable(m) == pc[m] /= "invoking" \/ CrashInClaimGap

ASSUME Named \in Msgs

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

\* maybe_start_next_request/2 + start_pending_request (queue.ex:304, :329):
\* pop the FIFO head, start and monitor its task, release it. p is the
\* pending queue after this callback's own update.
StartNext(p, pcNow) ==
    /\ claimed' = FALSE
    /\ finalSent' = FALSE
    /\ IF p = <<>>
       THEN /\ active' = None /\ held' = FALSE
            /\ pending' = p /\ pc' = pcNow
       ELSE /\ active' = Head(p)
            /\ held' = TRUE
            /\ pending' = Tail(p)
            /\ pc' = [pcNow EXCEPT ![Head(p)] = "start"]

\* handle_call({:fresh?, ...}) (queue.ex:250): fresh iff m's task is active.
\* After a Queue restart the task's calls go to the dead pid, exit, and are
\* caught as "not fresh" (fresh?/1 catch, :661-665); the new Queue never
\* holds m.
Fresh(m) == active = m

-----------------------------------------------------------------------------
(* The user and the Queue process *)

\* handle_cast({:enqueue, msg}) (queue.ex:196): enqueue, start if idle.
\* A message sent while the Queue is restarting is lost: enqueue/2 casts to
\* the registered name (queue.ex:91-94), and a cast to an unregistered name
\* is dropped silently, with no outcome (QUEUE-8's class). The Peer is not
\* exposed: it resolves the name first and hands the prompt to that process
\* (hand_off, peer.ex:558-566), so a prompt that finds no Queue registered
\* is refused at once, and one handed to a Queue that dies gets that Queue's
\* :DOWN. Send is disabled while restarting only to keep the model small.
Send(m) ==
    /\ ~restarting
    /\ m \in unsent
    /\ unsent' = unsent \ {m}
    /\ IF active = None \/ ~StartsWhenIdle
       THEN StartNext(Append(pending, m), pc)
       ELSE /\ pending' = Append(pending, m)
            /\ UNCHANGED <<active, held, claimed, finalSent, pc>>
    /\ UNCHANGED <<restarting, holding, outcomes, shown, history, dropped, watch>>

\* Does a stop kill the active turn? One that has not claimed its outcome,
\* always; one that has, only without StopSparesClaimedTurn.
KillsActive == active /= None /\ (~claimed \/ ~StopSparesClaimedTurn)

\* stop_one_conversation/2 and stop_all_conversations/1 ->
\* stop_conversation_runtime/3 (queue.ex:221, :216, :968-994), one callback:
\* - stop_active_turn/3 (:1048-1064): a claimed turn is left running with its
\*   slot and monitor (:1048-1050); any other active turn is killed
\*   synchronously, fires {:cancelled} if the Queue still holds its closure,
\*   gets the stopped marker (mark_stopped_turn, :1108-1121), and the
\*   conversation is dropped. A task killed while it holds a claimed closure
\*   takes the closure with it.
\* - cancel_pending/1 (:1068-1074): every dropped message fires {:cancelled}.
\* A stop that would change nothing (a claimed turn and nothing waiting) is
\* not a step. The claim is a Queue callback too, so the Queue serialises it
\* against the stop: claimed is exact here.
\* A stop while no Queue is registered is not modelled: every caller's
\* GenServer.call exits :noproc. For Acp.Peer (stop_turn, peer.ex:671-675)
\* that ends the connection, and its open prompts get no answer (reported,
\* not fixed; check 17 does not cover that window).
StopConversation ==
    /\ pending /= <<>> \/ KillsActive
    /\ LET cancelled(x) ==
               \/ StopCancelsPending /\ x \in Range(pending)
               \/ KillsActive /\ x = active /\ MayFire
       IN outcomes' = [x \in Msgs |->
                         IF cancelled(x) THEN Append(outcomes[x], "cancelled") ELSE outcomes[x]]
    /\ dropped' = dropped \cup Range(pending)
    /\ pending' = <<>>
    /\ IF KillsActive
       THEN /\ pc' = [pc EXCEPT ![active] = "gone"]
            /\ holding' = [holding EXCEPT ![active] = "none"]
            /\ history' = AppendMarker(history)
            /\ active' = None
            /\ held' = FALSE
            /\ claimed' = FALSE
            /\ finalSent' = FALSE
       ELSE UNCHANGED <<pc, holding, history, active, held, claimed, finalSent>>
    /\ UNCHANGED <<unsent, shown, restarting, watch>>

Stop ==
    /\ UsersCanStop
    /\ ~restarting
    /\ StopConversation

\* Does a named stop kill the named turn? Only while it is the active turn and,
\* with StopTurnSparesClaimedTurn, has not claimed its outcome.
KillsNamed == active = Named /\ (~claimed \/ ~StopTurnSparesClaimedTurn)

\* Queue.stop_turn/3 -> handle_call({:stop_turn, ...}) -> stop_named_turn/3
\* (queue.ex:172, :226, :998-1042), one callback, naming the message Named:
\* - Named is active and has claimed its outcome: left running with its slot
\*   (:1005-1011).
\* - Named is active otherwise: killed synchronously, fires {:cancelled} if
\*   the Queue still holds its closure, gets the stopped marker, and the next
\*   waiting message starts in the same callback (:1015-1026). A task killed
\*   while it holds a claimed closure takes the closure with it.
\* - Named is waiting: dropped alone, with {:cancelled} (:1028-1042).
\* - Otherwise (it ended, or was never sent) nothing changes: not a step.
\* Without StopTurnNamesTurn the named stop is the conversation stop.
StopNamed ==
    \/ /\ KillsNamed
       /\ IF MayFire THEN Fire(Named, "cancelled") ELSE UNCHANGED outcomes
       /\ history' = AppendMarker(history)
       /\ holding' = [holding EXCEPT ![Named] = "none"]
       /\ StartNext(pending, [pc EXCEPT ![Named] = "gone"])
       /\ UNCHANGED <<unsent, shown, restarting, dropped, watch>>
    \/ /\ Named \in Range(pending)
       /\ Fire(Named, "cancelled")
       /\ pending' = SelectSeq(pending, LAMBDA x : x /= Named)
       /\ dropped' = dropped \cup {Named}
       /\ UNCHANGED <<unsent, active, held, claimed, finalSent, restarting, pc, holding,
                      shown, history, watch>>

StopTurn ==
    /\ UsersCanStopTurn
    /\ ~restarting
    /\ IF StopTurnNamesTurn THEN StopNamed ELSE StopConversation

\* The Queue GenServer dies with empty state. With TurnsShareQueueFate its
\* supervisor is QueueSupervisor (:one_for_all, queue_supervisor.ex:46-51):
\* before it restarts the Queue it terminates the turn-task supervisor
\* (QueueRestart). Until then the dead Queue's turns keep running and can
\* still deliver and commit; no new turn can start, because no Queue runs.
\* Without it the Queue restarts at once (a :one_for_one child) while its
\* turns, under a supervisor it is not linked to, keep running.
\* Every consumer watching this Queue gets its :DOWN now (ConsumerFencesQueue):
\* the Peer monitored the Queue process it handed each message to
\* (hand_off, peer.ex:558-566), so every message the dead Queue held, active
\* or waiting, has a :DOWN in the Peer's mailbox, except one whose result the
\* Peer already has: that result is ahead of the :DOWN, and answering it
\* closes the turn and flushes the :DOWN (close_turn, peer.ex:907-917).
QueueDown ==
    /\ QueueCanCrash
    /\ ~restarting
    /\ active /= None
    /\ restarting' = TurnsShareQueueFate
    /\ dropped' = dropped \cup Range(pending)
    /\ pending' = <<>>
    /\ active' = None
    /\ held' = FALSE
    /\ claimed' = FALSE
    /\ finalSent' = FALSE
    /\ watch' = [m \in Msgs |->
                   IF /\ ConsumerFencesQueue
                      /\ m \in {active} \cup Range(pending)
                      /\ outcomes[m] = <<>>
                   THEN "down" ELSE watch[m]]
    /\ UNCHANGED <<unsent, pc, holding, outcomes, shown, history>>

\* QueueSupervisor restarts its children (:one_for_all): Task.Supervisor
\* shutdown kills every turn task (they do not trap exits), then the task
\* supervisor and a fresh Queue start, in that order. A killed task takes
\* any closure it claimed with it, and nobody fires the outcomes of the
\* dead Queue's turns (QUEUE-8); the Peer answers them from the :DOWN
\* instead (PeerSettles).
QueueRestart ==
    /\ restarting
    /\ restarting' = FALSE
    /\ pc' = [m \in Msgs |-> IF pc[m] \in Alive THEN "gone" ELSE pc[m]]
    /\ holding' = [m \in Msgs |-> "none"]
    /\ UNCHANGED <<unsent, pending, active, held, claimed, finalSent, outcomes, shown,
                   history, dropped, watch>>

\* Acp.Peer handle_info({:DOWN, ...}) -> settle_queue_down (peer.ex:181-183,
\* :889-894): the :DOWN comes before any result for m in the mailbox, so the
\* Peer answers m as a failed turn through apply_turn_result and closes the
\* turn. (Mailbox order is taken to be send order; Erlang orders only each
\* sender's own messages, which changes who answers, not whether or how
\* often.) A result for m sent after this is dropped by the wire fence
\* (apply_if_open, peer.ex:712-718: the turn is closed), witness 17c.
PeerSettles(m) ==
    /\ watch[m] = "down"
    /\ watch' = [watch EXCEPT ![m] = "settled"]
    /\ UNCHANGED <<unsent, pending, active, held, claimed, finalSent, restarting, pc, holding,
                   outcomes, shown, history, dropped>>

-----------------------------------------------------------------------------
(* The turn task for message m *)

MoveTo(m, s) == pc' = [pc EXCEPT ![m] = s]
QueueUnchanged == UNCHANGED <<unsent, pending, active, held, claimed, finalSent,
                              restarting, dropped>>

\* MainAgent.checkout_turn_state fails (checkout_and_run, queue.ex:450-454):
\* deliver_checkout_error sends the error; no user message was persisted.
CheckoutFail(m) ==
    /\ pc[m] = "start"
    /\ MoveTo(m, "checkout_failed")
    /\ Show(m, "error")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* TurnRunner persist_user_message (turn_runner.ex:902), before AgentLoop.
PersistUser(m) ==
    /\ pc[m] = "start"
    /\ MoveTo(m, "loop")
    /\ history' = Append(history, <<"user", m>>)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* AgentLoop returned {:ok, ...}; deliver_response/3 asks fresh? (queue.ex:516).
\* Not fresh -> :stopped: no delivery, no commit, no claim (finish_turn :572).
LoopOk(m) ==
    /\ pc[m] = "loop"
    /\ MoveTo(m, IF Fresh(m) THEN "fresh" ELSE "done")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown, history>>

\* deliver_final/2 (queue.ex:534): the user now has the full reply.
Deliver(m) ==
    /\ pc[m] = "fresh"
    /\ MoveTo(m, "shown")
    /\ Show(m, "reply")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* mark_final_reply_delivered/1 -> handle_call({:final_reply_delivered, ...})
\* (queue.ex:535, :260): sets the flag only if m's task is still active.
MarkDelivered(m) ==
    /\ pc[m] = "shown"
    /\ MoveTo(m, "delivered")
    /\ finalSent' = IF active = m THEN TRUE ELSE finalSent
    /\ UNCHANGED <<unsent, pending, active, held, claimed, restarting, dropped, holding,
                   outcomes, shown, history>>

\* runner.commit/4 (queue.ex:538 -> turn_runner.ex:147): persist the reply,
\* then synchronous auto-compaction; the claim comes only after it returns.
\* An orphan that passed fresh? before its Queue died still commits here,
\* until QueueRestart kills it.
Commit(m) ==
    /\ pc[m] = "delivered"
    /\ MoveTo(m, "committed")
    /\ history' = Append(history, <<"assistant", m>>)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* AgentLoop returned {:error, ...}; deliver_turn_error/2 asks fresh? (queue.ex:555).
LoopErr(m) ==
    /\ pc[m] = "loop"
    /\ MoveTo(m, IF Fresh(m) THEN "err_fresh" ELSE "done")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown, history>>

\* turn.deliver.({:text, error_reply}) (queue.ex:558)
DeliverError(m) ==
    /\ pc[m] = "err_fresh"
    /\ MoveTo(m, "err_shown")
    /\ Show(m, "error")
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, history>>

\* append_marker(turn, @stopped_turn_marker) (queue.ex:561)
MarkFailed(m) ==
    /\ pc[m] = "err_shown"
    /\ MoveTo(m, "errored")
    /\ history' = AppendMarker(history)
    /\ QueueUnchanged /\ UNCHANGED <<holding, outcomes, shown>>

\* finish_turn/2 part 1 -> handle_call({:claim_turn_result, ...}) (queue.ex:574-577,
\* :237-246): the active turn gets its closure, and claim_active_turn (:1090-1094)
\* marks it claimed and clears the Queue's copy. A turn that is no longer
\* active, or a dead or restarted Queue (claim_turn_result's catch,
\* :582-586), gets nil.
Claim(m, from, outcome) ==
    /\ pc[m] = from
    /\ MoveTo(m, "invoking")
    /\ claimed' = IF active = m THEN TRUE ELSE claimed
    /\ IF active = m /\ MayFire
       THEN /\ holding' = [holding EXCEPT ![m] = outcome] /\ held' = FALSE
       ELSE UNCHANGED <<holding, held>>
    /\ UNCHANGED <<unsent, pending, active, finalSent, restarting, dropped, outcomes, shown,
                   history>>

\* finish_turn/2 part 2 -> invoke_turn_result/2 (queue.ex:577, :896-911), in the
\* task: run the claimed closure, if any. It catches whatever the closure
\* raises, exits or throws, so the closure itself cannot kill the task.
Invoke(m) ==
    /\ pc[m] = "invoking"
    /\ MoveTo(m, "done")
    /\ IF holding[m] = "none" THEN UNCHANGED outcomes ELSE Fire(m, holding[m])
    /\ holding' = [holding EXCEPT ![m] = "none"]
    /\ QueueUnchanged /\ UNCHANGED <<shown, history>>

\* The task exits :normal -> handle_info({:DOWN, ...}) (queue.ex:270) clears
\* the active slot and starts the next message. Only the Queue that
\* monitors the task hears it.
Exit(m) ==
    /\ pc[m] = "done"
    /\ LET pcNow == [pc EXCEPT ![m] = "gone"] IN
       IF active = m
       THEN StartNext(pending, pcNow)
       ELSE /\ pc' = pcNow /\ UNCHANGED <<active, held, claimed, finalSent, pending>>
    /\ UNCHANGED <<unsent, restarting, holding, outcomes, shown, history, dropped>>

\* The task dies -> abnormal DOWN -> clear_active_request/4 (queue.ex:821-843):
\* maybe_close_crashed_turn writes the stopped marker (:836, :850-856);
\* maybe_reply_on_crash sends the generic error unless the final reply was
\* marked delivered (:861); maybe_fail_turn_result fires {:failed, _} if
\* the Queue still holds the closure (:877-885). A closure the task had
\* already claimed dies with it. The next message starts in the same
\* callback, after the marker.
\* Where nothing in the task can raise, only a linked helper's exit kills
\* it: at "shown" (between deliver_final returning and the mark call),
\* at "invoking" (see CrashInClaimGap) and at "done" (after the closure
\* ran, before the typing loop is stopped and the task exits).
\* The two callbacks run in spawned processes (invoke_turn_result_async,
\* send_error_reply_async); they are folded into this step because no
\* property depends on their timing relative to the next turn.
Crash(m) ==
    /\ TasksCanCrash
    /\ pc[m] \in Alive
    /\ Hittable(m)
    /\ holding' = [holding EXCEPT ![m] = "none"]
    /\ LET pcNow == [pc EXCEPT ![m] = "gone"] IN
       IF active = m
       THEN /\ IF MayFire /\ CrashFiresOutcome THEN Fire(m, "failed") ELSE UNCHANGED outcomes
            /\ IF finalSent THEN UNCHANGED shown ELSE Show(m, "error")
            /\ history' = IF CrashClosesUserMessage THEN AppendMarker(history) ELSE history
            /\ StartNext(pending, pcNow)
       ELSE /\ pc' = pcNow
            /\ UNCHANGED <<active, held, claimed, finalSent, pending, outcomes, shown, history>>
    /\ UNCHANGED <<unsent, restarting, dropped, watch>>

\* No task step touches the Peer's state: its :DOWN handling is its own step.
TaskStep(m) ==
    /\ \/ CheckoutFail(m) \/ PersistUser(m) \/ LoopOk(m) \/ Deliver(m)
       \/ MarkDelivered(m) \/ Commit(m)
       \/ LoopErr(m) \/ DeliverError(m) \/ MarkFailed(m)
       \/ Claim(m, "committed", "completed") \/ Claim(m, "errored", "failed")
       \/ Claim(m, "checkout_failed", "failed")
       \/ Invoke(m) \/ Exit(m)
    /\ UNCHANGED watch

-----------------------------------------------------------------------------
Init ==
    /\ unsent = Msgs
    /\ pending = <<>>
    /\ active = None
    /\ held = FALSE
    /\ claimed = FALSE
    /\ finalSent = FALSE
    /\ restarting = FALSE
    /\ pc = [m \in Msgs |-> "idle"]
    /\ holding = [m \in Msgs |-> "none"]
    /\ outcomes = [m \in Msgs |-> <<>>]
    /\ shown = [m \in Msgs |-> {}]
    /\ history = <<>>
    /\ dropped = {}
    /\ watch = [m \in Msgs |-> "idle"]

\* The legitimate end: every message sent, the Queue running, no turn task
\* alive, nothing queued, no :DOWN left for the Peer. Deadlock checking is
\* on, so any other state where nothing can happen is reported as a wedge.
Done ==
    /\ unsent = {}
    /\ ~restarting
    /\ active = None
    /\ pending = <<>>
    /\ \A m \in Msgs : pc[m] \in {"idle", "gone"}
    /\ \A m \in Msgs : watch[m] /= "down"

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E m \in Msgs : Send(m) \/ TaskStep(m) \/ Crash(m) \/ PeerSettles(m)
    \/ Stop
    \/ StopTurn
    \/ QueueDown
    \/ QueueRestart
    \/ Terminated

\* A running turn task always makes progress, the Queue always handles its
\* DOWN, a supervisor always finishes a restart, and the Peer always handles
\* a :DOWN in its mailbox (all Fermix processes). The user, /stop, a named
\* stop and crashes get no fairness.
Fairness ==
    /\ \A m \in Msgs : WF_vars(TaskStep(m))
    /\ WF_vars(QueueRestart)
    /\ \A m \in Msgs : WF_vars(PeerSettles(m))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* queue.ex moduledoc: turn_result_fn is "invoked exactly once per turn";
\* claim handler (queue.ex:230-236). Safety half: never twice.
AtMostOneOutcome == \A m \in Msgs : Len(outcomes[m]) <= 1

\* Liveness half: every started turn eventually gets its one outcome.
EveryTurnGetsAnOutcome ==
    \A m \in Msgs : (pc[m] = "start") ~> (Len(outcomes[m]) = 1)

\* queue.ex:367: "a turn-result consumer must never be left waiting".
\* Read as: every message the user sent eventually gets an outcome, whether
\* or not its turn ever started.
EverySentMessageGetsAnOutcome ==
    \A m \in Msgs : (m \notin unsent) ~> (Len(outcomes[m]) = 1)

\* The ACP Queue fence (peer.ex moduledoc, "The Queue fence"): a prompt the
\* Peer handed to a Queue is answered even if that Queue dies. Read as: every
\* message sent is answered, by its result or by the Peer from the :DOWN.
\* The Peer answers the first of the two and the wire fence drops the other,
\* so it answers once (witness 17c shows both can arrive).
EverySentMessageIsAnswered ==
    \A m \in Msgs : (m \notin unsent) ~> (outcomes[m] /= <<>> \/ watch[m] = "settled")

\* Queue.stop_turn/3's doc: a stop that names one message never ends another.
\* Read as: no message but Named is ever cancelled (in checks where the
\* conversation stop is off).
OnlyNamedTurnCancelled ==
    \A m \in Msgs \ {Named} : \A i \in 1..Len(outcomes[m]) : outcomes[m][i] /= "cancelled"

\* queue.ex moduledoc: "Each conversation runs at most one active turn".
\* Read as: never two live turn tasks for one conversation.
SingleFlight == Cardinality({m \in Msgs : pc[m] \in Alive}) <= 1

\* TurnRunner.commit assumes the conversation is single-flight
\* (turn_runner.ex:129-135). Read as: no turn commits its reply while
\* another turn of the same conversation is starting or running its loop.
NoOrphanCommitBesideNewTurn ==
    ~(\E a, b \in Msgs :
        /\ a /= b
        /\ active = b /\ pc[b] \in {"start", "loop"}
        /\ pc[a] = "committed")

\* Proposed rule: a reply the user received stays in history, so the next
\* turn's model knows it already answered (the stopped marker says the
\* opposite: "stopped before I finished it").
DeliveredReplyIsInHistory ==
    \A m \in Msgs :
        ("reply" \in shown[m] /\ pc[m] = "gone") => InHistory(<<"assistant", m>>)

\* Proposed rule, rejected (QUEUE-3): a channel told {:cancelled} did not
\* already show the full reply. The ACP contract Fermix implements requires
\* the opposite: a prompt in flight when session/cancel arrives is answered
\* stopReason "cancelled".
CancelledMeansNotAnswered ==
    \A m \in Msgs :
        (outcomes[m] /= <<>> /\ outcomes[m][1] = "cancelled") => "reply" \notin shown[m]

\* queue.ex:549-553: a failed turn closes its user message with the marker
\* so a retry "must not reach a model with no record of what the failed turn
\* already did". Read as: when no turn task is alive, no user message is
\* left unanswered in history. (The empty-completion path, not modelled,
\* leaves one unanswered by design.)
NoDanglingUserMessage ==
    (\A m \in Msgs : pc[m] \in {"idle", "gone"}) => LastKind /= "user"

\* maybe_reply_on_crash (queue.ex:858-860): "If the final reply was already
\* delivered, do not send a second generic error".
NoErrorAfterReply == \A m \in Msgs : ~({"reply", "error"} \subseteq shown[m])

-----------------------------------------------------------------------------
(* WITNESSES: each is violated when its scenario is reachable. *)

\* The window the exactly-once claim exists for: the task is about to claim
\* while the Queue still holds the closure, so a stop or crash can race it.
Witness_ClaimRaceWindow ==
    ~(\E m \in Msgs : active = m /\ held /\ pc[m] \in {"committed", "errored", "checkout_failed"})

\* While QueueSupervisor restarts, a turn of the dead Queue that passed
\* fresh? can still commit its reply; no other turn runs then.
Witness_OrphanCommitsWhileRestarting ==
    ~(restarting /\ \E m \in Msgs : pc[m] = "committed")

\* A turn that claimed its result before its Queue died invokes it after the
\* Queue's :DOWN reached the Peer, so the Peer holds both for one prompt and
\* must answer only the first (the wire fence, apply_if_open).
Witness_ResultAfterQueueDown ==
    ~(\E m \in Msgs : watch[m] /= "idle" /\ outcomes[m] /= <<>>)

=============================================================================
