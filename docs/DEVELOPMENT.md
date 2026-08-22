# Local development & testing

Internal reference for running Fermix from source on a dev machine. User-facing install
lives in README.md; contribution basics in CONTRIBUTING.md; design docs in `docs/design/`.

## The dev daemon (daily loop)

Run the full daemon from source — the dev equivalent of `fermix run`:

```bash
FERMIX_HOME=~/.fermix-dev FERMIX_OPIK_ENABLED=1 FERMIX_BROWSER_HEADLESS=0 \
COMPUX_DISCLAIMED=1 PORT=4031 mix fermix.dev
```

Foreground, one BEAM node (`fermix_core` + `fermix_channels` + `fermix_web`), one Ctrl-C
tears it down. Flags: `--no-channels`, `--no-web`, `--no-realtime` skip those subsystems.
Channels and Realtime are config-gated anyway — no Telegram token means no poller, and
neither absence aborts boot (the readiness banner reports both).

What each env var does (all optional):

| Variable | Effect |
|---|---|
| `FERMIX_HOME=~/.fermix-dev` | Dev home. Keeps the dev daemon fully separate from the live daemon's `~/.fermix` (config, memory.db, traces, sockets). |
| `PORT=4031` | Phoenix/webhook port (default 4030 — which the live daemon usually owns). |
| `FERMIX_OPIK_ENABLED=1` | Turns on the Opik trace exporter (`fermix_opik`). Dev turns land in the local Opik instance, correlated by session id. |
| `FERMIX_BROWSER_HEADLESS=0` | Forces the browser tool headful. `1` forces headless; unset auto-detects (headless only on Linux without a display). |
| `COMPUX_DISCLAIMED=1` | Tells the compux computer-use sidecar it is already disclaimed, so it skips its self-disclaim re-exec — a dev-machine convenience for unsigned local sidecars. |

Two-daemon reality on this machine: the **live** daemon (launchd service, `~/.fermix`,
port 4030, real Telegram) and the **dev** daemon above (`~/.fermix-dev`, port 4031).
Always confirm which home a trace or socket belongs to before reading it.

Setup UI: `http://127.0.0.1:4031/setup` is token-gated by design — the dev task prints
the tokenized URL at boot.

## Tests and gates

Run everything from the umbrella **root** (per-app runs break on `runtime.exs`); scope
with paths:

```bash
mix test                                              # full umbrella (hermetic — config/test.exs pins FERMIX_HOME)
mix test apps/fermix_core/test/fermix_core/management # one area
mix compile --warnings-as-errors && mix credo --strict && mix format --check-formatted
python3 -m pytest scripts/release/ -q                 # release-script suite
```

All four Elixir gates plus the release-script suite must be green before calling any
change done.

## The packaged app engine (occasional — not the dev loop)

`fermix_app_engine` is the same daemon assembled as the plain release tree that ships
inside `Fermix.app`, stamped with the immutable `macos_app` identity. Build it only to
test the packaged form (release shape, management protocol against a prod tree,
app-managed behavior):

```bash
# Build (all-zero commit = local, non-publishable marker)
# BuildInfo's identity is compile-time literals; deleting its beam is the
# reliable invalidation (a touch is not — proven 2026-08-21). Dev/test builds
# are untouched: this only affects _build/prod.
rm -f _build/prod/lib/fermix_core/ebin/Elixir.FermixCore.BuildInfo.beam
FERMIX_BUILD_ID=local-test \
FERMIX_BUILD_SOURCE_COMMIT=0000000000000000000000000000000000000000 \
FERMIX_BUILD_DISTRIBUTION=macos_app \
FERMIX_BUILD_TARGET=macos_aarch64 \
MIX_ENV=prod mix release fermix_app_engine --overwrite

# Run against a disposable home on a spare port
export FERMIX_HOME=$HOME/.fermix-apptest PORT=4530
_build/prod/rel/fermix_app_engine/bin/fermix_app_engine daemon
curl http://127.0.0.1:4530/health/live      # ok when up
curl http://127.0.0.1:4530/health/ready     # 503 until configured — correct
_build/prod/rel/fermix_app_engine/bin/fermix_app_engine stop
```

The identity lives in compile-time literals inside `_build/prod` only — dev and test
builds always carry `standalone`, so nothing needs reverting. The management wire
contract (frames, methods, fixtures) is `apps/fermix_core/priv/management/`.

To exercise the management plane without the macOS app, `scripts/dev/management_request.py`
sends one v1 request and prints the reply:

```bash
FERMIX_HOME=$HOME/.fermix-apptest python3 scripts/dev/management_request.py hello
FERMIX_HOME=$HOME/.fermix-apptest python3 scripts/dev/management_request.py setup.session.create
FERMIX_HOME=$HOME/.fermix-apptest python3 scripts/dev/management_request.py doctor.start '{"scope":"local"}'
FERMIX_HOME=$HOME/.fermix-apptest python3 scripts/dev/management_request.py logs.query '{"limit":20}'
```

`setup.session.create` mints the one-use tokenized `/setup` URL (open it in a browser to
configure the engine — after that, `/health/ready` reports ready). `doctor.get` takes the
session id from `doctor.start`'s result. `lifecycle.commit` stops the daemon — that is
its job.

Release-grade build + smoke (requires a clean tree at a real commit):

```bash
FERMIX_BUILD_ID=<id> FERMIX_BUILD_SOURCE_COMMIT=$(git rev-parse HEAD) \
  scripts/release/build_app_engine.sh macos_aarch64 <out-dir> <version>
python3 scripts/release/verify_app_engine.py <archive> macos_aarch64 <version> $(git rev-parse HEAD) native
```

## Evals

Behavioral suites live in `benchmark/suites/` (vocabulary: `benchmark/suites/SCHEMA.md`;
`risk:` is mandatory on every scenario). Always finish authoring with a dry run — it
validates and plans without spending anything:

```bash
python3 benchmark/bin/run_eval.py --suite <name> --dry-run --judge <judge>
```

`make regression` runs the behavioral tier; `make capability-auto` the capability tier
(refuses non-sandboxable risks). The end-to-end tier (live Opik traces against the dev
daemon) runs through the `fermix-e2e-eval` skill.

## Where things live

- Dev traces: `~/.fermix-dev/traces/<date>/*.jsonl` — every run of the day shares the
  file; bucket by run window before counting anything.
- Daemon logs: `$FERMIX_HOME/logs/`; control socket: `$FERMIX_HOME/daemon.sock`;
  Realtime voice socket (when enabled): `$FERMIX_HOME/realtime.sock`.
- Telemetry rules: `docs/TELEMETRY_CONTRACT.md`. Realtime wire contract:
  `apps/fermix_core/priv/realtime/`. Management wire contract:
  `apps/fermix_core/priv/management/`.
