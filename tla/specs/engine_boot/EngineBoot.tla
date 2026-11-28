---------------------------- MODULE EngineBoot ----------------------------
(***************************************************************************)
(* One engine per home. A home is a directory: its database, its settings *)
(* and the daemon's control socket. Every rail of the engine settles, as   *)
(* it starts, the rows no worker of its own VM holds: a job run left       *)
(* running is failed, a reminder left delivering is reset, a coding run    *)
(* is ended interrupted, a meeting is failed, a phone call is settled and  *)
(* hung up. That is right only if the worker really is gone, and the       *)
(* sweeping boot can tell that only when no other engine serves the home.  *)
(* The daemon lock is that proof, and this spec checks that it is taken    *)
(* before anything it protects.                                            *)
(*                                                                         *)
(* The scene: two processes boot a tree on one home, in any order and any  *)
(* number of times within a bound. Each start is a daemon's (`fermix run`, *)
(* the app's engine, `mix fermix.dev`) or, where the check allows it, a    *)
(* command's that boots the tree in a process of its own (`fermix          *)
(* memory`, a supervised `fermix setup`). A serving engine takes work on   *)
(* each rail and settles it; an engine can die, or be stopped, with its    *)
(* work in flight.                                                         *)
(*                                                                         *)
(* What it describes:                                                      *)
(*  - FermixCore.Application: start_supervision_tree/0, which for a daemon *)
(*    boot takes the lock first (start_holding_home_lock/3,                *)
(*    take_home_lock/2) and only then runs start_tree/0: the role,         *)
(*    prepare_home/2 and the ownership marker (maybe_daemon_socket/0,      *)
(*    EngineOwner.record/0), which write the home, and                     *)
(*    supervision_children/3, whose order puts every rail before the       *)
(*    control socket and which starts the rails in a daemon's boot alone   *)
(*    (daemon_children/2: any other boot ends at MainAgent); stop/1,       *)
(*    which lets go of the lock.                                           *)
(*  - Fermix.CLI.Daemon.Lock: acquire/2 (the file beside the socket, held  *)
(*    in SQLite's exclusive mode), released when its process ends however  *)
(*    it ends.                                                             *)
(*  - Fermix.CLI.Daemon: init/1 binds the control socket, the last step of *)
(*    a daemon boot.                                                       *)
(*  - The rails' boot reconciliation, one step for all of them:            *)
(*    Jobs.Scheduler.init/1 (reconcile_active_runs/1),                     *)
(*    Temporal.Scheduler.init/1 (boot_sweep/1), Harness.Manager            *)
(*    (handle_continue :reconcile), Meetings.Sweep, PhoneCalls.Manager     *)
(*    (handle_continue :reconcile).                                        *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - what each rail's sweep writes and what its own spec proves about it  *)
(*    (job_runs, reminder_delivery, harness_delivery, open_loop_lifecycle, *)
(*    cue_inbox): each of those specs assumes the one engine this spec     *)
(*    proves, and models the sweep of a row whose worker is gone;          *)
(*  - the wait a starting daemon gives a reader of the lock file           *)
(*    (Lock.acquire/2's reader_wait_ms): a held lock is refused once the   *)
(*    wait is over, and a reader lets go within the wait;                  *)
(*  - a lock file that cannot be opened or written: the boot fails with    *)
(*    that reason before anything else, as a held one does;                *)
(*  - the tree-less command line (`fermix status`, `fermix stop`): it      *)
(*    boots nothing and reads the lock through Daemon.Client;              *)
(*  - a home's role (primary, device, candidate): every role's daemon      *)
(*    takes the same lock at the same step;                                *)
(*  - the timers a daemon's rails arm beside their sweeps (a due job       *)
(*    claimed and run): the sweep stands for both;                         *)
(*  - two homes: a lock is per home, and nothing here is shared between    *)
(*    homes.                                                               *)
(*                                                                         *)
(* One step = the lock's acquire, the home's preparation (prepare_home/2   *)
(* and the marker), the rails' start with their sweeps, the control        *)
(* socket's bind, one claim or settle of a row by a serving engine's       *)
(* worker, or the end of a process.                                        *)
(***************************************************************************)

\* SOURCE: apps/fermix_core/lib/fermix_core/application.ex#start_supervision_tree,start_holding_home_lock,take_home_lock,acquire_home_lock,start_holding,release_home_lock,start_tree,stop,supervision_children,every_boot_children,daemon_children,maybe_daemon_socket,daemon_boot? @ b94d874cc4e9
\* SOURCE: apps/fermix_core/lib/fermix/cli/daemon/lock.ex @ c68d18c190c1
\* SOURCE: apps/fermix_core/lib/fermix/cli/daemon.ex#init,bind,clear_stale_socket,terminate @ 851bd39720d1

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Boots,            \* the processes that boot a tree on the home, e.g. {b1, b2}
    Rails,            \* the rails that keep claimed rows, e.g. {calls, jobs}:
                      \* `jobs` stands for the jobs, reminder, coding-run and
                      \* meeting rails, which reconcile alike
    MaxStarts,        \* how many times each process starts (a bound)
    MaxClaims,        \* how many rows the engines take in all (a bound)
    \* Environment switches: what may happen.
    EnginesCanEnd,    \* a serving engine dies or is stopped; its work in
                      \* flight stays claimed in the database
    CommandsCanBoot,  \* a command boots the tree in its own process beside
                      \* a daemon (`fermix memory`, a supervised `fermix setup`)
    \* Mechanism switches: TRUE is the code.
    LockFirst,        \* a daemon boot takes the home's lock before it reads
                      \* or writes the home and before any child starts
                      \* (Application.start_holding_home_lock/3); FALSE takes it
                      \* where the control socket binds, after the home was
                      \* prepared and every rail swept
    SweepsAtBoot,     \* each rail settles, as it starts, the rows no worker
                      \* of its VM holds (Jobs.Scheduler.init/1 and the rest)
    SweepNeedsEngine  \* a command's tree starts no rail
                      \* (Application.supervision_children/3 ends a boot
                      \* that is not a daemon's at MainAgent); FALSE starts
                      \* every rail, each reconciling, in any tree boot

Kinds == {"daemon", "command"}
Pcs == {"off", "lock", "home", "rails", "socket", "serving", "command"}
Owners == Boots \cup {"none", "gone"}
Symm == Permutations(Boots)

VARIABLES
    \* the home's files
    lock,           \* who holds daemon.sock.lock: a boot, or "none"
    \* the database: one row of each rail
    row,            \* "idle", or "claimed" by a worker
    owner,          \* the boot whose worker holds the claim; "gone" once
                    \* that process ended with the claim standing; "none"
    \* each booting process
    kind,           \* this start is a daemon's or a command's
    pc,             \* where its boot is
    starts,         \* starts made
    wrote,          \* this start has written the home (prepare_home/2, the
                    \* ownership marker)
    \* bounds and history
    claims,         \* rows taken in all
    sweptLive,      \* per rail: a sweep settled a row a running engine's
                    \* worker held
    sweptGone,      \* a sweep settled a row whose engine had ended
    refusedDirty,   \* a refused daemon boot had written the home
    refusedBeside   \* a daemon boot was refused while an engine's work was
                    \* in flight

home_vars == <<lock, row, owner>>
boot_vars == <<kind, pc, starts, wrote>>
hist_vars == <<claims, sweptLive, sweptGone, refusedDirty, refusedBeside>>
vars == <<home_vars, boot_vars, hist_vars>>

TypeOK ==
    /\ lock \in Boots \cup {"none"}
    /\ row \in [Rails -> {"idle", "claimed"}] /\ owner \in [Rails -> Owners]
    /\ kind \in [Boots -> Kinds] /\ pc \in [Boots -> Pcs]
    /\ starts \in [Boots -> 0..MaxStarts] /\ wrote \in [Boots -> BOOLEAN]
    /\ claims \in 0..MaxClaims
    /\ sweptLive \in [Rails -> BOOLEAN] /\ sweptGone \in BOOLEAN
    /\ refusedDirty \in BOOLEAN /\ refusedBeside \in BOOLEAN

Init ==
    /\ lock = "none"
    /\ row = [r \in Rails |-> "idle"] /\ owner = [r \in Rails |-> "none"]
    /\ kind = [b \in Boots |-> "daemon"] /\ pc = [b \in Boots |-> "off"]
    /\ starts = [b \in Boots |-> 0] /\ wrote = [b \in Boots |-> FALSE]
    /\ claims = 0
    /\ sweptLive = [r \in Rails |-> FALSE] /\ sweptGone = FALSE
    /\ refusedDirty = FALSE /\ refusedBeside = FALSE

Goto(b, p) == pc' = [pc EXCEPT ![b] = p]

\* A running engine's worker holds the rail's row.
HeldLive(r) == row[r] = "claimed" /\ owner[r] \in Boots

-----------------------------------------------------------------------------
(* A boot: FermixCore.Application.start/2                                  *)

\* The process starts. A daemon boot goes to the lock first
\* (start_supervision_tree/0, start_holding_home_lock/3); a command's takes
\* none,
\* and neither does a daemon's when the lock is the socket's.
Start(b, k) ==
    /\ pc[b] = "off" /\ starts[b] < MaxStarts
    /\ k = "command" => CommandsCanBoot
    /\ kind' = [kind EXCEPT ![b] = k]
    /\ starts' = [starts EXCEPT ![b] = starts[b] + 1]
    /\ wrote' = [wrote EXCEPT ![b] = FALSE]
    /\ Goto(b, IF k = "daemon" /\ LockFirst THEN "lock" ELSE "home")
    /\ UNCHANGED <<home_vars, hist_vars>>

\* The boot is refused: nothing started stays up, and the process ends
\* ({:another_daemon_running, socket_path}).
Refused(b) ==
    /\ Goto(b, "off")
    /\ refusedDirty' = (refusedDirty \/ wrote[b])
    /\ refusedBeside' = (refusedBeside \/ \E r \in Rails : HeldLive(r))
    /\ UNCHANGED <<home_vars, kind, starts, wrote, claims, sweptLive, sweptGone>>

\* Lock.acquire/2, first: held by another process means this one starts
\* nothing.
TakeLockFirst(b) ==
    /\ pc[b] = "lock"
    /\ IF lock = "none"
          THEN /\ lock' = b /\ Goto(b, "home")
               /\ UNCHANGED <<row, owner, kind, starts, wrote, hist_vars>>
          ELSE Refused(b)

\* prepare_home/2 and, for a daemon, the ownership marker: the home is
\* written.
PrepareHome(b) ==
    /\ pc[b] = "home"
    /\ wrote' = [wrote EXCEPT ![b] = TRUE]
    /\ Goto(b, "rails")
    /\ UNCHANGED <<home_vars, kind, starts, hist_vars>>

\* Whether this boot reconciles the rail: a daemon's always does; a
\* command's starts no rail, so reconciles none.
Sweeps(b, r) ==
    /\ SweepsAtBoot
    /\ kind[b] = "daemon" \/ ~SweepNeedsEngine

\* The rows this boot's rails settle as they start: every claim, since a
\* VM that has just started holds none.
Swept(b) == {r \in Rails : Sweeps(b, r) /\ row[r] = "claimed"}

\* The rails start (supervision_children/3), each with its reconciliation;
\* a command's tree ends before them (daemon_children/2).
StartRails(b) ==
    /\ pc[b] = "rails"
    /\ Goto(b, IF kind[b] = "daemon" THEN "socket" ELSE "command")
    /\ row' = [r \in Rails |-> IF r \in Swept(b) THEN "idle" ELSE row[r]]
    /\ owner' = [r \in Rails |-> IF r \in Swept(b) THEN "none" ELSE owner[r]]
    /\ sweptLive' = [r \in Rails |-> sweptLive[r] \/ (r \in Swept(b) /\ owner[r] \in Boots)]
    /\ sweptGone' = (sweptGone \/ \E r \in Swept(b) : owner[r] = "gone")
    /\ UNCHANGED <<lock, kind, starts, wrote, claims, refusedDirty, refusedBeside>>

\* Fermix.CLI.Daemon.init/1: the control socket binds, the last step. With
\* the lock taken first there is nothing left to decide here; without, this
\* is where the lock is taken, and a held one tears the tree down.
BindSocket(b) ==
    /\ pc[b] = "socket"
    /\ IF LockFirst
          THEN /\ Goto(b, "serving")
               /\ UNCHANGED <<home_vars, kind, starts, wrote, hist_vars>>
          ELSE IF lock = "none"
                  THEN /\ lock' = b /\ Goto(b, "serving")
                       /\ UNCHANGED <<row, owner, kind, starts, wrote, hist_vars>>
                  ELSE Refused(b)

\* The command ran and its process halts.
CommandEnds(b) ==
    /\ pc[b] = "command"
    /\ Goto(b, "off")
    /\ UNCHANGED <<home_vars, kind, starts, wrote, hist_vars>>

-----------------------------------------------------------------------------
(* A serving engine and its work                                           *)

\* A rail takes a row for a worker of this VM.
Claim(b, r) ==
    /\ pc[b] = "serving" /\ row[r] = "idle" /\ claims < MaxClaims
    /\ row' = [row EXCEPT ![r] = "claimed"]
    /\ owner' = [owner EXCEPT ![r] = b]
    /\ claims' = claims + 1
    /\ UNCHANGED <<lock, boot_vars, sweptLive, sweptGone, refusedDirty, refusedBeside>>

\* The worker settles its own row. A row a sweep took from under it is no
\* longer its own, and its settle changes nothing.
Settle(b, r) ==
    /\ pc[b] = "serving" /\ row[r] = "claimed" /\ owner[r] = b
    /\ row' = [row EXCEPT ![r] = "idle"]
    /\ owner' = [owner EXCEPT ![r] = "none"]
    /\ UNCHANGED <<lock, boot_vars, hist_vars>>

\* The engine dies or is stopped (Application.stop/1 after an orderly
\* stop). Its workers end with it and its claims stay in the database; the
\* lock is let go of, by stop/1 or by the operating system.
EngineEnds(b) ==
    /\ EnginesCanEnd /\ pc[b] = "serving"
    /\ Goto(b, "off")
    /\ lock' = IF lock = b THEN "none" ELSE lock
    /\ owner' = [r \in Rails |-> IF owner[r] = b THEN "gone" ELSE owner[r]]
    /\ UNCHANGED <<row, kind, starts, wrote, hist_vars>>

-----------------------------------------------------------------------------

\* Every process made its starts and ended, or serves with nothing left to
\* take where engines never end.
Done ==
    \A b \in Boots :
        \/ pc[b] = "off" /\ starts[b] = MaxStarts
        \/ /\ pc[b] = "serving" /\ ~EnginesCanEnd /\ claims = MaxClaims
           /\ \A r \in Rails : owner[r] # b

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E b \in Boots :
          \/ \E k \in Kinds : Start(b, k)
          \/ TakeLockFirst(b) \/ PrepareHome(b) \/ StartRails(b) \/ BindSocket(b)
          \/ CommandEnds(b) \/ EngineEnds(b)
          \/ \E r \in Rails : Claim(b, r) \/ Settle(b, r)
    \/ Terminated

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* "Liveness is the signal, never age: the runner supervisor is the
\* authority on which runs still exist" (Jobs.Scheduler); "no worker
\* outlives the scheduler" (Temporal.Scheduler). The sweep's own VM is the
\* authority only while no other engine serves the home: no boot settles a
\* row a running engine's worker holds, a command's beside it included
\* ("Any other boot ... ends at `MainAgent`", Application).
OnlyGoneWorkIsSwept == \A r \in Rails : ~sweptLive[r]

\* "a second daemon that finds it held does not start" (Fermix.CLI.Daemon):
\* a refused boot leaves the home as it found it.
RefusedBootWritesNothing == ~refusedDirty

\* Why the sweeps exist: once an engine serves, every claim in the database
\* is one of its own workers', so a claim an ended engine left never
\* stands in the way of new work.
ServingEngineOwnsClaims ==
    \A b \in Boots, r \in Rails :
        pc[b] = "serving" /\ row[r] = "claimed" => owner[r] = b

\* Witnesses: each defined as "the scenario never happens".
Witness_RefusedBesideWork == ~refusedBeside
Witness_GoneWorkSwept == ~sweptGone
Witness_CommandBesideWork ==
    ~(\E b \in Boots, r \in Rails : pc[b] = "command" /\ HeldLive(r))

=============================================================================
