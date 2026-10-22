#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Hermetic tests for the Docker Sandboxes kit in packaging/sbx/fermix (M64).

Every command the scripts run is a stand-in on PATH that logs its argv, so
nothing here starts Fermix, sleeps or opens a shell.
"""

import hashlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[2] / "packaging" / "sbx" / "fermix"
# The scripts the kit installs in /usr/lib/fermix/sandbox, and the build-time
# helper its recipe runs in the fetch stage.
SCRIPTS = KIT / "files" / "sandbox"
FETCH = KIT / "files" / "build" / "fetch-verified.sh"
BASH = shutil.which("bash")

# `fermix`: logs its argv; FAKE_FERMIX_EXIT sets its status. `fermix status`
# says "not running" (3) until its FAKE_STATUS_UP_AT-th call (never when 0).
FAKE_FERMIX = """#!/bin/sh
printf 'fermix %s\\n' "$*" >> "$FAKE_LOG"
if [ "$1" = status ]; then
  calls=$(( $(cat "$FAKE_LOG.status" 2>/dev/null || echo 0) + 1 ))
  echo "$calls" > "$FAKE_LOG.status"
  if [ "${FAKE_STATUS_UP_AT:-0}" -ne 0 ] && [ "$calls" -ge "$FAKE_STATUS_UP_AT" ]; then
    echo "fermix: running (pid 7)"
    exit 0
  fi
  echo "fermix: not running"
  exit 3
fi
printf 'console line\\n'
printf 'fermix stderr line\\n' >&2
exit "${FAKE_FERMIX_EXIT:-0}"
"""

FAKE_SLEEP = """#!/bin/sh
printf 'sleep %s\\n' "$*" >> "$FAKE_LOG"
"""

# The session ends in `exec bash -l`; the stand-in proves the hand-over.
FAKE_BASH = """#!/bin/sh
printf 'bash %s\\n' "$*" >> "$FAKE_LOG"
"""

# Stands in for the loop the boot hook execs, so a boot test ends there.
FAKE_LOOP = """#!/bin/sh
printf 'loop\\n' >> "$FAKE_LOG"
"""


# `caddy`: logs its argv; FAKE_CADDY_EXIT sets its status.
FAKE_CADDY = """#!/bin/sh
printf 'caddy %s\\n' "$*" >> "$FAKE_LOG"
exit "${FAKE_CADDY_EXIT:-0}"
"""

# `flock -n FD`: logs its argv; FAKE_FLOCK_BUSY=1 answers as a lock another
# relay holds. macOS has no flock, so the stand-in is always the one asked.
FAKE_FLOCK = """#!/bin/sh
printf 'flock %s\\n' "$*" >> "$FAKE_LOG"
[ "${FAKE_FLOCK_BUSY:-0}" = 1 ] && exit 1
exit 0
"""


def relay_routes() -> dict:
    """The relay's loopback port for each provider host, read off the Caddyfile."""
    text = (SCRIPTS / "fermix-relay.Caddyfile").read_text()
    sites = re.findall(r"^http://127\.0\.0\.1:(\d+) \{\n\timport provider (\S+)\n\}", text, re.M)
    return {host: int(port) for port, host in sites}


PROVIDER_HOSTS = {"anthropic": "api.anthropic.com", "openai": "api.openai.com", "xai": "api.x.ai"}


def relay_flags() -> str:
    """The base-URL flags the boot hook must pass: one relay port per provider."""
    routes = relay_routes()
    return "".join(
        f" --{provider}-base-url http://127.0.0.1:{routes[host]}/v1"
        for provider, host in PROVIDER_HOSTS.items()
    )

