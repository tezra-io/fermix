#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for scripts/always_on_test_daemon.sh, the throwaway Always On daemon.

Nothing here reaches GitHub, launchd, the Keychain or the account's home: the
script runs with HOME in a directory this test owns and a PATH that holds only
this test's stand-ins (and the handful of real tools it needs). The release it
downloads is a stand-in `fermix` that writes the agent, answers the health
probe through the stand-in curl, and keeps its state under that HOME, because
the script hands the engine nothing else of its environment.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/always_on_test_daemon.sh"

VERSION = "9.9.9"
ARTIFACT = "fermix_macos_aarch64"
DOWNLOAD = f"github.com/tezra-io/fermix/releases/download/v{VERSION}"
LATEST = "github.com/tezra-io/fermix/releases/latest/download/releases.json"
IDENTITY = "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v"
ISSUER = "https://token.actions.githubusercontent.com"
MARKER = "This directory is a throwaway Fermix made by scripts/always_on_test_daemon.sh; its down removes it.\n"
RUNTIME = f"Library/Application Support/.burrito/fermix_erts-16.3_{VERSION}"

REAL_TOOLS = ("awk", "bash", "cat", "chmod", "cp", "env", "find", "head", "id", "mkdir", "mktemp", "mv", "rm", "sed", "sort", "touch")

# The released binary, as far as this script uses it. It runs under `env -i`
# with HOME and FERMIX_HOME only, so its state is under HOME/.fake.
FAKE_FERMIX = r"""#!/bin/sh
fake="$HOME/.fake"
runtime="$HOME/Library/Application Support/.burrito/fermix_erts-16.3_9.9.9"
printf '%s\n' "$*" >> "$fake/fermix.log"
case "$*" in
  "version") echo "fermix 9.9.9" ;;
  "maintenance directory") printf '%s\n' "$runtime" ;;
  "maintenance uninstall")
    read -r answer
    [ "$answer" = y ] && rm -rf "$runtime"
    ;;
  "setup --web --user --no-browser")
    env > "$fake/setup.env"
    port="$(awk '/^\[fermix_web\]/ { web = 1; next } /^\[/ { web = 0 } web && $1 == "port" { print $3 }' "$FERMIX_HOME/config.toml")"
    mkdir -p "$runtime" "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/io.tezra.fermix.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.tezra.fermix</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FERMIX_HOME</key><string>$FERMIX_HOME</string>
    <key>PATH</key><string>/usr/bin:/bin</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>$0</string>
    <string>run</string>
  </array>
</dict>
</plist>
PLIST
    : > "$fake/loaded"
    printf 'Open Fermix setup in your browser:\n  http://127.0.0.1:%s/setup?t=launch-token\nWaiting for the daemon to come up...\n' "$port"
    ;;
  "service uninstall --user")
    rm -f "$HOME/Library/LaunchAgents/io.tezra.fermix.plist" "$fake/loaded"
    ;;
  "home status --json"|"home status")
    if [ -f "$fake/home-status.json" ]; then
      cat "$fake/home-status.json"
      exit "$(cat "$fake/home-status.code")"
    fi
    echo "fermix: unknown command: home" >&2
    echo "usage" >&2
    exit 2
    ;;
  *) echo "fake fermix: unexpected: $*" >&2; exit 64 ;;
esac
"""

FAKE_UNAME = """#!/bin/sh
case "$1" in
  -s) printf '%s\\n' "${FAKE_UNAME_S:-Darwin}" ;;
  -m) printf 'arm64\\n' ;;
  *) exit 2 ;;
esac
"""

# A download is a file under $FAKE_REMOTE; the daemon's health answers while
# the stand-in agent is loaded.
FAKE_CURL = """#!/bin/sh
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\\n' "$url" >> "$HOME/.fake/curl.log"
case "$url" in
  http://127.0.0.1:*/health/live)
    [ -f "$HOME/.fake/loaded" ] || exit 7
    printf '{"app":"fermix","status":"ok","timestamp":"2031-05-04T11:50:00Z","version":"%s"}' "${FAKE_HEALTH_VERSION:-9.9.9}"
    exit 0
    ;;
esac
source="$FAKE_REMOTE/${url#https://}"
[ -f "$source" ] || exit 22
cat "$source" > "$output"
"""

