# TLA+ specs

Hand-written specs of the parts of Fermix where several processes act on the
same state: the turn queue, scheduled deliveries, token refresh and so on. A
spec lists the processes, the steps each can take and the rules that must
always hold. TLC, the TLA+ model checker, then tries every order those steps
can happen in, within small bounds such as two messages or two profiles. For
each rule it either finds no way to break it or prints the shortest sequence
of steps that does.

The specs catch timing bugs that unit tests rarely hit: a result fired twice, a
message never delivered, or work that keeps running after `/stop`. They do not
test LLM behaviour or single-call rules; ExUnit covers those.

## Requirements

- Java 11 or newer on `PATH`. On macOS, `brew install openjdk`; the
  `/usr/bin/java` stub alone is not enough.
- `uv`, as for `benchmark/`.
- On first run, the runner downloads the pinned TLA+ tools (v1.7.4) to
  `~/.cache/fermix/` (or `$XDG_CACHE_HOME/fermix/`). It checks their sha256 on
  every run and refuses a mismatch. Nothing is vendored.

## Run

```sh
make -C tla check                       # every spec
make -C tla check SPECS="turn_queue"    # one or more specs by name
make -C tla report                      # check, then write tla/out/report.md for fixing findings
make -C tla list                        # every check, its expectation, stale specs (no Java)
make -C tla repin SPECS="turn_queue"    # after committing and re-reading a stale spec (see below)
make -C tla tests                       # the runner's own tests
```

`tla/bin/check.py` takes the same arguments directly. Each spec runs in
seconds. The exit status is 0 when everything is ok and nothing is stale, and 1
otherwise.

## Reading the results

Every check declares what TLC should find, and the runner compares.

| Expectation | Meaning | `ok` when |
|---|---|---|
| `holds` | A rule Fermix relies on | TLC finds no way to break it |
| `needs <Mechanism>` | The same setup as a `holds` check, with one mechanism of the real code switched off | TLC breaks the rule, which proves the pass depends on that mechanism |
| `violated <ID>` | A known finding, described in the spec's README | TLC breaks exactly that rule. For a safety rule, the shortest counterexample also has exactly the recorded length. |
| `reachable` | A witness: a risky situation the spec explores | TLC reaches it |

Every rule a `holds` check proves must have a `needs` check. This rule is
enforced, so no pass can be empty.

`FAIL` means the result no longer matches:
- **Expected to hold, but TLC broke it:** either a new bug, or a spec that no
  longer matches the code. Read the counterexample.
- **`<ID>` now holds:** either the finding was fixed (see below), or the spec
  changed so the bug can no longer happen.
- **`<ID>` now has an N-state counterexample:** a different path now breaks the
  rule. Walk the new path through the code before updating `len=`. Only safety
  rules (invariants) pin a length. TLC finds their shortest counterexample, but
  not the shortest one for a liveness rule.
- **Holds without `<Mechanism>`:** the pass no longer depends on that
  mechanism, so the spec or the check has drifted.
- **Witness unreachable:** the spec stopped exploring a scenario.
- **Deadlock:** a state where nothing can happen and the spec's `Done` does
  not hold. This is a wedge in the code, or a step missing from the spec.
- **TLC error, parse error, timeout, or the wrong rule broken:** the spec itself
  is wrong.

Full TLC output for every check is written to `tla/out/<spec>/<check>.txt`
(gitignored). A counterexample is a numbered list of states. Read it top to
bottom: each state names the step that produced it (for example `<Stop line
…>`) and shows every variable.

## The report: fixing a finding

`make -C tla report` runs the checks and then writes `tla/out/report.md`, with
the same content as JSON in `tla/out/report.json`. For every finding it gives:
- the finding's write-up from the spec's README;
- the counterexample as numbered steps. Each step names the spec action, the
  Elixir function and `path:line` that action mirrors, and only the variables
  that step changed.

Unexpected results (`FAIL`) get the same treatment. The report opens with how
to use it. In short:
1. A counterexample is a path through the spec, not a recording of the daemon,
   so walk it through the cited code first.
2. Reproduce it as a failing ExUnit test.
3. Change the spec to the fixed design and check that only that finding
   flips.
4. Then write the code.

The runner refuses a `violated <ID>` check whose ID has no `### <ID>:` section
in the spec's README, so no counterexample ever arrives without its
explanation.

## When you change a feature

A spec does not read the code; it describes it. Each spec pins the code it
describes by content hash:
- A whole file: `\* SOURCE: <path> @ <hash>`.
- For a large shared file, only the functions and module attributes the spec
  relies on: `\* SOURCE: <path>#claim_due_job,@schema_sql @ <hash>`. This
  covers every clause of each function and the full text of each attribute,
  heredocs included.

When the pinned code changes, every run reports the spec as **STALE** and exits
1. Update the spec only after the change is committed:

1. Open the spec's `.tla` file. Every step has a comment naming the function
   and `path:line` it mirrors. Re-read those against your change: each step
   should still do the same thing, in the same order and in the same process.
