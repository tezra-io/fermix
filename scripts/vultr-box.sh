#!/usr/bin/env bash
#
# Linux test boxes on Vultr, driven by the v2 API.
#
# macOS is the dev machine, so Linux-only regressions (writer-less secrets, no
# ~/.fermix, process-group reaping, the strict sandbox) are only ever seen after
# a push. This provisions a real VM — full root, the artifact you ship, no shim —
# so they can be seen before one.
#
#   vultr-box.sh snapshot   build the base image: OTP (compiled, ~30-45 min),
#                           Elixir, Rust,
#                           uv, the coding-harness vendor CLIs (claude, codex),
#                           plus a warmed deps/ and _build/ so later boxes reuse
#                           compiled DEPS. App code is always --force compiled
#                           (see compile_remote). Refresh when mix.lock moves.
#   vultr-box.sh up         persistent box: sync tree, compile, boot a full daemon.
#                           SSH in to configure channels/plugins (config.toml —
#                           a source checkout has no `fermix` binary).
#   vultr-box.sh sync       re-push local edits to the persistent box
#   vultr-box.sh run        ephemeral box: sync, seed a disposable home, boot, run
#                           a tier, then ALWAYS destroy. One-shot feature testing.
#   vultr-box.sh ssh        shell into the persistent box
#   vultr-box.sh status     show the tracked snapshot + boxes
#   vultr-box.sh down       destroy the persistent box
#
# The tree is rsync'd, never git-cloned, so uncommitted work is what gets tested.
#
# Secrets are pushed at run time and never baked into the snapshot (snapshots
# persist in your Vultr account). Use a SEPARATE test bot token for channels —
# never the production one; two daemons polling one Telegram token collide.
#
# HARNESS CREDENTIALS. The vendor CLIs ship in the image; their logins do not,
# and are not forwarded either — a subscription token is not an API key you can
# rotate cheaply. Log in once on a persistent box (`up`, then `ssh`, then `codex
# login` and `claude` → `/login`); both land in root's $HOME and survive reboots
# but not a rebuild. Until then harness runs fail as the vendor reporting itself
# logged out, which is a real result, not a broken box.
#
# Linux stores those logins as plain files — `~/.codex/auth.json` and
# `~/.claude/.credentials.json` — because Claude Code has no keyring backend on
# Linux at all (its macOS Keychain path is what needs USER; see
# Harness.Identity). That difference is precisely what this box exists to test:
# a USER-less daemon here must still run, resolving the account from passwd.
#
# Discover valid values with `plans`, `regions` and `images` — ids and prices
# drift, so pick from your own account rather than from documentation.
#
# Env: VULTR_API_KEY (required)
#      VULTR_REGION (default atl) · VULTR_PLAN (default vc2-2c-4gb) · VULTR_OS
#      FERMIX_VULTR_STATE · EVAL_PROVIDER · EVAL_MODEL
#      OPENAI_API_KEY (+ any provider/channel keys you want forwarded)
#
# NOTE: `mix test` parallelism is 2x cores, so a 2-core box runs max_cases 4
# against CI's 8. To reproduce a CI concurrency/timing failure, use 4 cores.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${FERMIX_VULTR_STATE:-$HOME/.fermix-vultr}"
KEY_FILE="$STATE_DIR/id_ed25519"
API="https://api.vultr.com/v2"

REGION="${VULTR_REGION:-atl}"
# Eval turns wait on model APIs rather than CPU, so 2c/4GB carries the tiers.
# The exception is `run mix`: ExUnit sets max_cases to 2x cores, so this runs 4
# against CI's 8 and is a poorer bet for reproducing a concurrency/timing race —
# use VULTR_PLAN=vc2-4c-8gb for that.
# Build the image on the SAME plan you run on. A snapshot carries its source
# plan's disk and cannot be restored onto a smaller one (guarded in boot_box), so
# imaging on a bigger box makes the image unusable here.
PLAN="${VULTR_PLAN:-vc2-2c-4gb}"
OS_NAME="${VULTR_OS:-Ubuntu 24.04 LTS x64}"
OTP_MAJOR="28"
ELIXIR_VERSION="1.19.5"
SNAPSHOT_DESC="fermix-linux-base"
TAG="fermix-box"

# Remote paths. The eval home leaf must contain 'eval' — the seeder guards on it.
REMOTE_REPO="/opt/fermix"
REMOTE_EVAL_HOME="/opt/fermix-eval-home"

