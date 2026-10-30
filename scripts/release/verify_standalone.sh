#!/usr/bin/env bash
# Verify one standalone release artifact and its packaged macOS spawn shim.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <artifact> <target> <version> [<iroh-helper-pin>]\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage

artifact="$1"
target="$2"
version="$3"
# The helper the artifact must carry is the one this checkout pins; a test
# passes a pin that matches its fake tree.
iroh_pin="${4:-$(cd "$(dirname "$0")/../.." && pwd -P)/apps/fermix_core/priv/iroh_helper/PIN.json}"

case "$target" in
  linux_x86_64|linux_aarch64|macos_aarch64|macos_x86_64) ;;
  *) fail "unsupported standalone target: $target" ;;
esac

[ -n "$version" ] || fail "expected version must not be empty"
[ ! -L "$artifact" ] && [ -f "$artifact" ] || fail "standalone artifact must be a regular file, not a symlink: $artifact"
# The staged-asset stage hands over the bare downloaded file name. Executed as
# is, a name with no slash is looked up on PATH rather than in the working
# directory, so the artifact is anchored to its directory before it is run.
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"

# One reader for the helper pin: the digest pinned for this target, the exact
# `--version` line, the macOS Team ID and the notices' digest, one per line. A
# pin missing any of them is refused here, before the artifact runs.
iroh_pin_fields() {
  uv run --no-project python -c '
import json, re, sys
path, target = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as stream:
        pin = json.load(stream)
except (OSError, ValueError) as error:
    sys.exit(f"cannot read the iroh helper pin {path}: {error}")
if not isinstance(pin, dict) or pin.get("schema_version") != 2:
    sys.exit(f"the iroh helper pin {path} is not schema_version 2")
def digest(entry):
    sha256 = entry.get("sha256") if isinstance(entry, dict) else None
    return sha256 if isinstance(sha256, str) and re.fullmatch(r"[0-9a-f]{64}", sha256) else None
targets = pin.get("targets")
sha256 = digest(targets.get(target) if isinstance(targets, dict) else None)
if sha256 is None:
    sys.exit(f"the iroh helper pin {path} has no sha256 for {target}")
notices_sha256 = digest(pin.get("notices"))
if notices_sha256 is None:
    sys.exit(f"the iroh helper pin {path} has no sha256 for the notices")
fields = [pin.get(key) for key in ("version", "iroh_version", "macos_team_id")]
if not all(isinstance(value, str) and value for value in fields):
    sys.exit(f"the iroh helper pin {path} must name version, iroh_version and macos_team_id")
version, iroh_version, team_id = fields
print(sha256)
print(f"fermix-iroh {version} (iroh {iroh_version})")
print(team_id)
print(notices_sha256)
' "$1" "$2"
}

sha256_of() {
  uv run --no-project python -c '
import hashlib, sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
' "$1"
}

mode_of() {
  uv run --no-project python -c '
import os, stat, sys
print(f"{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):04o}")
' "$1"
}

[ -f "$iroh_pin" ] || fail "iroh helper pin not found: $iroh_pin"
iroh_fields="$(iroh_pin_fields "$iroh_pin" "$target")" || fail "the iroh helper pin cannot be used (the reason is above)"
iroh_sha256="$(printf '%s\n' "$iroh_fields" | sed -n 1p)"
iroh_version_line="$(printf '%s\n' "$iroh_fields" | sed -n 2p)"
iroh_team_id="$(printf '%s\n' "$iroh_fields" | sed -n 3p)"
iroh_notices_sha256="$(printf '%s\n' "$iroh_fields" | sed -n 4p)"

runtime_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[ -d "$runtime_parent" ] || fail "standalone verification temporary directory does not exist"
runtime_root="$(mktemp -d "$runtime_parent/fermix-standalone-verify.XXXXXX")"
home="$runtime_root/home"
fermix_home="$runtime_root/fermix-home"
mkdir -m 700 "$home" "$fermix_home"

cleanup() {
  rm -rf -- "$runtime_root"
}
trap cleanup EXIT

chmod +x "$artifact"
if ! version_output="$(HOME="$home" FERMIX_HOME="$fermix_home" "$artifact" --version 2>&1)"; then
  printf '%s\n' "$version_output" >&2
  fail "standalone --version command failed"
fi
printf '%s\n' "$version_output"
case "$version_output" in
  *"$version"*) ;;
  *) fail "--version output does not contain $version" ;;
esac

