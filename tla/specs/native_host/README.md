# native_host: this Mac's own services, through the Fermix app

Models the native host wire (M76 §4.4, decision D10): the daemon listens on
one 0600 Unix socket, `native_host.sock`, and the Fermix app connects to it
as the host of this Mac's own services, notifications first. As on the
browser host wire the daemon asks (a request with an id, answered ok or
error) and the app tells (`attached`, `capabilities`, `host_stopping`).
Unlike it there are no tasks and no tabs: a request is one grant question or
one post.

What it is about: a due reminder's delivery (`MacApp.post/2`) finds the app
attached and posts on its link, or opens the app once and waits for it under
the launch's deadline, and gives up within the cooldown after a launch that
never attached; and the app's quit, which is final for its connection and
answered `host.stop_ack`.

The modules it describes:
- `FermixCore.Native.HostAvailability`: the record (the attached link,
  stopping, the pending launch's deadline) and `claim/3`, which reads it and
  records a launch in one call; its monitor of the link.
- `FermixCore.NativeHost.Link`: the connection process. Each caller's request
  is one `GenServer.call`, written with the next id, refused once the link took
  `host_stopping`, which it answers `host.stop_ack`; its exit ends every
  caller still waiting with `:closed`.
- `FermixCore.Native.Notifications.MacApp`: the caller. `post/2` claims a
  step, opens the app on `:launch` (`AppLauncher.launch/1`), waits on a
  pending launch, and asks on the attached link under a bound.
- The Mac app's native host client, in `tezra-io/fermix-macos`: an
  **unpinned mirror**. This spec states what it must do: connect, attach,
  answer posts, and on quit send `host_stopping` and hold its quit for
  `host.stop_ack`. The app's own bound on that hold is not modelled;
  `StopAlwaysAnswered` states the daemon's half.

## Pins

The `.tla` header pins these sources by hash, so `make -C tla check` reports
the spec STALE when one of them changes. The comments cite functions by name,
not by line, since the pins are by function:

- `apps/fermix_core/lib/fermix_core/native/host_availability.ex`, whole;
- `apps/fermix_core/lib/fermix_core/native_host/link.ex`, by function:
  `request`, `handle_call`, `handle_info`, `caller_request`, `write_request`,
  `sent`, `attach`, `host_stopping`, `answered`, `deliver`;
- `apps/fermix_core/lib/fermix_core/native/notifications/mac_app.ex`, by
  function: `post`, `posted`, `host`, `run`, `launch`, `wait`;
- `apps/fermix_core/lib/fermix_core/app_launcher.ex#launch`;
- `apps/fermix_core/priv/native_host/PROTOCOL.md`, whole.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `PersonCanOpen` | environment | the person opens the app themself, once |
| `AppCanQuit` | environment | the person quits the app, once: `host_stopping`, then the hold |
| `AppCanCrash` | environment | the app dies with no `host_stopping`, once |
| `LaunchCanFail` | environment | `open` exits non-zero at once, once |
| `AtomicClaim` | mechanism | the step and the launch's record are one call (`claim/3`); `FALSE` reads the record, then records the launch |
| `Cooldown` | mechanism | a claim within the cooldown after a launch that never attached is unavailable; `FALSE` launches again |
| `RefuseAfterStopping` | mechanism | the link refuses a request once it took `host_stopping` |
| `CallerBound` | mechanism | a request is bounded by its caller's timeout (`Link.request/4`) |
| `StopAck` | mechanism | the link answers `host_stopping` with `host.stop_ack` |

## What holds

Three `holds` checks, each with the environment its rules are about:
`01_launch_rules` (the launch on demand), `04_quit_rules` (the quit and its
answer) and `07_callers_end` (every delivery attempt ends). Each has a
`needs` check per rule, and the witnesses use the launch and quit bounds.

| Rule | Claim it checks | Needs |
|---|---|---|
| `OneOpenPerLaunch` | the app is opened once however many reminders come while it comes up | `AtomicClaim` |
| `NoLaunchInCooldown` | a launch that never attached is not repeated within the cooldown after it | `Cooldown` |
| `NothingAfterStopAck` | a request after `host_stopping` is refused before it reaches the wire | `RefuseAfterStopping` |
| `EveryCallerEnds` | proposed rule: every delivery attempt ends, posted or with a reason the rail classifies | `CallerBound` |
| `StopAlwaysAnswered` | `host_stopping` is answered with `host.stop_ack` | `StopAck` |

Witnesses: `Witness_LaunchedAndPosted` (a reminder due with the app closed
opens it, it attaches, and the post is answered) and `Witness_QuitMidPost`
(the person quits while a post is still unanswered).

## Design note: the browser host's claim

`AtomicClaim` is the one place this wire departs from the browser host's
shape. `Browser.HostLauncher.decide/2` reads the record (`current/1`), takes
its step, and records the launch (`launching/2`) in a second call, so two
tasks that read the record before either records can both run `open`, and a
task descheduled between the two calls can open the app within a cooldown.
`02_needs_atomic_claim` is that interleaving here. Both effects are benign
(`open` on an app already starting brings it no further), and the browser
host spec models its decision as one step, so it does not see the gap. This
spec's `claim/3` closes it for the native host; the browser host is left as
it is.

## Found while writing it

### NATIVE-1: a caller could open the app again past its own deadline (fixed before commit)

The first draft of the model had no clock on a caller's wait, and TLC found a
cycle: a waiting caller claims again, the cooldown has ended, and it opens the
app again, forever. The cycle itself is the model's (a 5-minute cooldown does
not end within a 3-second wait), but walking it through the code found a real
gap: `step/2` answered `:launch` whatever time the caller had left, and a
launch did not count as one of its polls. An app that attaches and dies at
once voids the launch, so one delivery attempt could keep running `open`
past its deadline for as long as the app kept coming up and dying. Fixed:
`step/2` launches only with time left, and `MacApp.launch` counts as a poll;
`mac_app_test.exs` holds it ("an app that attaches and dies at once is opened
again only within the deadline", which hung before the fix). The model now
says the cooldown never ends while a caller opens the app or waits on a
launch (`CooldownEnds`).

## Bounds

Two callers, two connections, and each environment kind at most once.
Each `holds` check was run once by hand with one more of each (TLC, one
worker set aside, the same fingerprint):

| Check | Three callers | Three connections |
|---|---|---|
| `01_launch_rules` | holds, 106,122 distinct states | holds, 18,394 |
| `04_quit_rules` | holds, 435,043 | holds, 30,273 |
| `07_callers_end` | holds, 531,733 | holds, 34,859 |