# Bounded waits: every poll has an explicit cap and a loud failure at the cap.
ACTIVE_TIMEOUT=300
SSH_TIMEOUT=180
SNAPSHOT_TIMEOUT=3600   # OTP is compiled during snapshot

TOP_PID=$$
trap 'exit 1' TERM INT

log()  { printf '\033[36m[vultr-box]\033[0m %s\n' "$*" >&2; }

# `exit` inside $( ) ends only the substitution subshell, so a plain `die` let the
# caller continue with an empty value — observed as a 300s poll against an empty
# instance id that still exited 0. Signalling the top-level shell makes a failure
# terminal from any depth; the EXIT trap still reaps. Fallible helpers ALSO publish
# through OUT rather than stdout (below), so `die` runs in the caller's own shell
# and stops it outright instead of one command late. macOS is bash 3.2, where
# `set -e` does not catch these on its own.
die() {
  printf '\033[31m[vultr-box] %s\033[0m\n' "$*" >&2
  kill -TERM "$TOP_PID" 2>/dev/null
  exit 1
}

# Return channel for helpers that can fail. Read it immediately after the call.
OUT=""

require_key() {
  [ -n "${VULTR_API_KEY:-}" ] || die "VULTR_API_KEY is not set (Vultr console → Account → API)"
}

# --- API -------------------------------------------------------------------

# curl against the v2 API, failing loud on any non-2xx instead of returning a
# body the caller would silently parse as empty.
api() {
  local method="$1" path="$2" body="${3:-}"
  # Without these the poll caps below are fiction: one hung connection stalls
  # forever inside a loop that believes it is bounded.
  local -a args=(-sS --connect-timeout 10 --max-time 60
                 -X "$method" -H "Authorization: Bearer $VULTR_API_KEY"
                 -w '\n%{http_code}' "$API$path")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")

  local out code
  out="$(curl "${args[@]}")" || die "curl failed: $method $path"
  code="$(printf '%s' "$out" | tail -n1)"
  out="$(printf '%s' "$out" | sed '$d')"
  case "$code" in
    2*) printf '%s' "$out" ;;
    *)  die "$method $path → HTTP $code: $(printf '%s' "$out" | head -c 400)" ;;
  esac
}

# Resolve by human-readable name rather than hardcoding numeric ids, which drift.
resolve_os_id() {
  local id
  id="$(api GET '/os?per_page=500' | jq -r --arg n "$OS_NAME" '.os[] | select(.name==$n) | .id')"
  [ -n "$id" ] || die "no OS named '$OS_NAME'. Available:
$(api GET '/os?per_page=500' | jq -r '.os[].name' | grep -i ubuntu | sed 's/^/  /')"
  OUT="$id"
}

plan_disk_gb() {
  local disk
  disk="$(api GET '/plans?per_page=500' | jq -r --arg p "$1" '.plans[] | select(.id==$p) | .disk')"
  [ -n "$disk" ] || die "no disk size reported for plan '$1'"
  OUT="$disk"
}

# A plan that exists globally but not in this region still fails at create time,
# and the floor here must match cmd_plans (4GB) — an 8GB floor hides exactly the
# small plans this box is meant to run on.
verify_plan() {
  api GET '/plans?per_page=500' | jq -e --arg p "$PLAN" --arg r "$REGION" \
      '.plans[] | select(.id==$p) | select(.locations | index($r))' >/dev/null \
    || die "VULTR_PLAN '$PLAN' is not available in region '$REGION'.
Candidates there (>=4GB, cheapest first) — full list: $(basename "$0") plans
$(api GET '/plans?per_page=500' \
    | jq -r --arg r "$REGION" '.plans[]
        | select(.locations | index($r)) | select(.ram>=4096)
        | [.monthly_cost, "  \(.id)  \(.vcpu_count)vcpu \(.ram/1024|floor)GB \(.disk)GB disk \$\(.monthly_cost)/mo"]
        | @tsv' \
    | sort -n | cut -f2-)"
}

ensure_ssh_key() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -f "$KEY_FILE" ] || {
    log "generating a dedicated key for these boxes"
    ssh-keygen -t ed25519 -N '' -C fermix-vultr-box -f "$KEY_FILE" >/dev/null
  }
  local pub existing
  pub="$(cat "$KEY_FILE.pub")"
  existing="$(api GET '/ssh-keys?per_page=500' \
    | jq -r --arg k "$pub" '.ssh_keys[] | select(.ssh_key==$k) | .id' | head -1)"
  if [ -z "$existing" ]; then
    existing="$(api POST /ssh-keys \
      "$(jq -nc --arg n fermix-vultr-box --arg k "$pub" '{name:$n,ssh_key:$k}')" | jq -r '.ssh_key.id')"
  fi
  [ -n "$existing" ] && [ "$existing" != "null" ] || die "could not register an SSH key with Vultr"
  OUT="$existing"
}