# ── the bundled fermix-iroh helper ──────────────────────────────────────────
# Reach from anywhere runs this helper, and a release without it reports the
# switch as unavailable on every install. The Burrito step puts the pinned
# helper into each target's tree before packing, so this stage reads the
# payload the run above unpacked: exactly one helper, executable, the bytes the
# pin names for this target, and the pinned `--version`; on macOS also a strict
# signature by the pinned team. Where that payload lies is the wrapper's to
# say, not a layout under $home (on Linux Burrito honours `XDG_DATA_HOME`), so
# the wrapper is asked with the same environment the run above had. With
# `FERMIX_INSTALL_DIR` set the wrapper prints its own notices on stdout ahead
# of the directory, and that answer is refused below rather than parsed. The
# digest is checked before the helper runs, so no unpinned bytes are executed.
# It runs before the migrate-to-app stage because that stage ends the script on
# a Linux target.
payload="$(HOME="$home" FERMIX_HOME="$fermix_home" "$artifact" maintenance directory)" ||
  fail "$artifact maintenance directory did not name the unpacked payload"
[ -d "$payload" ] || fail "the unpacked payload directory does not exist: $payload"

iroh_helper=""
iroh_helper_count=0
iroh_helper_paths=""
for candidate in "$payload"/lib/fermix_core-*/priv/iroh_helper/bin/fermix-iroh; do
  [ -e "$candidate" ] || continue
  iroh_helper="$candidate"
  iroh_helper_count=$((iroh_helper_count + 1))
  iroh_helper_paths="$iroh_helper_paths $candidate"
done

[ "$iroh_helper_count" -eq 1 ] ||
  fail "the unpacked release must carry exactly one fermix-iroh helper (lib/fermix_core-*/priv/iroh_helper/bin/fermix-iroh under $payload), found $iroh_helper_count:${iroh_helper_paths:- none}"
[ -x "$iroh_helper" ] || fail "the bundled fermix-iroh helper is not executable: $iroh_helper"

iroh_helper_sha256="$(sha256_of "$iroh_helper")" || fail "cannot hash the bundled fermix-iroh helper: $iroh_helper"
[ "$iroh_helper_sha256" = "$iroh_sha256" ] ||
  fail "the bundled fermix-iroh helper is not the pinned $target build: expected sha256 $iroh_sha256 (from $iroh_pin), found $iroh_helper_sha256"

iroh_helper_version="$("$iroh_helper" --version < /dev/null)" ||
  fail "the bundled fermix-iroh helper --version failed: $iroh_helper"
[ "$iroh_helper_version" = "$iroh_version_line" ] ||
  fail "the bundled fermix-iroh helper --version must print exactly '$iroh_version_line', got '$iroh_helper_version'"

case "$target" in
  macos_aarch64|macos_x86_64)
    iroh_signature="$(codesign --verify --strict "$iroh_helper" 2>&1)" ||
      fail "the bundled fermix-iroh helper does not pass codesign --verify --strict: $iroh_signature"
    iroh_signature="$(codesign -dv "$iroh_helper" 2>&1)" ||
      fail "codesign cannot display the bundled fermix-iroh helper's signature: $iroh_signature"
    iroh_signed_team="$(printf '%s\n' "$iroh_signature" | sed -n 's/^TeamIdentifier=//p')"
    [ "$iroh_signed_team" = "$iroh_team_id" ] ||
      fail "the bundled fermix-iroh helper must be signed by team $iroh_team_id, found ${iroh_signed_team:-no TeamIdentifier}"
    ;;
esac
printf 'fermix-iroh helper: %s (%s)\n' "$iroh_helper" "$iroh_helper_version"

# The licences of what is compiled into the helper ask for their notices to
# travel with it, so the payload carries them beside it: one regular file,
# mode 0644, the bytes the pin names.
iroh_notices="${iroh_helper%/bin/fermix-iroh}/THIRD-PARTY-NOTICES.txt"
[ ! -L "$iroh_notices" ] && [ -f "$iroh_notices" ] ||
  fail "the unpacked release must carry the fermix-iroh third-party notices as a regular file beside the helper: $iroh_notices"
iroh_notices_mode="$(mode_of "$iroh_notices")" || fail "cannot read the mode of the fermix-iroh notices: $iroh_notices"
[ "$iroh_notices_mode" = 0644 ] ||
  fail "the fermix-iroh notices must be mode 0644, found $iroh_notices_mode: $iroh_notices"
iroh_notices_actual="$(sha256_of "$iroh_notices")" || fail "cannot hash the fermix-iroh notices: $iroh_notices"
[ "$iroh_notices_actual" = "$iroh_notices_sha256" ] ||
  fail "the fermix-iroh notices are not the pinned ones: expected sha256 $iroh_notices_sha256 (from $iroh_pin), found $iroh_notices_actual"
printf 'fermix-iroh notices: %s\n' "$iroh_notices"

