# engine_boot: one engine per home

Models what happens when more than one process boots a supervision tree on
one home. Every rail of the engine settles, as it starts, the rows no worker
of its own VM holds: `Jobs.Scheduler` fails a job run left running,
`Temporal.Scheduler` resets a reminder left delivering, `Harness.Manager`
ends a coding run interrupted, `Meetings.Sweep` fails a meeting,
`PhoneCalls.Manager` settles a call and asks the provider to hang it up.
Each of those is right only when the worker really is gone, and a boot can
tell that only while no other engine serves the home. The daemon lock
(`Fermix.CLI.Daemon.Lock`) is that proof.

What it is about: the lock is taken before anything it protects. A daemon
boot takes it first, before it reads or writes the home and before any child
starts; a boot that finds it held starts nothing and leaves the home as it
found it. The spec also records what the lock does not cover: a command that
boots the tree in a process of its own beside the daemon.

The other specs that model a boot sweep (`job_runs`, `reminder_delivery`,
`harness_delivery`, `open_loop_lifecycle`, `cue_inbox`) each assume one
engine and model the sweep of a row whose worker is gone. This spec is where
that assumption is checked.

The modules it describes:
- `FermixCore.Application`: `start_supervision_tree/0`, which for a daemon
  boot takes the lock first (`start_holding_home_lock/3`) and only then remembers
  the role, prepares the home (`prepare_home/2`), writes the ownership marker
  (`maybe_daemon_socket/0`, `EngineOwner.record/0`) and starts the children
  (`supervision_children/2`); `stop/1`, which lets go of the lock once the
  tree is down.
- `Fermix.CLI.Daemon.Lock`: `acquire/2`, a SQLite file beside the control
  socket held in exclusive mode. The operating system lets go of it when its
  process ends, however it ends.
- `Fermix.CLI.Daemon`: `init/1` binds the control socket, the last step of a
  daemon boot. It took the lock itself before this spec's fix.
- The rails' boot reconciliation: `Jobs.Scheduler.init/1`
  (`reconcile_active_runs/1`), `Temporal.Scheduler.init/1` (`boot_sweep/1`),
  `Harness.Manager` and `PhoneCalls.Manager` (`handle_continue(:reconcile)`),
  `Meetings.Sweep`. The spec folds them into one step and keeps one row for
  the phone-call rail and one for the others.

## Pins

The `.tla` header pins these sources by hash, so `make -C tla check` reports
the spec STALE when one of them changes. The comments cite functions by name,
not by line, since the application's pins are by function:

- `apps/fermix_core/lib/fermix_core/application.ex`, by function:
  `start_supervision_tree`, `start_holding_home_lock`, `take_home_lock`,
  `acquire_home_lock`, `start_holding`, `release_home_lock`, `start_tree`,
  `stop`, `supervision_children`, `maybe_daemon_socket`, `daemon_boot?`,
  `phone_calls_opts`, `jobs_scheduler_opts`, `temporal_scheduler_opts`,
  `harness_worker_opts`;
- `apps/fermix_core/lib/fermix/cli/daemon/lock.ex`, whole;
- `apps/fermix_core/lib/fermix/cli/daemon.ex`, by function: `init`, `bind`,
  `clear_stale_socket`, `terminate`.

The rails' own sweeps are pinned by the specs that model them.

## Switches

| Switch | Kind | `TRUE` means |
|---|---|---|
| `EnginesCanEnd` | environment | a serving engine dies or is stopped, and its work in flight stays claimed in the database |
| `CommandsCanBoot` | environment | a command boots the tree in its own process beside a daemon (`fermix memory`, a supervised `fermix setup`) |
| `LockFirst` | mechanism | a daemon boot takes the lock before it reads or writes the home and before any child starts (`start_holding_home_lock/3`); `FALSE` takes it where the control socket binds, after the home was prepared and every rail swept |
| `SweepsAtBoot` | mechanism | each rail settles, as it starts, the rows no worker of its VM holds |
| `SweepNeedsEngine` | mechanism | an engine-only rail does not reconcile in a command's tree (`PhoneCalls.Manager` with `reconcile?: false`); `FALSE` reconciles it in any tree boot |

`EngineOnly` is not a switch: it names the rails whose reconciliation is
asked for only in the home's daemon. In the code that is the phone-call rail
alone (`Application.phone_calls_opts/2`, `reconcile: daemon?`), so every
check sets `EngineOnly = {calls}`. The `jobs` rail stands for the jobs,
reminder, coding-run and meeting rails, whose options are gated on the build
and not on the daemon (`jobs_scheduler_opts/0`, `temporal_scheduler_opts/0`,
`harness_worker_opts/0`, and `Meetings.Sweep`, which always runs).

## What holds

Two `holds` checks. `01_one_engine_sweeps` is two daemons on one home, with
engines that end with work in flight. `07_command_spares_engine_only_rail`
adds a command's tree beside the daemon.

