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
(*  - the two cross-VM lockfiles around it (Plugins.Dist.Lock): the store  *)
(*    lock over each Store.write and delete_provider, and the profile lock *)
(*    over one refresh, from its read of the entry to its write, and over  *)
(*    a delete. The profile lock is always taken first.                    *)
(*  - after a 4xx, the status write of a profile other than Codex: it      *)
(*    writes back the entry read when the refresh began.                   *)
(*  - a response lost after the provider rotated, retried by RefreshClient *)
(*    with the same refresh token.                                         *)
(*  - a logout that deletes the entry, then stops the profile's manager    *)
(*    (plugin logout) or forgets its tokens (provider sign-out).           *)
(*  - a logout from a tree-less CLI VM: the same delete, then a notice     *)
(*    that has a running daemon let go of the profile (forget, then stop   *)
(*    a TokenSupervisor child).                                            *)
(*  - a manager whose stored entry is gone dropping its tokens instead of  *)
(*    refreshing them.                                                     *)
(*                                                                         *)
(* Not modelled:                                                           *)
(*  - access tokens and expiry. Every trigger of a refresh (the proactive  *)
(*    timer, get_token when due, a reactive 401) runs the same do_refresh, *)
(*    so a refresh simply may start. CodexToken locks only a due entry and *)
(*    re-checks it under the lock: a subset of these starts.               *)
(*  - a refused sign-in client (mark_client_rejected), xAI's 403 (no       *)
(*    write), sign-in writes and reloads: more Store.writes of one shape.  *)
(*    A sign-in or import holds the profile lock from before it spends     *)
(*    anything (its code exchange, the Codex CLI's refresh token) through  *)
(*    its write (Store.with_profile_lock), so it lands before a refresh's  *)
(*    read or after its write, never between; a lock still busy after the *)
(*    wait refuses it with nothing spent.                                  *)
(*  - a transport error before the provider acts: the retry is harmless.   *)
(*  - a daemon crash or a manager restart between the provider's rotation  *)
(*    and the rename: it loses the rotation the way a lost response does.  *)
(*  - a CLI logout's notice the daemon answers with an error: the CLI      *)
(*    exits non-zero. The model takes the pessimistic case, nothing        *)
(*    reaching the manager; a forget that timed out still runs, late.      *)
(*  - disk write errors, callers' GenServer.call timeouts (the callback    *)
(*    runs to its end regardless), the token-file projection, and a        *)
(*    stopped manager restarted by ensure_child (it re-reads auth.json).   *)
(*  - lock timing. A step that needs a lock waits until it is free; a wait *)
(*    that runs out fails with nothing changed, the same as not starting.  *)
(*    Each stale threshold exceeds its locked section, so a lockfile is    *)
(*    broken only after its holder died, bar a clock jump (README).        *)
(*                                                                         *)
(* One step = one indivisible thing in the code: a file read, a file       *)
(* rename, one provider-side effect, or one GenServer callback that does   *)
(* no I/O. Steps of one refresh run in the refresher's own process. Taking *)
(* a lock is folded into the read after it, and releasing one into the     *)
(* rename before it: either only enables or disables the other takers of   *)
(* that lock, so it commutes with every step in between.                   *)
(***************************************************************************)
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_manager.ex @ bae696857f03
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_supervisor.ex @ 559c96b83e34
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/store.ex @ ad03752ea118
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/refresh_client.ex @ 4a517539ab3f
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/codex_token.ex @ 091e221339b5
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/token_expiry.ex @ 8373575105e9
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/codex_import.ex @ b87011fae1ad
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/codex_login.ex @ 0337bd553071
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/xai_login.ex @ d81c71a108d7
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/anthropic_login.ex @ e580e287fec4
\* SOURCE: apps/fermix_core/lib/fermix_core/auth/oauth_flow.ex @ 238a61352a4c
\* SOURCE: apps/fermix_core/lib/fermix_core/plugins/auth.ex @ 989e7163313e
\* SOURCE: apps/fermix_core/lib/fermix_core/plugins/dist/lock.ex @ a72706b8aa1a
\* SOURCE: apps/fermix_core/lib/fermix_core/management/auth.ex @ 2a44b8fd3cc2
\* SOURCE: apps/fermix_core/lib/fermix_core/tools/media/backends/codex_image.ex @ ea4175294f01
\* SOURCE: apps/fermix_core/lib/fermix/cli/plugins_command.ex @ 7dce15e18d94
\* SOURCE: apps/fermix_core/lib/fermix/cli/auth_command.ex @ 0fdfc82bfdcd
\* SOURCE: apps/fermix_core/lib/fermix/cli/daemon.ex @ a3d42529ca98
\* SOURCE: apps/fermix_core/lib/fermix/cli/daemon/client.ex @ fd0cff9607dc
EXTENDS Naturals, FiniteSets

CONSTANTS
    Profiles,           \* OAuth auth profiles in auth.json, e.g. {p1, p2}
    CodexProfiles,      \* the Codex profile, if modelled: no status write after a 4xx
    CliProfile,         \* the profile the CLI VM refreshes
    LogoutProfile,      \* the profile the user logs out of
    None,               \* "no token" / "no entry" / "no lock holder"
    MaxAttempts,        \* RefreshClient @max_attempts (refresh_client.ex:31), 3 in the code
    Rounds,             \* bound: how many refreshes each refresher may start
    \* Environment switches: what may happen.
    CliRefreshes,           \* a tree-less CLI VM refreshes CliProfile directly
    RefreshesCanOverlap,    \* one process's refresh or logout can be in flight while another's is
    ResponseCanBeLost,      \* the provider rotates, then its response never arrives
    UserCanLogout,          \* the user logs out of LogoutProfile
    LogoutFromCli,          \* that logout runs in a tree-less CLI VM
    SignOutForgets,         \* that logout is the provider sign-out (forget), not the plugin logout (stop)
    \* Mechanism switches: what the code does about it. TRUE is the real code;
    \* each is switched off by at least one check to show a property needs it.
    ReadsDiskBeforeRefresh, \* latest_entry re-reads auth.json before each refresh (token_manager.ex:492-496)
    OneCallbackPerManager,  \* one process per profile, one callback at a time (see "Who refreshes")
    MergesOnWrite,          \* Store.write re-reads the file and replaces only its own entry (store.ex:380-386, :470-495)
    LogoutReachesManager,   \* logout stops or forgets the live manager (plugins/auth.ex:72, management/auth.ex:138)
    StoreLock,              \* auth.json.lock around every Store.write and delete_provider (store.ex:116-121, :132-139)
    ProfileLock,            \* the profile's lock over one refresh, read to write, and over a delete (store.ex:158-162)
    RefusesMissingEntry,    \* a manager whose entry is gone drops its tokens (token_manager.ex:323-324, :372-380)
    CliLogoutReachesDaemon  \* a CLI logout then has a running daemon let go of the profile (auth_command.ex:267-283, plugins_command.ex:504-529, cli/daemon.ex:787-817)

ASSUME /\ CodexProfiles \subseteq Profiles
       /\ CliProfile \in Profiles /\ LogoutProfile \in Profiles
       /\ MaxAttempts \in Nat \ {0} /\ Rounds \in Nat
       /\ \A s \in {CliRefreshes, RefreshesCanOverlap, ResponseCanBeLost, UserCanLogout,
                    LogoutFromCli, SignOutForgets, ReadsDiskBeforeRefresh,
                    OneCallbackPerManager, MergesOnWrite, LogoutReachesManager,
                    StoreLock, ProfileLock, RefusesMissingEntry,
                    CliLogoutReachesDaemon} : s \in BOOLEAN

(* A refresh token is its generation number: the provider issues 0 at      *)
(* sign-in and n+1 when n is refreshed. Every token below the newest one   *)
(* is consumed.                                                            *)
Tok == Nat \cup {None}

(* Who refreshes. <<"mgr", p, l>> is the manager of profile p;             *)
(* <<"cli", CliProfile, 1>> is the CLI VM.                                 *)
(* A profile has one manager process: TokenSupervisor registers children   *)
(* in a Registry with keys: :unique (token_supervisor.ex:214) and answers  *)
(* {:already_started, _} with the running one (:262); the Codex manager is *)
(* registered under the module name (token_manager.ex:36-37). Its mailbox  *)
(* runs one callback at a time, so concurrent callers of one profile       *)
(* queue. Lane 2 is a second process refreshing the same profile beside    *)
(* the manager, possible only with OneCallbackPerManager off. It stands    *)
(* for those concurrent callers, so RefreshesCanOverlap does not restrain  *)
(* it. With ProfileLock on it waits for the lock like any other refresher. *)
Lanes == {1, 2}
Actors == {<<"mgr", p, l>> : p \in Profiles, l \in Lanes} \cup {<<"cli", CliProfile, 1>>}
IsMgr(a) == a[1] = "mgr"
Prof(a) == a[2]
Proc(a) == <<a[1], a[2]>>       \* the manager's callers, as one process

(* The logout caller, as a lock holder. *)
LogoutActor == <<"logout", LogoutProfile, 1>>
Holders == Actors \cup {LogoutActor, None}

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
    best,       \* history: the newest refresh token ever written to disk for p
    slock,      \* disk: who holds auth.json.lock (Store.store_lock_path), or None
    plock       \* disk: plock[p] = who holds p's profile lock (Store.profile_lock_path), or None

vars == <<disk, issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, lpc, lbuf, best,
          slock, plock>>

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
    /\ slock \in Holders
    /\ plock \in [Profiles -> Holders]

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

\* The locks: Plugins.Dist.Lock.with_lock (lock.ex:48-57), an O_EXCL
\* lockfile created and removed by a linked Lock.Owner (:167-181, :151-160).
\* A lock whose mechanism is switched off is never taken, so it stays None,
\* and releasing it changes nothing.
TakeProfile(a) ==
    IF ProfileLock
    THEN /\ plock[Prof(a)] = None
         /\ plock' = [plock EXCEPT ![Prof(a)] = a]
    ELSE UNCHANGED plock
ReleaseProfile(a) == plock' = [plock EXCEPT ![Prof(a)] = None]
TakeStore(a) == IF StoreLock THEN slock = None /\ slock' = a ELSE UNCHANGED slock
ReleaseStore == slock' = None
ProfileFree(p) == ~ProfileLock \/ plock[p] = None

-----------------------------------------------------------------------------
(* Starting a refresh *)

\* A manager callback runs do_refresh (token_manager.ex:275-310): from
\* handle_call(:refresh) (:198), handle_call(:get_token) when due (:171) or
\* handle_info(:proactive_refresh) (:250). A manager with state.refusal set
\* never refreshes (:194, :245); one with no refresh token neither (:275).
MgrMayStart(a) ==
    /\ IsMgr(a)
    /\ pc[a] = "idle"
    /\ rounds[a] < Rounds
    /\ mgr[Prof(a)] = "serving"
    /\ mem[Prof(a)] /= None
    /\ a[3] = 1 \/ ~OneCallbackPerManager
    /\ QuietForRefresh(a)

\* do_refresh's read finds no entry (stored_entry_error, :323-324).
SignedOut(a) == RefusesMissingEntry /\ ReadsDiskBeforeRefresh /\ disk[Prof(a)] = None

\* do_refresh takes the profile lock (Store.with_profile_lock, :285-290;
\* store.ex:158-162); refresh_stored (token_manager.ex:314-319) reads the
\* entry under it through latest_entry (:492-496) and refreshes the stored
\* token. Without
\* RefusesMissingEntry, a read that finds no entry falls back to the
\* in-memory tokens (the entry_from_state fallback this fix removed).
MgrStart(a) ==
    /\ MgrMayStart(a)
    /\ ~SignedOut(a)
    /\ TakeProfile(a)
    /\ tok' = [tok EXCEPT ![a] =
                 IF ReadsDiskBeforeRefresh /\ disk[Prof(a)] /= None
                 THEN disk[Prof(a)] ELSE mem[Prof(a)]]
    /\ pc' = [pc EXCEPT ![a] = "send"]
    /\ tries' = [tries EXCEPT ![a] = 1]
    /\ rounds' = [rounds EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, got, buf, lpc, lbuf, best, slock>>

\* The entry is gone: a logout ran since the manager loaded its tokens.
\* signed_out/2 (:372-380) drops them through drop_tokens/1 (:384-396),
\* the state forget/1 builds (:205-208), and sends and writes nothing. The
\* profile lock is taken for the read and released at once.
MgrSignedOut(a) ==
    /\ MgrMayStart(a)
    /\ SignedOut(a)
    /\ ProfileFree(Prof(a))
    /\ mgr' = [mgr EXCEPT ![Prof(a)] = "refused"]
    /\ mem' = [mem EXCEPT ![Prof(a)] = None]
    /\ rounds' = [rounds EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<disk, issued, revoked, pc, tok, got, tries, buf, lpc, lbuf, best,
                   slock, plock>>

\* A tree-less CLI VM: TokenManager.refresh(profile) -> TokenSupervisor
\* call_or_read finds no supervisor (token_supervisor.ex:221-224, :237-251)
\* -> direct_refresh takes the profile lock, then Store.read and
\* refresh_entry under it (:321-330). CodexToken.get_token does the same for
\* Codex once the entry it read is due: it takes the lock, reads again and
\* refreshes only if still due (codex_token.ex:15-23, :112-126). A missing
\* entry fails the read and nothing is refreshed.
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
    /\ TakeProfile(a)
    /\ tok' = [tok EXCEPT ![a] = disk[Prof(a)]]
    /\ pc' = [pc EXCEPT ![a] = "send"]
    /\ tries' = [tries EXCEPT ![a] = 1]
    /\ rounds' = [rounds EXCEPT ![a] = @ + 1]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, got, buf, lpc, lbuf, best, slock>>

-----------------------------------------------------------------------------
(* The refresh request: one provider-side effect each. RefreshClient.refresh *)
(* posts the refresh token (refresh_client.ex:66-110 for Codex, :112-172 for *)
(* the others). The provider accepts only its newest token.                  *)

Valid(a) == ~revoked[Prof(a)] /\ tok[a] = issued[Prof(a)]

\* 200: the provider rotates and the new pair arrives (refresh_client.ex:85,
\* :150). refresh_entry goes on to Store.write.
SendOk(a) ==
    /\ pc[a] = "send"
    /\ Valid(a)
    /\ issued' = [issued EXCEPT ![Prof(a)] = @ + 1]
    /\ got' = [got EXCEPT ![a] = issued[Prof(a)] + 1]
    /\ pc' = [pc EXCEPT ![a] = "write"]
    /\ UNCHANGED <<disk, revoked, mgr, mem, tok, tries, buf, rounds, lpc, lbuf, best,
                   slock, plock>>

\* The provider rotates, but the response is lost: Req's receive timeout, a
\* closed connection, or a 5xx after the rotation. RefreshClient cannot tell
\* and retries with the SAME refresh token (refresh_client.ex:94-97, :102-105;
\* :156-159, :164-167). After the last attempt the refresh fails with no
\* state change (token_manager.ex:307-308) and the profile lock is released.
SendLost(a) ==
    /\ ResponseCanBeLost
    /\ pc[a] = "send"
    /\ Valid(a)
    /\ issued' = [issued EXCEPT ![Prof(a)] = @ + 1]
    /\ IF tries[a] < MaxAttempts
       THEN /\ tries' = [tries EXCEPT ![a] = @ + 1]
            /\ UNCHANGED <<pc, tok, got, buf, plock>>
       ELSE Reset(a) /\ ReleaseProfile(a)
    /\ UNCHANGED <<disk, revoked, mgr, mem, rounds, lpc, lbuf, best, slock>>

\* A consumed token, or any token of a revoked session: 4xx, returned as
\* {:permanent, status, body} (refresh_client.ex:91-92, :153-154). A
\* consumed token revokes the whole session (Codex rule,
\* token_manager.ex:487-491). The manager refuses from now on
\* (refresh_outcome/2 -> permanently_refused/2, :343-349, :359-366; refuse/2,
\* :422). For Codex nothing is written (:585-586; the CLI's
\* CodexToken.refresh_entry returns the error, codex_token.ex:99-100) and the
\* profile lock is released. Any other profile goes on to
\* mark_reauthorization_required, a Store.write of the entry read when this
\* refresh began (token_manager.ex:588-600; token_supervisor.ex:352, :376,
\* :407, :429-441), still under the profile lock.
SendRejected(a) ==
    /\ pc[a] = "send"
    /\ ~Valid(a)
    /\ revoked' = [revoked EXCEPT ![Prof(a)] = TRUE]
    /\ mgr' = IF IsMgr(a) /\ mgr[Prof(a)] = "serving"
              THEN [mgr EXCEPT ![Prof(a)] = "refused"] ELSE mgr
    /\ IF Prof(a) \in CodexProfiles
       THEN Reset(a) /\ ReleaseProfile(a)
       ELSE /\ pc' = [pc EXCEPT ![a] = "reject_write"]
            /\ UNCHANGED <<tok, got, tries, buf, plock>>
    /\ UNCHANGED <<disk, issued, mem, rounds, lpc, lbuf, best, slock>>

-----------------------------------------------------------------------------
(* Persisting: Store.write (store.ex:116-121), two steps each, under the    *)
(* store lock (lock/4 and hold/4, :540-555).                                *)

\* read_for_write (store.ex:380-381, :396-407) reads the whole file. Without
\* MergesOnWrite the writer would start from an empty document instead.
ReadForWrite(a) == IF MergesOnWrite THEN disk ELSE EmptyDoc

WriteRead(a) ==
    /\ pc[a] = "write"
    /\ TakeStore(a)
    /\ buf' = [buf EXCEPT ![a] = ReadForWrite(a)]
    /\ pc' = [pc EXCEPT ![a] = "rename"]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, tok, got, tries, rounds, lpc, lbuf, best,
                   plock>>

\* put_provider + atomic_write (store.ex:382-383, :470-495, :562-577): the map
\* read above, with this profile's entry replaced (or created: put_provider
\* merges into Map.get(providers, key, %{}), :473), renamed over auth.json.
\* Both locks are then released: the store lock as Store.write returns, the
\* profile lock as the refresh's locked section returns. A manager then
\* applies the entry in memory (apply_entry, token_manager.ex:292-293,
\* :398-415). mgr is left alone: a refresh only runs while the manager is
\* serving (:194, :245).
Rename(a) ==
    /\ pc[a] = "rename"
    /\ disk' = [buf[a] EXCEPT ![Prof(a)] = got[a]]
    /\ best' = [best EXCEPT ![Prof(a)] = Max(@, got[a])]
    /\ mem' = IF IsMgr(a) THEN [mem EXCEPT ![Prof(a)] = got[a]] ELSE mem
    /\ Reset(a)
    /\ ReleaseStore
    /\ ReleaseProfile(a)
    /\ UNCHANGED <<issued, revoked, mgr, rounds, lpc, lbuf>>

\* mark_reauthorization_required's Store.write, read half.
RejectRead(a) ==
    /\ pc[a] = "reject_write"
    /\ TakeStore(a)
    /\ buf' = [buf EXCEPT ![a] = ReadForWrite(a)]
    /\ pc' = [pc EXCEPT ![a] = "reject_rename"]
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, tok, got, tries, rounds, lpc, lbuf, best,
                   plock>>

\* ...and rename half: %{entry | status: "reauthorization_required"}, whose
\* tokens are the ones this refresh presented, over whatever another
\* refresher renamed since. That status is not a quarantine the store reads
\* back (store.ex:233); the damage is the consumed token on disk. Both locks
\* are released.
RejectRename(a) ==
    /\ pc[a] = "reject_rename"
    /\ disk' = [buf[a] EXCEPT ![Prof(a)] = tok[a]]
    /\ best' = [best EXCEPT ![Prof(a)] = Max(@, tok[a])]
    /\ Reset(a)
    /\ ReleaseStore
    /\ ReleaseProfile(a)
    /\ UNCHANGED <<issued, revoked, mgr, mem, rounds, lpc, lbuf>>

RefreshStep(a) ==
    \/ MgrStart(a) \/ MgrSignedOut(a) \/ CliStart(a)
    \/ SendOk(a) \/ SendLost(a) \/ SendRejected(a)
    \/ WriteRead(a) \/ Rename(a)
    \/ RejectRead(a) \/ RejectRename(a)

-----------------------------------------------------------------------------
(* Logout, in the caller's process. Plugins.Auth.logout (plugins/auth.ex:  *)
(* 66-88): Store.delete_provider, then TokenSupervisor.stop_profile. The   *)
(* provider sign-out (management/auth.ex:135-142) deletes, then forgets.   *)

\* delete_provider (store.ex:132-139) takes the profile lock, then the store
\* lock, then read_existing (:388-389, :447-463). With no entry, the in-daemon
\* plugin logout fails and stops there (plugins/auth.ex:69-71), while the
\* provider sign-out treats :provider_missing as done and goes on to forget
\* (management/auth.ex:351-360), and both CLI logouts go on to their notice
\* (auth_command.ex:295-298, plugins_command.ex:269-275). Init stores every
\* entry, and with MergesOnWrite on (every check with LogoutFromCli) only
\* the logout deletes one, so the entry is never already gone here: the
\* LogoutFromCli disjunct records the code and changes no state space.
LogoutRead ==
    /\ UserCanLogout
    /\ lpc = "idle"
    /\ disk[LogoutProfile] /= None \/ SignOutForgets \/ LogoutFromCli
    /\ QuietForLogout
    /\ IF ProfileLock
       THEN /\ plock[LogoutProfile] = None
            /\ plock' = [plock EXCEPT ![LogoutProfile] = LogoutActor]
       ELSE UNCHANGED plock
    /\ IF StoreLock THEN slock = None /\ slock' = LogoutActor ELSE UNCHANGED slock
    /\ lbuf' = disk
    /\ lpc' = "read"
    /\ UNCHANGED <<disk, issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, best>>

\* remove_provider + atomic_write (store.ex:390-391, :497-507, :562-577),
\* then both locks are released. An entry that was already gone is not
\* rewritten (remove_provider refuses, :503).
LogoutDelete ==
    /\ lpc = "read"
    /\ disk' = IF lbuf[LogoutProfile] = None THEN disk
               ELSE [lbuf EXCEPT ![LogoutProfile] = None]
    /\ lbuf' = EmptyDoc
    /\ lpc' = "deleted"
    /\ slock' = None
    /\ plock' = [plock EXCEPT ![LogoutProfile] = None]
    /\ UNCHANGED <<issued, revoked, mgr, mem, pc, tok, got, tries, buf, rounds, best>>

\* The manager's lanes, killed by stop_profile.
Killed(b) == IsMgr(b) /\ Prof(b) = LogoutProfile
Kill(f, v) == [b \in Actors |-> IF Killed(b) THEN v ELSE f[b]]
\* Lock.Owner traps its holder's exit and removes the lockfile
\* (lock.ex:141-148, :153-160), so a killed lane's locks go with it.
Freed(h) == IF h \in Actors /\ Killed(h) THEN None ELSE h

\* Four cases:
\*  - A CLI VM has no TokenSupervisor tree (plugins_command.ex:5-8), so its
\*    own stop_profile does nothing (token_supervisor.ex:183, :193-194).
\*    After the delete, both CLI logouts tell a running daemon to let go of
\*    the profile (plugins_command.ex:262, :504-529; auth_command.ex:223-241,
\*    :267-283, :295-298): an `auth_forget` request on the control socket
\*    (cli/daemon/client.ex:61-74), answered by forget_signed_out
\*    (cli/daemon.ex:562, :787-817; token_supervisor.ex:151-170). That is
\*    forget, as below, then stop_profile for a child of TokenSupervisor,
\*    which by then is idle and refusing; the Codex manager, a top-level
\*    child, is only forgotten. One step: after the forget nothing can run
\*    in that manager but the stop. Without CliLogoutReachesDaemon, or when
\*    the daemon does not answer "ok" (the CLI then exits non-zero),
\*    nothing reaches the manager.
\*  - stop_profile (plugins/auth.ex:72, token_supervisor.ex:181-196):
\*    DynamicSupervisor.terminate_child sends :shutdown; TokenManager does
\*    not trap exits, so it dies at once, mid-callback if one is running.
\*  - forget (management/auth.ex:138, :362-379 -> token_manager.ex:205-208):
\*    a GenServer.call, so it waits behind any refresh callback in flight,
\*    then drops the tokens and sets state.refusal (drop_tokens, :384-396).
\*  - neither, with LogoutReachesManager off.
LogoutStop ==
    /\ lpc = "deleted"
    /\ lpc' = "done"
    /\ CASE \/ LogoutFromCli /\ ~CliLogoutReachesDaemon
            \/ ~LogoutFromCli /\ ~LogoutReachesManager ->
              UNCHANGED <<mgr, mem, pc, tok, got, tries, buf, slock, plock>>
         [] LogoutFromCli /\ CliLogoutReachesDaemon ->
              /\ \A b \in Actors : Killed(b) => pc[b] = "idle"
              /\ mgr' = [mgr EXCEPT ![LogoutProfile] =
                            IF LogoutProfile \in CodexProfiles THEN "refused" ELSE "stopped"]
              /\ mem' = [mem EXCEPT ![LogoutProfile] = None]
              /\ UNCHANGED <<pc, tok, got, tries, buf, slock, plock>>
         [] ~LogoutFromCli /\ LogoutReachesManager /\ ~SignOutForgets ->
              /\ mgr' = [mgr EXCEPT ![LogoutProfile] = "stopped"]
              /\ mem' = [mem EXCEPT ![LogoutProfile] = None]
              /\ pc' = Kill(pc, "idle")
              /\ tok' = Kill(tok, None)
              /\ got' = Kill(got, None)
              /\ tries' = Kill(tries, 0)
              /\ buf' = Kill(buf, EmptyDoc)
              /\ slock' = Freed(slock)
              /\ plock' = [p \in Profiles |-> Freed(plock[p])]
         [] OTHER ->
              /\ \A b \in Actors : Killed(b) => pc[b] = "idle"
              /\ mgr' = [mgr EXCEPT ![LogoutProfile] = "refused"]
              /\ mem' = [mem EXCEPT ![LogoutProfile] = None]
              /\ UNCHANGED <<pc, tok, got, tries, buf, slock, plock>>
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
    /\ slock = None
    /\ plock = [p \in Profiles |-> None]

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

\* token_manager.ex:487-491: "Refresh from the newest persisted entry, not
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

\* Proposed rule (TOKEN-6): once a logout completes, the profile's manager
\* no longer serves its tokens. The plugin logout stops it and the provider
\* sign-out forgets them (token_manager.ex:68-76: forget "drops the tokens
\* this manager holds and refuses to serve them again"). A CLI logout has
\* the running daemon do both (CliLogoutReachesDaemon).
LogoutStopsServing == lpc = "done" => mgr[LogoutProfile] /= "serving"

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