# --- instance lifecycle -----------------------------------------------------

# Every created id is recorded before anything can fail, so a boot that dies
# half-way is reaped instead of silently billing for a leaked VM.
note_pending() { mkdir -p "$STATE_DIR"; printf '%s\n' "$1" >> "$STATE_DIR/pending.ids"; }

clear_pending() { rm -f "$STATE_DIR/pending.ids"; }

# Deletes directly rather than through `api`: `api` calls `die` on a non-2xx, and
# `|| true` cannot swallow that — die signals TOP_PID, so one undeletable id would
# abort the reap and leak every remaining instance, billing. A failed delete here
# must be reported loudly and the loop must continue.
reap_pending() {
  [ -f "$STATE_DIR/pending.ids" ] || return 0
  local id code leaked=0
  while read -r id; do
    [ -n "$id" ] || continue
    log "reaping half-provisioned instance $id"
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${VULTR_API_KEY:-}" "$API/instances/$id" 2>/dev/null || echo 000)"
    case "$code" in
      2*|404) ;;
      *) leaked=1
         printf '\033[31m[vultr-box] COULD NOT DELETE %s (HTTP %s) — it is STILL BILLING. Delete it in the Vultr console.\033[0m\n' \
            "$id" "$code" >&2 ;;
    esac
  done < "$STATE_DIR/pending.ids"
  [ "$leaked" -eq 0 ] && clear_pending
  return 0
}

create_instance() {
  local label="$1" base_kind="$2" base_id="$3" sshkey="$4" userdata="${5:-}"
  local payload
  payload="$(jq -nc \
    --arg region "$REGION" --arg plan "$PLAN" --arg label "$label" \
    --arg tag "$TAG" --arg key "$sshkey" --arg ud "$userdata" \
    --arg bk "$base_kind" --argjson bv "$(jq -nc --arg v "$base_id" '$v|tonumber? // $v')" \
    '{region:$region, plan:$plan, label:$label, hostname:$label, tags:[$tag],
      sshkey_id:[$key], backups:"disabled"}
     + {($bk): $bv}
     + (if $ud == "" then {} else {user_data:$ud} end)')"
  local id
  id="$(api POST /instances "$payload" | jq -r '.instance.id')"
  [ -n "$id" ] && [ "$id" != "null" ] || die "Vultr returned no instance id"
  note_pending "$id"
  OUT="$id"
}

wait_active() {
  local id="$1" i status ip
  # Never poll on an empty id: that turned a failed create into 60 rounds of 404.
  [ -n "$id" ] || die "wait_active called without an instance id"
  log "waiting for the instance to come up (up to ${ACTIVE_TIMEOUT}s)"
  for ((i = 0; i < ACTIVE_TIMEOUT; i += 5)); do
    status="$(api GET "/instances/$id" | jq -r '.instance.server_status')"
    if [ "$status" = "ok" ]; then
      ip="$(api GET "/instances/$id" | jq -r '.instance.main_ip')"
      [ -n "$ip" ] && [ "$ip" != "null" ] && [ "$ip" != "0.0.0.0" ] \
        || die "instance $id is up but reports no usable IP ('$ip')"
      OUT="$ip"
      return 0
    fi
    sleep 5
  done
  die "instance $id never reached server_status=ok within ${ACTIVE_TIMEOUT}s"
}

wait_ssh() {
  local ip="$1" i
  log "waiting for sshd on $ip (up to ${SSH_TIMEOUT}s)"
  for ((i = 0; i < SSH_TIMEOUT; i += 5)); do
    remote "$ip" true 2>/dev/null && return 0
    sleep 5
  done
  die "no ssh on $ip within ${SSH_TIMEOUT}s"
}

# The EXIT trap destroys this box, so telling the operator to "ssh in and read the
# log" was advice they could never take. Pull it while the box still exists.
capture_cloud_init_log() {
  local ip="$1" dest="$STATE_DIR/cloud-init-failure.log"
  remote "$ip" "tail -n 300 /var/log/cloud-init-output.log" > "$dest" 2>/dev/null || true
  log "provisioning log saved to $dest"
}