# ── the bundled Landlock shim (Linux) ───────────────────────────────────────
# On Linux every command a turn runs goes through `fermix_landlock`, and a
# release without it, or with one that cannot run, refuses every command on
# every install ("Fermix's Landlock shim is missing"). The NIF build makes it
# per target with zig, static, so the packaged-interpreter rewrite leaves it
# alone: exactly one shim in the payload, a regular executable file, an ELF
# that names no program interpreter (checked before it runs), and `--abi`
# answering its contract: its ABI (exit 0) or why this runner's kernel cannot
# hold commands (exit 69: no Landlock, or an ABI below the shim's floor). A
# macOS release carries none. It runs before the
# migrate-to-app stage because that stage ends the script on a Linux target.
elf_interpreter() {
  uv run --no-project python -c '
import struct, sys
with open(sys.argv[1], "rb") as stream:
    head = stream.read(64)
    if head[:4] != b"\x7fELF" or len(head) < 64:
        print("none")
        sys.exit(0)
    order = "<" if head[5] == 1 else ">"
    if head[4] == 2:
        (offset,) = struct.unpack(order + "Q", head[32:40])
        size, count = struct.unpack(order + "HH", head[54:58])
    else:
        (offset,) = struct.unpack(order + "I", head[28:32])
        size, count = struct.unpack(order + "HH", head[42:46])
    for index in range(count):
        stream.seek(offset + index * size)
        if struct.unpack(order + "I", stream.read(4))[0] == 3:
            print("PT_INTERP")
            sys.exit(0)
print("none")
' "$1"
}

case "$target" in
  linux_x86_64|linux_aarch64)
    landlock_shim=""
    landlock_shim_count=0
    for candidate in "$payload"/lib/fermix_nif-*/priv/fermix_landlock; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      landlock_shim="$candidate"
      landlock_shim_count=$((landlock_shim_count + 1))
    done
    [ "$landlock_shim_count" -eq 1 ] ||
      fail "the unpacked Linux release must carry exactly one Landlock shim (lib/fermix_nif-*/priv/fermix_landlock under $payload), found $landlock_shim_count"
    [ ! -L "$landlock_shim" ] && [ -f "$landlock_shim" ] && [ -x "$landlock_shim" ] ||
      fail "the bundled Landlock shim is not an executable regular file: $landlock_shim"
    landlock_interpreter="$(elf_interpreter "$landlock_shim")" ||
      fail "cannot read the bundled Landlock shim's program headers: $landlock_shim"
    [ "$landlock_interpreter" = none ] ||
      fail "the bundled Landlock shim is dynamically linked (it names a program interpreter); the release builds it static with zig: $landlock_shim"
    landlock_status=0
    landlock_answer="$("$landlock_shim" --abi < /dev/null 2>&1)" || landlock_status=$?
    case "$landlock_status:$landlock_answer" in
      "0:fermix_landlock: abi "[0-9]*|"69:fermix_landlock: "*) ;;
      *)
        fail "the bundled Landlock shim --abi must print its ABI (exit 0) or why Landlock is unavailable (exit 69), got exit $landlock_status: $landlock_answer"
        ;;
    esac
    printf 'Landlock shim: %s (%s)\n' "$landlock_shim" "$landlock_answer"
    ;;
esac

# ── plugins auth clear, run tree-less from this artifact ────────────────────
# Every `fermix plugins` verb runs without the supervision tree, so no command
# host exists to own a keychain helper and each helper has to run inline. Unit
# tests can only model that world, and `auth clear` shipped dying on every
# install with "command host supervisor ... is not running", so this stage runs
# it from the artifact the release is about to publish. It runs before the
# migrate-to-app stage because that stage ends the script on a Linux target.
#
# No keychain is touched. A stand-in `security` first on PATH answers the one
# delete the verb makes with "item not found" (exit 44, which the writer reads
# as already forgotten) and records it. The keychain writer takes the first
# helper it finds on PATH, so the stand-in is the one used on every target, and
# an argv it does not recognize exits non-zero so a keychain call added later
# cannot pass this gate unanswered. The home is a fresh one whose profile names
# no stored item, and it holds a dev_local api_key plugin for the verb to find,
# because `auth clear` resolves the plugin before it asks the keychain.
plugins_home="$runtime_root/plugins-home"
keychain_bin="$runtime_root/keychain-bin"
keychain_log="$runtime_root/keychain.log"
plugin_checkout="$runtime_root/dev-plugins"
profile="fermix-verify-standalone-$$"
mkdir -m 700 "$plugins_home"
mkdir -p "$keychain_bin" "$plugin_checkout/discord"

cat > "$keychain_bin/security" <<SECURITY
#!/bin/sh
printf '%s\n' "\$*" >> "$keychain_log"
case "\$1" in
  delete-generic-password)
    printf 'security: The specified item could not be found in the keychain.\n'
    exit 44
    ;;
  *) printf 'stand-in security: unexpected invocation: security %s\n' "\$*" >&2 ; exit 64 ;;
