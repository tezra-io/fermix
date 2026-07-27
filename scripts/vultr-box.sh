#!/usr/bin/env bash
#
# Linux test boxes on Vultr, driven by the v2 API.
#
# macOS is the dev machine, so Linux-only regressions (writer-less secrets, no
# ~/.fermix, process-group reaping, the strict sandbox) are only ever seen after
# a push. This provisions a real VM — full root, the artifact you ship, no shim —
# so they can be seen before one.
#
#   vultr-box.sh snapshot   build the base image: prebuilt OTP + Elixir, Rust,
#                           uv, the coding-harness vendor CLIs (claude, codex),
#                           plus a warmed deps/ and _build/ so later boxes
#                           compile incrementally. Refresh it when mix.lock
#                           moves; app-code drift is handled incrementally.
#   vultr-box.sh up         persistent box: sync tree, compile, boot a full daemon.
#                           SSH in and run `fermix setup` for channels/plugins.
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
#      VULTR_REGION (default atl) · VULTR_PLAN (default vhp-2c-4gb) · VULTR_OS
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
# Eval turns wait on model APIs, not CPU, so 2c/4GB is enough; vhp buys newer
# cores + NVMe, which is where the per-run `mix compile` actually spends time.
# For a one-off bigger snapshot box: VULTR_PLAN=vc2-4c-8gb ... snapshot — but see
# the disk guard in boot_box, a snapshot cannot be restored onto a smaller disk.
PLAN="${VULTR_PLAN:-vhp-2c-4gb}"
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
SNAPSHOT_TIMEOUT=1800

log()  { printf '\033[36m[vultr-box]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[vultr-box] %s\033[0m\n' "$*" >&2; exit 1; }

require_key() {
  [ -n "${VULTR_API_KEY:-}" ] || die "VULTR_API_KEY is not set (Vultr console → Account → API)"
}

# --- API -------------------------------------------------------------------

# curl against the v2 API, failing loud on any non-2xx instead of returning a
# body the caller would silently parse as empty.
api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -X "$method" -H "Authorization: Bearer $VULTR_API_KEY"
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
  printf '%s' "$id"
}

plan_disk_gb() {
  api GET '/plans?per_page=500' | jq -r --arg p "$1" '.plans[] | select(.id==$p) | .disk'
}

verify_plan() {
  api GET '/plans?per_page=500' | jq -e --arg p "$PLAN" '.plans[] | select(.id==$p)' >/dev/null \
    || die "unknown VULTR_PLAN '$PLAN'. Candidates with >=8GB:
$(api GET '/plans?per_page=500' \
    | jq -r '.plans[] | select(.ram>=8192) | "  \(.id)  \(.vcpu_count)vcpu \(.ram)MB $\(.monthly_cost)/mo"' \
    | head -15)"
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
  printf '%s' "$existing"
}

# --- instance lifecycle -----------------------------------------------------

# Every created id is recorded before anything can fail, so a boot that dies
# half-way is reaped instead of silently billing for a leaked VM.
note_pending() { mkdir -p "$STATE_DIR"; printf '%s\n' "$1" >> "$STATE_DIR/pending.ids"; }

clear_pending() { rm -f "$STATE_DIR/pending.ids"; }

reap_pending() {
  [ -f "$STATE_DIR/pending.ids" ] || return 0
  local id
  while read -r id; do
    [ -n "$id" ] && { log "reaping half-provisioned instance $id"; api DELETE "/instances/$id" >/dev/null || true; }
  done < "$STATE_DIR/pending.ids"
  clear_pending
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
  printf '%s' "$id"
}

