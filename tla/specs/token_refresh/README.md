# token_refresh: OAuth refresh and `auth.json`

Models how Fermix rotates OAuth refresh tokens and stores them in
`~/.fermix/auth.json`. The daemon runs one `TokenManager` GenServer per auth
profile, a child of `TokenSupervisor` started on the profile's first use
(`token_supervisor.ex:228-256`). A tree-less CLI VM refreshes a profile
directly, with no manager (`token_supervisor.ex:212-218`, `:303-320`). Every
refresher persists through `Store.write`, which reads the whole file and then
renames a new one over it (`store.ex:150-156`, `:427-435`, `:625-639`). The
model therefore keeps the file as one map: a write is never torn, and the last
rename wins. After a 4xx, every refresher writes back the entry it read when
its refresh began (`mark_reauthorization_required`). Logout deletes the entry,
then has the profile's manager forget its tokens and stops it (plugin logout,
`plugins/auth.ex:66-89` → `TokenSupervisor.forget_signed_out`,
`token_supervisor.ex:131-153`) or only forgets them (the provider sign-out of
anthropic and xai, `management/auth.ex:147-154`, `:390-394`). A logout from a
tree-less CLI VM deletes the entry the same way, then has a running daemon let
go of the profile over the control socket (`auth_forget`,
`cli/daemon.ex:852-882` → `TokenSupervisor.forget_signed_out`).

OpenAI Codex signs in with ChatGPT, under the `chatgpt` profile
(`store.ex:230-240`). That registration outlives a sign-out, so the sign-out
writes instead of deleting: under the profile lock it revokes the session
upstream and writes the entry back with no token, then calls
`TokenSupervisor.forget_signed_out` (`auth/chatgpt/logout.ex:35-49`, `:71-86`).
It is reached through `ChatGPT.logout` from the app's `auth.logout`
(`management/auth.ex:381-388`), `fermix auth logout` (`auth_command.ex:284-310`)
and the web setup. Every reader treats an entry with no token as gone:
`Store.read` refuses it as `:missing_access_token` (`store.ex:345-354`), and a
manager maps that to signed out exactly as it maps a deleted entry
(`token_manager.ex:320-328`). So the model's delete, then `forget_signed_out`
(the plugin logout) covers it. The revoke is not modelled: it runs under the
profile lock, so no refresh of the profile is in flight, and after the write no
stored entry holds the revoked token. Its refresh (`auth/chatgpt/refresh.ex`)
runs under the same profile lock as every other, never before the provider's
`earliest_refresh_at` (`:39-48`; a refresher that waits is a step the model
already allows), and quarantines on the provider's terminal codes,
`refresh_token_reused` among them (`:33-34`, `:91-92`), as the 4xx rule below
says. Any other 4xx keeps the stored tokens and writes nothing (`:94-97`).

Two cross-VM lockfiles (`FermixCore.Plugins.Dist.Lock`) order those writers
(`store.ex:11-41`):
- the store lock, `auth.json.lock`, around every `Store.write` and
  `Store.delete_provider` (`store.ex:150-156`, `:166-174`);
- one profile lock per profile, `auth.json.<base64 profile>.lock`, around one
  refresh from its read of the entry to its write (`token_manager.ex:285-288`,
  `token_supervisor.ex:314-319`), around a delete (`store.ex:166-174`) and
  ChatGPT's sign-out (`chatgpt/logout.ex:40-43`), and around a sign-in or
  import from before it spends anything to its write (`store.ex:176-197`;
  `chatgpt/login.ex:73-90`, `xai_login.ex:46-58`, `plugins/auth.ex:190-207`,
  `anthropic_login.ex:101-121`). Every taker waits the same 10 s, and a lock
  still busy after it is `{:error, :profile_busy}` with nothing spent.

The profile lock is always taken first. A manager whose stored entry is gone
drops its tokens instead of refreshing them (`token_manager.ex:320-328`,
`:377-405`).