esac
SECURITY
chmod +x "$keychain_bin/security"

cat > "$plugin_checkout/discord/plugin.json" <<'MANIFEST'
{
  "schema_version": 2,
  "name": "discord",
  "display_name": "Discord",
  "description": "An api_key plugin for the standalone verification",
  "category": "communication",
  "version": "1.0.0",
  "min_core_version": "0.1.0",
  "plugin_api": 2,
  "auth": {"type": "api_key", "header": "authorization", "scheme": "Bot", "scopes": []},
  "tools": [],
  "skills": []
}
MANIFEST

cat > "$plugins_home/config.toml" <<CONFIG
[fermix_core]
profile = "$profile"

[fermix_core.plugins]
dev_local = "$plugin_checkout"
CONFIG

clear_status=0
clear_output="$(
  env -u FERMIX_OPIK_ENABLED \
    HOME="$home" \
    FERMIX_HOME="$plugins_home" \
    PATH="$keychain_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$artifact" plugins auth clear discord 2>&1
)" || clear_status=$?
printf '%s\n' "$clear_output"

# Named before any other verdict so the message is precise when this class
# comes back: a keychain helper asked for a host the tree-less verb lacks.
case "$clear_output" in
  *"command host supervisor"*)
    fail "plugins auth clear ran its keychain helper under a command host this tree-less verb does not have"
    ;;
esac
[ "$clear_status" -eq 0 ] || fail "plugins auth clear must exit 0 in the throwaway world, got $clear_status"
case "$clear_output" in
  *"deleted the stored api key for discord"*) ;;
  *) fail "plugins auth clear did not report the forgotten key" ;;
esac
# Without the recorded delete the verb never reached the keychain helper, and
# this stage would pass vacuously.
grep -Fq "delete-generic-password -a fermix -s fermix:$profile:FERMIX_PLUGIN_DISCORD" "$keychain_log" 2>/dev/null ||
  fail "plugins auth clear never ran the stand-in keychain helper, so this stage proved nothing"

# ── auth logout, run tree-less from this artifact ───────────────────────────
# `fermix auth logout` runs without the supervision tree. It takes the two
# cross-VM lockfiles beside auth.json (the profile lock, then the store lock),
# whose owner processes this VM has to start and stop on its own, and then dials
# $FERMIX_HOME/daemon.sock to tell a running daemon to let go of the account.
# ExUnit boots the tree, so only this stage proves the packaged binary takes and
# releases those locks and reads a missing socket as "no daemon". It runs before
# the migrate-to-app stage because that stage ends the script on a Linux target.
#
# The home is a fresh one with one seeded ChatGPT sign-in, the `chatgpt`
# registration `openai_codex` signs in with, and no daemon. An entry an older
# build stored under `openai_codex` is no longer read, so seeding one proves
# nothing. The sign-in holds an access token and no refresh token: there is no
# renewable session to revoke, so the verb makes no network call. ChatGPT has
# no auth-mode route to revert, so it touches no config and no keychain: it
# must exit 0, clear the tokens and leave no lockfile.
logout_home="$runtime_root/logout-home"
mkdir -m 700 "$logout_home"
cat > "$logout_home/auth.json" <<'AUTH'
{"version": 2, "providers": {"chatgpt": {"auth_mode": "oauth_siwc", "provider": "chatgpt", "client_id": "verify-client", "subject": "verify-subject", "account": {"email": "verify@example.com"}, "granted_scopes": ["openid", "email", "offline_access", "chatgpt.tokens.use.direct"], "tokens": {"access_token": "verify-at", "refresh_token": null}, "expires_at": null, "last_refresh": null, "status": "ready"}}}
AUTH
chmod 600 "$logout_home/auth.json"

logout_status=0
logout_output="$(
  env -u FERMIX_OPIK_ENABLED \
    HOME="$home" \
    FERMIX_HOME="$logout_home" \
    "$artifact" auth logout 2>&1
)" || logout_status=$?
printf '%s\n' "$logout_output"

[ "$logout_status" -eq 0 ] || fail "auth logout must exit 0 in the throwaway world, got $logout_status"
case "$logout_output" in
  *"Logged out of ChatGPT. Cleared its tokens in"*) ;;
  *) fail "auth logout did not report the removed entry" ;;
esac
if grep -Fq 'verify-at' "$logout_home/auth.json"; then
  fail "auth logout left the ChatGPT tokens in auth.json"
fi
logout_locks="$(find "$logout_home" -name '*.lock' -print)"
[ -z "$logout_locks" ] || fail "auth logout left a lockfile behind: $logout_locks"

