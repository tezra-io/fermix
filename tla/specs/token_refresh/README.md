# token_refresh: OAuth refresh and `auth.json`

Models how Fermix rotates OAuth refresh tokens and stores them in
`~/.fermix/auth.json`. The daemon runs one `TokenManager` GenServer per auth
profile: the top-level `TokenManager` for Codex (`application.ex:173`,
`:362-364`), and a child under `TokenSupervisor` for every other profile
(`token_supervisor.ex:196-224`). A tree-less CLI VM refreshes a profile directly,
with no manager (`token_supervisor.ex:180-183`, `:271-276`;
`codex_token.ex:14-23`). Every refresher persists through `Store.write`, which
reads the whole file and then renames a new one over it (`store.ex:74-82`,
`:420-435`). The model therefore keeps the file as one map: a write is never
torn, and the last rename wins. After a 4xx, a profile other than Codex writes
back the entry it read when its refresh began (`mark_reauthorization_required`).
Logout deletes the entry, then stops the profile's manager (plugin logout,
`plugins/auth.ex:65-88`) or forgets its tokens (provider sign-out,
`management/auth.ex:135-142`).

The provider rotates the refresh token on every refresh and revokes the session
when a consumed token comes back. The code states that rule for Codex only
(`token_manager.ex:414-417`). It says X's refresh tokens are "single-use and
rotated on every refresh" (`oauth_providers.ex:289-290`), but not what X does on
reuse, and it says nothing about rotation for Anthropic, xAI or the other plugin
providers. A provider that returns no new refresh token keeps the old one
(`token_manager.ex:519`), so it can never be sent a consumed one. For every
rotating provider the Fermix side is the same: a consumed token draws a 4xx,
which Fermix treats as permanent, and it quarantines the grant until a new
sign-in (`token_manager.ex:311-318`).

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
  `codex_token.ex:14-23`), so it is a second refresher of this shape.
- `RefreshesCanOverlap`: one process's refresh or logout can be in flight while
  another process's is. This is always true of the real code. Off, it is a
  global mutex that no code provides.
- `ResponseCanBeLost`: the provider rotates, then its response is lost: Req's
  receive timeout, a closed connection, or a 5xx after the rotation.
- `UserCanLogout`: the user logs out of `LogoutProfile`.
- `LogoutFromCli`: that logout runs in a tree-less CLI VM
  (`fermix plugins auth logout`, `fermix auth logout`).
- `SignOutForgets`: that logout is the provider sign-out (delete, then
  `forget`), not the plugin logout (delete, then `stop_profile`). The sign-out
  goes on to `forget` even when the entry is already gone
  (`management/auth.ex:351-360`). The plugin logout stops at the failed delete
  (`plugins/auth.ex:69-71`).

**Mechanism switches** (`TRUE` is the real code; each is switched off by exactly
one check):
- `ReadsDiskBeforeRefresh`: `latest_entry` re-reads `auth.json` before each
  refresh (`token_manager.ex:418-422`).
- `OneCallbackPerManager`: a profile has one manager process, and it runs one
  callback at a time. `TokenSupervisor` registers children in a Registry with
  `keys: :unique` (`token_supervisor.ex:173`) and answers `{:already_started, _}`
  with the running one (`:221`). The Codex manager is registered under its
  module name (`token_manager.ex:36-37`). The BEAM mailbox then queues
  concurrent callers. Switching it off models a second process refreshing the
  same profile beside the manager. That process stands for those concurrent
  callers, so `RefreshesCanOverlap` does not restrain it.
- `MergesOnWrite`: `Store.write` re-reads the file and replaces only its own
  entry (`store.ex:77-78`, `:356-381`).
- `LogoutReachesManager`: logout stops the profile's live manager
  (`plugins/auth.ex:72` → `token_supervisor.ex:140-155`) or forgets its tokens
  (`management/auth.ex:138` → `token_manager.ex:205-222`).

The atomic rename (`store.ex:427`) is not a switch. The model writes the whole
map by construction, and no property here is about a torn file.

## What holds: the sequential baseline

**With overlap allowed (the real code), every rule fails:** checks 07–15. The
headline result of this spec is those failures, not the pass below.

Check 01 is the sequential baseline. It sets `RefreshesCanOverlap = FALSE`, a
global mutex no code provides, and lets every response arrive. With the CLI
refreshing and the user logging out of a plugin, then:
- No consumed refresh token is ever sent. This rests on
  `ReadsDiskBeforeRefresh` (check 02: after the CLI rotates the token, the
  manager would send its stale in-memory one). It also rests on
  `OneCallbackPerManager` (check 03: two callers of one profile would both send
  the same token).