# The certificate holds the identity it was minted for, so a signature from
# another tag fails here the way it fails in cosign.
FAKE_COSIGN = """#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/.fake/cosign.log"
[ "$1" = verify-blob ] || exit 64
shift
cert=""; identity=""; issuer=""
while [ "$#" -gt 1 ]; do
  case "$1" in
    --certificate) cert="$2"; shift 2 ;;
    --signature) shift 2 ;;
    --certificate-identity) identity="$2"; shift 2 ;;
    --certificate-oidc-issuer) issuer="$2"; shift 2 ;;
    *) exit 64 ;;
  esac
done
[ "$(cat "$cert")" = "$identity" ] || { echo "none of the expected identities matched" >&2; exit 1; }
[ "$issuer" = "https://token.actions.githubusercontent.com" ] || exit 1
echo "Verified OK" >&2
"""

FAKE_LAUNCHCTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/.fake/launchctl.log"
[ "$1" = print ] || exit 64
case "$2" in
  gui/*/io.tezra.fermix)
    [ -f "$HOME/.fake/loaded" ] || { echo 'Could not find service "io.tezra.fermix"'; exit 113; }
    printf 'gui/501/io.tezra.fermix = {\\n\\tstate = running\\n\\tpid = 4242\\n}\\n'
    ;;
  *) exit 64 ;;
esac
"""

FAKE_LSOF = """#!/bin/sh
for arg in "$@"; do
  case "$arg" in -iTCP:*) port="${arg#-iTCP:}" ;; esac
done
for busy in $FAKE_LISTENING; do
  [ "$busy" = "$port" ] && exit 0
done
exit 1
"""

FAKE_PS = """#!/bin/sh
[ -f "$HOME/.fake/ps" ] && cat "$HOME/.fake/ps"
exit 0
"""

FAKE_OPEN = """#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/.fake/open.log"
"""

FAKE_SLEEP = """#!/bin/sh
exit 0
"""

# The login Keychain as one item name a line under HOME/.fake/keychain, all on
# the fermix account.
FAKE_SECURITY = """#!/bin/sh
store="$HOME/.fake/keychain"
touch "$store"
case "$1" in
  dump-keychain)
    while IFS= read -r name; do
      printf 'keychain: "/Users/tester/Library/Keychains/login.keychain-db"\\nclass: "genp"\\nattributes:\\n'
      printf '    "acct"<blob>="fermix"\\n    "svce"<blob>="%s"\\n' "$name"
    done < "$store"
    ;;
  delete-generic-password)
    [ "$2 $3 $4" = "-a fermix -s" ] || exit 64
    line="$(awk -v name="$5" '$0 == name { print NR; exit }' "$store")"
    [ -n "$line" ] || exit 44
    awk -v n="$line" 'NR != n' "$store" > "$store.new" && mv "$store.new" "$store"
    ;;
  *) exit 64 ;;
esac
"""


class AlwaysOnTestDaemonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fermix-aot-")
        base = Path(self.tmp.name)
        self.home = base / "home"
        self.fake = self.home / ".fake"
        self.fake.mkdir(parents=True)
        self.remote = base / "remote"
        self.bin = base / "bin"
        self.bin.mkdir()
        self.root = self.home / "fermix-always-on-test"
        self.plist = self.home / "Library/LaunchAgents/io.tezra.fermix.plist"
        self.runtime = self.home / RUNTIME
        self._install_tools()
        self.publish(identity=f"{IDENTITY}{VERSION}")

    def tearDown(self):
        self.tmp.cleanup()

    # ── the world ────────────────────────────────────────────────────────────

    def _install_tools(self):
        for tool in REAL_TOOLS:
            found = shutil.which(tool)
            self.assertIsNotNone(found, f"{tool} is needed on the test host")
            (self.bin / tool).symlink_to(found)
        (self.bin / "uv").symlink_to(shutil.which("uv"))
        stand_ins = {
            "uname": FAKE_UNAME,
            "curl": FAKE_CURL,
            "cosign": FAKE_COSIGN,
            "launchctl": FAKE_LAUNCHCTL,
            "lsof": FAKE_LSOF,
            "ps": FAKE_PS,
            "open": FAKE_OPEN,
            "sleep": FAKE_SLEEP,
            "security": FAKE_SECURITY,
            "shasum": f"#!{sys.executable}\nimport hashlib, sys\n"
            "print(hashlib.sha256(open(sys.argv[3], 'rb').read()).hexdigest() + '  ' + sys.argv[3])\n",
        }
        for name, body in stand_ins.items():
            self._executable(self.bin / name, body)

    def _executable(self, path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def publish(self, identity, digest=None, latest=VERSION):
        release = self.remote / DOWNLOAD
        release.mkdir(parents=True, exist_ok=True)
        binary = release / ARTIFACT
        self._executable(binary, FAKE_FERMIX)
        actual = hashlib.sha256(binary.read_bytes()).hexdigest()
        (release / f"{ARTIFACT}.sha256").write_text(f"{digest or actual}  {ARTIFACT}\n", encoding="utf-8")
        (release / f"{ARTIFACT}.sig").write_text("signature\n", encoding="utf-8")
        (release / f"{ARTIFACT}.pem").write_text(identity, encoding="utf-8")
        manifest = self.remote / LATEST
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({"schema_version": 1, "latest": latest}, indent=2), encoding="utf-8")

    def run_script(self, *args, extra_env=None):
        env = {
            "HOME": str(self.home),
            "USER": "tester",
            "TMPDIR": str(Path(self.tmp.name)),
            "PATH": str(self.bin),
            "FAKE_REMOTE": str(self.remote),
            "UV_PYTHON": sys.executable,
            "UV_CACHE_DIR": str(Path(self.tmp.name) / "uv-cache"),
            "UV_NO_CONFIG": "1",
            **(extra_env or {}),
        }
        return subprocess.run(
            [str(self.bin / "bash"), str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def up(self, *args, extra_env=None):
        result = self.run_script("up", "--release", VERSION, *args, extra_env=extra_env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def screen(self, state, role="primary", move=None, code=0):
        envelope = {
            "schema_version": 1,
            "ok": True,
            "result": {
                "role": role,
                "move": move,
                "summary": {"key": "k", "state": state, "sentence": f"The {state} sentence."},
            },
        }
        self.screen_envelope(envelope, code)

    def screen_envelope(self, envelope, code):
        (self.fake / "home-status.json").write_text(json.dumps(envelope), encoding="utf-8")
        (self.fake / "home-status.code").write_text(str(code), encoding="utf-8")

    def keychain(self, *names):
        (self.fake / "keychain").write_text("".join(f"{name}\n" for name in names), encoding="utf-8")

    def keychain_left(self):
        return (self.fake / "keychain").read_text(encoding="utf-8").split()

    def log(self, name):
        path = self.fake / f"{name}.log"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def assert_nothing_installed(self):
        self.assertFalse(self.root.exists())
        self.assertFalse(self.plist.exists())
        self.assertFalse((self.fake / "loaded").exists())
        self.assertEqual(self.log("open"), "")

    # ── usage ────────────────────────────────────────────────────────────────

    def test_usage_errors_exit_2_before_anything_runs(self):
        for args in ([], ["bogus"], ["up", "--release"], ["up", "--release", "latest"], ["up", "--source"], ["status", "x"], ["down", "x"]):
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
        self.assert_nothing_installed()

    def test_a_release_may_be_named_with_its_tag(self):
        result = self.run_script("up", "--release", f"v{VERSION}")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Fermix {VERSION} (published", result.stdout)

    # ── up refuses ───────────────────────────────────────────────────────────

    def test_up_refuses_off_a_mac(self):
        result = self.run_script("up", extra_env={"FAKE_UNAME_S": "Linux"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("runs only on a Mac", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_while_the_label_is_loaded(self):
        (self.fake / "loaded").touch()

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("launchd already has io.tezra.fermix loaded", result.stderr)
        self.assertFalse(self.root.exists())
        self.assertEqual(self.log("curl"), "")

    def test_up_refuses_while_the_agent_file_exists(self):
        self.plist.parent.mkdir(parents=True)
        self.plist.write_text("someone else's agent", encoding="utf-8")

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("io.tezra.fermix.plist already exists", result.stderr)
        self.assertEqual(self.plist.read_text(encoding="utf-8"), "someone else's agent")
        self.assertFalse(self.root.exists())

    def test_up_refuses_a_root_it_did_not_make(self):
        self.root.mkdir()
        (self.root / "notes.txt").write_text("keep me", encoding="utf-8")

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("has no marker of this script", result.stderr)
        self.assertEqual((self.root / "notes.txt").read_text(encoding="utf-8"), "keep me")

    def test_up_refuses_a_root_it_already_made(self):
        self.up()

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("a throwaway daemon is already set up at", result.stderr)

    def test_up_refuses_another_fermix_on_path(self):
        self._executable(self.bin / "fermix", "#!/bin/sh\nexit 0\n")

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"another fermix is installed at {self.bin / 'fermix'}", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_while_a_fermix_runs_from_the_shared_runtime(self):
        base = self.home / "Library/Application Support/.burrito"
        (self.fake / "ps").write_text(f"/usr/bin/login\n{base}/fermix_erts-16.3_0.1.0/erts-16.3/bin/beam.smp -- run\n", encoding="utf-8")

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("a fermix runs from", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_a_runtime_of_its_version_already_unpacked(self):
        self.runtime.mkdir(parents=True)

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"a Fermix {VERSION} runtime is already unpacked", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_a_download_that_does_not_match_its_sidecar(self):
        self.publish(identity=f"{IDENTITY}{VERSION}", digest="0" * 64)

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match its sha256 sidecar", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_a_binary_signed_for_another_tag(self):
        self.publish(identity=f"{IDENTITY}9.9.8")

        result = self.run_script("up", "--release", VERSION)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"cosign did not verify {ARTIFACT} as signed by release.yml on refs/tags/v{VERSION}", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_a_release_that_was_not_published(self):
        result = self.run_script("up", "--release", "9.9.7")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"could not download {ARTIFACT} of release 9.9.7", result.stderr)
        self.assert_nothing_installed()

    def test_up_refuses_a_daemon_that_answers_as_another_version(self):
        result = self.run_script("up", "--release", VERSION, extra_env={"FAKE_HEALTH_VERSION": "0.0.1"})

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"answers, but not as Fermix {VERSION}", result.stderr)
        self.assertIn("run scripts/always_on_test_daemon.sh down to remove what up left", result.stderr)
        self.assertEqual(self.log("open"), "")

    # ── up ───────────────────────────────────────────────────────────────────

    def test_up_installs_the_verified_release_with_a_home_of_its_own(self):
        result = self.up(extra_env={"FAKE_LISTENING": "4731", "PORT": "4000", "FERMIX_OPIK_ENABLED": "1"})

        self.assertEqual((self.root / ".always-on-test-daemon").read_text(encoding="utf-8"), MARKER)
        self.assertEqual(
            (self.root / "bin/fermix").read_bytes(),
            (self.remote / DOWNLOAD / ARTIFACT).read_bytes(),
        )
        config = (self.root / "home/config.toml").read_text(encoding="utf-8")
        # 4731 is taken, so the whole first group is skipped.
        for line in (
            '[fermix_core]\nprofile = "always-on-test"\n',
            "[fermix_core.cues]\ndoor_port = 4742\n",
            "[fermix_channels.mobile]\nport = 4741\n",
            "[fermix_web]\nport = 4740\n",
            "[fermix_core.always_on]\nenabled = true\n",
        ):
            self.assertIn(line, config)
        state = (self.root / "state").read_text(encoding="utf-8")
        self.assertIn(f"version={VERSION}\nport=4740\nruntime={self.runtime}\n", state)
        self.assertEqual(self.log("open"), "http://127.0.0.1:4740/setup?t=launch-token\n")
        self.assertIn("Web setup (opened in your browser): http://127.0.0.1:4740/setup?t=launch-token", result.stdout)

    def test_up_verifies_the_signature_against_the_tag_and_the_workflow_issuer(self):
        self.up()

        cosign = self.log("cosign")
        self.assertIn(f"--certificate-identity {IDENTITY}{VERSION} ", cosign)
        self.assertIn(f"--certificate-oidc-issuer {ISSUER} ", cosign)

    def test_up_hands_the_engine_only_its_home_and_a_bare_path(self):
        self.up(extra_env={"PORT": "4000", "FERMIX_OPIK_ENABLED": "1", "FERMIX_INSTALL_DIR": "/elsewhere"})

        setup_env = dict(
            line.split("=", 1) for line in (self.fake / "setup.env").read_text(encoding="utf-8").splitlines() if "=" in line
        )
        self.assertEqual(setup_env["FERMIX_HOME"], str(self.root / "home"))
        self.assertEqual(setup_env["HOME"], str(self.home))
        self.assertEqual(setup_env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        for name in ("PORT", "FERMIX_OPIK_ENABLED", "FERMIX_INSTALL_DIR", "FAKE_REMOTE"):
            self.assertNotIn(name, setup_env)

    def test_up_without_a_release_installs_the_latest(self):
        result = self.run_script("up")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"https://{LATEST}\n", self.log("curl"))
        self.assertIn(f"version={VERSION}\n", (self.root / "state").read_text(encoding="utf-8"))

    def test_up_names_the_older_runtimes_burrito_removes(self):
        older = self.home / "Library/Application Support/.burrito/fermix_erts-16.3_0.1.0"
        older.mkdir(parents=True)

        result = self.up()

        self.assertIn(f"Note: Burrito deletes {older} on this binary's first launch", result.stdout)

    def test_status_reports_the_daemon_and_what_the_home_says(self):
        self.up()

        result = self.run_script("status")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Release:   {VERSION}\n", result.stdout)
        self.assertIn("Setup:     http://127.0.0.1:4730/setup (signed in in the browser up opened;\n", result.stdout)
        self.assertIn("Service:   io.tezra.fermix running (pid 4242)\n", result.stdout)
        self.assertIn(f"runs {self.root / 'bin/fermix'}", result.stdout)
        self.assertIn("  fermix: unknown command: home\n  (exit 2)\n", result.stdout)
        self.assertNotIn("usage", result.stdout)

    def test_status_refuses_a_root_it_did_not_make(self):
        self.root.mkdir()

        result = self.run_script("status")

        self.assertEqual(result.returncode, 1)
        self.assertIn("has no marker of this script", result.stderr)

    # ── down ─────────────────────────────────────────────────────────────────

    def test_down_with_nothing_up_does_nothing(self):
        result = self.run_script("down")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Nothing to take down", result.stdout)

    def test_down_leaves_a_root_it_did_not_make(self):
        self.root.mkdir()
        (self.root / "notes.txt").write_text("keep me", encoding="utf-8")

        result = self.run_script("down")

        self.assertEqual(result.returncode, 1)
        self.assertIn("has no marker of this script", result.stderr)
        self.assertEqual((self.root / "notes.txt").read_text(encoding="utf-8"), "keep me")

    def test_down_leaves_an_agent_that_is_not_its_own(self):
        self.up()
        self.plist.write_text(self.plist.read_text(encoding="utf-8").replace(str(self.root / "bin/fermix"), "/opt/other/fermix"), encoding="utf-8")

        result = self.run_script("down")

        self.assertEqual(result.returncode, 1)
        self.assertIn("is not this root's and is left alone", result.stderr)
        self.assertIn("/opt/other/fermix", self.plist.read_text(encoding="utf-8"))
        self.assertTrue(self.root.exists())

    def test_down_leaves_a_label_loaded_without_an_agent_file_and_no_root(self):
        (self.fake / "loaded").touch()

        result = self.run_script("down")

        self.assertEqual(result.returncode, 1)
        self.assertIn("is not this script's and is left alone", result.stderr)
        self.assertTrue((self.fake / "loaded").exists())

    def test_down_refuses_while_always_on_holds_a_server_or_a_move(self):
        self.up()
        self.keychain("fermix:always-on-test:OPENAI_API_KEY")
        held = [
            {"state": "ready"},
            {"state": "creating"},
            {"state": "problem"},
            {"state": "moving", "move": {"phase": "streaming", "candidate": "fermix-a3f9", "sentence": "Moving."}},
            {"state": "on", "role": "device"},
            {"state": "off", "move": {"phase": "requested", "candidate": "fermix-a3f9", "sentence": "Moving."}},
        ]
        for case in held:
            with self.subTest(case=case):
                self.screen(**case)

                result = self.run_script("down")

                self.assertEqual(result.returncode, 1)
                self.assertIn(f'Always On says "The {case["state"]} sentence."', result.stderr)
                self.assertIn("move back or cancel in the web setup (http://127.0.0.1:4730/setup) first", result.stderr)
                self.assertTrue(self.plist.exists())
                self.assertTrue((self.root / "bin/fermix").exists())
                self.assertEqual(self.keychain_left(), ["fermix:always-on-test:OPENAI_API_KEY"])

    def test_down_refuses_a_home_status_it_cannot_read(self):
        self.up()
        self.screen_envelope(
            {"schema_version": 1, "ok": False, "error": {"code": "home_status_unavailable", "sentence": "Fermix could not read this home's status."}},
            1,
        )

        result = self.run_script("down")

        self.assertEqual(result.returncode, 1)
        self.assertIn("fermix home status refused: Fermix could not read this home's status.", result.stderr)
        self.assertTrue(self.plist.exists())

    def test_down_removes_the_service_the_profile_items_the_runtime_and_the_root(self):
        self.up()
        self.assertTrue(self.runtime.exists())
        self.keychain(
            "fermix:always-on-test:OPENAI_API_KEY",
            "fermix:OPENAI_API_KEY",
            "fermix:always-on-test:ANTHROPIC_API_KEY",
            "fermix:always-on-test:ANTHROPIC_API_KEY",
            "fermix:fermix-dev:OPENAI_API_KEY",
            "fermix:always-on-tester:OPENAI_API_KEY",
        )

        result = self.run_script("down")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Fermix {VERSION} predates Always On, so it holds no server.", result.stdout)
        self.assertIn("Removed 2 Keychain items of profile always-on-test.", result.stdout)
        self.assertEqual(
            self.keychain_left(),
            ["fermix:OPENAI_API_KEY", "fermix:fermix-dev:OPENAI_API_KEY", "fermix:always-on-tester:OPENAI_API_KEY"],
        )
        self.assertFalse(self.plist.exists())
        self.assertFalse((self.fake / "loaded").exists())
        self.assertFalse(self.runtime.exists())
        self.assertFalse(self.root.exists())
        self.assertIn("service uninstall --user\n", self.log("fermix"))

    def test_down_proceeds_where_always_on_holds_nothing(self):
        for state in ("off", "connect"):
            with self.subTest(state=state):
                self.up()
                self.screen(state)

                result = self.run_script("down")

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Always On holds no server here ({state}).", result.stdout)
                self.assertFalse(self.root.exists())

    def test_down_proceeds_where_the_build_serves_no_always_on(self):
        self.up()
        self.screen_envelope(
            {"schema_version": 1, "ok": False, "error": {"code": "always_on_unavailable", "sentence": "Always On is not in this release of Fermix yet."}},
            1,
        )

        result = self.run_script("down")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"Fermix {VERSION} serves no Always On here, so it holds no server.", result.stdout)
        self.assertFalse(self.root.exists())

    def test_down_finishes_what_a_failed_up_left(self):
        failed = self.run_script("up", "--release", VERSION, extra_env={"FAKE_HEALTH_VERSION": "0.0.1"})
        self.assertEqual(failed.returncode, 1)

        result = self.run_script("down")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.root.exists())
        self.assertFalse(self.runtime.exists())


if __name__ == "__main__":
    unittest.main()