# ── the browser-bridge pump, run from this artifact ─────────────────────────
# `fermix browser-bridge` is the class of verb that works from source and breaks
# packaged: it is started by Chrome with no shell environment, its stdout IS the
# native-messaging wire, and a release installs its own stdout log handler after
# the config provider has already logged. So this stage installs the host
# manifest into a throwaway HOME, then starts the pump from the staged artifact
# twice — once admitted and once with an origin the manifest does not list — and
# requires stdout to be EMPTY both times. Nothing is connected: with no daemon
# the pump refuses, which is the point. It runs before the migrate-to-app stage
# because that stage ends the script on a Linux target.
bridge_home="$runtime_root/bridge-home"
browser_home="$runtime_root/browser-home"
mkdir -m 700 "$bridge_home" "$browser_home"
bridge_extension="abcdefghijklmnopabcdefghijklmnop"
bridge_origin="chrome-extension://$bridge_extension/"

install_output="$(
  env -u FERMIX_OPIK_ENABLED \
    HOME="$browser_home" \
    FERMIX_HOME="$bridge_home" \
    "$artifact" browser bridge install --browser chrome --extension-id "$bridge_extension" 2>&1
)" || fail "browser bridge install failed from the packaged artifact: $install_output"
printf '%s\n' "$install_output"

case "$target" in
  macos_aarch64|macos_x86_64)
    bridge_manifest="$browser_home/Library/Application Support/Google/Chrome/NativeMessagingHosts/ai.fermix.bridge.json"
    ;;
  *)
    bridge_manifest="$browser_home/.config/google-chrome/NativeMessagingHosts/ai.fermix.bridge.json"
    ;;
esac
[ -f "$bridge_manifest" ] || fail "browser bridge install wrote no manifest at $bridge_manifest"

bridge_wrapper="$bridge_home/bin/fermix-browser-bridge-chrome"
[ -x "$bridge_wrapper" ] || fail "browser bridge install wrote no executable wrapper at $bridge_wrapper"
# The launcher the wrapper execs has to be the packaged wrapper binary, not the
# extracted release launcher inside the Burrito cache (which rejects our verbs).
bridge_launcher="$(sed -n "s/^exec '\(.*\)' browser-bridge .*/\1/p" "$bridge_wrapper" | head -1)"
[ -n "$bridge_launcher" ] || fail "the browser bridge wrapper names no launcher"
[ -x "$bridge_launcher" ] || fail "the browser bridge wrapper names a launcher that does not exist: $bridge_launcher"

status_output="$(
  env -u FERMIX_OPIK_ENABLED HOME="$browser_home" FERMIX_HOME="$bridge_home" \
    "$artifact" browser bridge status --browser chrome 2>&1
)" || fail "browser bridge status failed from the packaged artifact: $status_output"
printf '%s\n' "$status_output"
case "$status_output" in
  *"chrome: installed"*) ;;
  *) fail "browser bridge status did not report the install it just made" ;;
esac
case "$status_output" in
  *MISSING*) fail "browser bridge status reports a missing launcher right after installing one" ;;
esac

# Admitted origin, no daemon: exit 1, the reason on stderr, and NOTHING on stdout.
bridge_out="$runtime_root/bridge.out"
bridge_err="$runtime_root/bridge.err"
bridge_status=0
env -u FERMIX_OPIK_ENABLED HOME="$browser_home" FERMIX_HOME="$bridge_home" \
  "$artifact" browser-bridge --manifest "$bridge_manifest" "$bridge_origin" \
  < /dev/null > "$bridge_out" 2> "$bridge_err" || bridge_status=$?
printf '%s\n' "$(cat "$bridge_err")"
[ "$bridge_status" -eq 1 ] || fail "the browser-bridge pump must exit 1 with no daemon, got $bridge_status"
[ ! -s "$bridge_out" ] || fail "the browser-bridge pump wrote to stdout, which is the native-messaging wire: $(cat "$bridge_out")"
grep -Fq "the Fermix daemon is not running" "$bridge_err" ||
  fail "the browser-bridge pump did not say why it could not start: $(cat "$bridge_err")"

# An origin the installed manifest does not list is refused, and still silent.
bridge_status=0
env -u FERMIX_OPIK_ENABLED HOME="$browser_home" FERMIX_HOME="$bridge_home" \
  "$artifact" browser-bridge --manifest "$bridge_manifest" "chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba/" \
  < /dev/null > "$bridge_out" 2> "$bridge_err" || bridge_status=$?
[ "$bridge_status" -eq 1 ] || fail "the browser-bridge pump admitted an unlisted origin (exit $bridge_status)"
[ ! -s "$bridge_out" ] || fail "the browser-bridge pump wrote to stdout while refusing an origin"
grep -Fq "is not listed in" "$bridge_err" ||
  fail "the browser-bridge pump admitted an unlisted origin: $(cat "$bridge_err")"

