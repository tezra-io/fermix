#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Structural tests for native app-engine release automation."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"
LINUX_PACKAGES_WORKFLOW = ROOT / ".github/workflows/linux-packages.yml"
NIF_MAKEFILE = ROOT / "apps/fermix_nif/Makefile"
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.ci = CI_WORKFLOW.read_text(encoding="utf-8")
        self.linux_packages = LINUX_PACKAGES_WORKFLOW.read_text(encoding="utf-8")

    def test_external_actions_are_pinned_in_release_and_ci(self):
        for path, contents in (
            (RELEASE_WORKFLOW, self.release),
            (CI_WORKFLOW, self.ci),
            (LINUX_PACKAGES_WORKFLOW, self.linux_packages),
        ):
            for reference in USES.findall(contents):
                if reference.startswith("./"):
                    continue
                with self.subTest(workflow=path.name, reference=reference):
                    self.assertIn("@", reference)
                    revision = reference.rsplit("@", 1)[1]
                    self.assertRegex(revision, FULL_SHA)

    def test_builds_both_app_engines_natively_and_hands_them_off(self):
        self.assertIn("{ os: macos-15, target: macos_aarch64 }", self.release)
        self.assertIn("{ os: macos-15-intel, target: macos_x86_64 }", self.release)
        self.assertIn("macos_aarch64", self.release)
        self.assertIn("macos_x86_64", self.release)
        self.assertIn("scripts/release/build_app_engine.sh", self.release)
        self.assertIn("actions/upload-artifact@", self.release)
        self.assertIn("actions/download-artifact@", self.release)
        self.assertIn("app_engine_out", self.release)

    def test_publication_keeps_engine_archives_outside_standalone_feed(self):
        self.assertIn("./scripts/release/build_releases_json.sh > burrito_out/releases.json", self.release)
        self.assertIn("burrito_out/releases.json", self.release)
        self.assertRegex(
            self.release,
            r"app_engine_out/fermix_app_engine_\*",
            "the release candidate must publish app-engine archives and their sidecars",
        )
        self.assertNotRegex(
            self.release,
            r"build_releases_json\.sh\s*>\s*app_engine_out",
            "app-engine archives must never enter the standalone releases.json feed",
        )

    def test_verifies_exact_tag_bound_identity_for_every_engine(self):
        self.assertIn("target: macos_aarch64", self.release)
        self.assertIn("target: macos_x86_64", self.release)
        self.assertIn("fermix_app_engine_${{ matrix.target }}.tar.gz", self.release)
        self.assertIn("--certificate-identity ", self.release)
        self.assertIn(
            ".github/workflows/release.yml@refs/tags/${{ github.ref_name }}",
            self.release,
        )
        self.assertNotIn("--certificate-identity-regexp", self.release)

    def test_runtime_smokes_bind_every_engine_to_the_workflow_source_commit(self):
        source_bindings = re.findall(
            r"^\s+SOURCE_COMMIT: \$\{\{ github\.sha \}\}$",
            self.release,
            re.MULTILINE,
        )
        self.assertEqual(len(source_bindings), 2)
        self.assertEqual(self.release.count('"$SOURCE_COMMIT"'), 2)

    def test_ci_runs_intel_and_release_script_tests_as_required_gates(self):
        self.assertIn("macos-15-intel", self.ci)
        self.assertIn('for t in scripts/release/test_*.py; do echo "== $t =="; uv run "$t" || exit 1; done', self.ci)
        self.assertRegex(self.ci, r"needs:\s*\[[^\]]*release-scripts[^\]]*\]")
        self.assertIn("${{ needs.release-scripts.result }}", self.ci)

    # The Apple Maps helper is built by the Makefile on CI's macOS legs and on
    # the app-engine release runners alike; the CI step's own copy of the flags
    # is what holds the line if the Makefile's are loosened.
    def test_ci_compiles_the_apple_maps_helper_with_the_makefile_flags(self):
        makefile = NIF_MAKEFILE.read_text(encoding="utf-8")
        flags = re.search(r"^MAPS_SWIFTFLAGS = (.+)$", makefile, re.MULTILINE)
        self.assertIsNotNone(flags, "the Makefile names no MAPS_SWIFTFLAGS")
        expected = flags.group(1).replace("$(MAPS_ARCH)", "$(uname -m)")
        self.assertIn("-warnings-as-errors", expected)
        self.assertIn("-apple-macos15.0", expected)
        compiles = [
            line.strip().replace('"', "").rstrip(" \\")
            for line in self.ci.splitlines()
            if line.strip().startswith("swiftc -") and "--version" not in line
        ]
        self.assertEqual(compiles, [f"swiftc {expected}"])
        self.assertIn("if: runner.os == 'macOS'", self.ci)
        self.assertIn('"$helper" --check', self.ci)

    def test_refuses_to_replace_an_already_published_release(self):
        self.assertGreaterEqual(
            self.release.count("Refuse published release replacement"),
            2,
        )
        self.assertEqual(
            self.release.count("scripts/release/refuse_published_release.sh"),
            2,
        )
        self.assertNotIn("github.run_attempt", self.release)

    def test_refuses_a_tag_whose_commit_is_not_on_main_before_building(self):
        preflight = self._job("preflight")

        # Ancestry needs main's history; a depth-one checkout cannot decide it.
        self.assertRegex(
            preflight,
            r"uses: actions/checkout@[0-9a-f]{40} # v\S+\n\s+with:\n(?:\s+#[^\n]*\n)*\s+fetch-depth: 0\n",
        )
        self.assertIn("COMMIT: ${{ github.sha }}", preflight)
        self.assertIn('scripts/release/refuse_unmerged_tag.sh "$COMMIT"', preflight)
        for job in ("standalone", "linux-packages", "app-engine"):
            with self.subTest(job=job):
                self.assertIn("needs: preflight\n", self._job(job))

    # The build jobs compare the helper's and its notices' digests with the pin
    # and nothing more, so preflight, which every build needs, is where their
    # signatures are checked.
    def test_preflight_verifies_the_pinned_iroh_helper_against_its_signatures(self):
        preflight = self._job("preflight")
        installer = re.search(r"uses: sigstore/cosign-installer@[0-9a-f]{40} # v\S+\n", self._job("sign-candidate"))
        self.assertIsNotNone(installer, "sign-candidate installs no pinned cosign")
        self.assertIn(installer.group(0), preflight)
        self.assertIn("- uses: astral-sh/setup-uv@d4b2f3b6ecc6e67c4457f6d3e41ec42d3d0fcb86 # v5.4.2\n", preflight)
        check = "        run: uv run scripts/release/pin_iroh_helper.py --check\n"
        self.assertIn(check, preflight)
        self.assertLess(preflight.index(installer.group(0)), preflight.index(check))
        self.assertLess(preflight.index("astral-sh/setup-uv@"), preflight.index(check))
        self.assertNotIn("continue-on-error", preflight)

    def test_only_publishing_waits_on_the_release_environment(self):
        environments = re.findall(
            r"^  ([a-z][a-z0-9-]*):\n(?:    [^\n]*\n|\s*\n)*?    environment: (\S+)\n",
            self.release,
            re.MULTILINE,
        )
        # One approval per release: only promote waits on `release`; the tap job
        # runs after it in `homebrew`, which holds the tap credential.
        self.assertEqual(environments, [("promote", "release"), ("homebrew", "homebrew")])
        self.assertEqual(self.release.count("secrets.HOMEBREW_TAP_TOKEN"), 1)
        self.assertIn("secrets.HOMEBREW_TAP_TOKEN", self._job("homebrew"))

    def test_verifies_the_exact_push_authorized_draft_release(self):
        self.assertIn("release_id: ${{ steps.release.outputs.id }}", self.release)
        self.assertIn(
            "RELEASE_ID: ${{ needs.stage-release.outputs.release_id }}",
            self.release,
        )
        self.assertRegex(
            self.release,
            re.compile(
                r"verify-published:.*?permissions:\n\s+contents: write",
                re.DOTALL,
            ),
        )
        self.assertIn("/releases/$RELEASE_ID", self.release)
        self.assertNotIn('gh release download "$TAG_NAME"', self.release)

    def test_candidate_and_staged_jobs_share_standalone_verification(self):
        self.assertGreaterEqual(
            self.release.count("scripts/release/verify_standalone.sh"),
            2,
        )

    def test_signed_candidate_can_be_replaced_by_a_same_run_job_retry(self):
        self.assertIn(
            "name: signed-release-candidate\n          overwrite: true",
            self.release,
        )

    def test_builds_both_linux_packages_from_the_tag_the_engines_come_from(self):
        self.assertRegex(
            self.release,
            r"\n  linux-packages:\n    name: Build Linux packages \(\$\{\{ matrix.target \}\}\)\n    needs: preflight\n",
        )
        self.assertIn("scripts/release/build_linux_packages.sh", self.release)
        # One job per target: a second build in the same checkout refuses on
        # the first build's leftovers, which is what a shared job did.
        self.assertIn("target: [linux_x86_64, linux_aarch64]", self.release)
        self.assertNotIn("for target in linux_x86_64 linux_aarch64; do", self.release)
        self.assertIn("FERMIX_BUILD_ID: release-${{ github.run_id }}", self.release)
        self.assertIn("name: linux-packages-${{ matrix.target }}\n", self.release)
        self.assertIn("pattern: linux-packages-*\n          path: linux_packages\n          merge-multiple: true", self.release)
        self.assertIn("packaging/linux/out/packages/*.deb", self.release)
        self.assertIn("packaging/linux/out/packages/*.rpm", self.release)
        # patchelf is what points the packaged interpreters at the loader the
        # package materialises; without it the release step refuses.
        self.assertIn("patchelf", self.release)

    def test_every_package_is_signed_beside_the_binaries_of_the_same_tag(self):
        self.assertIn("needs: [standalone, linux-packages, app-engine]", self.release)
        self.assertIn("linux_packages/fermix_*.deb", self.release)
        self.assertIn("linux_packages/fermix-*.rpm", self.release)
        self.assertIn('[ "${#unsigned[@]}" -eq 10 ]', self.release)
        self.assertIn("linux_packages/fermix*", self.release)

    def test_the_release_feed_is_generated_where_both_halves_are_present(self):
        self.assertIn("PACKAGES_DIR: linux_packages", self.release)
        self.assertRegex(
            self.release,
            re.compile(
                r"sign-candidate:.*?PACKAGES_DIR: linux_packages.*?verify-candidate:",
                re.DOTALL,
            ),
            "releases.json must be built in the job that holds the packages",
        )

    def test_both_verification_jobs_install_every_package_on_a_real_host(self):
        for row in (
            "{ name: deb-linux-x64, os: ubuntu-24.04, kind: deb, target: linux_x86_64, package_arch: amd64, mode: native }",
            "{ name: deb-linux-arm64, os: ubuntu-24.04-arm, kind: deb, target: linux_aarch64, package_arch: arm64, mode: native }",
            "{ name: rpm-linux-x64, os: ubuntu-24.04, kind: rpm, target: linux_x86_64, package_arch: x86_64, mode: native }",
            "{ name: rpm-linux-arm64, os: ubuntu-24.04-arm, kind: rpm, target: linux_aarch64, package_arch: aarch64, mode: native }",
        ):
            with self.subTest(row=row):
                self.assertEqual(self.release.count(row), 2)

        self.assertEqual(self.release.count("scripts/release/verify_linux_package.sh"), 2)

    def test_the_staged_release_carries_the_packages(self):
        self.assertRegex(
            self.release,
            re.compile(r"files: \|\n(?:\s+\S+\n)*\s+linux_packages/fermix\*", re.MULTILINE),
        )

    def test_a_branch_can_build_packages_without_signing_or_publishing(self):
        self.assertIn("workflow_dispatch:", self.linux_packages)
        self.assertIn("pull_request:", self.linux_packages)
        for path in (
            "packaging/linux/**",
            "scripts/release/build_linux_packages.sh",
            "scripts/release/linux_packages.py",
            "mix.exs",
        ):
            with self.subTest(path=path):
                self.assertIn(f"- {path}", self.linux_packages)

        self.assertIn("FERMIX_BUILD_ID: pr-${{ github.run_id }}", self.linux_packages)
        self.assertIn('\'["linux_x86_64","linux_aarch64"]\'', self.linux_packages)
        self.assertNotIn("if: github.event_name", self.linux_packages)
        self.assertIn("scripts/release/build_linux_packages.sh", self.linux_packages)
        self.assertNotIn("cosign", self.linux_packages)
        self.assertNotIn("softprops/action-gh-release", self.linux_packages)

    # The package build places the pinned iroh helper, so a pin bump, a
    # change to the step that places it or to the verifier builds the
    # packages, and the x86_64 deb is installed and verified before any tag.
    def test_a_helper_pin_change_builds_and_verifies_the_packages(self):
        paths = re.search(r"\n  pull_request:\n    paths:\n((?:      - \S+\n)+)", self.linux_packages)
        self.assertIsNotNone(paths, "linux-packages.yml has no pull_request paths filter")
        for path in (
            "apps/fermix_core/priv/iroh_helper/PIN.json",
            "apps/fermix_core/lib/fermix_core/release/iroh_helper.ex",
            "scripts/release/verify_linux_package.sh",
        ):
            with self.subTest(path=path):
                self.assertIn(f"      - {path}\n", paths.group(1))

        step = re.search(
            r"\n      - name: Install and run the deb\n(.*?)(?=\n      - |\Z)", self.linux_packages, re.DOTALL
        )
        self.assertIsNotNone(step, "linux-packages.yml installs and verifies no deb")
        body = step.group(1)
        self.assertIn("        if: matrix.target == 'linux_x86_64'\n", body)
        self.assertIn("""awk -F '"' '/^      version:/ { print $2; exit }' mix.exs""", body)
        self.assertIn(
            "          scripts/release/verify_linux_package.sh \\\n"
            '            "packaging/linux/out/packages/fermix_${version}_amd64.deb" \\\n'
            "            deb \\\n"
            '            "$version"',
            body,
        )
        self.assertLess(
            self.linux_packages.index("- name: Build the package target"),
            self.linux_packages.index("- name: Install and run the deb"),
        )
        # One run of the verifier; its only other mention is the paths filter.
        self.assertEqual(body.count("scripts/release/verify_linux_package.sh"), 1)
        self.assertEqual(self.linux_packages.count("scripts/release/verify_linux_package.sh"), 2)

    def test_the_advertised_installer_is_run_against_the_published_release(self):
        job = re.search(r"\n  installer:\n(.*?)\n  homebrew:\n", self.release, re.DOTALL)
        self.assertIsNotNone(job, "release.yml has no installer job ahead of homebrew")
        body = job.group(1)

        # The installer reads the public `latest` feed, which a draft is not.
        self.assertIn("needs: promote\n", body)
        self.assertIn("if: ${{ !contains(github.ref_name, '-') }}", body)
        for row in (
            "{ name: deb-linux-x64, os: ubuntu-24.04, kind: deb }",
            "{ name: deb-linux-arm64, os: ubuntu-24.04-arm, kind: deb }",
            "{ name: rpm-linux-x64, os: ubuntu-24.04, kind: rpm }",
            "{ name: rpm-linux-arm64, os: ubuntu-24.04-arm, kind: rpm }",
        ):
            with self.subTest(row=row):
                self.assertIn(row, body)
        # Without cosign the installer skips the signature check, loudly, and
        # the verification requires that it ran.
        self.assertIn("sigstore/cosign-installer@", body)
        self.assertIn("scripts/release/verify_installer.sh", body)
        # Nothing may wait on a job that can only run once the release is out.
        self.assertNotRegex(self.release, r"needs:[^\n]*\binstaller\b")

    def test_homebrew_formula_is_installed_and_reports_the_release_version(self):
        self.assertIn("runs-on: macos-15", self.release)
        self.assertIn("brew install tezra-io/tap/fermix", self.release)
        self.assertIn('fermix --version | grep -F "$version"', self.release)

    def _job(self, name):
        job = re.search(
            rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)",
            self.release,
            re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(job, f"release.yml has no {name} job")
        return job.group(1)


if __name__ == "__main__":
    unittest.main()