- No rotation is lost from disk. This rests on `MergesOnWrite` (check 04).
- A logout sticks. This rests on `LogoutReachesManager` (check 05: a manager
  left running refreshes later and writes the entry back).

So the mechanisms are right for refreshes that happen one after another.
Nothing in the code keeps refreshes one after another.

Witness 06 shows that the CLI can rotate a token under a serving manager, the
case the disk re-read exists for. Check 01 was also run once by hand with three
profiles and three refreshes per refresher, for both the plugin logout and the
provider sign-out. It still holds (10,168 states each). The model has one CLI
actor. A second CLI VM is one more refresher of the same shape, and TOKEN-2
already covers it.

## Plan hypotheses

These are the "Expected" entries of `docs/design/TLA_PLUS_MODELS.md` §4.2.

- **Lost update between two profiles: confirmed, TOKEN-1.** `Store`'s moduledoc
  still says "callers are serialized in-process: TokenManager is a singleton
  GenServer" (`store.ex:9-12`), but each profile has its own GenServer. The CLI
  VM, sign-ins and logouts are further writers. The atomic rename the moduledoc
  relies on keeps the file whole, but it does not prevent a lost update.
- **Reuse after an ambiguous transport retry: confirmed, TOKEN-3.** The retry is
  not the root cause: once the response is lost, the only token Fermix holds is
  consumed.
- **CLI and daemon refreshing at the same time: confirmed, TOKEN-2.** For a
  profile other than Codex, the loser's status write also erases the winner's
  new token. The daemon can race on its own, through the Codex image backend,
  in a narrow window.
- **Logout undone by an in-flight refresh: confirmed, TOKEN-4** (the profile's
  own refresh) and TOKEN-1 (another profile's write). A logout from the CLI is
  undone with no race at all: TOKEN-5.

## Findings

Every finding below was confirmed by walking the counterexample through the
code on `dev`. None has been reproduced on a running daemon. To see a
counterexample, run `tla/bin/check.py token_refresh` and open
`tla/out/token_refresh/<check>.txt`.

### TOKEN-1: concurrent `auth.json` writers lose each other's updates
- **Severity:** medium. The window is one writer's read-to-rename, but the
  outcome is a revoked session or a deleted account restored.
- **Status:** open.
- **Checks:** 07 (9 states), 08 (11 states), 11 (8 states).
- **Counterexample:**
  - Check 07: p1's and p2's managers refresh at about the same time. p2's
    `Store.write` reads the file before p1's rename lands, then renames its copy
    over it. `auth.json` now holds p1's consumed R0, while p1's manager holds R1
    in memory.
  - Check 08: p1's next refresh re-reads `auth.json` (`latest_entry`), gets R0
    and sends it. The provider revokes p1's session.
  - Check 11: p1's `Store.write` reads the file, the user logs out of p2, and
    p1's rename writes back the map from before the logout. p2's entry is back.
    A path of the same length runs through p2's own refresh instead (TOKEN-4).
    If this check's counterexample ever shows that path, re-walk it.
- **Code:**
  - `Store.write` runs `read_for_write`, then `put_provider` into the document
    it read, then `atomic_write` (`store.ex:77-79`, `:282-293`, `:356-381`,
    `:420-435`). It takes no lock (`store.ex:9-12`). `delete_provider` has the
    same shape (`store.ex:84-92`).
  - Each profile's manager is its own process (`token_supervisor.ex:212-224`;
    for Codex, `application.ex:173`), so two managers' writes interleave. A CLI
    VM's writes (`token_supervisor.ex:271-276`), sign-ins and logouts interleave
    with them too.
  - `latest_entry` prefers the stale disk entry over the manager's valid
    in-memory token (`token_manager.ex:418-420`). The mechanism that guards
    against a CLI refresh (TOKEN-2) is what turns this lost update into a reuse.
    A daemon restart does the same, because `init` loads the disk entry
    (`token_manager.ex:150-152`).
- **Impact:** a rotating profile loses its session at its next refresh. For
  Codex the whole session is revoked. An account that was logged out can come
  back.
- **Confidence:** the overlap needs one rename to land between another writer's
  read and rename, a sub-millisecond window. The model has no timing, so it
  says this can happen, not how often.

### TOKEN-2: two refreshers of one profile send the same token
- **Severity:** medium. It needs two refreshes of one profile within one round
  trip, and the outcome is a revoked session or a lost grant.
- **Status:** open.
- **Checks:** 09 (5 states), 15 (9 states).
- **Counterexample:**
  - Check 09, Codex: p1's manager reads R0 and sends it, and the provider
    rotates to R1. Before the manager's rename, a CLI refresh of p1 reads R0
    from `auth.json` and sends it. The provider revokes the session.
  - Check 15, one plugin profile: the manager reads R0, gets R1, and starts its
    `Store.write`. `fermix plugins auth refresh` reads R0, and the manager
    renames R1. The CLI sends R0 and gets a 4xx. Its status write then renames
    the R0 entry it read at the start over the manager's R1.
