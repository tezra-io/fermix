# token_refresh: OAuth refresh and `auth.json`

Models how Fermix rotates OAuth refresh tokens and stores them in
`~/.fermix/auth.json`. The daemon runs one `TokenManager` GenServer per auth
profile: the top-level `TokenManager` for Codex (`application.ex:173`,
`:362-364`), and a child under `TokenSupervisor` for every other profile
(`token_supervisor.ex:237-265`). A tree-less CLI VM refreshes a profile directly,
with no manager (`token_supervisor.ex:221-224`, `:312-330`;
`codex_token.ex:15-23`). Every refresher persists through `Store.write`, which
reads the whole file and then renames a new one over it (`store.ex:116-121`,
`:380-386`, `:562-577`). The model therefore keeps the file as one map: a write
is never torn, and the last rename wins. After a 4xx, a profile other than Codex
writes back the entry it read when its refresh began
(`mark_reauthorization_required`). Logout deletes the entry, then stops the
profile's manager (plugin logout, `plugins/auth.ex:66-88`) or forgets its tokens
(provider sign-out, `management/auth.ex:135-142`). A logout from a tree-less CLI
VM deletes the entry the same way, then has a running daemon let go of the
profile over the control socket (`auth_forget`, `cli/daemon.ex:787-817` →
`TokenSupervisor.forget_signed_out`, `token_supervisor.ex:132-170`).

Two cross-VM lockfiles (`FermixCore.Plugins.Dist.Lock`) order those writers
(`store.ex:9-39`):
- the store lock, `auth.json.lock`, around every `Store.write` and
  `Store.delete_provider` (`store.ex:116-121`, `:132-139`);
- one profile lock per profile, `auth.json.<base64 profile>.lock`, around one
  refresh from its read of the entry to its write (`token_manager.ex:285-290`,
  `token_supervisor.ex:321-330`, `codex_token.ex:112-126`), around a delete
  (`store.ex:132-139`), and around a sign-in or import from before it spends
  anything to its write (`store.ex:141-162`; `codex_login.ex:40-51`,
  `xai_login.ex:50-58`, `plugins/auth.ex:195-206`, `codex_import.ex:38-56`,
  `anthropic_login.ex:104-121`). Every taker waits the same 10 s, and a lock
  still busy after it is `{:error, :profile_busy}` with nothing spent.

The profile lock is always taken first. A manager whose stored entry is gone
drops its tokens instead of refreshing them (`token_manager.ex:323-324`,
`:372-396`).

The provider rotates the refresh token on every refresh and revokes the session
when a consumed token comes back. The code states that rule for Codex only
(`token_manager.ex:487-491`). It says X's refresh tokens are "single-use and
rotated on every refresh" (`oauth_providers.ex:289-290`), but not what X does on
reuse, and it says nothing about rotation for Anthropic, xAI or the other plugin
providers. A provider that returns no new refresh token keeps the old one
(`token_manager.ex:573`), so it can never be sent a consumed one. For every
rotating provider the Fermix side is the same: a consumed token draws a 4xx,
which Fermix treats as permanent, and it quarantines the grant until a new
sign-in (`token_manager.ex:343-349`, `:359-366`).

Most checks use two profiles:
- `p1` is the Codex profile (`CodexProfiles = {p1}`): the top-level manager,
  and a CLI VM that refreshes it through `CodexToken`.
- `p2` is a plugin profile under `TokenSupervisor`, and the user logs out of
  it.

Each refresher may start two refreshes. Tokens are written R0, R1, … below.

**Environment switches** (set per check):
- `CliRefreshes`: a tree-less CLI VM refreshes `CliProfile` directly
  (`fermix plugins auth refresh`, or `fermix setup` and `fermix doctor` with no
  daemon tree). Inside the daemon, the Codex image backend refreshes the same
  way from a tool process (`tools/media/backends/codex_image.ex:279` →
  `codex_token.ex:15-23`), so it is a second refresher of this shape.
- `RefreshesCanOverlap`: one process's refresh or logout can be in flight while
  another process's is. This is always true of the real code. Off, it is a
  global mutex that no code provides.
- `ResponseCanBeLost`: the provider rotates, then its response is lost: Req's
  receive timeout, a closed connection, or a 5xx after the rotation.
- `UserCanLogout`: the user logs out of `LogoutProfile`.
- `LogoutFromCli`: that logout runs in a tree-less CLI VM
  (`fermix plugins auth logout`, `fermix auth logout`) while the daemon runs.
  With no daemon running there is no manager to reach, and nothing to model.