def write_tool(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text(body)
    path.chmod(0o755)


class KitCase(unittest.TestCase):
    def setUp(self) -> None:
        # A short root: the session test binds a unix socket under it, and the
        # socket address has a 104-byte limit on macOS.
        self.root = Path(tempfile.mkdtemp(prefix="sbx", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.root)
        self.home = self.root / "h"
        self.bin = self.root / "b"
        self.kit = self.root / "k"
        for directory in (self.home, self.bin, self.kit):
            directory.mkdir()
        self.log = self.root / "log"
        self.log.touch()
        write_tool(self.bin, "fermix", FAKE_FERMIX)
        write_tool(self.bin, "sleep", FAKE_SLEEP)

    def env(self, **extra: str) -> dict:
        # Only the stand-ins and the base system: a cosign or fermix installed
        # on the developer's machine must not answer for a stand-in.
        path = f"{self.bin}:/usr/bin:/bin"
        env = {"HOME": str(self.home), "PATH": path, "FAKE_LOG": str(self.log)}
        env.update(extra)
        return env

    def run_script(self, script: Path, *args: str, **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [BASH, str(script), *args],
            env=self.env(**extra),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def calls(self) -> list:
        return self.log.read_text().splitlines()


class LoopTest(KitCase):
    def test_restarts_after_every_exit_and_stops_after_the_fifth(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-loop", FAKE_FERMIX_EXIT="3")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            self.calls(),
            ["fermix run", "sleep 5"] * 4 + ["fermix run"],
        )
        self.assertIn("exited with status 3 (start 5 of 5)", result.stderr)
        self.assertIn("fermix run exited 5 times, so it stays stopped", result.stderr)
        self.assertIn(f"setsid {SCRIPTS / 'fermix-sandbox-loop'} &", result.stderr)

    def test_drops_the_console_log_and_keeps_what_fermix_run_says_on_stderr(self) -> None:
        # The daemon writes its log to stdout and to ~/.fermix/logs; only a
        # crash before the logger starts is worth keeping beside the boot log.
        result = self.run_script(SCRIPTS / "fermix-sandbox-loop", FAKE_FERMIX_EXIT="1")

        self.assertNotIn("console line", result.stdout + result.stderr)
        self.assertEqual(result.stderr.count("fermix stderr line"), 5)

    def test_a_clean_exit_also_counts_as_a_start(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-loop", FAKE_FERMIX_EXIT="0")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls().count("fermix run"), 5)


class BootTest(KitCase):
    def setUp(self) -> None:
        super().setUp()
        shutil.copy(SCRIPTS / "fermix-sandbox-boot", self.kit / "fermix-sandbox-boot")
        write_tool(self.kit, "fermix-sandbox-loop", FAKE_LOOP)
        self.boot = self.kit / "fermix-sandbox-boot"
        self.boot_log = self.home / ".fermix-sandbox-boot.log"
        self.done = self.home / ".fermix-sandbox-setup-done"

    def settings(self, provider: str) -> None:
        (self.home / ".fermix-sandbox").write_text(f"PROVIDER={provider}\n")

    def test_first_boot_runs_setup_with_the_placeholder_and_no_proxy(self) -> None:
        self.settings("openai")

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 0, self.boot_log.read_text())
        self.assertEqual(
            self.calls(),
            [
                "fermix setup --cli --no-service --skip-probe --secret-store file "
                "--provider openai --openai-api-key proxy-managed" + relay_flags(),
                "fermix status",
                "loop",
            ],
        )
        self.assertTrue(self.done.exists())

    def test_setup_reads_no_answers_from_whatever_stdin_the_hook_was_given(self) -> None:
        # A hook has no user at the keyboard: every question setup asks gets
        # end-of-input, so it takes the default instead of waiting.
        write_tool(
            self.bin,
            "fermix",
            '#!/bin/sh\n[ "$1" = status ] && exit 3\nread -r line && echo "read $line" >> "$FAKE_LOG"; exit 0\n',
        )
        self.settings("openai")

        result = subprocess.run(
            [BASH, str(self.boot)],
            env=self.env(OPENAI_API_KEY="proxy-managed"),
            input="an answer nobody typed\n",
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        self.assertEqual(result.returncode, 0, self.boot_log.read_text())
        self.assertEqual(self.calls(), ["loop"])

    def test_never_hands_fermix_the_sandbox_proxy(self) -> None:
        # Erlang/OTP refuses the credential proxy's certificate, so only the
        # relay talks to it; Fermix dials the relay on loopback.
        self.settings("anthropic")

        result = self.run_script(
            self.boot,
            ANTHROPIC_API_KEY="proxy-managed",
            HTTPS_PROXY="http://192.0.2.1:8889",
        )

        self.assertEqual(result.returncode, 0, self.boot_log.read_text())
        self.assertNotIn("--proxy", self.calls()[0])
        self.assertTrue(self.calls()[0].endswith(relay_flags()), self.calls()[0])

    def test_every_provider_goes_through_its_own_relay_port(self) -> None:
        # A later `fermix settings primary xai` must find xAI's relay already
        # set, so the hook names all three whichever provider comes first.
        routes = relay_routes()

        self.assertEqual(set(routes), set(PROVIDER_HOSTS.values()))
        self.assertEqual(len(set(routes.values())), len(routes), routes)

    def test_a_claude_sandbox_runs_haiku_and_the_others_take_fermix_default(self) -> None:
        for provider, model_flag in (
            ("anthropic", " --default-model claude-haiku-5-5"),
            ("openai", ""),
            ("xai", ""),
        ):
            with self.subTest(provider=provider):
                self.log.write_text("")
                self.done.unlink(missing_ok=True)
                self.settings(provider)

                result = self.run_script(self.boot, **{f"{provider.upper()}_API_KEY": "proxy-managed"})

                self.assertEqual(result.returncode, 0, self.boot_log.read_text())
                self.assertEqual(
                    self.calls()[0],
                    "fermix setup --cli --no-service --skip-probe --secret-store file "
                    f"--provider {provider} --{provider}-api-key proxy-managed{model_flag}"
                    + relay_flags(),
                )

    def test_a_later_boot_skips_setup_and_starts_the_loop(self) -> None:
        self.settings("openai")
        self.done.touch()

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["fermix status", "loop"])

    def test_a_boot_that_finds_fermix_running_leaves_it_to_its_loop(self) -> None:
        # A cloud stop is a pause: the daemon and its loop outlive the boot
        # that runs this hook again.
        self.settings("openai")
        self.done.touch()

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed", FAKE_STATUS_UP_AT="1")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["fermix status"])
        self.assertIn("Fermix is already running", self.boot_log.read_text())

    def test_reads_the_settings_file_without_running_it(self) -> None:
        marker = self.root / "ran"
        (self.home / ".fermix-sandbox").write_text(f"PROVIDER=openai\ntouch {marker}\n")

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 0, self.boot_log.read_text())
        self.assertFalse(marker.exists())

    def test_refuses_a_settings_file_that_names_two_providers(self) -> None:
        (self.home / ".fermix-sandbox").write_text("PROVIDER=openai\nPROVIDER=xai\n")

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed", XAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_a_failed_setup_stops_the_boot_and_runs_again_next_time(self) -> None:
        self.settings("openai")

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed", FAKE_FERMIX_EXIT="1")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(self.done.exists())
        log = self.boot_log.read_text()
        self.assertIn("fermix setup failed, so Fermix stays stopped", log)
        self.assertIn(f"then run: setsid {self.kit.resolve() / 'fermix-sandbox-boot'} &", log)

    def test_refuses_a_provider_the_kit_does_not_offer(self) -> None:
        self.settings("ollama")

        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertIn("must name one PROVIDER, openai, anthropic or xai, not 'ollama'", self.boot_log.read_text())

    def test_refuses_a_sandbox_without_the_provider_placeholder(self) -> None:
        self.settings("xai")

        result = self.run_script(self.boot)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertIn("XAI_API_KEY is not set", self.boot_log.read_text())

    def test_refuses_a_sandbox_without_the_kit_settings_file(self) -> None:
        result = self.run_script(self.boot, OPENAI_API_KEY="proxy-managed")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertIn(".fermix-sandbox is missing", self.boot_log.read_text())


class RelayTest(KitCase):
    def setUp(self) -> None:
        super().setUp()
        shutil.copy(SCRIPTS / "fermix-sandbox-relay", self.kit / "fermix-sandbox-relay")
        write_tool(self.kit, "caddy", FAKE_CADDY)
        write_tool(self.bin, "flock", FAKE_FLOCK)
        self.relay = self.kit / "fermix-sandbox-relay"
        self.relay_log = self.home / ".fermix-relay.log"
        self.caddy_run = (
            f"caddy run --config {self.kit.resolve() / 'fermix-relay.Caddyfile'} --adapter caddyfile"
        )

    def test_restarts_caddy_after_every_exit_and_stops_after_the_fifth(self) -> None:
        result = self.run_script(self.relay, HTTPS_PROXY="http://192.0.2.1:8889", FAKE_CADDY_EXIT="1")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), ["flock -n 9"] + [self.caddy_run, "sleep 5"] * 4 + [self.caddy_run])
        log = self.relay_log.read_text()
        self.assertIn("caddy exited with status 1 (start 5 of 5)", log)
        self.assertIn(f"then run: setsid {self.kit.resolve() / 'fermix-sandbox-relay'} &", log)

    def test_refuses_a_sandbox_without_the_credential_proxy(self) -> None:
        # No provider secret, no credential proxy: a relay would send the
        # placeholder straight to the provider.
        result = self.run_script(self.relay)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [])
        log = self.relay_log.read_text()
        self.assertIn("HTTPS_PROXY is not set", log)
        self.assertIn("sbx --cloud secret set", log)

    def test_a_relay_already_running_is_left_to_run(self) -> None:
        # A cloud stop is a pause: the relay outlives the boot that starts it again.
        result = self.run_script(self.relay, HTTPS_PROXY="http://192.0.2.1:8889", FAKE_FLOCK_BUSY="1")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["flock -n 9"])
        self.assertIn("the relay is already running", self.relay_log.read_text())