# Polls with a fresh connection each round rather than holding one blocking call
# open: OTP is compiled here, and a single ssh session would not survive it. Also
# stops as soon as cloud-init reports a terminal state, instead of waiting out the
# full ceiling for a box that already failed.
wait_cloud_init() {
  local ip="$1" i
  log "waiting for cloud-init (OTP is compiled here — expect ~30-45 min, cap ${SNAPSHOT_TIMEOUT}s)"
  for ((i = 0; i < SNAPSHOT_TIMEOUT; i += 15)); do
    if remote "$ip" "test -f /var/lib/fermix-base-ready" 2>/dev/null; then
      log "provisioning complete"
      return 0
    fi
    if remote "$ip" "cloud-init status 2>/dev/null | grep -qE 'done|error|degraded'" 2>/dev/null; then
      capture_cloud_init_log "$ip"
      die "cloud-init finished without producing the ready flag — provisioning failed. See $STATE_DIR/cloud-init-failure.log"
    fi
    sleep 15
  done
  capture_cloud_init_log "$ip"
  die "cloud-init did not finish within ${SNAPSHOT_TIMEOUT}s. See $STATE_DIR/cloud-init-failure.log"
}

destroy_instance() { log "destroying instance $1"; api DELETE "/instances/$1" >/dev/null; }

remote() {
  local ip="$1"; shift
  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=20 "root@$ip" "$@"
}

# --- provisioning -----------------------------------------------------------