- `SignOutForgets`: that logout is the provider sign-out (delete, then
  `forget`), not the plugin logout (delete, then `stop_profile`). The sign-out
  goes on to `forget` even when the entry is already gone
  (`management/auth.ex:351-360`). The in-daemon plugin logout stops at the
  failed delete (`plugins/auth.ex:69-71`). Both CLI logouts go on to their
  notice (`auth_command.ex:295-298`, `plugins_command.ex:269-275`). Every
  entry starts stored, and with `MergesOnWrite` on (as in every check with
  `LogoutFromCli`) only the logout deletes one, so a CLI logout never finds its
  entry already gone.

**Mechanism switches** (`TRUE` is the real code; each is switched off by at
least one check):
- `ReadsDiskBeforeRefresh`: `latest_entry` re-reads `auth.json` before each
  refresh (`token_manager.ex:492-496`).
- `OneCallbackPerManager`: a profile has one manager process, and it runs one
  callback at a time. `TokenSupervisor` registers children in a Registry with
  `keys: :unique` (`token_supervisor.ex:214`) and answers `{:already_started, _}`
  with the running one (`:262`). The Codex manager is registered under its
  module name (`token_manager.ex:36-37`). The BEAM mailbox then queues
  concurrent callers. Switching it off models a second process refreshing the
  same profile beside the manager. That process stands for those concurrent
  callers, so `RefreshesCanOverlap` does not restrain it. The profile lock
  subsumes this mechanism, so it is load-bearing only in check 16, which has
  the profile lock off.
- `MergesOnWrite`: `Store.write` re-reads the file and replaces only its own
  entry (`store.ex:380-386`, `:470-495`).
- `LogoutReachesManager`: logout stops the profile's live manager
  (`plugins/auth.ex:72` → `token_supervisor.ex:181-196`) or forgets its tokens
  (`management/auth.ex:138` → `token_manager.ex:205-208`).
- `StoreLock`: `Store.write` and `Store.delete_provider` hold `auth.json.lock`
  from their read to their rename (`store.ex:116-121`, `:132-139`,
  `:540-560`).
- `ProfileLock`: a refresh holds its profile's lock from its read of the entry
  to its write, in the manager (`token_manager.ex:285-290`), the tree-less
  direct refresh (`token_supervisor.ex:321-330`) and `CodexToken`
  (`codex_token.ex:112-126`); `Store.delete_provider` takes it before its store
  lock (`store.ex:132-139`). A sign-in holds it from before its code exchange
  to its write; that is folded (see the spec header).
- `RefusesMissingEntry`: a manager whose read finds no entry (no auth file, or
  no entry for the profile) drops its tokens, as `forget` does, and sends and
  writes nothing (`token_manager.ex:323-324`, `:372-396`). Off, it refreshes
  the in-memory copy, which is what `entry_from_state` did before the fix.
- `CliLogoutReachesDaemon`: after its delete, a CLI logout sends a running
  daemon `auth_forget` for the profile (`plugins_command.ex:262`, `:504-529`;
  `auth_command.ex:223-241`, `:267-283`, `:295-298`;
  `cli/daemon/client.ex:61-74`). The daemon has the profile's manager forget
  its tokens, which also deletes its plugin child's token file, then stops a
  `TokenSupervisor` child; the top-level Codex manager is only forgotten
  (`cli/daemon.ex:562`, `:787-817`; `token_supervisor.ex:132-170`). Off, the
  CLI logout reaches no manager. That is also the state a daemon leaves when
  it answers the notice with an error, which the CLI reports by exiting
  non-zero; checks 14 and 26 model that case.

The atomic rename (`store.ex:569`) is not a switch. The model writes the whole
map by construction, and no property here is about a torn file.

## What holds

**With overlap allowed (the real code), every rule holds except the accepted
finding:** checks 07–09, 11–15, 27 and 29. Checks 14 and 27 need no overlap
to reach their state; 29 is 27 with overlap and the CLI refreshing. Each rests
on the mechanism named by its `needs` check:

| Holds | Rule | Needs (check) |
|---|---|---|
| 07 two managers write at once | `NoLostRotation` | `StoreLock` (17) |
| 08 the same, then a re-read | `NeverSendConsumed` | `StoreLock` (18) |
| 09 CLI and manager, Codex | `NeverSendConsumed` | `ProfileLock` (20) |
| 11 logout beside another profile's write | `LogoutSticks` | `StoreLock` (19) |
| 12 plugin logout during the profile's refresh | `LogoutSticks` | `ProfileLock` (22), `RefusesMissingEntry` (23) |
| 13 provider sign-out during the profile's refresh | `LogoutSticks` | `ProfileLock` (24), `RefusesMissingEntry` (25) |
| 14 CLI logout whose notice did not land | `LogoutSticks` | `RefusesMissingEntry` (26) |
| 15 CLI and manager, plugin profile | `NoLostRotation` | `ProfileLock` (21) |
| 27 CLI logout with the daemon running | `LogoutStopsServing` | `CliLogoutReachesDaemon` (28) |
| 29 the same, beside both profiles' refreshes | `LogoutSticks` | `RefusesMissingEntry` (30) |