The provider rotates the refresh token on every refresh and revokes the session
when a consumed token comes back. The code allows that of any provider ("a
provider may revoke the whole session when a rotated (consumed) refresh token
is reused", `token_manager.ex:496-500`), and ChatGPT's refresh reads OpenAI's
`refresh_token_reused` as terminal (`chatgpt/refresh.ex:33-34`). It says X's
refresh tokens are "single-use and rotated on every refresh"
(`oauth_providers.ex:289-290`), but not what X does on reuse, and it says
nothing about rotation for Anthropic, xAI or the other plugin providers. A
provider that returns no new refresh token keeps the old one
(`token_manager.ex:578`), so it can never be sent a consumed one. For every
rotating provider the Fermix side is the same: a consumed token draws a 4xx,
which Fermix treats as permanent, and it quarantines the grant until a new
sign-in (`token_manager.ex:348-360`, `:370-375`). A 408 or a 429 is not a
verdict on the grant: `RefreshClient` retries it like a 5xx and never
quarantines on it (`refresh_client.ex:43-49`).

Most checks use two profiles:
- `p1` is a profile that both its manager and a tree-less CLI VM refresh
  (`CliProfile`).
- `p2` is a plugin profile, and the user logs out of it.

Each refresher may start two refreshes. Tokens are written R0, R1, … below.

**Environment switches** (set per check):
- `CliRefreshes`: a tree-less CLI VM refreshes `CliProfile` directly
  (`fermix plugins auth refresh`, or `fermix setup` and `fermix doctor` with no
  daemon tree). Inside the daemon only the managers refresh.
- `RefreshesCanOverlap`: one process's refresh or logout can be in flight while
  another process's is. This is always true of the real code. Off, it is a
  global mutex that no code provides.
- `ResponseCanBeLost`: the provider rotates, then its response is lost: Req's
  receive timeout, a closed connection, or a 5xx, a 408 or a 429 after the
  rotation.
- `UserCanLogout`: the user logs out of `LogoutProfile`.
- `LogoutFromCli`: that logout runs in a tree-less CLI VM
  (`fermix plugins auth logout`, `fermix auth logout`) while the daemon runs.
  With no daemon running there is no manager to reach, and nothing to model.
- `SignOutForgets`: that logout is the provider sign-out of anthropic or xai
  (delete, then `forget`), not the plugin logout (delete, then
  `forget_signed_out`: forget, then `stop_profile`), which ChatGPT's sign-out
  also ends in. The provider sign-out goes on to `forget` even when the entry
  is already gone (`management/auth.ex:399-408`). The in-daemon plugin logout
  stops at the failed delete (`plugins/auth.ex:70-72`, `:84-88`). ChatGPT's
  sign-out writes nothing when it finds no registration and goes on to
  `forget_signed_out` (`chatgpt/logout.ex:71-77`). Both CLI logouts go on to
  their notice (`auth_command.ex:289-291`, `:326-330`, `:389-392`;
  `plugins_command.ex:269-273`). Every entry starts stored, and with
  `MergesOnWrite` on (as in every check with `LogoutFromCli`) only the logout
  deletes one, so a CLI logout never finds its entry already gone.

**Mechanism switches** (`TRUE` is the real code; each is switched off by at
least one check):
- `ReadsDiskBeforeRefresh`: `latest_entry` re-reads `auth.json` before each
  refresh (`token_manager.ex:501-505`).
- `OneCallbackPerManager`: a profile has one manager process, and it runs one
  callback at a time. `TokenSupervisor` registers children in a Registry with
  `keys: :unique` (`token_supervisor.ex:205`) and answers `{:already_started, _}`
  with the running one (`:253`). A `TokenManager` takes the name its
  supervisor gives it and has no default one (`token_manager.ex:32-36`). The
  BEAM mailbox then queues concurrent callers. Switching it off models a second
  process refreshing the same profile beside the manager. That process stands
  for those concurrent callers, so `RefreshesCanOverlap` does not restrain it.
  The profile lock subsumes this mechanism, so it is load-bearing only in check
  16, which has the profile lock off.
- `MergesOnWrite`: `Store.write` re-reads the file and replaces only its own
  entry (`store.ex:427-435`, `:519-550`).
- `LogoutReachesManager`: logout reaches the profile's live manager: the plugin
  logout and ChatGPT's sign-out have it forget its tokens and stop it
  (`plugins/auth.ex:73`, `chatgpt/logout.ex:46` →
  `token_supervisor.ex:149-153`), the provider sign-out of anthropic and xai
  has it forget them (`management/auth.ex:392`, `:417` →
  `token_supervisor.ex:123-129` → `token_manager.ex:196-199`).
- `PluginLogoutForgets`: the in-daemon plugin logout calls
  `forget_signed_out`, the same call as a CLI logout's notice, so the manager
  forgets its tokens, which deletes its plugin child's access-token file,
  before it is stopped (`plugins/auth.ex:73` → `token_supervisor.ex:149-153`;
  `drop_tokens`, `token_manager.ex:393-405`). Off, it calls `stop_profile`
  alone (`token_supervisor.ex:172-187`), as it did until this switch was
  added (ea1a12b5): the manager dies without a
  `terminate/2`, mid-callback if one is running, and the token file stays on
  disk until the next boot sweep.
- `StoreLock`: `Store.write` and `Store.delete_provider` hold `auth.json.lock`
  from their read to their rename (`store.ex:150-156`, `:166-174`,
  `:603-623`).
- `ProfileLock`: a refresh holds its profile's lock from its read of the entry
  to its write, in the manager (`token_manager.ex:285-288`) and the tree-less
  direct refresh (`token_supervisor.ex:314-319`); `Store.delete_provider` takes
  it before its store lock (`store.ex:166-174`), and ChatGPT's sign-out holds
  it from its read of the entry through its write (`chatgpt/logout.ex:40-43`).
  A sign-in holds it from before its code exchange to its write; that is folded
  (see the spec header).
- `RefusesMissingEntry`: a manager whose read finds no entry (no auth file, no
  entry for the profile, or ChatGPT's entry with no token) drops its tokens, as
  `forget` does, and sends and writes nothing (`token_manager.ex:320-328`,
  `:377-405`). Off, it refreshes the in-memory copy, which is what
  `entry_from_state` did before the fix.
- `CliLogoutReachesDaemon`: after its delete, or ChatGPT's write, a CLI logout
  sends a running daemon `auth_forget` for the profile (`plugins_command.ex:262`,
  `:504-529`; `auth_command.ex:284-310`, `:317-335`, `:361-377`;
  `cli/daemon/client.ex:60-74`). The daemon has the profile's manager forget
  its tokens, which also deletes its plugin child's token file, then stops it
  (`cli/daemon.ex:628`, `:852-882`; `token_supervisor.ex:131-153`). Off, the
  CLI logout reaches no manager. That is also the state a daemon leaves when
  it answers the notice with an error, which the CLI reports by exiting
  non-zero; checks 14 and 26 model that case.

The atomic rename (`store.ex:631`) is not a switch. The model writes the whole
map by construction, and no property here is about a torn file. Neither is the
tmp it renames: it is made private before its bytes land, and filled through
the descriptor that created it (`store.ex:641-657`), and a tmp a killed VM
left is removed by the next write or delete under the store lock every tmp
writer holds (`store.ex:659-701`), so neither touches the map. A writer whose
store lock was broken as stale (see "Lock staleness") and whose tmp the next
holder removes fails its chmod or its rename; its bytes never reach a
re-created file.

## What holds

**With overlap allowed (the real code), every rule holds except the accepted
finding:** checks 07–09, 11–15, 27, 29 and 31. Checks 14 and 27 need no overlap
to reach their state; 29 is 27 with overlap and the CLI refreshing, and 31 is
29 with the plugin logout run in the daemon. Each rests on the mechanism named
by its `needs` check:

| Holds | Rule | Needs (check) |
|---|---|---|
| 07 two managers write at once | `NoLostRotation` | `StoreLock` (17) |
| 08 the same, then a re-read | `NeverSendConsumed` | `StoreLock` (18) |
| 09 CLI and manager of one profile, beside another | `NeverSendConsumed` | `ProfileLock` (20) |
| 11 logout beside another profile's write | `LogoutSticks` | `StoreLock` (19) |
| 12 plugin logout or ChatGPT sign-out during the profile's refresh | `LogoutSticks` | `ProfileLock` (22), `RefusesMissingEntry` (23) |
| 13 anthropic or xai sign-out during the profile's refresh | `LogoutSticks` | `ProfileLock` (24), `RefusesMissingEntry` (25) |
| 14 CLI logout whose notice did not land | `LogoutSticks` | `RefusesMissingEntry` (26) |
| 15 CLI and manager of one profile, after a 4xx | `NoLostRotation` | `ProfileLock` (21) |
| 27 CLI logout with the daemon running | `LogoutStopsServing` | `CliLogoutReachesDaemon` (28) |
| 29 the same, beside both profiles' refreshes | `LogoutSticks` | `RefusesMissingEntry` (30) |
| 31 plugin logout in the daemon, beside both profiles' refreshes | `LogoutDropsTokenFile` | `PluginLogoutForgets` (32) |

Check 10 (TOKEN-3, accepted) stays violated.

Checks 14 and 26 set `CliLogoutReachesDaemon` off: they are a CLI logout whose
notice the daemon refused, where the refusal at the next refresh is what keeps
the logout. The refusal matters with the notice on, too. Between the CLI's
delete and the daemon's forget, the manager can still refresh. Check 30, which
is check 29 with `RefusesMissingEntry` off, breaks `LogoutSticks` in 8 states:
p2's manager refreshes from memory in that gap and writes the entry back, and
the notice then stops a manager whose entry is already restored.

Check 32, which is check 31 with `PluginLogoutForgets` off, breaks
`LogoutDropsTokenFile` in 4 states: the plugin logout reads and deletes p2's
entry, then `stop_profile` kills p2's manager, and the helper's access-token
file stays on disk with a live token. That was the in-daemon plugin logout
until this change (ea1a12b5); it now calls
`forget_signed_out`, as a CLI logout's notice does, so checks 12 and 22-23
also run the forget before the stop. `LogoutDropsTokenFile` is a proposed
rule, from `TokenFile`'s moduledoc ("deletes it the moment the grant stops
being servable") and the self_knowledge plugins reference.

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
profiles), 29 in 58,168 (three profiles), and 31 in 58,168 (three profiles,
against all five rules). Check 27 was also run with overlap and the CLI
refreshing, against all four rules (`NeverSendConsumed`,
`NoLostRotation`, `LogoutSticks`, `LogoutStopsServing`): with the plugin
profile logged out, 1,367 states (4,924 with three refreshes per refresher;
check 29 runs this configuration against `LogoutSticks`); with the profile the
CLI refreshes logged out instead, as `fermix auth logout` signs out the
`chatgpt` profile a CLI also refreshes, 989. All hold. The model has one CLI
actor. A second CLI VM is one more refresher of the same shape, and it takes
the same profile lock.

## Plan hypotheses

These are the "Expected" entries of `docs/design/TLA_PLUS_MODELS.md` §4.2.

- **Lost update between two profiles: confirmed, TOKEN-1, fixed.** `Store`'s
  moduledoc used to say "callers are serialized in-process: TokenManager is a
  singleton GenServer", but each profile has its own GenServer. The CLI VM,
  sign-ins and logouts are further writers. The atomic rename kept the file
  whole but did not prevent a lost update. The moduledoc now describes the
  store lock that does (`store.ex:11-32`).
- **Reuse after an ambiguous transport retry: confirmed, TOKEN-3, accepted.**
  The retry is not the root cause: once the response is lost, the only token
  Fermix holds is consumed.
- **CLI and daemon refreshing at the same time: confirmed, TOKEN-2, fixed.**
  For a profile other than Codex, the loser's status write also erased the
  winner's new token. The daemon could race on its own, through the Codex
  image backend, which has since been removed.
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

At `693970b7` the Codex profile had its own path: a top-level `TokenManager`, a
`CodexToken` refresher used by the CLI and by the Codex image backend, and no
status write after a 4xx. All three went with the Codex-client sign-in
(9336d149). Every profile now follows the `TokenSupervisor` rules the model
describes, and the **Fix** bullets cite the code as it is now.

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
    it read, then `atomic_write` (`store.ex:105-107`, `:315-326`, `:395-420`,
    `:459-474`). It took no lock (`store.ex:9-12`). `delete_provider` had the
    same shape (`store.ex:112-120`).
  - Each profile's manager is its own process (`token_supervisor.ex:213-225`;
    for Codex, `application.ex:173`), so two managers' writes interleave. A CLI
    VM's writes, sign-ins and logouts interleave with them too.
  - `latest_entry` prefers the disk entry over the manager's in-memory token
    (`token_manager.ex:439-441`), so the lost update became a reuse. A daemon
    restart does the same, because `init` loads the disk entry.