- **Code:**
  - `latest_entry` re-reads the disk (`token_manager.ex:418-422`), which only
    helps once the other refresh has renamed its result. Nothing coordinates a
    refresh that is still in flight. The CLI VM has no manager
    (`token_supervisor.ex:180-183`, `:197`, `:208`) and reads the file itself
    (`:272`; `codex_token.ex:19-20`).
  - After a 4xx, any profile but Codex runs `mark_reauthorization_required`.
    That is a `Store.write` of the entry read when the refresh began, with the
    consumed token and the status `reauthorization_required`
    (`token_manager.ex:294`, `:317`, `:534-536`; `token_supervisor.ex:298-299`,
    `:322-323`, `:353-354`, `:376-379`). Codex writes nothing
    (`token_manager.ex:531-532`; `codex_token.ex:99-100`).
  - Inside the daemon, the Codex image backend refreshes through
    `CodexToken.get_token` from a tool process
    (`tools/media/backends/codex_image.ex:273-289`), not through the Codex
    `TokenManager`. It refreshes only within 10 seconds of expiry
    (`token_expiry.ex:4-10`), while the manager's proactive timer fires five
    minutes earlier (`token_manager.ex:30`) and re-arms on every success
    (`:277-287`). So the daemon races itself only when the proactive refresh
    did not keep the token fresh. The timer is not armed when the token was
    loaded with under five minutes left (`:282-287`), and it is not re-armed
    after a failed proactive refresh (`:265-267`). No Codex manager runs at all
    when Codex is not routable (`application.ex:362-364`). Then two image calls
    at once, or one beside the manager's lazy refresh, send the same token.
- **Impact:**
  - Codex: the session is revoked, and the operator must sign in again.
  - Other rotating providers: the loser's status write puts the consumed R0
    back over the winner's R1 (check 15). The status it writes is not one the
    store reads back as a quarantine (`store.ex:129-135`). The damage comes
    through the token: the winner's next refresh re-reads R0
    (`token_manager.ex:418-420`) and gets a 4xx, and the winner is quarantined
    too. This happens even for a provider that only rejects a reused token and
    never revokes the session, so R1 was still valid. The grant is lost to
    Fermix all the same.

### TOKEN-3: a response lost after rotation leads to a consumed token being sent
- **Severity:** low. This is inherent to rotating refresh tokens: once the
  response is lost, nothing can recover the new token.
- **Status:** open.
- **Check:** 10 (4 states).
- **Counterexample:** p1's manager sends R0, the provider rotates to R1, and the
  response is lost. `RefreshClient` retries with R0. The provider revokes the
  session, and the manager refuses from then on.
- **Code:**
  - `RefreshClient` retries a transport error or a 5xx with the same refresh
    token, up to three attempts (`refresh_client.ex:17`, `:63-66`, `:71-74`;
    `:123-126`, `:131-134`).
  - Req does not retry the POST itself: its default `retry: :safe_transient`
    covers GET and HEAD only.
  - Without the retry, the next refresh would send R0 anyway. It is the only
    token Fermix has, because a failed refresh keeps the old state
    (`token_manager.ex:320-321`).
- **Impact:** the session is revoked on the retry, about 350 ms later, instead
  of at the next refresh.
- **Confidence:** this assumes the provider has no grace window for reusing a
  token it has just consumed. The code does not say. If Codex has one, the
  immediate retry can succeed, and the retry is then the better behaviour.

### TOKEN-4: the logged-out profile's own refresh writes its entry back
- **Severity:** low. A sign-out must coincide with a refresh of that profile.
  The window is microseconds for the plugin logout, but it is the whole refresh
  for the provider sign-out.
- **Status:** open.
- **Checks:** 12 (8 states, plugin logout) and 13 (8 states, provider
  sign-out). Both use one profile, so only that profile's own refresh can
  write.
- **Counterexample:** the manager's refresh gets R1, and its `Store.write` reads
  `auth.json`. The logout deletes the entry. The refresh then renames its copy,
  which still has the entry. The logout then stops the manager (check 12) or
  forgets its tokens (check 13), but the entry is back.