class CaddyfileTest(unittest.TestCase):
    def test_each_site_listens_on_loopback_and_dials_through_the_sandbox_proxy(self) -> None:
        text = (SCRIPTS / "fermix-relay.Caddyfile").read_text()
        snippet = re.search(r"^\(provider\) \{\n(.*?)^\}", text, re.M | re.S).group(1)

        self.assertIn("\tbind 127.0.0.1\n", snippet)
        self.assertIn("\treverse_proxy https://{args[0]} {", snippet)
        self.assertIn("\t\theader_up Host {args[0]}\n", snippet)
        self.assertIn("\t\t\tnetwork_proxy url {$HTTPS_PROXY}\n", snippet)
        self.assertIn("\tadmin off\n", text)


class ImageTest(unittest.TestCase):
    def test_the_image_installs_every_file_the_kit_runs(self) -> None:
        # The kit and the scripts name files under /usr/lib/fermix/sandbox; a
        # file the recipe never copies fails only in a sandbox.
        dockerfile = (KIT / "fermix.dockerfile").read_text()
        copied = set()
        for line in dockerfile.splitlines():
            if line.startswith("COPY "):
                *sources, destination = line.split()[1:]
                sources = [source for source in sources if not source.startswith("--")]
                if destination.endswith("/"):
                    copied.update(destination + Path(source).name for source in sources)
                else:
                    copied.add(destination)

        named = set()
        for path in (KIT / "fermix.yaml", SCRIPTS / "fermix-sandbox-boot", SCRIPTS / "fermix-sandbox-relay"):
            named.update(re.findall(r"/usr/lib/fermix/sandbox/[\w.-]+", path.read_text()))
        relay = (SCRIPTS / "fermix-sandbox-relay").read_text()
        for local in re.findall(r'"\$sandbox_dir/([\w.-]+)"', relay):
            named.add(f"/usr/lib/fermix/sandbox/{local}")

        self.assertTrue(named)
        self.assertEqual(named - copied, set())

    def test_every_file_the_recipe_copies_from_the_kit_exists(self) -> None:
        # The build context is the kit directory alone, so a mistyped source
        # fails only when Docker's CI builds the kit.
        sources = re.findall(r"\b(files/[\w./-]+)", (KIT / "fermix.dockerfile").read_text())

        self.assertTrue(sources)
        self.assertEqual([source for source in sources if not (KIT / source).is_file()], [])

    def test_the_kit_version_reaches_the_build_that_installs_and_checks_it(self) -> None:
        # One version drives the install, the provide and the published tag;
        # a buildArg the recipe never declares would build with no version.
        kit = (KIT / "fermix.yaml").read_text()
        build_arg = re.search(r"^  version:\n(?:    .*\n)*?    buildArg: (\w+)$", kit, re.M).group(1)
        stages = (KIT / "fermix.dockerfile").read_text().split("\nFROM ")[1:]

        self.assertIn('version: "${{ kit.args.version }}"', kit)
        self.assertIn('provides: ["fermix@${{ kit.args.version }}"]', kit)
        for stage in stages[1:]:
            self.assertIn(f"ARG {build_arg}\n", stage)
        self.assertIn(f'fetch-verified.sh "${{{build_arg}}}"', stages[1])
        self.assertIn(f'"$installed" != "${{{build_arg}}}"', stages[2])

    def test_the_build_unpacks_fermix_for_the_agent_so_no_two_first_runs_race(self) -> None:
        # The fermix binary unpacks its runtime into the user's home on its
        # first run, with no lock, so a second fermix started meanwhile reads
        # half-written files: on every first boot the boot hook's setup and a
        # session's `fermix status` start together.
        stage = (KIT / "fermix.dockerfile").read_text().split("\nFROM ")[-1]
        steps = [line for line in stage.splitlines() if re.match(r"(RUN|USER) ", line)]
        unpack = next((i for i, line in enumerate(steps) if re.match(r"RUN fermix\b", line)), None)
        install = next(i for i, line in enumerate(steps) if "dpkg -i" in line)

        self.assertIsNotNone(unpack)
        self.assertLess(install, unpack)
        self.assertEqual([line for line in steps[:unpack] if line.startswith("USER ")][-1], "USER agent")

    def test_the_image_carries_no_fermix_home(self) -> None:
        # Any fermix run writes a web secret_key_base into a new home; baked
        # into a public image, every sandbox would sign with the same key.
        dockerfile = (KIT / "fermix.dockerfile").read_text()
        unpack = re.search(r"^RUN fermix\b(?:.*\\\n)*.*$", dockerfile, re.M).group(0)

        self.assertIn('rmdir "$HOME/.fermix"', unpack)

    def test_the_relay_gets_the_sandbox_proxy_and_the_boot_hook_does_not(self) -> None:
        kit = (KIT / "fermix.yaml").read_text()
        startups = re.findall(
            r"- command: \[/usr/lib/fermix/sandbox/([\w-]+)\]\n\s+background: true\n\s+env: \[([^\]]*)\]",
            kit,
        )
        env = {command: [name.strip() for name in names.split(",")] for command, names in startups}

        self.assertEqual(env["fermix-sandbox-relay"], ["HTTPS_PROXY"])
        self.assertNotIn("HTTPS_PROXY", env["fermix-sandbox-boot"])