# ── settings with no daemon, run from this artifact ─────────────────────────
# `fermix settings` changes settings only through the running daemon and never
# writes config.toml itself, so with no daemon it must refuse: exit 3, nothing
# changed. Under `--json` its stdout is a machine contract, exactly one JSON
# object, and the packaged runtime is where a boot log line on stdout comes
# from, so this stage runs it from the artifact the release is about to
# publish. The home is a fresh, empty one, so no socket can answer. It runs
# before the migrate-to-app stage because that stage ends the script on a
# Linux target.
settings_home="$runtime_root/settings-home"
mkdir -m 700 "$settings_home"
settings_out="$runtime_root/settings.out"
settings_err="$runtime_root/settings.err"
settings_status=0
env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$settings_home" \
  "$artifact" settings --json < /dev/null > "$settings_out" 2> "$settings_err" || settings_status=$?
printf '%s\n' "$(cat "$settings_err")"
[ "$settings_status" -eq 3 ] || fail "fermix settings with no daemon must exit 3, got $settings_status"
settings_json="$(cat "$settings_out")"
[ "$settings_json" = '{"error":{"code":"not_running"}}' ] ||
  fail "fermix settings --json with no daemon must print exactly {\"error\":{\"code\":\"not_running\"}} on stdout, got: $settings_json"
grep -Fq "daemon is not running" "$settings_err" ||
  fail "fermix settings did not say on stderr why it changed nothing: $(cat "$settings_err")"

# ── fermix home export, import and mark-moved, run from this artifact ──────
# `fermix home` runs without the supervision tree and carries a whole home: it
# probes the control socket, seals and opens the archive with the packaged
# crypto, writes the restored tree and its epoch, and writes the moved marker.
# ExUnit boots the tree, so only this stage proves the packaged binary does all
# of that on its own. It runs before the migrate-to-app stage because that
# stage ends the script on a Linux target.
#
# The source home is a fresh one holding a primary epoch and one setting that
# names its own path, and no daemon. The passphrase comes from a file, so no
# terminal is needed. The archive is restored into a second fresh root, which
# must come back one epoch higher with the setting moved to the new path. The
# source is then marked moved twice: the first must succeed and the second
# refuse, because the first move is the one that counts.
home_src="$runtime_root/home-src"
home_dst="$runtime_root/home-dst"
home_archive="$runtime_root/home.fxhome"
home_passphrase="$runtime_root/home-passphrase"
mkdir -m 700 "$home_src" "$home_src/mobile"
printf '5\n' > "$home_src/mobile/primary_epoch"
chmod 600 "$home_src/mobile/primary_epoch"
printf '[sandbox]\nworkspace_root = "%s/workspace"\n' "$home_src" > "$home_src/config.toml"
printf 'invented-verify-passphrase\n' > "$home_passphrase"
chmod 600 "$home_passphrase"

home_status=0
home_output="$(
  env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$home_src" \
    "$artifact" home export "$home_archive" --passphrase-file "$home_passphrase" < /dev/null 2>&1
)" || home_status=$?
printf '%s\n' "$home_output"
[ "$home_status" -eq 0 ] || fail "fermix home export must exit 0 in the throwaway world, got $home_status"
[ -f "$home_archive" ] || fail "fermix home export wrote no archive at $home_archive"
case "$home_output" in
  *"primary epoch: 5"*) ;;
  *) fail "fermix home export did not report the home's primary epoch" ;;
esac

home_status=0
home_output="$(
  env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$home_src" \
    "$artifact" home import "$home_archive" --into "$home_dst" \
    --passphrase-file "$home_passphrase" < /dev/null 2>&1
)" || home_status=$?
printf '%s\n' "$home_output"
[ "$home_status" -eq 0 ] || fail "fermix home import must exit 0 into an empty root, got $home_status"
[ "$(cat "$home_dst/mobile/primary_epoch" 2>/dev/null)" = 6 ] ||
  fail "fermix home import must make the restored home the next primary, epoch 6"
grep -Fq "\"$home_dst/workspace\"" "$home_dst/config.toml" 2>/dev/null ||
  fail "fermix home import did not move the setting that named the old home to the new one"
[ ! -e "$home_dst/moved.json" ] || fail "fermix home import marked the restored home moved"

# `fermix home status --json` with no daemon answers from the home's own
# files: the role its settings configure and its primary epoch, through the
# packaged binary's tree-less path.
status_out="$runtime_root/home-status.out"
status_err="$runtime_root/home-status.err"
home_status=0
env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$home_src" \
  "$artifact" home status --json < /dev/null > "$status_out" 2> "$status_err" || home_status=$?
printf '%s\n' "$(cat "$status_err")"
[ "$home_status" -eq 0 ] ||
  fail "fermix home status must exit 0 with no daemon, got $home_status: $(cat "$status_out")"