2. If behaviour changed, update the spec's steps, comments and line numbers.
3. Run `make -C tla repin SPECS=<spec>` to record that the spec matches the
   committed code. Re-pinning refuses a `SOURCE` file with uncommitted changes,
   so a pin always names code that exists in history.
4. Run `make -C tla check SPECS=<spec>`. A `FAIL` after an honest update is the
   point of the exercise: the change broke a rule, or fixed a finding.

Name every function whose behaviour the spec encodes, including the helpers
it calls. A function pin does not see changes anywhere else in the file. A
comment-only edit to pinned code also marks the spec stale. The re-read then takes a minute,
and that is the cost of knowing each result describes the code as it is. If
you move or rename a `SOURCE` file, the runner refuses to run the spec until
you fix the path.

### When you fix a finding

1. Update the spec to match the fixed code, then re-pin it.
2. The finding's check now fails with "`<ID>` now holds". Change its header to
   `EXPECT: holds` and add a `needs` check for whatever mechanism the fix
   introduced.
3. Mark the finding fixed in the spec's README, with the commit.

## Anatomy of a spec

```
tla/specs/<name>/
  <Name>.tla             the spec
  checks/NN_<what>.cfg   one check each
  README.md              scope, switches, what holds, findings
```

- **The `.tla` header** pins every `\* SOURCE:` file and says what is
  deliberately left out.
- **Environment switches** (`UsersCanStop`, `TasksCanCrash`, …) turn on failures
  the environment can inject. **Mechanism switches** (`OneClaimant`, …) name
  what the code does about them, with `path:line`; `TRUE` is the real code.
  Every check sets every switch, so each verdict reads "holds when these things
  can happen, because of these mechanisms".
- **Steps.** Each action is one indivisible step of the real code and names the
  function and `path:line` it mirrors. A step is one of:
  - one GenServer callback;
  - one `Memory.Repo` call (every SQLite access goes through that one process);
  - one file write;
  - one side effect at a provider or platform.

  A read-modify-write done as two calls is two steps. Each variable belongs to
  one process, and a step only reads what its process can see.
- **Properties** quote the code or doc claim they check. A rule Fermix does not
  claim is labelled a proposed rule.
- **`Done`** is the legitimate end state. Deadlock checking is always on, and
  the runner refuses `CHECK_DEADLOCK FALSE`, so any other stuck state is
  reported.
- **Witnesses** are named `Witness_<Scenario>` and defined as "the scenario
  never happens". TLC breaking one proves the scenario is reachable.

Each `.cfg` starts with two header lines, which TLC reads as comments:

```
\* EXPECT: holds | violated <ID> [len=<N>] | mechanism <Switch> covers <holds-check> | reachable
\* CHECKS: one plain sentence
```

A `needs` (mechanism) check sets its switch to `FALSE`. Every other constant
must equal the `holds` check it covers, and the runner checks this.

`violated` checks:
- An invariant violation pins `len=<N>`.
- A temporal-property violation does not pin a length.
- Every run is reproducible: TLC runs with one worker, a fixed fingerprint and
  its own temporary directory.

### Adding a spec

1. Copy the shape of `turn_queue`.
2. Pin the sources with `make -C tla repin SPECS=<name>`.
3. Give every rule in a `holds` check a `needs` check.
4. Walk every violation through the real code before recording it as a
   finding.
5. Keep bounds small, two or three of each thing, and every check under a
   minute. Run each `holds` check once by hand with one more of each entity,
   and note the result in the spec's README.
6. Use fairness only on steps Fermix itself drives, such as a process's next
   callback or its own timer. Never use it on users, providers, platforms or
   crashes.

## Specs

| Spec | Covers |
|---|---|
| [turn_queue](specs/turn_queue/README.md) | One conversation's turn queue: FIFO, `/stop`, crashes, Queue restarts, and how each turn's result reaches ACP, mobile and voice |
| [job_runs](specs/job_runs/README.md) | Scheduled jobs: the atomic claim, runner finish steps, reconciliation, pause/resume, and delivery |
| [token_refresh](specs/token_refresh/README.md) | OAuth refresh across per-profile managers, the CLI and `auth.json`: rotation, reuse and logout |
| [harness_delivery](specs/harness_delivery/README.md) | Coding-run outcomes: one terminal write, the inline hand-off versus the delivery worker, and continuations |
| [reminder_delivery](specs/reminder_delivery/README.md) | Reminders: the single claimer, attempt cap, boot sweep, validity window and duplicate sends |
| [computer_history](specs/computer_history/README.md) | The capture buffer against pause, `/history off` and purge: M32 invariant 12 |

## Learning TLA+

- Read `specs/turn_queue/TurnQueue.tla` beside
  `apps/fermix_channels/lib/fermix_channels/gateway/queue.ex`. Each step
  names the function it mirrors.
- [Learn TLA+](https://learntla.com): a practical, programmer-oriented guide.
- [Leslie Lamport's video course](https://lamport.azurewebsites.net/video/videos.html).
- The TLA+ extension for VS Code runs TLC inside the editor and can step
  through a counterexample.