Check 10 (TOKEN-3, accepted) stays violated.

Checks 14 and 26 set `CliLogoutReachesDaemon` off: they are a CLI logout whose
notice the daemon refused, where the refusal at the next refresh is what keeps
the logout. The refusal matters with the notice on, too. Between the CLI's
delete and the daemon's forget, the manager can still refresh. Check 30, which
is check 29 with `RefusesMissingEntry` off, breaks `LogoutSticks` in 8 states:
p2's manager refreshes from memory in that gap and writes the entry back, and
the notice then stops a manager whose entry is already restored.

Check 01 is the sequential baseline. It sets `RefreshesCanOverlap = FALSE`, a
global mutex no code provides, and lets every response arrive. With the CLI
refreshing and the user logging out of a plugin, then:
- No consumed refresh token is ever sent. This rests on
  `ReadsDiskBeforeRefresh` (check 02: after the CLI rotates the token, the
  manager would send its stale in-memory one).
- No rotation is lost from disk. This rests on `MergesOnWrite` (check 04).
- Once the logout completes, the manager no longer serves the account
  (`LogoutStopsServing`). This rests on `LogoutReachesManager` (check 05).

Check 16 is check 01 with the profile lock off. There the one-callback mailbox
is what keeps a manager's own callers from sending one token twice (check 03).
With the lock on, a second caller waits for the lock, and the mailbox is no
longer load-bearing.

`LogoutSticks` is no longer a rule of check 01. Sequentially, a logout sticks
twice over: the manager is stopped, and a refresh that found the entry gone
would refuse. No single switch breaks it, so the runner could not give it a
`needs` check there. Checks 11–14 prove it with overlap, which is stronger.

Witness 06 shows that the CLI can rotate a token under a serving manager, the
case the disk re-read exists for.

Every `holds` check was also run once by hand with one more of each entity:
three profiles (checks 01, 07, 08, 09, 11, 14, 16) or two (checks 12, 13, 15),
and three refreshes per refresher. All hold: 01 and 16 in 10,168 states (01
also with the provider sign-out, 10,168), 07 and 08 in 1,900, 09 in 24,340, 11
in 4,540, 12 and 13 in 382, 14 in 1,240, 15 in 2,062, 27 in 976 (three
profiles), 29 in 58,168 (three profiles). Check 27 was also run with overlap
and the CLI refreshing, against all four rules (`NeverSendConsumed`,
`NoLostRotation`, `LogoutSticks`, `LogoutStopsServing`): with the plugin
profile logged out, 1,367 states (4,924 with three refreshes per refresher;
check 29 runs this configuration against `LogoutSticks`); with the Codex
profile signed out through `fermix auth logout`, 989. All hold. The model has
one CLI actor. A second CLI VM is one more refresher of the same shape, and it
takes the same profile lock.

## Plan hypotheses

These are the "Expected" entries of `docs/design/TLA_PLUS_MODELS.md` §4.2.

- **Lost update between two profiles: confirmed, TOKEN-1, fixed.** `Store`'s
  moduledoc used to say "callers are serialized in-process: TokenManager is a
  singleton GenServer", but each profile has its own GenServer. The CLI VM,
  sign-ins and logouts are further writers. The atomic rename kept the file
  whole but did not prevent a lost update. The moduledoc now describes the
  store lock that does (`store.ex:9-30`).
- **Reuse after an ambiguous transport retry: confirmed, TOKEN-3, accepted.**
  The retry is not the root cause: once the response is lost, the only token
  Fermix holds is consumed.
- **CLI and daemon refreshing at the same time: confirmed, TOKEN-2, fixed.**
  For a profile other than Codex, the loser's status write also erased the
  winner's new token. The daemon could race on its own, through the Codex
  image backend.