class SessionTest(KitCase):
    def setUp(self) -> None:
        super().setUp()
        write_tool(self.bin, "bash", FAKE_BASH)

    def test_a_tty_session_shows_the_status_then_opens_a_login_shell(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-session", "--shell", FAKE_STATUS_UP_AT="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["fermix status", "bash -l"])
        self.assertIn("fermix: running (pid 7)", result.stdout)

    def test_waits_until_the_daemon_answers_not_until_its_socket_exists(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-session", "--shell", FAKE_STATUS_UP_AT="3")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls(),
            ["fermix status", "sleep 1", "fermix status", "sleep 1", "fermix status", "bash -l"],
        )

    def test_a_headless_run_shows_the_status_then_follows_the_log(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-session", FAKE_STATUS_UP_AT="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["fermix status", "fermix logs -f"])

    def test_a_tty_session_waits_sixty_seconds_then_shows_the_boot_log_and_a_shell(self) -> None:
        (self.home / ".fermix-sandbox-boot.log").write_text("fermix-sandbox-boot: fermix setup failed\n")

        result = self.run_script(SCRIPTS / "fermix-sandbox-session", "--shell")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["fermix status", "sleep 1"] * 60 + ["fermix status", "bash -l"])
        self.assertIn("Fermix did not start within 60 seconds: fermix: not running", result.stderr)
        self.assertIn("fermix setup failed", result.stderr)

    def test_a_headless_run_without_a_daemon_fails_after_the_boot_log(self) -> None:
        (self.home / ".fermix-sandbox-boot.log").write_text("fermix-sandbox-boot: fermix setup failed\n")

        result = self.run_script(SCRIPTS / "fermix-sandbox-session")

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("fermix logs -f", self.calls())
        self.assertIn("fermix setup failed", result.stderr)

    def test_says_when_the_boot_hook_never_ran(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-session", "--shell")

        self.assertIn("the boot hook never ran", result.stderr)
        self.assertEqual(self.calls()[-1], "bash -l")

    def test_refuses_an_unknown_argument(self) -> None:
        result = self.run_script(SCRIPTS / "fermix-sandbox-session", "--shel")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


# `curl -fsSL --retry 3 -o OUT URL`: copies URL's file name out of the fake
# release, and fails like curl -f when the release has no such file.
FAKE_CURL = """#!/bin/sh
out="$5"; url="$6"
printf 'curl %s\\n' "$url" >> "$FAKE_LOG"
cp "$FAKE_RELEASE/${url##*/}" "$out" 2>/dev/null || exit 22
"""

# `cosign verify-blob ... BLOB`: refuses the blob whose name is in FAKE_COSIGN_REFUSE.
FAKE_COSIGN = """#!/bin/sh
for last; do :; done
printf 'cosign %s\\n' "$*" >> "$FAKE_LOG"
case "$last" in *"${FAKE_COSIGN_REFUSE:-no blob}"*) echo "invalid signature" >&2; exit 1 ;; esac
"""

# The build stage has GNU coreutils; macOS keeps them off the test's PATH, and
# shasum prints the same line.
FAKE_SHA256SUM = """#!/bin/sh
exec shasum -a 256 "$@"
"""
FAKE_SHA512SUM = """#!/bin/sh
exec shasum -a 512 "$@"
"""

VERSION = "9.8.7"
IDENTITY = f"https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v{VERSION}"
CADDY_VERSION = re.search(r"^readonly caddy_version=(\S+)$", FETCH.read_text(), re.M).group(1)
CADDY_IDENTITY = (
    f"https://github.com/caddyserver/caddy/.github/workflows/release.yml@refs/tags/v{CADDY_VERSION}"
)
CADDY_SUMS = f"caddy_{CADDY_VERSION}_checksums.txt"


class FetchVerifiedTest(KitCase):
    def setUp(self) -> None:
        super().setUp()
        self.release = self.root / "r"
        self.release.mkdir()
        self.out = self.root / "o"
        for name, body in (
            ("curl", FAKE_CURL),
            ("cosign", FAKE_COSIGN),
            ("sha256sum", FAKE_SHA256SUM),
            ("sha512sum", FAKE_SHA512SUM),
        ):
            write_tool(self.bin, name, body)
        for arch in ("amd64", "arm64"):
            self.publish(arch, f"package {arch}".encode())
        self.publish_caddy()

    # The recipe runs the helper with sh, as the build stage does.
    def fetch(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["/bin/sh", str(FETCH), *args],
            env=self.env(FAKE_RELEASE=str(self.release), **extra),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    # Caddy's release: one tarball per arch holding the `caddy` binary, and a
    # sha512 checksums file signed by Caddy's release workflow.
    def publish_caddy(self, digests: dict | None = None) -> None:
        sums = []
        for arch in ("amd64", "arm64"):
            name = f"caddy_{CADDY_VERSION}_linux_{arch}.tar.gz"
            staging = self.root / f"caddy-{arch}"
            staging.mkdir(exist_ok=True)
            (staging / "caddy").write_text(f"caddy {arch}")
            (staging / "LICENSE").write_text("license")
            subprocess.run(
                ["tar", "-czf", str(self.release / name), "-C", str(staging), "caddy", "LICENSE"],
                check=True,
            )
            sha = (digests or {}).get(arch) or hashlib.sha512((self.release / name).read_bytes()).hexdigest()
            sums.append(f"{sha} {name}\n")
        (self.release / CADDY_SUMS).write_text("".join(sums))
        (self.release / f"{CADDY_SUMS}.sig").write_text("sig")
        (self.release / f"{CADDY_SUMS}.pem").write_text("pem")

    def publish(self, arch: str, body: bytes, digest: str | None = None) -> None:
        name = f"fermix_{VERSION}_{arch}.deb"
        (self.release / name).write_bytes(body)
        sha = digest or hashlib.sha256(body).hexdigest()
        (self.release / f"{name}.sha256").write_text(f"{sha}  {name}\n")
        (self.release / f"{name}.sig").write_text("sig")
        (self.release / f"{name}.pem").write_text("pem")

    def assert_nothing_placed(self) -> None:
        self.assertEqual(sorted(self.out.iterdir()) if self.out.exists() else [], [])

    def test_places_the_package_and_caddy_after_both_verify(self) -> None:
        result = self.fetch(VERSION, "arm64", str(self.out))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.out / "fermix.deb").read_bytes(), b"package arm64")
        self.assertEqual((self.out / "caddy").read_text(), "caddy arm64")
        origin = f"https://github.com/tezra-io/fermix/releases/download/v{VERSION}"
        self.assertIn(f"curl {origin}/fermix_{VERSION}_arm64.deb.sig", self.calls())
        cosign = [line for line in self.calls() if line.startswith("cosign ")]
        self.assertEqual(len(cosign), 2)
        for line in cosign:
            identity = CADDY_IDENTITY if line.endswith(CADDY_SUMS) else IDENTITY
            self.assertIn(f"--certificate-identity {identity} ", line)
            self.assertIn("--certificate-oidc-issuer https://token.actions.githubusercontent.com ", line)

    def test_downloads_only_the_architecture_being_built(self) -> None:
        result = self.fetch(VERSION, "amd64", str(self.out))

        self.assertEqual(result.returncode, 0, result.stderr)
        downloads = [line for line in self.calls() if line.startswith("curl ")]
        self.assertTrue(downloads)
        self.assertEqual([line for line in downloads if "arm64" in line], [])
        self.assertEqual((self.out / "caddy").read_text(), "caddy amd64")

    def test_a_caddy_checksum_mismatch_places_nothing(self) -> None:
        self.publish_caddy(digests={"arm64": "0" * 128})

        result = self.fetch(VERSION, "arm64", str(self.out))

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"caddy_{CADDY_VERSION}_linux_arm64.tar.gz: sha512", result.stderr)
        self.assert_nothing_placed()

    def test_a_refused_caddy_signature_places_nothing(self) -> None:
        result = self.fetch(VERSION, "arm64", str(self.out), FAKE_COSIGN_REFUSE=CADDY_SUMS)

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{CADDY_SUMS}: cosign verify-blob failed: invalid signature", result.stderr)
        self.assert_nothing_placed()

    def test_a_package_checksum_mismatch_places_nothing(self) -> None:
        self.publish("arm64", b"package arm64", digest="0" * 64)

        result = self.fetch(VERSION, "arm64", str(self.out))

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"fermix_{VERSION}_arm64.deb: sha256", result.stderr)
        self.assert_nothing_placed()

    def test_a_refused_package_signature_places_nothing(self) -> None:
        result = self.fetch(VERSION, "arm64", str(self.out), FAKE_COSIGN_REFUSE=f"fermix_{VERSION}_arm64.deb")

        self.assertEqual(result.returncode, 1)
        self.assertIn("cosign verify-blob failed: invalid signature", result.stderr)
        self.assert_nothing_placed()

    def test_a_release_without_the_package_is_refused(self) -> None:
        (self.release / f"fermix_{VERSION}_arm64.deb.pem").unlink()

        result = self.fetch(VERSION, "arm64", str(self.out))

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"cannot download https://github.com/tezra-io/fermix/releases/download/v{VERSION}/fermix_{VERSION}_arm64.deb.pem",
            result.stderr,
        )
        self.assert_nothing_placed()

    def test_refuses_to_run_without_cosign(self) -> None:
        (self.bin / "cosign").unlink()

        result = self.fetch(VERSION, "arm64", str(self.out))

        self.assertEqual(result.returncode, 1)
        self.assertIn("cosign is required", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_refuses_a_version_with_a_leading_v(self) -> None:
        result = self.fetch(f"v{VERSION}", "arm64", str(self.out))

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_refuses_an_architecture_the_kit_does_not_build(self) -> None:
        result = self.fetch(VERSION, "riscv64", str(self.out))

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
