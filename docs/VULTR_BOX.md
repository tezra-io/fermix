# Linux test boxes on Vultr (`scripts/vultr-box.sh`)

macOS is the dev machine, so Linux-only regressions are otherwise seen only
*after* a push: writer-less secrets (no macOS keychain), no `~/.fermix`,
process-group reaping, the strict sandbox, and the coding harness resolving an
account without `USER`. This provisions a real VM — full root, the artifact you
ship, no shim — so they can be seen before one.

It also covers a gap nothing else does: **no push-triggered CI job runs e2e.**
`ci.yml` is entirely hermetic (`mix test`, harness unit specs, `make dry`), and
the eval tiers only run on schedules — `eval-nightly` (regression) and
`eval-weekly` (capability + dangerous), both against `dev`, both after you have
already pushed. `vultr-box.sh run` is the only way to drive a real daemon with
real turns before pushing.

---

## 1. Prerequisites

- A Vultr account with credit and an API key (**Console → Account → API**).
  Enable the key and check its **access-control / allowed IPs** — a key that is
  IP-restricted to an address you are not on fails every call.
- Local tools: `curl`, `jq`, `rsync`, `ssh`, `ssh-keygen`, `base64`.
- A provider key for the daemon to actually answer turns (`OPENAI_API_KEY`, or
  whatever `EVAL_PROVIDER` needs).

```sh
export VULTR_API_KEY=...        # required for every command
export OPENAI_API_KEY=...       # forwarded to the box at run time
```

---

## 2. First run

```sh
# 1. See what your account actually offers — ids and prices drift, so never
#    take them from documentation, including this file.
./scripts/vultr-box.sh regions
./scripts/vultr-box.sh plans          # filtered to your region, >=4GB, by price

# 2. Build the base image. Once. Everything after restores from it.
./scripts/vultr-box.sh snapshot

# 3. Prove it works end to end, then destroy itself.
./scripts/vultr-box.sh run regression
```

`snapshot` provisions a box, installs the toolchain, warms the build, images it,
and deletes the box. It is the only slow step.

**What lands in the image**

