#!/usr/bin/env bash
# Verify one standalone release artifact and its packaged macOS spawn shim.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <artifact> <target> <version>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

artifact="$1"
target="$2"
version="$3"

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
