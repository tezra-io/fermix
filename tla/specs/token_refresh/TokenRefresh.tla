---------------------------- MODULE TokenRefresh ----------------------------
(***************************************************************************)
(* OAuth refresh-token rotation and ~/.fermix/auth.json.                   *)
(*                                                                         *)
(* Modelled:                                                               *)
(*  - one TokenManager GenServer per auth profile in the daemon. The Codex *)
(*    profile's is the top-level TokenManager; every other profile's is a  *)
(*    child under TokenSupervisor. Both run the same do_refresh.           *)
(*  - a refresher outside the manager: a tree-less CLI VM refreshing one   *)
(*    profile directly (TokenSupervisor.direct_refresh, CodexToken).       *)
(*  - per profile, a provider that rotates the refresh token on every      *)
(*    refresh and revokes the session when a consumed one comes back (the  *)
(*    Codex rule in the latest_entry comment).                             *)
(*  - auth.json as one map. Store.write reads the file, then replaces it   *)
(*    by an atomic tmp+rename, so a write is never torn: the rename puts   *)
(*    back the whole map the read returned, with one entry replaced.       *)
(*  - after a 4xx, the status write of a profile other than Codex: it      *)
(*    writes back the entry read when the refresh began.                   *)
(*  - a response lost after the provider rotated, retried by RefreshClient *)
(*    with the same refresh token.                                         *)
(*  - a logout that deletes the entry, then stops the profile's manager    *)
(*    (plugin logout) or forgets its tokens (provider sign-out).           *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - access tokens and expiry. Every trigger of a refresh (the proactive  *)
(*    timer, get_token when due, a reactive 401) runs the same do_refresh, *)
(*    so a refresh simply may start.                                       *)
(*  - a refused sign-in client (mark_client_rejected), xAI's 403 (no       *)
(*    write), sign-in writes and reloads: more Store.writes of one shape.  *)
(*  - a transport error before the provider acts: the retry is harmless.   *)
(*  - a daemon crash or a manager restart between the provider's rotation  *)
(*    and the rename: it loses the rotation the way a lost response does.  *)
(*  - disk write errors, callers' GenServer.call timeouts (the callback    *)
(*    runs to its end regardless), the token-file projection, and a        *)
(*    stopped manager restarted by ensure_child (it re-reads auth.json).   *)
(*                                                                         *)
(* One step = one indivisible thing in the code: a file read, a file       *)
(* rename, one provider-side effect, or one GenServer callback that does   *)
(* no I/O. Steps of one refresh run in the refresher's own process.        *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_manager.ex @ 5749c02a3da4
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_supervisor.ex @ 0ece6fabe600
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/store.ex @ e426debb9442
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/refresh_client.ex @ f427a1ce7477
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/codex_token.ex @ ce4857b05d39
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_expiry.ex @ 8373575105e9
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/codex_import.ex @ f9d19c24d0b9
\* SOURCE: apps/fermix_core/lib/fermix_core/plugins/auth.ex @ a43a83378675
\* SOURCE: apps/fermix_core/lib/fermix_core/management/auth.ex @ fbbf85bec2b2
\* SOURCE: apps/fermix_core/lib/fermix_core/tools/media/backends/codex_image.ex @ ea4175294f01
\* SOURCE: apps/fermix_core/lib/fermix/cli/plugins_command.ex @ e53642170f73
\* SOURCE: apps/fermix_core/lib/fermix/cli/auth_command.ex @ e129adea0e61
EXTENDS Naturals, FiniteSets

CONSTANTS
    Profiles,           \* OAuth auth profiles in auth.json, e.g. {p1, p2}
    CodexProfiles,      \* the Codex profile, if modelled: no status write after a 4xx
    CliProfile,         \* the profile the CLI VM refreshes
    LogoutProfile,      \* the profile the user logs out of
    None,               \* "no token" / "no entry"
    MaxAttempts,        \* RefreshClient @max_attempts (refresh_client.ex:17), 3 in the code
    Rounds,             \* bound: how many refreshes each refresher may start
    \* Environment switches: what may happen.
    CliRefreshes,           \* a tree-less CLI VM refreshes CliProfile directly
    RefreshesCanOverlap,    \* one process's refresh or logout can be in flight while another's is
    ResponseCanBeLost,      \* the provider rotates, then its response never arrives
    UserCanLogout,          \* the user logs out of LogoutProfile
    LogoutFromCli,          \* that logout runs in a tree-less CLI VM
    SignOutForgets,         \* that logout is the provider sign-out (forget), not the plugin logout (stop)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by exactly one check to show a property needs it.
    ReadsDiskBeforeRefresh, \* latest_entry re-reads auth.json before each refresh (token_manager.ex:418-422)
    OneCallbackPerManager,  \* one process per profile, one callback at a time (see "Who refreshes")
    MergesOnWrite,          \* Store.write re-reads the file and replaces only its own entry (store.ex:77-78, :356-381)
    LogoutReachesManager    \* logout stops or forgets the live manager (plugins/auth.ex:72, management/auth.ex:138)

ASSUME /\ CodexProfiles \subseteq Profiles
       /\ CliProfile \in Profiles /\ LogoutProfile \in Profiles
       /\ MaxAttempts \in Nat \ {0} /\ Rounds \in Nat
       /\ \A s \in {CliRefreshes, RefreshesCanOverlap, ResponseCanBeLost, UserCanLogout,
                    LogoutFromCli, SignOutForgets, ReadsDiskBeforeRefresh,
                    OneCallbackPerManager, MergesOnWrite, LogoutReachesManager} : s \in BOOLEAN

(* A refresh token is its generation number: the provider issues 0 at      *)
(* sign-in and n+1 when n is refreshed. Every token below the newest one   *)
(* is consumed.                                                            *)
Tok == Nat \cup {None}

(* Who refreshes. <<"mgr", p, l>> is the manager of profile p;             *)
(* <<"cli", CliProfile, 1>> is the CLI VM.                                 *)
(* A profile has one manager process: TokenSupervisor registers children   *)
(* in a Registry with keys: :unique (token_supervisor.ex:173) and answers  *)
(* {:already_started, _} with the running one (:221); the Codex manager is *)
(* registered under the module name (token_manager.ex:36-37). Its mailbox  *)
(* runs one callback at a time, so concurrent callers of one profile       *)
(* queue. Lane 2 is a second process refreshing the same profile beside    *)
(* the manager, possible only with OneCallbackPerManager off. It stands    *)
(* for those concurrent callers, so RefreshesCanOverlap does not restrain  *)
(* it.                                                                     *)
Lanes == {1, 2}
Actors == {<<"mgr", p, l>> : p \in Profiles, l \in Lanes} \cup {<<"cli", CliProfile, 1>>}
IsMgr(a) == a[1] = "mgr"
Prof(a) == a[2]
Proc(a) == <<a[1], a[2]>>       \* the manager's callers, as one process

EmptyDoc == [q \in Profiles |-> None]

VARIABLES
    disk,       \* file on disk: auth.json, disk[p] = the refresh token stored for p, or None
    issued,     \* provider-side: issued[p] = the newest refresh token, the only one it accepts
    revoked,    \* provider-side: p's session was revoked because a consumed token came back
    mgr,        \* daemon: p's manager. "serving": alive, state.refusal nil (GenServer state);
                \*   "refused": alive, state.refusal set (GenServer state); "stopped":
                \*   terminated by the DynamicSupervisor and gone from TokenRegistry
    mem,        \* GenServer state: mem[p] = the manager's state.refresh_token
    pc,         \* process-local: pc[a] = where refresher a is
    tok,        \* process-local: the refresh token a's refresh presents
    got,        \* process-local: the rotated token a received
    tries,      \* process-local: RefreshClient's attempt number
    buf,        \* process-local: the auth.json map a's Store.write read (read_for_write)
    rounds,     \* bound: refreshes a has started
    lpc,        \* process-local: the logout caller: "idle", "read", "deleted", "done"
    lbuf,       \* process-local: the auth.json map the logout read (read_existing)
    best        \* history: the newest refresh token ever written to disk for p

vars == <<disk, issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, lpc, lbuf, best>>

PcStates == {"idle", "send", "write", "rename", "reject_write", "reject_rename"}

TypeOK ==
    /\ disk \in [Profiles -> Tok]
    /\ issued \in [Profiles -> Nat]
    /\ revoked \in [Profiles -> BOOLEAN]
    /\ mgr \in [Profiles -> {"serving", "refused", "stopped"}]
    /\ mem \in [Profiles -> Tok]
    /\ pc \in [Actors -> PcStates]
    /\ tok \in [Actors -> Tok]
    /\ got \in [Actors -> Tok]
    /\ tries \in [Actors -> 0..MaxAttempts]
    /\ \A a \in Actors : buf[a] \in [Profiles -> Tok]
    /\ rounds \in [Actors -> 0..Rounds]
    /\ lpc \in {"idle", "read", "deleted", "done"}
    /\ lbuf \in [Profiles -> Tok]
    /\ best \in [Profiles -> Nat]

Max(x, y) == IF x > y THEN x ELSE y

-----------------------------------------------------------------------------
(* Who may start. With RefreshesCanOverlap off, a process starts a refresh *)
(* or a logout only when no other process has one in flight. No code makes *)
(* that true; it is the sequential baseline the findings are measured      *)
(* against.                                                                *)

InFlight(a) == pc[a] /= "idle"
LogoutInFlight == lpc \in {"read", "deleted"}

QuietForRefresh(a) ==
    \/ RefreshesCanOverlap
    \/ /\ ~LogoutInFlight
       /\ \A b \in Actors : Proc(b) /= Proc(a) => ~InFlight(b)

QuietForLogout == RefreshesCanOverlap \/ \A b \in Actors : ~InFlight(b)

\* The refresher's process-local state returns to "nothing in flight".
Reset(a) ==
    /\ pc' = [pc EXCEPT ![a] = "idle"]
    /\ tok' = [tok EXCEPT ![a] = None]
    /\ got' = [got EXCEPT ![a] = None]
    /\ tries' = [tries EXCEPT ![a] = 0]
    /\ buf' = [buf EXCEPT ![a] = EmptyDoc]

-----------------------------------------------------------------------------
(* Starting a refresh *)

\* A manager callback runs do_refresh (token_manager.ex:289-323): from
\* handle_call(:refresh) (:198), handle_call(:get_token) when due (:171) or
\* handle_info(:proactive_refresh) (:264). A manager with state.refusal set
\* never refreshes (:194, :259); one with no refresh token neither (:289).
\* latest_entry (:418-422) reads auth.json and, when the entry is there,
\* refreshes with the stored token; when the read fails it falls back to the
\* in-memory entry (entry_from_state, :421, :425-442).
MgrStart(a) ==
    /\ IsMgr(a)
    /\ pc[a] = "idle"
    /\ rounds[a] < Rounds
    /\ mgr[Prof(a)] = "serving"
    /\ mem[Prof(a)] /= None
    /\ a[3] = 1 \/ ~OneCallbackPerManager
    /\ QuietForRefresh(a)
    /\ tok' = [tok EXCEPT ![a] =
                 IF ReadsDiskBeforeRefresh /\ disk[Prof(a)] /= None
                 THEN disk[Prof(a)] ELSE mem[Prof(a)]]
    /\ pc' = [pc EXCEPT ![a] = "send"]
    /\ tries' = [tries EXCEPT ![a] = 1]
    /\ rounds' = [rounds EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, got, buf, lpc, lbuf, best>>

\* A tree-less CLI VM: TokenManager.refresh(profile) -> TokenSupervisor
\* call_or_read finds no supervisor (token_supervisor.ex:180-183, :197,
\* :208) -> direct_refresh: Store.read, then refresh_entry (:271-276).
\* CodexToken.get_token does the same for Codex (codex_token.ex:14-23,
\* :80-102). A missing entry fails the read and nothing is refreshed.
\* The daemon's Codex image backend calls CodexToken.get_token from a tool
\* process too (tools/media/backends/codex_image.ex:279), so inside the
\* daemon it is a second refresher of this shape.
CliStart(a) ==
    /\ ~IsMgr(a)
    /\ CliRefreshes
    /\ pc[a] = "idle"
    /\ rounds[a] < Rounds
    /\ disk[Prof(a)] /= None
    /\ QuietForRefresh(a)
    /\ tok' = [tok EXCEPT ![a] = disk[Prof(a)]]
    /\ pc' = [pc EXCEPT ![a] = "send"]
    /\ tries' = [tries EXCEPT ![a] = 1]
    /\ rounds' = [rounds EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, got, buf, lpc, lbuf, best>>

-----------------------------------------------------------------------------
(* The refresh request: one provider-side effect each. RefreshClient.refresh *)
(* posts the refresh token (refresh_client.ex:37-79 for Codex, :81-139 for   *)
(* the others). The provider accepts only its newest token.                  *)

Valid(a) == ~revoked[Prof(a)] /\ tok[a] = issued[Prof(a)]

\* 200: the provider rotates and the new pair arrives (refresh_client.ex:54,
\* :117). refresh_entry goes on to Store.write.
SendOk(a) ==
    /\ pc[a] = "send"
    /\ Valid(a)
    /\ issued' = [issued EXCEPT ![Prof(a)] = @ + 1]
    /\ got' = [got EXCEPT ![a] = issued[Prof(a)] + 1]
    /\ pc' = [pc EXCEPT ![a] = "write"]
    /\ UNCHANGED <<disk, revoked, mgr, mem, tok, tries, buf, rounds, lpc, lbuf, best>>

\* The provider rotates, but the response is lost: Req's receive timeout, a
\* closed connection, or a 5xx after the rotation. RefreshClient cannot tell
\* and retries with the SAME refresh token (refresh_client.ex:63-66, :71-74;
\* :123-126, :131-134). After the last attempt the refresh fails with no
\* state change (token_manager.ex:320-321).
SendLost(a) ==
    /\ ResponseCanBeLost
    /\ pc[a] = "send"
    /\ Valid(a)
    /\ issued' = [issued EXCEPT ![Prof(a)] = @ + 1]
    /\ IF tries[a] < MaxAttempts
       THEN /\ tries' = [tries EXCEPT ![a] = @ + 1]
            /\ UNCHANGED <<pc, tok, got, buf>>
       ELSE Reset(a)
    /\ UNCHANGED <<disk, revoked, mgr, mem, rounds, lpc, lbuf, best>>

\* A consumed token, or any token of a revoked session: 4xx, returned as
\* {:permanent, status, body} (refresh_client.ex:60-61, :120-121). A
\* consumed token revokes the whole session (Codex rule,
\* token_manager.ex:414-417). The manager refuses from now on (refuse/2,
\* :311-318, :349). For Codex nothing is written (:531-532; the CLI's
\* CodexToken.refresh_entry returns the error, codex_token.ex:99-100). Any
\* other profile goes on to mark_reauthorization_required, a Store.write of
\* the entry read when this refresh began (token_manager.ex:294, :317,
\* :534-536; token_supervisor.ex:298-299, :322-323, :353-354, :376-379).
SendRejected(a) ==
    /\ pc[a] = "send"
    /\ ~Valid(a)
    /\ revoked' = [revoked EXCEPT ![Prof(a)] = TRUE]
    /\ mgr' = IF IsMgr(a) /\ mgr[Prof(a)] = "serving"
              THEN [mgr EXCEPT ![Prof(a)] = "refused"] ELSE mgr
    /\ IF Prof(a) \in CodexProfiles
       THEN Reset(a)
       ELSE /\ pc' = [pc EXCEPT ![a] = "reject_write"]
            /\ UNCHANGED <<tok, got, tries, buf>>
    /\ UNCHANGED <<disk, issued, mem, rounds, lpc, lbuf, best>>

-----------------------------------------------------------------------------
(* Persisting: Store.write (store.ex:74-82), two steps each. *)

\* read_for_write (store.ex:77, :282-293) reads the whole file. Without
\* MergesOnWrite the writer would start from an empty document instead.
ReadForWrite(a) == IF MergesOnWrite THEN disk ELSE EmptyDoc

WriteRead(a) ==
    /\ pc[a] = "write"
    /\ buf' = [buf EXCEPT ![a] = ReadForWrite(a)]
    /\ pc' = [pc EXCEPT ![a] = "rename"]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, tok, got, tries, rounds, lpc, lbuf, best>>

\* put_provider + atomic_write (store.ex:78-79, :356-381, :420-435): the map
\* read above, with this profile's entry replaced (or created: put_provider
\* merges into Map.get(providers, key, %{}), :359), renamed over auth.json.
\* A manager then applies the entry in memory (apply_entry,
\* token_manager.ex:298, :325-342). mgr is left alone: a refresh only runs
\* while the manager is serving (:194, :259).
Rename(a) ==
    /\ pc[a] = "rename"
    /\ disk' = [buf[a] EXCEPT ![Prof(a)] = got[a]]
    /\ best' = [best EXCEPT ![Prof(a)] = Max(@, got[a])]
    /\ mem' = IF IsMgr(a) THEN [mem EXCEPT ![Prof(a)] = got[a]] ELSE mem
    /\ Reset(a)
    /\ UNCHANGED <<issued, revoked, mgr, rounds, lpc, lbuf>>

\* mark_reauthorization_required's Store.write, read half.
RejectRead(a) ==
    /\ pc[a] = "reject_write"
    /\ buf' = [buf EXCEPT ![a] = ReadForWrite(a)]
    /\ pc' = [pc EXCEPT ![a] = "reject_rename"]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, tok, got, tries, rounds, lpc, lbuf, best>>

\* ...and rename half: %{entry | status: "reauthorization_required"}, whose
\* tokens are the ones this refresh presented, over whatever another
\* refresher renamed since. That status is not a quarantine the store reads
\* back (store.ex:129-135); the damage is the consumed token on disk.
RejectRename(a) ==
    /\ pc[a] = "reject_rename"
    /\ disk' = [buf[a] EXCEPT ![Prof(a)] = tok[a]]
    /\ best' = [best EXCEPT ![Prof(a)] = Max(@, tok[a])]
    /\ Reset(a)
    /\ UNCHANGED <<issued, revoked, mgr, mem, rounds, lpc, lbuf>>

RefreshStep(a) ==
    \/ MgrStart(a) \/ CliStart(a)
    \/ SendOk(a) \/ SendLost(a) \/ SendRejected(a)
    \/ WriteRead(a) \/ Rename(a)
    \/ RejectRead(a) \/ RejectRename(a)

-----------------------------------------------------------------------------
(* Logout, in the caller's process. Plugins.Auth.logout (plugins/auth.ex:  *)
(* 65-88): Store.delete_provider, then TokenSupervisor.stop_profile. The   *)
(* provider sign-out (management/auth.ex:135-142) deletes, then forgets.   *)

\* delete_provider -> read_existing (store.ex:87, :333-349). With no entry,
\* the plugin logout fails and stops there (plugins/auth.ex:69-71), while
\* the provider sign-out treats :provider_missing as done and goes on to
\* forget (management/auth.ex:351-360).
LogoutRead ==
    /\ UserCanLogout
    /\ lpc = "idle"
    /\ disk[LogoutProfile] /= None \/ SignOutForgets
    /\ QuietForLogout
    /\ lbuf' = disk
    /\ lpc' = "read"
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, best>>

\* remove_provider + atomic_write (store.ex:88-89, :383-391). An entry that
\* was already gone is not rewritten (remove_provider refuses, :389).
LogoutDelete ==
    /\ lpc = "read"
    /\ disk' = IF lbuf[LogoutProfile] = None THEN disk
               ELSE [lbuf EXCEPT ![LogoutProfile] = None]
    /\ lbuf' = EmptyDoc
    /\ lpc' = "deleted"
    /\ UNCHANGED <<issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, best>>

\* The manager's lanes, killed by stop_profile.
Killed(b) == IsMgr(b) /\ Prof(b) = LogoutProfile
Kill(f, v) == [b \in Actors |-> IF Killed(b) THEN v ELSE f[b]]

\* Three cases:
\*  - A CLI VM has no TokenSupervisor tree (plugins_command.ex:5-8), so
\*    stop_profile does nothing (token_supervisor.ex:142, :152-153); the
\*    CLI's `fermix auth logout` does not reach the daemon either
\*    (auth_command.ex:216-225).
\*  - stop_profile (plugins/auth.ex:72, token_supervisor.ex:140-155):
\*    DynamicSupervisor.terminate_child sends :shutdown; TokenManager does
\*    not trap exits, so it dies at once, mid-callback if one is running.
\*  - forget (management/auth.ex:138, :362-379 -> token_manager.ex:205-222):
\*    a GenServer.call, so it waits behind any refresh callback in flight,
\*    then drops the tokens and sets state.refusal.
LogoutStop ==
    /\ lpc = "deleted"
    /\ lpc' = "done"
    /\ CASE ~LogoutReachesManager \/ LogoutFromCli ->
              UNCHANGED <<mgr, mem, pc, tok, got, tries, buf>>
         [] ~SignOutForgets ->
              /\ mgr' = [mgr EXCEPT ![LogoutProfile] = "stopped"]
              /\ mem' = [mem EXCEPT ![LogoutProfile] = None]
              /\ pc' = Kill(pc, "idle")
              /\ tok' = Kill(tok, None)
              /\ got' = Kill(got, None)
              /\ tries' = Kill(tries, 0)
              /\ buf' = Kill(buf, EmptyDoc)
         [] OTHER ->
              /\ \A b \in Actors : Killed(b) => pc[b] = "idle"
              /\ mgr' = [mgr EXCEPT ![LogoutProfile] = "refused"]
              /\ mem' = [mem EXCEPT ![LogoutProfile] = None]
              /\ UNCHANGED <<pc, tok, got, tries, buf>>
    /\ UNCHANGED <<disk, issued, revoked, rounds, lbuf, best>>

LogoutStep == LogoutRead \/ LogoutDelete \/ LogoutStop

-----------------------------------------------------------------------------
Init ==
    /\ disk = [p \in Profiles |-> 0]
    /\ issued = [p \in Profiles |-> 0]
    /\ revoked = [p \in Profiles |-> FALSE]
    /\ mgr = [p \in Profiles |-> "serving"]
    /\ mem = [p \in Profiles |-> 0]
    /\ pc = [a \in Actors |-> "idle"]
    /\ tok = [a \in Actors |-> None]
    /\ got = [a \in Actors |-> None]
    /\ tries = [a \in Actors |-> 0]
    /\ buf = [a \in Actors |-> EmptyDoc]
    /\ rounds = [a \in Actors |-> 0]
    /\ lpc = "idle"
    /\ lbuf = EmptyDoc
    /\ best = [p \in Profiles |-> 0]

\* The legitimate end: no refresh and no logout in flight. A refresher that
\* could still start is waiting for its next trigger, which is not a wedge.
\* Deadlock checking is on, so any other state where nothing can happen is
\* reported.
Done ==
    /\ \A a \in Actors : pc[a] = "idle"
    /\ lpc \in {"idle", "done"}

Terminated == Done /\ UNCHANGED vars

Next ==
    \/ \E a \in Actors : RefreshStep(a)
    \/ LogoutStep
    \/ Terminated

\* Inert today: no check has a temporal property. Kept for a future
\* liveness check. Fermix drives the writes once a refresh has an answer,
\* and the logout's own steps once it has begun; refresh triggers, the
\* provider and the user get no fairness.
Fairness ==
    /\ \A a \in Actors : WF_vars(WriteRead(a) \/ Rename(a) \/ RejectRead(a) \/ RejectRename(a))
    /\ WF_vars(LogoutDelete \/ LogoutStop)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* PROPERTIES *)