| | Pinned? | Why |
|---|---|---|
| OTP 28, Elixir 1.19.5 | yes, **verified** | prebuilt (Erlang Solutions debs + Elixir's per-OTP zip). CI ships these; a mismatch aborts before the image is accepted |
| Rust (rustup), `uv` | no | NIF build; harness |
| `claude`, `codex` CLIs | no, **presence verified** | the harness must work against what you actually run, so pinning would test a fossil. Override with `CLAUDE_CLI_VERSION` / `CODEX_CLI_VERSION` |
| warm `deps/` + `_build/` (dev + test) | — | ~214 MB of deps and the Rust NIF, reused instead of rebuilt |

Vendor-CLI **logins are not in the image** — see §5.

---

## 3. Commands

| Command | What it does |
|---|---|
| `snapshot` | Build/refresh the base image. Refresh when `mix.lock` moves. |
| `up` | Persistent box: restore, sync tree, compile, ready for `fermix setup`. |
| `sync` | Re-push local edits to the persistent box and recompile. |
| `run <tier>` | Ephemeral box: restore, sync, seed, boot, run a tier, **always destroy**. |
| `ssh` | Shell into the persistent box. |
| `status` | Tracked snapshot + persistent box + every live instance tagged `fermix-box`. |
| `plans` / `regions` / `images` | Discovery, from your own account. |
| `down` | Destroy the persistent box. |

`run` tiers: `regression` · `capability` · `dangerous` · `dry` · `tests` · `mix`

- `regression`, `capability` — the behavioral/capability eval tiers.
- `dangerous` — `sandbox_verify`. **This is the only place `FERMIX_EVAL_DISPOSABLE=1`
  is an honest attestation** rather than one you would be stretching on a dev Mac.
- `dry`, `tests` — no spend: suite validation and the harness unit specs.
- `mix` — the umbrella ExUnit suite, on Linux.

Reports are rsync'd back into `benchmark/reports/` **whether the tier passes or fails** — the box is destroyed on exit, so a failing run's report would otherwise be lost with it. A failed pull warns rather than passing silently.

---

## 4. The two workflows

**Persistent box** — a living Linux Fermix you keep and poke at.

```sh
./scripts/vultr-box.sh up
./scripts/vultr-box.sh ssh
#   on the box — note there is NO `fermix` binary: the umbrella builds no
#   escript, so the setup wizard exists only in an installed release. Configure
#   channels/plugins by editing $FERMIX_HOME/config.toml.
cd /opt/fermix && mix fermix.dev

./scripts/vultr-box.sh sync     # after editing locally
./scripts/vultr-box.sh down     # when finished — it bills until you do
```

**Ephemeral run** — one-shot testing of a change, destroys itself on every path
including failure and Ctrl-C.

```sh
./scripts/vultr-box.sh run regression
./scripts/vultr-box.sh run dangerous
EVAL_MODEL=gpt-5.6-luna ./scripts/vultr-box.sh run capability
```

Channels are deliberately **not** configured for ephemeral runs. The harness
drives the `cli` channel, so tiers need none — and a Telegram token allows only
one active `getUpdates` consumer, so a second daemon on your existing token
would collide (HTTP 409) and break both.

---

## 5. Harness credentials (read before running harness cases)

The vendor CLIs ship in the image; **their logins do not, and are not forwarded**
— a subscription login is not an API key you can cheaply rotate, and the image
persists in your Vultr account. Log in once on a persistent box:

```sh
./scripts/vultr-box.sh up && ./scripts/vultr-box.sh ssh
codex login
claude          # then /login
```

Both land in root's `$HOME` and survive reboots, but **not a rebuild**. Until you
do this, harness runs fail with the vendor reporting itself logged out — that is
a real result, not a broken box.

On Linux these are plain files (`~/.codex/auth.json`,
`~/.claude/.credentials.json`) because Claude Code has no keyring backend on
Linux at all. That difference is exactly what this box exists to test: a
`USER`-less daemon here must still resolve its account from `passwd`.

---

## 6. Secrets

- **Never baked into the image.** Provider and channel keys are forwarded per
  run and quoted with `printf %q`. Snapshots persist in your Vultr account.
- Forwarded when set: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `XAI_API_KEY`,
  `OPENROUTER_API_KEY`, `EVAL_JUDGE_API_KEY`, `FERMIX_OPIK_API_KEY`,
  `FERMIX_OPIK_WORKSPACE`, `OPIK_API_KEY`, `OPIK_WORKSPACE`,
  `TELEGRAM_BOT_TOKEN`.
- **Use a separate test bot token** for channels. Never the production one.

---

## 7. Configuration

| Variable | Default | Notes |
|---|---|---|
| `VULTR_API_KEY` | — | required |
| `VULTR_REGION` | `atl` | `regions` to list |
| `VULTR_PLAN` | `vc2-4c-8gb` | `plans` to list |
| Opik (`OPIK_BASE_URL`, `FERMIX_OPIK_BASE_URL`, `OPIK_PROJECT`, + keys) | — | forwarded when set; the graded tiers need a reachable Opik |
| `VULTR_OS` | `Ubuntu 24.04 LTS x64` | `images` to list |
| `FERMIX_VULTR_STATE` | `~/.fermix-vultr` | ssh key + tracked ids |
| `EVAL_PROVIDER` / `EVAL_MODEL` | `openai` / `gpt-5.6-luna` | seeds the disposable home |
| `CLAUDE_CLI_VERSION` / `CODEX_CLI_VERSION` | `stable` / latest | pin to reproduce a case |

State lives in `$FERMIX_VULTR_STATE`: `id_ed25519{,.pub}`, `snapshot.id`,
`snapshot.disk`, `persistent.{id,ip}`, `pending.ids`.

---

## 8. Cost

Vultr Cloud Compute is on-demand hourly, capped monthly, so hourly ≈ monthly/730.
An ephemeral run is **cents**. The thing that actually costs money is a
persistent box left up — that bills until `down`.

Every created instance id is recorded *before* anything can fail and reaped on
`EXIT`/`INT`/`TERM`, so a half-provisioned box does not silently bill. `status`
lists every live instance tagged `fermix-box` if you want to confirm.

---

## 9. Limits worth knowing

- **`linux-x64` only.** No macOS guest exists on any general cloud, and Vultr
  ARM was not confirmed — so this does not cover the `macos-arm64` or
  `linux-arm64` CI legs.
- **`mix test` parallelism is 2× cores.** A 2-core box runs `max_cases 4`
  against CI's 8. To chase a CI *concurrency/timing* failure (like the
  `CommandHostStreamTest` teardown race), use a 4-core plan.
- **App code is always compiled with `--force`, deliberately.** `mix compile`
  skips a source whose mtime is not *newer* than its manifest, and rsync carries
  your macOS mtimes — so a file edited before the image was built arrives
  "older" than the warm `_build` and is silently not recompiled, leaving the box
  testing code that is not on it (verified: a reverted module kept returning its
  old value). `--force` rebuilds only this project, so warm deps still pay off.
- **A snapshot cannot restore onto a smaller disk.** Building the image on a
  bigger plan and running on a smaller one is refused up front, with the fix in
  the message.

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `VULTR_API_KEY is not set` | export it; check the key is enabled and not IP-restricted |
| `unknown VULTR_PLAN` | it prints candidates; or run `plans` |
| `unknown VULTR_REGION` | run `regions` |
| `snapshot was built on a NNNGB-disk plan` | rebuild the image on a plan whose disk fits the target; the message gives the command |
| `cloud-init did not complete` | `ssh` in and read `/var/log/cloud-init-output.log` |
| `FATAL: OTP … != 28` / `Elixir pin mismatch` | the prebuilt repo resolved a different version — the image is correctly rejected rather than silently testing the wrong toolchain |
| `FATAL: claude/codex CLI missing` | vendor install failed; a box without them would let a harness run be "skipped" and read as "Linux is fine" |
| harness cases fail "logged out" | expected until you complete §5 on a persistent box |
| an instance you did not expect | `status` lists everything tagged `fermix-box`; `down` removes the persistent one |

---

## 11. What is *not* verified

The script fails loud rather than guessing, but two things can only be proven by
running it: **live API behavior** (plan/region/OS ids are resolved by name
against your account, and refuse with the valid list) and **the Erlang Solutions
repo path** for prebuilt OTP. Both surface on the first `snapshot`, loudly.