grep -Fq '"role":"primary"' "$status_out" ||
  fail "fermix home status did not read the role from the home: $(cat "$status_out")"
grep -Fq '"epoch":5' "$status_out" ||
  fail "fermix home status did not read the home's primary epoch: $(cat "$status_out")"

moved_out="$runtime_root/home-moved.out"
moved_err="$runtime_root/home-moved.err"
home_status=0
env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$home_src" \
  "$artifact" home mark-moved --to verify-host --json < /dev/null > "$moved_out" 2> "$moved_err" || home_status=$?
printf '%s\n' "$(cat "$moved_err")"
[ "$home_status" -eq 0 ] || fail "fermix home mark-moved must exit 0 the first time, got $home_status: $(cat "$moved_out")"
grep -Fq '"ok":true' "$moved_out" || fail "fermix home mark-moved --json did not print its result: $(cat "$moved_out")"
[ -f "$home_src/moved.json" ] || fail "fermix home mark-moved wrote no marker"

home_status=0
env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$home_src" \
  "$artifact" home mark-moved --to verify-host --json < /dev/null > "$moved_out" 2> "$moved_err" || home_status=$?
[ "$home_status" -eq 1 ] || fail "a second fermix home mark-moved must exit 1, got $home_status"
grep -Fq '"code":"already_moved"' "$moved_out" ||
  fail "a second fermix home mark-moved must refuse with already_moved, got: $(cat "$moved_out")"

# `fermix home enroll` makes a fresh home a candidate with no engine running:
# it reads the code file and decodes the code through the packaged binary's
# tree-less path, and a refusal must leave the home and the code file as it
# found them. The home does not exist yet and the code file holds text that is
# no enrollment code, so the verb must exit 1, say why on stderr, and leave no
# home behind: no candidate, no role, no directory at all. The code file stays.
enroll_home="$runtime_root/enroll-home"
enroll_code="$runtime_root/enroll-code"
enroll_err="$runtime_root/enroll.err"
printf 'fxenroll1.not-a-code\n' > "$enroll_code"
home_status=0
env -u FERMIX_OPIK_ENABLED HOME="$home" FERMIX_HOME="$enroll_home" \
  "$artifact" home enroll --code-file "$enroll_code" < /dev/null > /dev/null 2> "$enroll_err" || home_status=$?
printf '%s\n' "$(cat "$enroll_err")"
[ "$home_status" -eq 1 ] ||
  fail "fermix home enroll with an invalid code must exit 1, got $home_status: $(cat "$enroll_err")"
grep -Fq "not an enrollment code" "$enroll_err" ||
  fail "fermix home enroll did not say on stderr why it refused: $(cat "$enroll_err")"
[ ! -e "$enroll_home/candidate" ] || fail "fermix home enroll wrote a candidate from an invalid code"
[ ! -e "$enroll_home" ] ||
  fail "fermix home enroll left a home behind at $enroll_home: $(ls -A "$enroll_home")"
[ -f "$enroll_code" ] || fail "fermix home enroll removed the code file it refused"

# ── migrate-to-app preflight, run from this artifact ────────────────────────
# `fermix migrate-to-app` with no `--yes` is a plan: it inspects the account
# and mutates nothing. It is also the one verb that reads PATH, the process
# environment and the account's files, and the packaged standalone is a world
# of its own — the Burrito wrapper boots ERTS out of an unpacked copy under
# HOME and `erlexec` prepends `$ROOTDIR/bin` to the PATH every process it
# spawns inherits, so `which -a fermix` answers with this release's own
# launcher. Three engine releases shipped a verb that refused that launcher as
# a foreign `fermix`, green in every injected-world unit test, so this stage
# runs it from the artifact the release is about to publish.
#
# HOME and FERMIX_HOME are the throwaway directories, so the only Fermix facts
# the preflight can read outside them are these two absolute paths. Neither
# exists on a runner. They are surveyed rather than asserted absent — an
# installed application switches the plan to its already-installed
# configuration, which this stage asserts nothing about — and named in every
# failure message so a host fact is never a silent cause of a different verdict.
host_facts=""
for host_fact in /Applications/Fermix.app /Library/LaunchDaemons/io.tezra.fermix.plist; do
  [ ! -e "$host_fact" ] || host_facts="$host_facts $host_fact"
done
host_hint="no host Fermix facts outside the throwaway world"
[ -z "$host_facts" ] || host_hint="host facts present outside the throwaway world:$host_facts"

brew_prefix="$runtime_root/brew-prefix"
mkdir -p "$brew_prefix/bin"