- **Fix:** `Store.write` and `Store.delete_provider` run their read, merge and
  rename under `auth.json.lock` (`store.ex:150-156`, `:166-174`, `:603-623`):
  80 attempts 100 ms apart, broken as stale after 5 s. The wait outlasts the
  stale threshold, so a dead VM's lockfile never fails a live writer. Reads
  take no lock. A lock that is not taken (busy past the wait, or a lockfile
  that cannot be created) is a tuple, not a raise (`store.ex:597-623`),
  because a raise inside a token manager would crash it mid-refresh and lose
  the profile's state. Only a wedged filesystem, which makes the lock owner's
  own calls time out, still exits the caller (see "Outside this model").
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
  - Check 09, p1 then the Codex profile: p1's manager reads R0 and sends it,
    and the provider rotates to R1. Before the manager's rename, a CLI refresh
    of p1 reads R0 from `auth.json` and sends it. The provider revokes the
    session.
  - Check 15, one plugin profile: the manager reads R0, gets R1, and starts its
    `Store.write`. `fermix plugins auth refresh` reads R0, and the manager
    renames R1. The CLI sends R0 and gets a 4xx. Its status write then renames
    the R0 entry it read at the start over the manager's R1.
- **Code (693970b7):**
  - `latest_entry` re-read the disk (`token_manager.ex:439-443`), which only
    helps once the other refresh has renamed its result. Nothing coordinated a
    refresh still in flight. The CLI VM has no manager
    (`token_supervisor.ex:181-184`, `:198`, `:209`) and reads the file itself
    (`:273`; `codex_token.ex:19-20`).
  - After a 4xx, any profile but Codex runs `mark_reauthorization_required`, a
    `Store.write` of the entry read when the refresh began
    (`token_manager.ex:303`, `:326`, `:559-561`; `token_supervisor.ex:299-300`,
    `:323-324`, `:363-364`, `:386-389`).
  - Inside the daemon, the Codex image backend refreshes through
    `CodexToken.get_token` from a tool process
    (`tools/media/backends/codex_image.ex:273-289`), not through the Codex
    `TokenManager`. It refreshes only within 10 seconds of expiry
    (`token_expiry.ex:4-10`). No Codex manager runs at all when Codex is not
    routable (`application.ex:362-364`); then two image generations after an
    idle period, for example from parallel subagents, both send the expired
    entry's token.