\* token_manager.ex:414-417: "Refresh from the newest persisted entry, not
\* the in-memory copy. Another refresher (a CLI/doctor probe, or a prior
\* refresh) may have rotated the refresh token in the store; Codex
\* invalidates the whole session if a rotated (consumed) refresh token is
\* reused, so always start from disk." Read as: no refresher ever presents
\* a consumed refresh token, so the provider never revokes the session.
NeverSendConsumed == \A p \in Profiles : ~revoked[p]

\* Proposed rule: a successful rotation is never lost from disk. Every
\* profile's newest stored refresh token stays in auth.json until that
\* profile is logged out.
NoLostRotation ==
    \A p \in Profiles :
        \/ p = LogoutProfile /\ lpc \in {"deleted", "done"}
        \/ disk[p] = best[p]

\* Proposed rule: after a logout completes, the entry never reappears.
LogoutSticks == lpc = "done" => disk[LogoutProfile] = None

-----------------------------------------------------------------------------
(* WITNESS: violated when its scenario is reachable. *)

\* The situation latest_entry exists for: another refresher rotated the
\* token, so a serving manager's in-memory refresh token is consumed.
Witness_StaleManagerMemory ==
    ~(\E p \in Profiles :
        /\ mgr[p] = "serving"
        /\ mem[p] /= None /\ disk[p] /= None
        /\ mem[p] < disk[p])

=============================================================================