- **Logout undone by an in-flight refresh: confirmed, TOKEN-4** (the profile's
  own refresh) and TOKEN-1 (another profile's write), **both fixed.** A logout
  from the CLI was undone with no race at all: TOKEN-5, fixed. After a CLI
  logout the daemon still served the account until its next refresh: TOKEN-6,
  fixed.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev` at `693970b7`; the **Code** bullets cite that commit. None has
been reproduced on a running daemon; each fixed one has an ExUnit test that
failed before the fix. To see a counterexample, run
`tla/bin/check.py token_refresh` and open `tla/out/token_refresh/<check>.txt`.

### TOKEN-1: concurrent `auth.json` writers lose each other's updates
- **Severity:** medium. The window is one writer's read-to-rename, but the
  outcome is a revoked session or a deleted account restored.
- **Status:** fixed (d514e149).
- **Checks:** 07, 08 and 11 now hold; 17, 18 and 19 show they need
  `StoreLock` (before the fix: 07 violated in 9 states, 08 in 11, 11 in 8).
- **Counterexample (before the fix):**
  - Check 07: p1's and p2's managers refresh at about the same time. p2's
    `Store.write` reads the file before p1's rename lands, then renames its copy
    over it. `auth.json` now holds p1's consumed R0, while p1's manager holds R1
    in memory.
  - Check 08: p1's next refresh re-reads `auth.json` (`latest_entry`), gets R0
    and sends it. The provider revokes p1's session.
  - Check 11: p1's `Store.write` reads the file, the user logs out of p2, and
    p1's rename writes back the map from before the logout. p2's entry is back.
- **Code (693970b7):**
  - `Store.write` ran `read_for_write`, then `put_provider` into the document
    it read, then `atomic_write` (`store.ex:77-79`, `:282-293`, `:356-381`,
    `:420-435`). It took no lock (`store.ex:9-12`). `delete_provider` had the
    same shape (`store.ex:84-92`).
  - Each profile's manager is its own process (`token_supervisor.ex:212-224`;
    for Codex, `application.ex:173`), so two managers' writes interleave. A CLI
    VM's writes, sign-ins and logouts interleave with them too.
  - `latest_entry` prefers the disk entry over the manager's in-memory token
    (`token_manager.ex:418-420`), so the lost update became a reuse. A daemon
    restart does the same, because `init` loads the disk entry.
- **Fix:** `Store.write` and `Store.delete_provider` run their read, merge and
  rename under `auth.json.lock` (`store.ex:116-121`, `:132-139`, `:540-560`):
  80 attempts 100 ms apart, broken as stale after 5 s. The wait outlasts the
  stale threshold, so a dead VM's lockfile never fails a live writer. Reads
  take no lock. A lock that is not taken (busy past the wait, or a lockfile
  that cannot be created) is a tuple, not a raise (`store.ex:534-560`),
  because a raise inside the Codex manager would restart the rest of the
  top-level `:rest_for_one` tree. Only a wedged filesystem, which makes the
  lock owner's own calls time out, still exits the caller (see "Outside this
  model").
- **Impact (before the fix):** a rotating profile lost its session at its next
  refresh. For Codex the whole session was revoked. An account that was logged
  out could come back.

### TOKEN-2: two refreshers of one profile send the same token
- **Severity:** medium. It needs two refreshes of one profile within one round
  trip, and the outcome is a revoked session or a lost grant.
- **Status:** fixed (d514e149).
- **Checks:** 09 and 15 now hold; 20 and 21 show they need `ProfileLock`
  (before the fix: 09 violated in 5 states, 15 in 9).
- **Counterexample (before the fix):**
  - Check 09, Codex: p1's manager reads R0 and sends it, and the provider
    rotates to R1. Before the manager's rename, a CLI refresh of p1 reads R0
    from `auth.json` and sends it. The provider revokes the session.
  - Check 15, one plugin profile: the manager reads R0, gets R1, and starts its
    `Store.write`. `fermix plugins auth refresh` reads R0, and the manager
    renames R1. The CLI sends R0 and gets a 4xx. Its status write then renames
    the R0 entry it read at the start over the manager's R1.
- **Code (693970b7):**
  - `latest_entry` re-read the disk (`token_manager.ex:418-422`), which only
    helps once the other refresh has renamed its result. Nothing coordinated a
    refresh still in flight. The CLI VM has no manager
    (`token_supervisor.ex:180-183`, `:197`, `:208`) and reads the file itself
    (`:272`; `codex_token.ex:19-20`).
  - After a 4xx, any profile but Codex runs `mark_reauthorization_required`, a
    `Store.write` of the entry read when the refresh began
    (`token_manager.ex:294`, `:317`, `:534-536`; `token_supervisor.ex:298-299`,
    `:322-323`, `:353-354`, `:376-379`).
  - Inside the daemon, the Codex image backend refreshes through
    `CodexToken.get_token` from a tool process
    (`tools/media/backends/codex_image.ex:273-289`), not through the Codex
    `TokenManager`. It refreshes only within 10 seconds of expiry
    (`token_expiry.ex:4-10`). No Codex manager runs at all when Codex is not
    routable (`application.ex:362-364`); then two image generations after an
    idle period, for example from parallel subagents, both send the expired
    entry's token.
- **Fix:** one refresher per profile at a time, across processes and VMs.
  `Store.with_profile_lock/3` (`store.ex:158-162`) wraps
  `Plugins.Dist.Lock.with_lock` on `auth.json.<base64 profile>.lock` (the name
  is encoded, so no `/` or `..` in an operator-set profile name leaves the auth
  file's directory): 100 attempts 100 ms apart, broken as stale after 120 s.
  It is taken around `TokenManager.do_refresh` (read, refresh, status write;
  `token_manager.ex:285-310`), `TokenSupervisor.direct_refresh`
  (`token_supervisor.ex:321-330`) and, only once the entry it read is due,
  `CodexToken.get_token`, which then reads again and refreshes only if still
  due (`codex_token.ex:112-126`). The manager's own state and token file change
  after the lock is released. A busy lock is a transient, logged error, never a
  refresh from memory. `RefreshClient` states its per-attempt bounds (pool 5 s,
  connect 10 s, receive 15 s; `refresh_client.ex:34-47`, `:174-189`), so a live
  refresh (about 107 s with two store-lock waits) ends before its lockfile
  looks stale, unless the wall clock jumps mid-refresh (a system sleep or a
  clock step; see "Lock staleness"); a test holds that bound.
- **Impact (before the fix):**
  - Codex: the session was revoked, and the operator had to sign in again.
  - Other rotating providers: the loser's status write put the consumed R0 back
    over the winner's R1, and the winner's next refresh re-read R0 and was
    quarantined too, even for a provider that only rejects a reused token.

### TOKEN-3: a response lost after rotation leads to a consumed token being sent
- **Severity:** low. This is inherent to rotating refresh tokens: once the
  response is lost, nothing can recover the new token.
- **Status:** accepted by design. No Fermix change can recover a rotation whose
  response never arrived: without the retry, the next refresh re-reads R0 from
  disk and draws the same 4xx (`token_manager.ex:307-308`, `:492-496`). The
  retry exists for transport errors before the provider acts (a refused or
  closed connection, the common case), which the model leaves out as harmless,
  and for a provider with a grace window it is what saves the session.
  `RefreshClient` keeps its receive wait at Req's 15 s default
  (`refresh_client.ex:7-20`), so Fermix's own timeout does not make this more
  likely.
- **Check:** 10 (4 states), still violated.
- **Counterexample:** p1's manager sends R0, the provider rotates to R1, and the
  response is lost. `RefreshClient` retries with R0. The provider revokes the
  session, and the manager refuses from then on.
- **Code:**
  - `RefreshClient` retries a transport error or a 5xx with the same refresh
    token, up to three attempts (`refresh_client.ex:31`, `:94-97`, `:102-105`;
    `:156-159`, `:164-167`).
  - Req does not retry the POST itself: its default `retry: :safe_transient`
    covers GET and HEAD only.
- **Impact:** the session is revoked on the retry, about 350 ms later, instead
  of at the next refresh.
- **Confidence:** this assumes the provider has no grace window for reusing a
  token it has just consumed. The code does not say.

### TOKEN-4: the logged-out profile's own refresh writes its entry back
- **Severity:** low. A sign-out had to coincide with a refresh of that profile.
- **Status:** fixed (d514e149).
- **Checks:** 12 (plugin logout) and 13 (provider sign-out) now hold; 22 and 24
  show they need `ProfileLock`, 23 and 25 that they need `RefusesMissingEntry`
  (before the fix: both violated in 8 states). Both use one profile, so only
  that profile's own refresh can write.
- **Counterexample (before the fix):** the manager's refresh gets R1, and its
  `Store.write` reads `auth.json`. The logout deletes the entry. The refresh
  then renames its copy, which still has the entry. The logout then stops the
  manager (check 12) or forgets its tokens (check 13), but the entry is back.
- **Code (693970b7):**
  - The plugin logout deletes, then calls `stop_profile`
    (`plugins/auth.ex:71-72`), which kills the manager only after the delete. A
    rename that lands in between stays.
  - A refresh that starts in that gap also wrote the entry back: `latest_entry`
    found no entry and fell back to the in-memory tokens
    (`token_manager.ex:421`, `:425-442`), and `put_provider` created the entry
    (`store.ex:359`).
  - The provider sign-out deletes, then calls `forget`
    (`management/auth.ex:137-138`, `:371-379`). `forget` is a `GenServer.call`
    (`token_manager.ex:80`), so it waits behind any refresh callback already
    running, and that refresh's write always landed first.
- **Fix:** `Store.delete_provider` takes the profile lock before its store lock
  (`store.ex:132-139`), so a delete waits for the profile's refresh in flight
  and deletes after it. A refresh that starts after the delete refuses
  (TOKEN-5's fix). A profile lock still busy after 10 s fails the logout loudly
  with nothing deleted (`{:error, :profile_busy}`). Every sign-in and import
  takes the same lock, with the same wait, before it spends anything, and holds
  it through its write: the code exchange of the Codex, xAI and plugin flows
  (`codex_login.ex:40-51`, `xai_login.ex:50-58`, `plugins/auth.ex:195-206`,
  through `OAuthFlow`'s `:redeem`), the Codex import's refresh of the Codex
  CLI's token (`codex_import.ex:38-56`), and the write alone for the Claude
  Code import and a setup token (`anthropic_login.ex:104-121`). So an
  in-flight refresh cannot undo a fresh sign-in either, and a busy profile
  refuses the sign-in with the code or the Codex CLI's token unspent, inside
  the app's job budget; each surface says to try again shortly
  (`Store.busy_sentence/0`). Each reload runs after the lock is released.
- **Impact (before the fix):** the account was back in `auth.json`. After a
  plugin logout, the `Runtime.reload` right after it could serve it again at
  once. After a provider sign-out, the daemon refused it in memory until it
  restarted, then served it again.

### TOKEN-5: a logout from the CLI is undone by the daemon's next refresh
- **Severity:** medium. No race was needed: it happened whenever the daemon had
  a live manager for the profile and refreshed before it restarted.
- **Status:** fixed (d514e149).
- **Check:** 14 now holds; 26 shows it needs `RefusesMissingEntry` (before the
  fix: violated in 8 states).
- **Counterexample (before the fix):** `fermix plugins auth logout` deletes p2's
  entry in a CLI VM, and its `stop_profile` does nothing. Later, p2's manager in
  the daemon refreshes. The disk read finds no entry, so the manager refreshes
  with its in-memory token, and `Store.write` creates the entry again.
- **Code (693970b7):**
  - The `fermix plugins` verbs run tree-less (`plugins_command.ex:5-8`), so
    `stop_profile` finds no registry and returns `:ok`
    (`token_supervisor.ex:142`, `:152-153`).
  - `auth_logout` (`plugins_command.ex:250-261`) does not ask the daemon to
    re-apply, unlike the verbs that call `apply_to_daemon` (`:469-486`).
  - `fermix auth logout` only deletes, then tells the operator to restart the
    daemon (`auth_command.ex:216-225`).
  - `latest_entry`'s fallback to the in-memory entry when the read fails
    (`token_manager.ex:421`) refreshed a deleted profile, and `put_provider`
    recreated the entry (`store.ex:359`).
- **Fix:** `latest_entry` returns the read's result, and `entry_from_state` is
  gone (`token_manager.ex:492-496`). A missing auth file or entry means a
  signed-out profile, because a manager's tokens only ever come from disk: the
  manager drops its tokens through the same `drop_tokens/1` as `forget`, which
  also deletes its plugin child's token file, logs a warning, and sends and
  writes nothing (`token_manager.ex:323-324`, `:372-396`). Any other read error
  is transient and keeps the state.
- **Impact (before the fix):** the operator was told the account was logged
  out; the daemon wrote it back to `auth.json` at its next refresh.

### TOKEN-6: after a CLI logout the daemon keeps serving the account until its next refresh
- **Severity:** low. The entry stays deleted (TOKEN-5's fix), but the daemon's
  manager served the in-memory access token, and a plugin child kept its
  projected token file, until the manager's next refresh or a restart. The
  proactive refresh runs five minutes before expiry (`token_manager.ex:30`,
  `:263-273`), so this lasted up to one token lifetime.
- **Status:** fixed (d514e149). The owner decided that a CLI
  logout hands the logout to a running daemon.
- **Checks:** 27 now holds; 28 shows it needs `CliLogoutReachesDaemon` (before
  the fix: 27 violated in 4 states). 29 shows the logout still sticks with
  refreshes of both profiles running beside it, and 30 that TOKEN-5's refusal
  is what keeps it there. Rule `LogoutStopsServing` is a proposed
  rule, taken from `forget`'s own doc at `token_manager.ex:68-76`.
- **Counterexample (before the fix):** the CLI logout reads and deletes p2's
  entry, and its `stop_profile` does nothing. The logout is done, and p2's
  manager is still serving.
- **Code (693970b7):**
  - The CLI verbs run tree-less and never reached the daemon
    (`plugins_command.ex:5-8`, `:250-261`; `auth_command.ex:216-225`).
  - The manager learns of the deletion only when it next reads the entry, at
    its next refresh (`token_manager.ex:314-325`).
- **Fix:** both CLI logouts keep their local logout unchanged, then tell a
  running daemon to let go of the profile. This is the shape of
  `apply_to_daemon` (`plugins_command.ex:484-501`): the CLI makes the change on
  disk itself every time, then notifies the daemon, and "no daemon" is the
  authoritative `:not_running` answer.
  - **The CLI side.** After the delete, `fermix plugins auth logout` and
    `fermix auth logout` send `auth_forget` with the profile
    (`plugins_command.ex:262`, `:504-529`; `auth_command.ex:223-241`,
    `:267-283`; `cli/daemon/client.ex:61-74`). Both also send it when the entry
    was already gone (`auth_command.ex:295-298`, `plugins_command.ex:269-275`),
    so rerunning the logout after a failed notice reaches the daemon.
  - **No daemon.** The output is exactly the local logout's.
  - **The daemon answers ok.** One more stderr line.
  - **The daemon answers with an error, or not in time.** The verb exits 1
    with a sentence saying the local entry is already removed and asking for a
    restart of the daemon (from the Fermix app, or `fermix restart` for a
    daemon the operator runs).
  - **The daemon side.** The daemon validates the profile, then runs
    `TokenSupervisor.forget_signed_out/1` (`cli/daemon.ex:562`, `:787-817`;
    `token_supervisor.ex:132-170`).
    - It reuses `forget` (`drop_tokens`: tokens cleared, refusal set, and the
      plugin child's token file deleted), then `stop_profile` for a
      `TokenSupervisor` child. The next use of that profile then starts a
      fresh manager from `auth.json`, so a later sign-in is served rather than
      refused.
    - The top-level Codex manager is only forgotten, as the in-daemon sign-out
      does (`management/auth.ex:371-379`).
    - A forget that exits (for example, a manager waiting on the profile lock
      past the call's 5 s) is logged and answered as an error, never "ok".
      A manager that stopped between the lookup and the call (`:noproc`)
      held nothing, so that is answered "ok" (`token_supervisor.ex:164-170`).
  - **Why a notice rather than the management methods.** `plugins.disconnect`
    and `auth.logout` are whole logouts, not notices, and neither works in
    either role:
    - *Sent after the CLI's own logout,* `plugins.disconnect` fails on the
      missing entry. `auth.logout` re-reverts the route and is refused with
      `external_change` for anthropic and xai, because the CLI has just written
      `config.toml` (`setup/restart_state.ex:143-149`).
    - *Sent instead of the local logout whenever a daemon answers,* they would
      make the verb do different things depending on whether a daemon runs.
      `plugins.disconnect` would clear an api-key plugin's keychain secret,
      which this verb never does, and `auth.logout` cannot tell "logged out"
      from "already logged out".

    The notice is a v0 method, like `plugins_apply`, because it is the CLI's
    own hook into its daemon and not part of the app's v1 contract.
- **Impact (before the fix):** the operator was told the account was logged
  out while the daemon kept calling as it for a while. Production macOS users
  sign out through the app, which runs in the daemon, so this affected Linux
  and CLI users and dev.
- **Left as is:**
  - A CLI plugin logout does not reload the daemon's plugin runtime. The
    plugin's tools answer "not connected" from the next call (a fresh manager
    has no token), and the plugin list the agent sees catches up at the
    daemon's next plugin reload.
  - The route revert of `fermix auth logout` for anthropic and xai still
    reaches the daemon only on restart, which the verb says.

## Open question for the owner

**Does importing a Codex CLI sign-in end the Codex CLI's session, and then
Fermix's?** Everything except the provider's reuse rule is confirmed in the
code:
- The import is the app's live path: the management `auth.import` for
  `codex_cli` runs `CodexImport.import_tokens` (`management/auth.ex:275-279`).
- The import refreshes the Codex CLI's refresh token once and stores the new
  pair only in Fermix's `auth.json` (`codex_import.ex:33-56`).
  `~/.codex/auth.json` is only read (`:66-76`), never rewritten, so the Codex
  CLI keeps the token Fermix just consumed.
- Both use the same OAuth client id (`refresh_client.ex:26`), so they share one
  session.

Under the rule the code states for Codex (`token_manager.ex:487-491`), the Codex
CLI's next refresh presents a consumed token, and the provider revokes the
session that Fermix now depends on. This is not modelled, because
`~/.codex/auth.json` belongs to another application. The one thing to verify is
whether OpenAI really revokes the session on reuse, and whether it allows a
grace window.

## Outside this model

- **A provider sign-out can still time out behind a lock wait.** `forget` is a
  `GenServer.call` with the default 5-second timeout (`token_manager.ex:80`).
  The profile lock mostly closes the old case: the delete waits for the
  refresh in flight, so `forget` normally finds the manager idle. It can still
  meet a manager that is itself waiting up to 10 s for the profile lock (held
  by a CLI refresh, say); the management caller then exits first, the socket
  turns that into `internal_error` (`cli/daemon.ex:315-325`), and
  `revert_route` (`management/auth.ex:139`) never runs.
- **Lock staleness.** The model never breaks a lock. A lockfile is broken only
  once it looks older than its stale threshold, and each threshold exceeds its
  locked section (see Assumptions). That bound is in wall-clock time: the age
  is the lockfile's mtime against `System.system_time` (`lock.ex:183-191`). A
  system sleep (a closed lid) or a clock step while a holder is live, for
  example mid-refresh, can make its lockfile look stale on wake. A second
  refresher that contends right then (the Codex image backend or a CLI)
  breaks the lock and can present the
  refresh token the woken holder is still consuming. It is rare, and only a
  monotonic, holder-aware lock would rule it out. The stale break is also
  check-then-remove (`lock.ex:183-191`), so right after a holder dies, two of
  three or more contenders could each come to hold the lock; `SingletonLock`
  documents the same limit. A VM killed while holding a profile lock blocks
  that profile's refreshes, sign-ins, imports and logouts for up to 120 s;
  they fail loudly meanwhile (`:profile_busy`, nothing spent).
- **A wedged filesystem exits the caller.** `Lock.with_lock` bounds its own
  calls to the lock owner: `acquire` gets the attempt budget plus 5 s, and
  `release` gets 5 s (`lock.ex:107-114`, `:196-201`). A filesystem slow enough
  to outlast them exits the caller instead of returning a tuple; inside the
  Codex manager that restarts every later child of the top-level
  `:rest_for_one` tree. `Store` does not catch the exit (Rule 7).
- **A refresher that waited for the profile lock refreshes again.** Only
  `CodexToken` re-checks under the lock that the entry is still due
  (`codex_token.ex:120-126`). A manager (`token_manager.ex:285-290`) or a
  tree-less refresh (`token_supervisor.ex:321-329`) that waited out another
  refresher's rotation, or a sign-in's write, rotates the fresh token once
  more. It reads under the lock, so it never presents a consumed token and
  `NeverSendConsumed` holds; the cost is one more token-endpoint round trip and
  one more TOKEN-3 window. The model already lets a refresh start at any time,
  so it covers this. A re-check could skip the extra rotation on the on-use
  trigger only: the proactive timer fires five minutes before expiry
  (`token_manager.ex:30`), outside `refresh_due?`'s 10-second window
  (`token_expiry.ex:4-10`), so a due check there would skip every proactive
  refresh.

- **A CLI logout's notice can meet a newer sign-in.** Suppose the app signs
  the same account in again between the CLI's delete and the daemon's
  `auth_forget`. The notice then drops the new tokens too. A `TokenSupervisor`
  child recovers at its next use, because it is stopped and its successor
  reads `auth.json`. The Codex manager stays refused until the next reload or
  restart. The window is one local socket round trip. The model has no second
  sign-in, so it cannot show this.
- **A token call queued on a stopped child exits its caller.**
  `forget_signed_out` stops a `TokenSupervisor` child, the `anthropic_oauth`
  and `xai_oauth` profiles included. `TokenManager` does not trap exits, so a
  `get_token` call queued on that manager at that moment exits in its caller
  (a provider request, `providers/anthropic/messages.ex:582`,
  `providers/xai/responses.ex:229`) instead of answering
  `{:error, :auth_invalidated}`. The window is one message, and a plugin
  logout's `stop_profile` (`plugins/auth.ex:72`) has always had it. A manager
  that stopped itself after replying would not close it: calls still queued
  when any process stops exit the same way. The model has no callers.
- **A daemon older than the CLI** answers `auth_forget` with `unknown method`.
  The CLI reports that and exits 1, with the entry already removed, and asks
  for a restart onto the new engine.

## Assumptions

- Every modelled profile follows the Codex rule: it rotates on every refresh,
  revokes the session on reuse, and has no grace window. The code states this
  for Codex only (see above). TOKEN-2's damage for other profiles does not
  depend on revocation.
- `File.rename` within one directory is atomic, and a later read sees it. A
  rename already queued in the kernel `file_server` when `stop_profile` kills
  the manager still lands after the kill (`File.rename` is a `file_server`
  call), and the model's kill drops it. The fixed design no longer depends on
  that ordering: with the profile lock and the refusal, no refresh of the
  logged-out profile is between its read and its rename when `stop_profile`
  runs. Were one there, `Lock.Owner`'s `File.rm` of its lockfile goes through
  the same `file_server` after the queued rename, so the lock is released only
  once the rename has landed (a practical ordering, not one Erlang guarantees
  across processes).
- Each lock's stale threshold exceeds the section it covers, so a live holder's
  lock is not broken, unless the wall clock jumps under it (a system sleep or a
  clock step; see "Lock staleness"). The store lock covers milliseconds of
  local I/O against 5 s. The profile lock covers at most one refresh, about
  107 s (`RefreshClient.worst_case_ms/0`, three attempts at 30 s plus 1.05 s of
  sleeps, plus two 8 s store-lock waits), or one sign-in, about 98 s (the code
  exchange, the account lookup and a region probe, each one 30 s attempt with
  no retry, `RefreshClient.request_bounds/0`, plus one 8 s store-lock wait),
  against 120 s. The Codex import's section is one refresh and one write. A
  lockfile's age is
  read from its whole-second mtime, so it can look up to a second older; the
  bounds keep that second of margin, and `store_test.exs` ("lock bounds")
  holds them.
- A refresh may start at any time. Expiry, the proactive timer and the
  10-second due window are not modelled. They decide how often the overlaps in
  TOKEN-1 and TOKEN-2 would happen, but not whether they can.