wait_active() {
  local id="$1" i status
  log "waiting for the instance to come up (up to ${ACTIVE_TIMEOUT}s)"
  for ((i = 0; i < ACTIVE_TIMEOUT; i += 5)); do
    status="$(api GET "/instances/$id" | jq -r '.instance.server_status')"
    [ "$status" = "ok" ] && { printf '%s' "$(api GET "/instances/$id" | jq -r '.instance.main_ip')"; return 0; }
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

wait_cloud_init() {
  log "waiting for cloud-init to finish provisioning (up to ${SNAPSHOT_TIMEOUT}s)"
  remote "$1" "cloud-init status --wait >/dev/null 2>&1 || true; \
                test -f /var/lib/fermix-base-ready" \
    || die "cloud-init did not complete — ssh in and read /var/log/cloud-init-output.log"
}

destroy_instance() { log "destroying instance $1"; api DELETE "/instances/$1" >/dev/null; }

remote() {
  local ip="$1"; shift
  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "root@$ip" "$@"
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
  libsqlite3-dev ca-certificates gnupg

# Prebuilt OTP ${OTP_MAJOR} (no source build).
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc \\
  | gpg --dearmor -o /usr/share/keyrings/erlang-solutions.gpg
. /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] \\
https://binaries2.erlang-solutions.com/ubuntu/ \${UBUNTU_CODENAME}-esl-erlang-${OTP_MAJOR} contrib" \\
  > /etc/apt/sources.list.d/erlang-solutions.list
apt-get update
apt-get install -y esl-erlang

# Precompiled Elixir, matched to the OTP major.
curl -fsSL -o /tmp/elixir.zip \\
  https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip
mkdir -p /usr/local/elixir
unzip -q -o /tmp/elixir.zip -d /usr/local/elixir
for b in elixir elixirc mix iex; do ln -sf /usr/local/elixir/bin/\$b /usr/local/bin/\$b; done

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
echo 'export PATH="/root/.cargo/bin:/root/.local/bin:\$PATH"' > /etc/profile.d/fermix-toolchain.sh
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
  rsync -az --delete \
    --exclude '_build' --exclude 'deps' --exclude 'burrito_out' \
    --exclude 'artifacts' --exclude 'videos' --exclude '.elixir_ls' \
    -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    "$REPO_ROOT/" "root@$ip:$REMOTE_REPO/"
}

# Forwarded at run time only — never into the snapshot, which persists remotely.
forwarded_env() {
  local name
  for name in OPENAI_API_KEY ANTHROPIC_API_KEY XAI_API_KEY OPENROUTER_API_KEY \
              EVAL_JUDGE_API_KEY FERMIX_OPIK_API_KEY FERMIX_OPIK_WORKSPACE \
              OPIK_API_KEY OPIK_WORKSPACE TELEGRAM_BOT_TOKEN; do
    [ -n "${!name:-}" ] && printf '%s=%q ' "$name" "${!name}"
  done
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
  key="$(ensure_ssh_key)"; os_id="$(resolve_os_id)"
  log "provisioning a base box ($OS_NAME, $PLAN, $REGION) — Erlang is compiled, expect ~20-30 min"
  id="$(create_instance "fermix-base" os_id "$os_id" "$key" "$(base_cloud_init | base64 | tr -d '\n')")"
  ip="$(wait_active "$id")"; wait_ssh "$ip"; wait_cloud_init "$ip"
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
  plan_disk_gb "$PLAN" > "$STATE_DIR/snapshot.disk"
  destroy_instance "$id"; clear_pending
  log "base snapshot ready: $snap — 'up' and 'run' now restore from it"
}

snapshot_id() {
  [ -f "$STATE_DIR/snapshot.id" ] || die "no base snapshot yet — run: $(basename "$0") snapshot"
  cat "$STATE_DIR/snapshot.id"
}

boot_box() {
  local label="$1" key ip id want have
  require_key; verify_plan
  # A snapshot taken on a bigger plan carries that plan's disk and cannot be
  # restored onto a smaller one. Catch it here, not after a box exists.
  have="$(cat "$STATE_DIR/snapshot.disk" 2>/dev/null || echo 0)"
  want="$(plan_disk_gb "$PLAN")"
  [ "${have:-0}" -le "${want:-0}" ] || die \
    "snapshot was built on a ${have}GB-disk plan; '$PLAN' has only ${want}GB.
Rebuild it on a plan with disk <= ${want}GB:  VULTR_PLAN=$PLAN $(basename "$0") snapshot"
  key="$(ensure_ssh_key)"
  id="$(create_instance "$label" snapshot_id "$(snapshot_id)" "$key")"
  ip="$(wait_active "$id")"; wait_ssh "$ip"
  printf '%s %s' "$id" "$ip"
}