- **Code:**
  - The plugin logout deletes, then calls `stop_profile`
    (`plugins/auth.ex:71-72`). `DynamicSupervisor.terminate_child`
    (`token_supervisor.ex:145`) kills the manager, which does not trap exits,
    but only after the delete. A rename that lands in between stays.
  - A refresh that starts in that gap also writes the entry back.
    `latest_entry` finds no entry and falls back to the in-memory tokens
    (`token_manager.ex:421`, `:425-442`), and `put_provider` creates the entry
    (`store.ex:359`).
  - The provider sign-out deletes, then calls `forget`
    (`management/auth.ex:137-138`, `:371-379`). `forget` is a `GenServer.call`
    (`token_manager.ex:80`), so it waits behind any refresh callback already
    running, and that refresh's write always lands first.
- **Impact:** the account is back in `auth.json`. After a plugin logout, the
  next manager start (`ensure_child`, `token_supervisor.ex:196-224`) serves it
  again. After a provider sign-out, the daemon refuses it in memory until the
  daemon restarts, then serves it again.

### TOKEN-5: a logout from the CLI is undone by the daemon's next refresh
- **Severity:** medium. No race is needed: it happens whenever the daemon has a
  live manager for the profile and refreshes before it restarts.
- **Status:** open.
- **Check:** 14 (8 states).
- **Counterexample:** `fermix plugins auth logout` deletes p2's entry in a CLI
  VM, and its `stop_profile` does nothing. Later, p2's manager in the daemon
  refreshes. The disk read finds no entry, so the manager refreshes with its
  in-memory token, and `Store.write` creates the entry again.
- **Code:**
  - The `fermix plugins` verbs run tree-less (`plugins_command.ex:5-8`), so
    `stop_profile` finds no registry and returns `:ok`
    (`token_supervisor.ex:142`, `:152-153`).
  - `auth_logout` (`plugins_command.ex:250-261`) does not ask the daemon to
    re-apply, unlike the verbs that call `apply_to_daemon` (`:469-486`).
  - `fermix auth logout` only deletes, then tells the operator to restart the
    daemon (`auth_command.ex:216-225`). A refresh before that restart undoes it
    the same way.
  - `latest_entry`'s fallback to the in-memory entry when the read fails
    (`token_manager.ex:421`) is what refreshes a deleted profile, and
    `put_provider` recreates the entry (`store.ex:359`).
- **Impact:** the operator is told the account is logged out. The daemon keeps
  using the account, then writes it back to `auth.json` at its next refresh.
  The proactive refresh runs five minutes before each expiry
  (`token_manager.ex:30`, `:277-287`).

## Open question for the owner

**Does importing a Codex CLI sign-in end the Codex CLI's session, and then
Fermix's?** Everything except the provider's reuse rule is confirmed in the
code:
- The import is the app's live path: the management `auth.import` for
  `codex_cli` runs `CodexImport.import_tokens` (`management/auth.ex:276-280`).
- The import refreshes the Codex CLI's refresh token once and stores the new
  pair only in Fermix's `auth.json` (`codex_import.ex:28-40`).
  `~/.codex/auth.json` is only read (`:50-61`), never rewritten, so the Codex
  CLI keeps the token Fermix just consumed.
- Both use the same OAuth client id (`refresh_client.ex:15`), so they share one
  session.

Under the rule the code states for Codex (`token_manager.ex:414-417`), the Codex
CLI's next refresh presents a consumed token, and the provider revokes the
session that Fermix now depends on. This is not modelled, because
`~/.codex/auth.json` belongs to another application. The one thing to verify is
whether OpenAI really revokes the session on reuse, and whether it allows a
grace window.

## Outside this model

- **A provider sign-out can time out behind a refresh, leaving the route
  unreverted.** `forget` is a `GenServer.call` with the default 5-second
  timeout (`token_manager.ex:80`). A refresh callback can hold the manager's
  mailbox for longer: up to three attempts, each bounded by Req's 15-second
  receive timeout, plus sleeps of 350 ms and 700 ms (`refresh_client.ex:17-18`,
  `:65`, `:73`). The queued `forget` still runs later. But the management
  caller exits first; the socket turns that exit into `internal_error`
  (`cli/daemon.ex:306-316`), and `revert_route` (`management/auth.ex:139`) never
  runs. The app reports a failed sign-out whose entry is already deleted, and
  the route it fed is not reverted.

## Assumptions

- Every modelled profile follows the Codex rule: it rotates on every refresh,
  revokes the session on reuse, and has no grace window. The code states this
  for Codex only (see above). TOKEN-2's damage for other profiles does not
  depend on revocation.
- `File.rename` within one directory is atomic, and a later read sees it. The
  kill in `stop_profile` and a rename are ordered: either the rename landed
  before the kill or it never happens.
- A refresh may start at any time. Expiry, the proactive timer and the
  10-second due window are not modelled. They decide how often the overlaps in
  TOKEN-1 and TOKEN-2 happen, but not whether they can.