# Exactly the `brew` invocations the preflight makes up to and including the
# PATH probe, and nothing else: an argv this fake does not recognize exits
# non-zero, so a brew call added later cannot silently pass this gate.
cat > "$brew_prefix/bin/brew" <<BREW
#!/bin/sh
set -eu
case "\$*" in
  "--prefix") printf '%s\n' "$brew_prefix" ;;
  "list --formula --versions fermix") printf 'fermix %s\n' "$version" ;;
  "services list") printf 'Name Status User File\nfermix none - -\n' ;;
  *) printf 'fake brew: unexpected invocation: brew %s\n' "\$*" >&2 ; exit 64 ;;
esac
BREW
chmod +x "$brew_prefix/bin/brew"

# The launcher the retired launch agent would name. Nothing runs it; it only
# has to exist on PATH under the brew prefix the preflight just read.
printf '#!/bin/sh\nexit 0\n' > "$brew_prefix/bin/fermix"
chmod +x "$brew_prefix/bin/fermix"

# A minimal PATH on purpose. The only `fermix` this probe may find is the stub
# under the fake prefix plus whatever the packaged wrapper puts there itself;
# a real formula install on the host would otherwise read as a foreign target
# and refuse a perfectly good artifact.
migrate_status=0
migrate_output="$(
  env -u FERMIX_OPIK_ENABLED \
    HOME="$home" \
    FERMIX_HOME="$fermix_home" \
    PATH="$brew_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$artifact" migrate-to-app 2>&1
)" || migrate_status=$?
printf '%s\n' "$migrate_output"

refusal="$(printf '%s\n' "$migrate_output" | sed -n 's/.*refused (\([a-z_]*\)).*/\1/p' | head -1 || true)"

# Named before any other verdict so the message is precise when this class
# comes back: the release's own launcher, read as somebody else's binary.
case "$refusal" in
  foreign_cli_target)
    fail "migrate-to-app refused this release's own launcher as a foreign fermix on PATH (foreign_cli_target)"
    ;;
esac

case "$target" in
  linux_x86_64|linux_aarch64)
    # macos_only is the first preflight stage, so a Linux artifact proves the
    # verb runs from the packaged binary at all and nothing else.
    [ "$refusal" = "not_macos" ] || fail "migrate-to-app on a Linux target must refuse not_macos, got: ${refusal:-no refusal}"
    [ "$migrate_status" -eq 1 ] || fail "a migrate-to-app preflight refusal must exit 1, got $migrate_status"
    exit 0
    ;;
  macos_aarch64|macos_x86_64)
    # The throwaway world satisfies every stage — no system LaunchDaemon, at
    # most one Fermix.app, a formula install with no brew service, a
    # recognized PATH, no user launch agent and so no daemon to drain — so the
    # plan is the outcome, and any refusal is a stage this binary should have
    # walked through.
    [ -z "$refusal" ] || fail "migrate-to-app refused the throwaway world ($refusal); the preflight output is above, $host_hint"
    case "$migrate_output" in
      *"could not inspect this account"*)
        fail "migrate-to-app could not read the throwaway world; the preflight output is above, $host_hint"
        ;;
    esac
    [ "$migrate_status" -eq 2 ] || fail "the migrate-to-app plan must exit 2, got $migrate_status"
    case "$migrate_output" in
      *"would perform this transaction:"*) ;;
      *) fail "migrate-to-app printed no plan" ;;
    esac
    # The Burrito prepend is what makes this stage mean anything: the plan has
    # to name the unpacked release's own launcher among the `fermix` binaries
    # on PATH. Without it the probe would pass vacuously.
    path_line="$(printf '%s\n' "$migrate_output" | grep -F 'on PATH:' || true)"
    case "$path_line" in
      *"/.burrito/"*) ;;
      *) fail "the migrate-to-app plan did not name the unpacked release's own launcher on PATH: ${path_line:-no PATH line}" ;;
    esac
    ;;
  *)
    fail "unhandled standalone target in the migrate-to-app gate: $target"
    ;;
esac

# ── the packaged macOS spawn shim ───────────────────────────────────────────
disclaim=""
while IFS= read -r -d '' candidate; do
  disclaim="$candidate"
  break
# The unpacked release names each application directory with its version
# (lib/fermix_nif-<version>/priv), which is not the source tree's
# apps/fermix_nif/priv; a pattern written to the source layout matched no
# release at all.
done < <(find "$home" -type f -path '*/fermix_nif-*/priv/disclaim' -print0)

[ -n "$disclaim" ] || fail "packaged disclaim shim not found in the isolated smoke home"
[ -x "$disclaim" ] || fail "packaged disclaim shim is not executable"

if ! check_output="$("$disclaim" --check 2>&1)"; then
  printf '%s\n' "$check_output" >&2
  fail "packaged disclaim shim self-check failed"
fi
printf '%s\n' "$check_output"