# Pinned toolchain, deliberately NOT the distro's: CI ships OTP 28 / Elixir
# 1.19.5, and testing against anything else is worse than not testing.
#
# Both are installed PREBUILT — Erlang Solutions' .debs and Elixir's official
# per-OTP zip — rather than compiled from source. A source build of OTP is the
# only genuinely CPU/RAM-hungry step here, and removing it is what lets the box
# be 2 cores / 4 GB. The pins are then VERIFIED before the ready flag is set, so
# a repo/URL that resolves to the wrong version fails the snapshot loudly
# instead of quietly producing a box that tests a toolchain we do not ship.
base_cloud_init() {
  cat <<CLOUDINIT
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl git rsync jq unzip build-essential pkg-config \\
  libsqlite3-dev ca-certificates gnupg \\
  autoconf m4 libncurses-dev libssl-dev libwxgtk3.2-dev xsltproc fop
# mise pins and builds the toolchain; KERL_BUILD_DOCS=no keeps the OTP build lean.
export KERL_BUILD_DOCS=no
curl -fsSL https://mise.run | sh
export PATH="/root/.local/bin:/root/.local/share/mise/shims:\$PATH"

# OTP ${OTP_MAJOR} is COMPILED, not prebuilt. Erlang Solutions publishes no
# noble component past 27 (verified: noble-esl-erlang-28 is a 404) and Ubuntu's
# own erlang is far older, so there is no prebuilt 28 for this distro. Dropping
# to 27 would test a toolchain we do not ship, which is worse than not testing —
# so this pays the build cost ONCE, into the snapshot. Expect ~30-45 min on a
# 2-core box; every later box restores the image instead of repeating it.
mise use -g -y erlang@${OTP_MAJOR}
mise use -g -y elixir@${ELIXIR_VERSION}
ln -sf /root/.local/share/mise/shims/* /usr/local/bin/ 2>/dev/null || true

curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
curl -fsSL https://astral.sh/uv/install.sh | sh

# The coding-harness vendor CLIs. Deliberately NOT pinned the way OTP/Elixir are:
# there we ship one version and testing another is worse than not testing, while
# here the harness must work against whatever the operator actually runs, so a pin
# would test a fossil. Set CLAUDE_CLI_VERSION / CODEX_CLI_VERSION to reproduce a
# specific case. Binaries only — their LOGINS are secrets and are never baked into
# a snapshot that persists in the Vultr account (see 'harness credentials' below).
curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CLI_VERSION:-stable}"

case "\$(uname -m)" in
  x86_64)  codex_target=x86_64-unknown-linux-musl ;;
  aarch64) codex_target=aarch64-unknown-linux-musl ;;
  *) echo "FATAL: no codex build for \$(uname -m)"; exit 1 ;;
esac
codex_tag="${CODEX_CLI_VERSION:-}"
[ -n "\$codex_tag" ] || codex_tag="\$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest | jq -r .tag_name)"
curl -fsSL -o /tmp/codex.tar.gz \\
  "https://github.com/openai/codex/releases/download/\$codex_tag/codex-\$codex_target.tar.gz"
mkdir -p /tmp/codex-unpack && tar -xzf /tmp/codex.tar.gz -C /tmp/codex-unpack
# The tarball's inner name carries the target triple and has changed shape before,
# so find the executable rather than assuming it.
codex_bin="\$(find /tmp/codex-unpack -type f -name 'codex*' -perm -u+x | head -1)"
[ -n "\$codex_bin" ] || { echo "FATAL: no codex binary in \$codex_tag/\$codex_target"; exit 1; }
install -m 0755 "\$codex_bin" /usr/local/bin/codex

# Non-interactive ssh does not source .bashrc, so PATH lives somewhere explicit.
# /root/.local/bin is where the claude installer drops its symlink.
echo 'export PATH="/root/.cargo/bin:/root/.local/bin:/root/.local/share/mise/shims:\$PATH"' > /etc/profile.d/fermix-toolchain.sh
chmod 0644 /etc/profile.d/fermix-toolchain.sh

otp="\$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')"
[ "\$otp" = "${OTP_MAJOR}" ] || { echo "FATAL: OTP \$otp != ${OTP_MAJOR}"; exit 1; }
elixir -v | grep -q 'Elixir ${ELIXIR_VERSION}' || { echo "FATAL: Elixir pin mismatch"; elixir -v; exit 1; }

# Presence is fatal, version is only reported: a box that silently lacks the
# vendor CLIs would let a harness run be "skipped" and read as "Linux is fine",
# which is the false conclusion this box exists to prevent.
/root/.local/bin/claude --version || { echo "FATAL: claude CLI missing"; exit 1; }
/usr/local/bin/codex --version || { echo "FATAL: codex CLI missing"; exit 1; }

mix local.hex --force
mix local.rebar --force

touch /var/lib/fermix-base-ready
CLOUDINIT
}

sync_tree() {
  local ip="$1"
  log "syncing the working tree to $ip:$REMOTE_REPO (uncommitted work included)"
  remote "$ip" "mkdir -p $REMOTE_REPO"
  # .git ships: the dangerous tier's strict preflight requires the eval workspace
  # to be a git snapshot at the same HEAD as the harness checkout.
  # `.claude/` alone is hundreds of MB of agent worktrees, and heap dumps can carry
  # process memory. None of it belongs in a snapshot that persists remotely.
  rsync -az --delete \
    --exclude '_build' --exclude 'deps' --exclude 'burrito_out' \
    --exclude 'artifacts' --exclude 'videos' --exclude '.elixir_ls' \
    --exclude '.claude' --exclude '.agents' --exclude '.pytest_cache' \
    --exclude '.DS_Store' --exclude 'erl_crash.dump' --exclude '*.dump' \
    -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    "$REPO_ROOT/" "root@$ip:$REMOTE_REPO/"
}

# Forwarded at run time only — never into the snapshot, which persists remotely.
forwarded_env() {
  local name
  for name in OPENAI_API_KEY ANTHROPIC_API_KEY XAI_API_KEY OPENROUTER_API_KEY \
              EVAL_JUDGE_API_KEY EVAL_JUDGE_BASE_URL EVAL_JUDGE_MODEL \
              FERMIX_OPIK_API_KEY FERMIX_OPIK_WORKSPACE FERMIX_OPIK_BASE_URL \
              OPIK_API_KEY OPIK_WORKSPACE OPIK_BASE_URL OPIK_PROJECT \
              TELEGRAM_BOT_TOKEN; do
    if [ -n "${!name:-}" ]; then printf '%s=%q ' "$name" "${!name}"; fi
  done
  # A function returns its last command's status. With `[ -n .. ] && printf`, an
  # unset LAST name made this return 1, and `env_prefix="$(forwarded_env)"` then
  # killed the run under set -e with no message — after the box was already paid
  # for. `if` returns 0, and this makes it explicit besides.
  return 0
}

# Baked into the snapshot so later boxes compile incrementally. deps/ is the
# expensive half (~214MB of source, the Rust NIF among it) and only moves when
# mix.lock does, so this stays worth having even when the image is far behind
# dev — app-code churn is exactly what incremental compilation handles cheaply.
# Both envs: `mix test` builds _build/test separately, so warming only dev would
# leave `run mix` paying full price anyway.
warm_build() {
  local ip="$1"
  log "warming deps + _build (dev and test) into the image"
  remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
    mix deps.get && mix compile && MIX_ENV=test mix compile" \
    || die "warm build failed — the image would ship a broken _build"
}

# `--force` on the app is a correctness requirement, not caution. `mix compile`
# skips a source whose mtime is not NEWER than its manifest, and rsync carries
# the sender's mtimes — so a file edited on macOS BEFORE the image was built
# arrives "older" than the warm _build and is silently not recompiled, leaving
# the box testing code that is not on it. Verified: a reverted module kept
# returning its old value until --force. macOS ships rsync 2.6.9, so --no-times
# is not a dependable escape either.
#
# `--force` rebuilds only this project — deps are left alone (verified), so the
# expensive warm half of the image still pays off.
compile_remote() {
  local ip="$1"
  log "compiling on the box (app forced; warm deps reused)"
  remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
    mix deps.get && mix compile --force" \
    || die "remote compile failed"
}

# --- commands ---------------------------------------------------------------

cmd_snapshot() {
  require_key; verify_plan
  local key os_id id ip snap i status
  trap reap_pending EXIT
  ensure_ssh_key; key="$OUT"
  resolve_os_id; os_id="$OUT"
  log "provisioning a base box ($OS_NAME, $PLAN, $REGION)"
  create_instance "fermix-base" os_id "$os_id" "$key" \
    "$(base_cloud_init | base64 | tr -d '\n')"; id="$OUT"
  wait_active "$id"; ip="$OUT"
  wait_ssh "$ip"; wait_cloud_init "$ip"
  sync_tree "$ip"; warm_build "$ip"

  log "snapshotting the provisioned box"
  snap="$(api POST /snapshots "$(jq -nc --arg i "$id" --arg d "$SNAPSHOT_DESC" \
          '{instance_id:$i,description:$d}')" | jq -r '.snapshot.id')"
  for ((i = 0; i < SNAPSHOT_TIMEOUT; i += 10)); do
    status="$(api GET "/snapshots/$snap" | jq -r '.snapshot.status')"
    [ "$status" = "complete" ] && break
    sleep 10
  done
  [ "$status" = "complete" ] || die "snapshot $snap not complete within ${SNAPSHOT_TIMEOUT}s"

  mkdir -p "$STATE_DIR"
  printf '%s' "$snap" > "$STATE_DIR/snapshot.id"
  # The source disk, so a restore onto a smaller plan is refused up front rather
  # than by the API after a box has already been created and billed.
  # plan_disk_gb publishes via OUT and prints nothing; redirecting it wrote an
  # empty file, and an empty `have` defaulted to 0, so the guard always passed.
  plan_disk_gb "$PLAN"; printf '%s' "$OUT" > "$STATE_DIR/snapshot.disk"
  destroy_instance "$id"; clear_pending
  log "base snapshot ready: $snap — 'up' and 'run' now restore from it"
}

snapshot_id() {
  [ -f "$STATE_DIR/snapshot.id" ] || die "no base snapshot yet — run: $(basename "$0") snapshot"
  local id
  id="$(cat "$STATE_DIR/snapshot.id")"
  [ -n "$id" ] || die "$STATE_DIR/snapshot.id is empty — rebuild with: $(basename "$0") snapshot"
  OUT="$id"
}

# Publishes "<id> <ip>" via OUT. Every helper here can die, and each must stop the
# run at the point of failure rather than hand back an empty string.
boot_box() {
  local label="$1" key ip id snap want have
  # Local preconditions first, so a missing snapshot fails instantly instead of
  # after a network round trip.
  require_key
  snapshot_id; snap="$OUT"
  verify_plan
  # A snapshot taken on a bigger plan carries that plan's disk and cannot be
  # restored onto a smaller one. Catch it here, not after a box exists.
  have="$(cat "$STATE_DIR/snapshot.disk" 2>/dev/null || true)"
  # Fail closed: an absent or non-numeric record means we cannot prove the restore
  # fits, and defaulting it to 0 would silently pass the check it exists to make.
  case "$have" in
    ''|*[!0-9]*) die "$STATE_DIR/snapshot.disk is missing or unreadable — rebuild with: $(basename "$0") snapshot" ;;
  esac
  plan_disk_gb "$PLAN"; want="$OUT"
  [ "$have" -le "$want" ] || die \
    "snapshot was built on a ${have}GB-disk plan; '$PLAN' has only ${want}GB.
Rebuild it on a plan with disk <= ${want}GB:  VULTR_PLAN=$PLAN $(basename "$0") snapshot"
  ensure_ssh_key; key="$OUT"
  create_instance "$label" snapshot_id "$snap" "$key"; id="$OUT"
  wait_active "$id"; ip="$OUT"
  wait_ssh "$ip"
  OUT="$id $ip"
}

cmd_up() {
  [ -f "$STATE_DIR/persistent.id" ] && die "a persistent box already exists ($(cat "$STATE_DIR/persistent.id")) — use ssh, or down first"
  local pair id ip
  trap reap_pending EXIT
  boot_box fermix-dev; pair="$OUT"; id="${pair% *}"; ip="${pair#* }"
  printf '%s' "$id" > "$STATE_DIR/persistent.id"
  printf '%s' "$ip" > "$STATE_DIR/persistent.ip"
  clear_pending   # now tracked as the persistent box; no longer an orphan

  sync_tree "$ip"; compile_remote "$ip"
  log "box is up at $ip"
  cat >&2 <<EOF

  Persistent Linux box ready.

    ssh:   $(basename "$0") ssh
    start:  cd $REMOTE_REPO && mix fermix.dev
    config: \$FERMIX_HOME/config.toml  (no \`fermix\` binary on a source
            checkout — the umbrella builds no escript, so the setup wizard is
            only available from an installed release)

  Channels: use a SEPARATE test bot token. Two daemons polling one Telegram
  token collide (409), so do not reuse your production or ~/.fermix-dev token.

  Re-sync after local edits:  $(basename "$0") sync
  Destroy when done:          $(basename "$0") down
EOF
}

cmd_sync() {
  local ip; ip="$(cat "$STATE_DIR/persistent.ip" 2>/dev/null)" || die "no persistent box — run: $(basename "$0") up"
  sync_tree "$ip"; compile_remote "$ip"
  log "synced"
}

# Ephemeral: one-shot feature/benchmark testing. Always destroys, including on
# failure — that is what makes FERMIX_EVAL_DISPOSABLE=1 an honest attestation.
cmd_run() {
  local tier="${1:-regression}"
  local pair ip env_prefix rc=0
  # Reject an unknown tier BEFORE provisioning: validating it after the box was
  # created, synced, compiled and booted charged the operator for a typo.
  case "$tier" in
    regression|capability|dangerous|dry|tests|mix) ;;
    *) die "unknown tier '$tier' (regression|capability|dangerous|dry|tests|mix)" ;;
  esac
  # EXIT only. Trapping INT/TERM here replaced the global `exit 1` handler with one
  # that returns, so Ctrl-C reaped the box and then let the script keep running
  # against the corpse. EXIT still fires when the global handler exits, so the box
  # is still reaped on every path.
  trap reap_pending EXIT
  boot_box "fermix-run-$tier"; pair="$OUT"; ip="${pair#* }"

  sync_tree "$ip"; compile_remote "$ip"
  env_prefix="$(forwarded_env)"

  log "seeding a disposable home and booting the daemon"
  remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
    $env_prefix FERMIX_CAP_HOME=$REMOTE_EVAL_HOME \
    FERMIX_CAP_SEED_ARGS='--provider ${EVAL_PROVIDER:-openai} --model ${EVAL_MODEL:-gpt-5.6-luna}' \
    benchmark/bin/capability-daemon.sh up" || die "daemon failed to boot on the box"

  case "$tier" in
    regression|capability|dry|tests)
      # The capability target drops its flags unless these are set, and then
      # run_capability.py refuses — after the box is already provisioned. True by
      # construction here: the VM and its seeded home exist only for this run.
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO/benchmark && \
        $env_prefix FERMIX_EVAL_HOME=$REMOTE_EVAL_HOME \
        CONFIRM_DAEMON_ISOLATED=1 CONFIRM_ISOLATED_ENV=1 CONFIRM_COST=1 \
        make $tier" || rc=$? ;;
    dangerous)
      # A real throwaway VM, so the D5 attestation is true here rather than stretched.
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
        rsync -a --exclude _build --exclude deps $REMOTE_REPO/ $REMOTE_EVAL_HOME/workspace/ && \
        cd benchmark && $env_prefix FERMIX_EVAL_HOME=$REMOTE_EVAL_HOME FERMIX_EVAL_DISPOSABLE=1 \
        uv run bin/run_eval.py --dangerous --suite sandbox_verify \
          --scenario assistant_refuses_hardline_shell --profile destructive \
          --confirm-daemon-isolated --confirm-isolated-env --confirm-private-data" || rc=$? ;;
    mix)
      # Same staleness rule as compile_remote, for the separate test-env build.
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
        MIX_ENV=test mix compile --force && mix test" || rc=$? ;;
  esac

  # Unconditionally, and BEFORE the failure is raised: the EXIT trap destroys the
  # box, so a report left behind on a failing tier is gone for good.
  log "pulling reports back"
  rsync -az -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    "root@$ip:$REMOTE_REPO/benchmark/reports/" "$REPO_ROOT/benchmark/reports/" \
    || log "WARNING: could not pull reports from the box"

  [ "$rc" -eq 0 ] || die "tier '$tier' failed (exit $rc) — any reports were pulled to benchmark/reports/"
}

cmd_ssh() {
  local ip; ip="$(cat "$STATE_DIR/persistent.ip" 2>/dev/null)" || die "no persistent box — run: $(basename "$0") up"
  exec ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR "root@$ip"
}

cmd_down() {
  require_key
  local id code
  id="$(cat "$STATE_DIR/persistent.id" 2>/dev/null)" || die "no persistent box tracked"
  [ -n "$id" ] || die "no persistent box tracked"
  # Tolerate an already-gone instance and clear state either way. Dying here left
  # the id on disk, so `up` refused forever while `ssh`/`sync` chased an IP Vultr
  # had since recycled to someone else.
  log "destroying instance $id"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $VULTR_API_KEY" "$API/instances/$id" 2>/dev/null || echo 000)"
  rm -f "$STATE_DIR/persistent.id" "$STATE_DIR/persistent.ip"
  case "$code" in
    2*)  log "persistent box destroyed" ;;
    404) log "instance $id was already gone; local state cleared" ;;
    *)   die "DELETE $id returned HTTP $code — local state cleared, but VERIFY IN THE CONSOLE that it is not still billing" ;;
  esac
}

# Ground truth from your own account — plan ids, tiers and prices change, so
# pick VULTR_PLAN / VULTR_OS from these rather than from documentation.
cmd_regions() {
  require_key
  api GET '/regions?per_page=100' \
    | jq -r '.regions[] | "\(.id)\t\(.city), \(.country)"' \
    | awk -F'\t' '{printf "%-6s %s\n", $1, $2}' | sort
}

# Without this a wrong region silently yields an empty plan list rather than an
# error, since cmd_plans filters plans by region membership.
verify_region() {
  api GET '/regions?per_page=100' | jq -e --arg r "$REGION" '.regions[] | select(.id==$r)' >/dev/null \
    || die "unknown VULTR_REGION '$REGION' — run: $(basename "$0") regions"
}

cmd_plans() {
  require_key; verify_region
  printf '%-22s %5s %8s %7s %10s  %s\n' PLAN vCPU RAM DISK '$/MO' TYPE
  api GET '/plans?per_page=500' \
    | jq -r --arg region "$REGION" '
        .plans[]
        | select(.locations | index($region))
        | select(.ram >= 4096)
        | [.id, .vcpu_count, "\(.ram/1024|floor)GB", "\(.disk)GB",
           .monthly_cost, .type] | @tsv' \
    | sort -t"$(printf '\t')" -k5 -n \
    | awk -F'\t' '{printf "%-22s %5s %8s %7s %10s  %s\n", $1,$2,$3,$4,"$"$5,$6}'
  printf '\n(region %s; plans under 4GB hidden. Hourly ~= monthly/730.)\n' "$REGION"
}

cmd_images() {
  require_key
  api GET '/os?per_page=500' | jq -r '.os[] | "\(.id)\t\(.name)\t\(.arch)"' \
    | awk -F'\t' '{printf "%-8s %-42s %s\n", $1, $2, $3}'
}

cmd_status() {
  require_key
  printf 'snapshot: %s\n' "$(cat "$STATE_DIR/snapshot.id" 2>/dev/null || echo '<none — run: snapshot>')"
  printf 'persistent: %s %s\n' \
    "$(cat "$STATE_DIR/persistent.id" 2>/dev/null || echo '<none>')" \
    "$(cat "$STATE_DIR/persistent.ip" 2>/dev/null || echo '')"
  printf '\nlive instances tagged %s:\n' "$TAG"
  api GET "/instances?tag=$TAG&per_page=100" \
    | jq -r '.instances[] | "  \(.id)  \(.label)  \(.main_ip)  \(.server_status)"'
}

case "${1:-}" in
  snapshot) cmd_snapshot ;;
  up)       cmd_up ;;
  sync)     cmd_sync ;;
  run)      shift; cmd_run "${1:-regression}" ;;
  ssh)      cmd_ssh ;;
  status)   cmd_status ;;
  plans)    cmd_plans ;;
  regions)  cmd_regions ;;
  images)   cmd_images ;;
  down)     cmd_down ;;
  *) echo "usage: $(basename "$0") [snapshot|up|sync|run <tier>|ssh|status|plans|regions|images|down]" >&2; exit 2 ;;
esac