- **Fix:** one refresher per profile at a time, across processes and VMs.
  `Store.with_profile_lock/3` (`store.ex:191-197`) wraps
  `Plugins.Dist.Lock.with_lock` on `auth.json.<base64 profile>.lock` (the name
  is encoded, so no `/` or `..` in an operator-set profile name leaves the auth
  file's directory): 100 attempts 100 ms apart, broken as stale after 120 s.
  It is taken around `TokenManager.do_refresh` (read, refresh, status write;
  `token_manager.ex:284-309`) and `TokenSupervisor.direct_refresh`
  (`token_supervisor.ex:312-320`), the only two refreshers. The manager's own
  state and token file change after the lock is released. A busy lock is a
  transient, logged error, never a refresh from memory. `RefreshClient` states
  its per-attempt bounds (pool 5 s, connect 10 s, receive 15 s;
  `refresh_client.ex:39-41`, `:51-60`, `:158-173`), so a live refresh (about
  107 s with two store-lock waits) ends before its lockfile looks stale,
  unless the wall clock jumps mid-refresh (a system sleep or a clock step; see
  "Lock staleness"); a test holds that bound.
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
  disk and draws the same 4xx (`token_manager.ex:306-307`, `:501-505`). The
  retry exists for transport errors before the provider acts (a refused or
  closed connection, the common case) and for a 408 or a 429, which the model
  leaves out as harmless, and for a provider with a grace window it is what
  saves the session.
  `RefreshClient` keeps its receive wait at Req's 15 s default
  (`refresh_client.ex:9-21`), so Fermix's own timeout does not make this more
  likely.
- **Check:** 10 (4 states), still violated.
- **Counterexample:** p1's manager sends R0, the provider rotates to R1, and the
  response is lost. `RefreshClient` retries with R0. The provider revokes the
  session, and the manager refuses from then on.
- **Code:**
  - `RefreshClient` retries a transport error, a 5xx, a 408 or a 429 with the
    same refresh token, up to three attempts (`refresh_client.ex:36`,
    `:43-49`, `:140-143`, `:148-151`).
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
    (`plugins/auth.ex:72-73`), which kills the manager only after the delete. A
    rename that lands in between stays.
  - A refresh that starts in that gap also wrote the entry back: `latest_entry`
    found no entry and fell back to the in-memory tokens
    (`token_manager.ex:442`, `:446-463`), and `put_provider` created the entry
    (`store.ex:398`).
  - The provider sign-out deletes, then calls `forget`
    (`management/auth.ex:362-363`, `:390-398`). `forget` is a `GenServer.call`
    (`token_manager.ex:81`), so it waits behind any refresh callback already
    running, and that refresh's write always landed first.
- **Fix:** `Store.delete_provider` takes the profile lock before its store lock
  (`store.ex:166-174`), so a delete waits for the profile's refresh in flight
  and deletes after it; ChatGPT's sign-out holds the same lock from its read
  through its write (`chatgpt/logout.ex:40-43`). A refresh that starts after
  the delete refuses (TOKEN-5's fix). A profile lock still busy after 10 s
  fails the logout loudly with nothing deleted (`{:error, :profile_busy}`).
  Every sign-in and import takes the same lock, with the same wait, before it
  spends anything, and holds it through its write: the code exchange of the
  ChatGPT, xAI and plugin flows (`chatgpt/login.ex:73-90`; `xai_login.ex:46-58`
  and `plugins/auth.ex:190-207`, through `OAuthFlow`'s `:redeem`,
  `oauth_flow.ex:7-13`), and the write alone for the Claude Code import and a
  setup token (`anthropic_login.ex:101-121`). So an in-flight refresh cannot
  undo a fresh sign-in either, and a busy profile refuses the sign-in with the
  code unspent, inside the app's job budget; each surface says to try again
  shortly (`Store.busy_sentence/0`). Each reload runs after the lock is
  released.
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
    (`token_supervisor.ex:143`, `:153-154`).
  - `auth_logout` (`plugins_command.ex:250-261`) does not ask the daemon to
    re-apply, unlike the verbs that call `apply_to_daemon` (`:469-486`).
  - `fermix auth logout` only deletes, then tells the operator to restart the
    daemon (`auth_command.ex:216-225`).
  - `latest_entry`'s fallback to the in-memory entry when the read fails
    (`token_manager.ex:442`) refreshed a deleted profile, and `put_provider`
    recreated the entry (`store.ex:398`).
- **Fix:** `latest_entry` returns the read's result, and `entry_from_state` is
  gone (`token_manager.ex:501-505`). A missing auth file or entry, or ChatGPT's
  entry with no token, means a signed-out profile, because a manager's tokens
  only ever come from disk: the manager drops its tokens through the same
  `drop_tokens/1` as `forget`, which also deletes its plugin child's token
  file, logs a warning, and sends and writes nothing
  (`token_manager.ex:320-328`, `:377-405`). Any other read error is transient
  and keeps the state.
- **Impact (before the fix):** the operator was told the account was logged
  out; the daemon wrote it back to `auth.json` at its next refresh.

### TOKEN-6: after a CLI logout the daemon keeps serving the account until its next refresh
- **Severity:** low. The entry stays deleted (TOKEN-5's fix), but the daemon's
  manager served the in-memory access token, and a plugin child kept its
  projected token file, until the manager's next refresh or a restart. The
  proactive refresh runs five minutes before expiry (`token_manager.ex:28`,
  `:253-272`), so this lasted up to one token lifetime.
- **Status:** fixed (d514e149). The owner decided that a CLI
  logout hands the logout to a running daemon.
- **Checks:** 27 now holds; 28 shows it needs `CliLogoutReachesDaemon` (before
  the fix: 27 violated in 4 states). 29 shows the logout still sticks with
  refreshes of both profiles running beside it, and 30 that TOKEN-5's refusal
  is what keeps it there. Rule `LogoutStopsServing` is a proposed
  rule, taken from `forget`'s own doc at `token_manager.ex:61-69`.
- **Counterexample (before the fix):** the CLI logout reads and deletes p2's
  entry, and its `stop_profile` does nothing. The logout is done, and p2's
  manager is still serving.
- **Code (693970b7):**
  - The CLI verbs run tree-less and never reached the daemon
    (`plugins_command.ex:5-8`, `:250-261`; `auth_command.ex:216-225`).
  - The manager learns of the deletion only when it next reads the entry, at
    its next refresh (`token_manager.ex:323-340`).
- **Fix:** both CLI logouts keep their local logout unchanged, then tell a
  running daemon to let go of the profile. This is the shape of
  `apply_to_daemon` (`plugins_command.ex:484-502`): the CLI makes the change on
  disk itself every time, then notifies the daemon, and "no daemon" is the
  authoritative `:not_running` answer.
  - **The CLI side.** After the delete, `fermix plugins auth logout` and
    `fermix auth logout` send `auth_forget` with the profile
    (`plugins_command.ex:262`, `:504-529`; `auth_command.ex:317-335`,
    `:361-377`; `cli/daemon/client.ex:60-74`); `fermix auth logout` for codex
    sends it after ChatGPT's sign-out (`auth_command.ex:284-310`). Both also
    send it when the entry was already gone (`auth_command.ex:289-291`,
    `:326-330`, `:389-392`; `plugins_command.ex:269-273`), so rerunning the
    logout after a failed notice reaches the daemon.
  - **No daemon.** The output is exactly the local logout's.
  - **The daemon answers ok.** One more stderr line.
  - **The daemon answers with an error, or not in time.** The verb exits 1
    with a sentence saying the local entry is already removed and asking for a
    restart of the daemon (from the Fermix app, or `fermix restart` for a
    daemon the operator runs).
  - **The daemon side.** The daemon validates the profile, then runs
    `TokenSupervisor.forget_signed_out/1` (`cli/daemon.ex:628`, `:852-882`;
    `token_supervisor.ex:131-153`).
    - It reuses `forget` (`drop_tokens`: tokens cleared, refusal set, and the
      plugin child's token file deleted), then `stop_profile`. The next use of
      that profile then starts a fresh manager from `auth.json`, so a later
      sign-in is served rather than refused.
    - A forget that exits (for example, a manager waiting on the profile lock
      past the call's 5 s) is logged and answered as an error, never "ok".
      A manager that stopped between the lookup and the call (`:noproc`)
      held nothing, so that is answered "ok" (`token_supervisor.ex:155-161`).
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

None open. The one this spec raised, whether importing a Codex CLI sign-in ends
the Codex CLI's session and then Fermix's, closed when that import was retired
(9336d149): `auth.import.start` now refuses `codex_cli`
(`management/auth.ex:132-133`).

## Outside this model

- **A provider sign-out can still time out behind a lock wait.** `forget` is a
  `GenServer.call` with the default 5-second timeout (`token_manager.ex:72`).
  The profile lock mostly closes the old case: the delete waits for the
  refresh in flight, so `forget` normally finds the manager idle. It can still
  meet a manager that is itself waiting up to 10 s for the profile lock (held
  by a CLI refresh, say); the management caller then exits first, the socket
  turns that into `internal_error` (`cli/daemon.ex:364-374`), and
  `revert_route` (`management/auth.ex:151`) never runs. The in-daemon plugin
  logout's forget (`forget_signed_out`, `plugins/auth.ex:73`) and ChatGPT's
  sign-out's (`chatgpt/logout.ex:46`) are the same call and can meet the same
  wait. Their caller then exits after the delete or the write: the forget still
  runs, late, but the stop and, for the plugin logout, the `Runtime.reload` do
  not.
- **Lock staleness.** The model never breaks a lock. A lockfile is broken only
  once it looks older than its stale threshold, and each threshold exceeds its
  locked section (see Assumptions). That bound is in wall-clock time: the age
  is the lockfile's mtime against `System.system_time` (`lock.ex:191-200`). A
  system sleep (a closed lid) or a clock step while a holder is live, for
  example mid-refresh, can make its lockfile look stale on wake. A second
  refresher that contends right then (a CLI, or the manager while a CLI holds
  the lock) breaks the lock and can present the
  refresh token the woken holder is still consuming. It is rare, and only a
  monotonic, holder-aware lock would rule it out. The stale break is also
  check-then-remove (`lock.ex:191-200`), so right after a holder dies, two of
  three or more contenders could each come to hold the lock; `SingletonLock`
  documents the same limit. A VM killed while holding a profile lock blocks
  that profile's refreshes, sign-ins, imports and logouts for up to 120 s;
  they fail loudly meanwhile (`:profile_busy`, nothing spent).
- **A wedged filesystem exits the caller.** `Lock.with_lock` bounds its own
  calls to the lock owner: `acquire` gets the attempt budget plus 5 s, and the
  owner starts no try once that budget has passed on the monotonic clock;
  `release` gets 5 s (`lock.ex:107-114`, `:185-189`, `:204-209`). A filesystem
  slow enough that one try or the release outlasts them exits the caller
  instead of returning a tuple; inside a token manager that crashes it
  mid-refresh, and its supervisor restarts it from `auth.json`
  (`token_supervisor.ex:244-256`). `Store` does not catch the exit (Rule 7).
- **A refresher that waited for the profile lock refreshes again.** No
  refresher re-checks under the lock that the entry is still due. A manager
  (`token_manager.ex:284-309`) or a tree-less refresh
  (`token_supervisor.ex:312-320`) that waited out another refresher's
  rotation, or a sign-in's write, rotates the fresh token once more, unless the
  entry is ChatGPT's and the fresh set's `earliest_refresh_at` has not passed
  (`chatgpt/refresh.ex:39-48`). It reads under the lock, so it never presents a
  consumed token and `NeverSendConsumed` holds; the cost is one more
  token-endpoint round trip and one more TOKEN-3 window. The model already lets
  a refresh start at any time, so it covers this. A re-check could skip the
  extra rotation on the on-use trigger only: the proactive timer fires five
  minutes before expiry (`token_manager.ex:28`), outside `refresh_due?`'s
  10-second window (`token_expiry.ex:4-11`), so a due check there would skip
  every proactive refresh.

- **A CLI logout's notice can meet a newer sign-in.** Suppose the app signs
  the same account in again between the CLI's delete and the daemon's
  `auth_forget`. The notice then drops the new tokens too and stops the
  manager; its successor reads `auth.json` at the profile's next use and
  serves the new sign-in. The window is one local socket round trip. The model
  has no second sign-in, so it cannot show this.
- **A token call queued on a stopped child exits its caller.**
  `forget_signed_out` stops a `TokenSupervisor` child, the `chatgpt`,
  `anthropic_oauth` and `xai_oauth` profiles included. `TokenManager` does not
  trap exits, so a `get_token` call queued on that manager at that moment exits
  in its caller (a provider request, `providers/anthropic/messages.ex:621`,
  `providers/xai/responses.ex:246`) instead of answering
  `{:error, :reauthorization_required}`; the OpenAI Codex route catches that
  exit and answers an error (`providers/openai/chatgpt_plan.ex:295-305`). The
  window is one message. The in-daemon plugin logout reaches it through the
  same `forget_signed_out` (`plugins/auth.ex:73`), and had it before through
  its bare `stop_profile`. A manager that stopped itself after replying would
  not close it: calls still queued when any process stops exit the same way.
  The model has no callers.
- **A daemon older than the CLI** answers `auth_forget` with `unknown method`.
  The CLI reports that and exits 1, with the entry already removed, and asks
  for a restart onto the new engine.

## Assumptions

- Every modelled profile rotates on every refresh, revokes the session on
  reuse, and has no grace window. The code allows that of any provider and
  reads OpenAI's `refresh_token_reused` as terminal (see above), but does not
  say which providers revoke, or whether any allows a grace window. TOKEN-2's
  damage for a provider that does not revoke does not depend on revocation.
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
  sleeps, plus two 8 s store-lock waits), one sign-in, about 98 s (the code
  exchange, the account lookup and a region probe, each one 30 s attempt with
  no retry, `RefreshClient.request_bounds/0`, plus one 8 s store-lock wait), or
  ChatGPT's sign-out, about 99 s (three revoke attempts at 30 s, 1.05 s of
  sleeps and one 8 s store-lock wait, `ChatGPT.Logout.worst_case_ms/0`,
  `chatgpt/logout.ex:51-69`), against 120 s. A lockfile's age is
  read from its whole-second mtime, so it can look up to a second older; the
  bounds keep that second of margin, and `store_test.exs` ("lock bounds")
  holds them.
- A refresh may start at any time. Expiry, the proactive timer and the
  10-second due window are not modelled. They decide how often the overlaps in
  TOKEN-1 and TOKEN-2 would happen, but not whether they can.