| Rule | Claim it checks | Needs |
|---|---|---|
| `OnlyGoneWorkIsSwept` | no boot settles a row a running engine's worker holds: the claim every rail's reconciliation rests on | `LockFirst` |
| `RefusedBootWritesNothing` | "a second daemon that finds it held does not start" (`Fermix.CLI.Daemon`): a refused boot leaves the home unwritten, its ownership marker included | `LockFirst` |
| `ServingEngineOwnsClaims` | once an engine serves, every claim in the database is one of its own workers', so what an ended engine left never stands in the way | `SweepsAtBoot` |
| `EngineOnlyWorkSpared` | "a command that boots the tree in a process of its own ... must not settle the daemon's live call as unowned or hang it up" (`Application.phone_calls_opts/2`) | `SweepNeedsEngine` |

Witnesses: `Witness_RefusedBesideWork` (a second daemon is refused while the
first engine's work is in flight), `Witness_GoneWorkSwept` (an engine ends
with a row claimed and the next engine's rails settle it) and
`Witness_CommandBesideWork` (a command's tree is up beside an engine whose
work is in flight).

## Finding, fixed: a second daemon swept the running engine's work before it was refused

The lock was taken by the control socket's process, one of the last children
of the tree, so everything before it ran in a boot that was about to be
refused. `02_needs_lock_first_sweep` is that boot, in nine states: the first
engine serves and holds a row; the second daemon starts, prepares the home,
and its rails settle the first engine's row; only then does its socket find
the lock held. In the code that meant, for a second `fermix run` on a
running home: the running engine's job runs marked failed
(`reconcile_active_runs/1` is synchronous in `init/1`), its reminders reset
for a second send, its coding runs ended `interrupted`, its meetings failed,
its phone call settled `closure_unconfirmed` and hung up, the home's
ownership marker rewritten (`EngineOwner.record/0` ran while the child list
was built) and `prepare_home/2`'s writes made. It was not a narrow race:
`Lock.acquire/2` waits out a reader for up to two seconds before it answers
that the lock is held. A service manager that restarts a refused daemon
repeated all of it at every attempt.

Fixed in 0705a4fc0: a daemon boot takes the lock first
(`Application.start_holding_home_lock/3`), keeps it in the application's state and
lets go of it in `stop/1`. `Fermix.CLI.Daemon` no longer takes or releases
it.

## Findings

### BOOT-1: a command that boots the tree sweeps the running engine's work

Open. `fermix memory` and a supervised `fermix setup` start the whole core
tree in a process of their own (`Application.cli_dispatch/2`), take no lock,
which is right since they are not the home's engine, and then run the rails'
boot reconciliation anyway. `10_command_sweeps_engine_work` is the
counterexample, in ten states: the daemon serves and holds a job's row; the
command's tree starts and its rails settle that row.

In the code, with a daemon running and the command run beside it:
- `Jobs.Scheduler.init/1` reads every unsettled run and fails each one whose
  runner is not in its own VM (`reap_orphaned_run/2`), so a job the daemon is
  running is recorded failed. Its timers are armed as well, so a command that
  runs long enough can claim and run a due job.
- `Temporal.Scheduler.init/1` returns every `delivering` reminder to
  `pending`, so one the daemon is sending is sent again.
- `Harness.Manager` ends every active local coding run `interrupted` and
  queues its report.
- `Meetings.Sweep` fails every live meeting row.

Each is gated on the build (`config/test.exs` turns it off) and not on the
boot being the home's engine. `PhoneCalls.Manager` is the one rail that asks:
`phone_calls_opts/2` hands it `reconcile: daemon?`, which
`07_command_spares_engine_only_rail` holds and `08_needs_sweep_needs_engine`
shows it depends on.

It needs a command run while the daemon has work in flight: seconds for a
reminder, minutes for a job, up to hours for a coding run or a meeting.

The fix is a decision between two shapes, and either makes `EngineOnly` every
rail and flips this check to `holds`: every rail takes the phone-call rail's
option, or a command's tree stops before the first rail (it needs the Repo
and the registries, and no scheduler). A source run with no daemon flag
(`iex -S mix`, `mix run`) is the same boot and would change with it.

## Done

Every process has made its starts and ended. Where engines never end
(`EnginesCanEnd = FALSE`) a serving engine with nothing left to take is also
an end.

## Bounds

Two processes, three starts each, two rails, two claims in all. With three
processes, four starts and three claims, `01_one_engine_sweeps` holds over
59,100 distinct states and `07_command_spares_engine_only_rail` over
567,320.

## Not modelled

- What each rail's sweep writes: the rails' own specs.
- The reader wait in `Lock.acquire/2`: a held lock is refused once it is
  over.
- A lock file that cannot be opened or written: the boot fails with that
  reason at the same step.
- A home's role: every role's daemon takes the same lock at the same step.
- `BootProfile.prepare/2`, which a packaged daemon's boot runs before the
  lock and which makes the web listener's signing key when the home has none.
  A home whose engine runs already has the key, so a refused boot writes
  nothing there either.
- The channels application, which starts after the core tree and has its own
  boot steps (`Voice.CallRowSweep`): a refused core boot never reaches it.