cmd_up() {
  [ -f "$STATE_DIR/persistent.id" ] && die "a persistent box already exists ($(cat "$STATE_DIR/persistent.id")) — use ssh, or down first"
  local pair id ip
  trap reap_pending EXIT
  pair="$(boot_box fermix-dev)"; id="${pair% *}"; ip="${pair#* }"
  printf '%s' "$id" > "$STATE_DIR/persistent.id"
  printf '%s' "$ip" > "$STATE_DIR/persistent.ip"
  clear_pending   # now tracked as the persistent box; no longer an orphan

  sync_tree "$ip"; compile_remote "$ip"
  log "box is up at $ip"
  cat >&2 <<EOF

  Persistent Linux box ready.

    ssh:   $(basename "$0") ssh
    setup: fermix setup          # wizard — channels, plugins, provider keys
    start: cd $REMOTE_REPO && mix fermix.dev

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
  local pair ip env_prefix
  # Set before anything is created: reap_pending is what guarantees the box dies
  # on every path, including a mid-boot failure or Ctrl-C.
  trap reap_pending EXIT INT TERM
  pair="$(boot_box "fermix-run-$tier")"; ip="${pair#* }"

  sync_tree "$ip"; compile_remote "$ip"
  env_prefix="$(forwarded_env)"

  log "seeding a disposable home and booting the daemon"
  remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
    $env_prefix FERMIX_CAP_HOME=$REMOTE_EVAL_HOME \
    FERMIX_CAP_SEED_ARGS='--provider ${EVAL_PROVIDER:-openai} --model ${EVAL_MODEL:-gpt-5.6-luna}' \
    benchmark/bin/capability-daemon.sh up" || die "daemon failed to boot on the box"

  case "$tier" in
    regression|capability|dry|tests)
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO/benchmark && \
        $env_prefix FERMIX_EVAL_HOME=$REMOTE_EVAL_HOME make $tier" ;;
    dangerous)
      # A real throwaway VM, so the D5 attestation is true here rather than stretched.
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
        rsync -a --exclude _build --exclude deps $REMOTE_REPO/ $REMOTE_EVAL_HOME/workspace/ && \
        cd benchmark && $env_prefix FERMIX_EVAL_HOME=$REMOTE_EVAL_HOME FERMIX_EVAL_DISPOSABLE=1 \
        uv run bin/run_eval.py --dangerous --suite sandbox_verify \
          --scenario assistant_refuses_hardline_shell --profile destructive \
          --confirm-daemon-isolated --confirm-isolated-env --confirm-private-data" ;;
    mix)
      # Same staleness rule as compile_remote, for the separate test-env build.
      remote "$ip" ". /etc/profile.d/fermix-toolchain.sh; cd $REMOTE_REPO && \
        MIX_ENV=test mix compile --force && mix test" ;;
    *) die "unknown tier '$tier' (regression|capability|dangerous|dry|tests|mix)" ;;
  esac

  log "pulling reports back"
  rsync -az -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    "root@$ip:$REMOTE_REPO/benchmark/reports/" "$REPO_ROOT/benchmark/reports/" 2>/dev/null || true
}

cmd_ssh() {
  local ip; ip="$(cat "$STATE_DIR/persistent.ip" 2>/dev/null)" || die "no persistent box — run: $(basename "$0") up"
  exec ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR "root@$ip"
}

cmd_down() {
  local id; id="$(cat "$STATE_DIR/persistent.id" 2>/dev/null)" || die "no persistent box tracked"
  destroy_instance "$id"; rm -f "$STATE_DIR/persistent.id" "$STATE_DIR/persistent.ip"
  log "persistent box destroyed"
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
