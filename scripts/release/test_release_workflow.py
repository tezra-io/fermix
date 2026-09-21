#!/usr/bin/env python3
"""Structural tests for native app-engine release automation."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"
LINUX_PACKAGES_WORKFLOW = ROOT / ".github/workflows/linux-packages.yml"
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
        self.assertIn("python3 -m unittest discover -s scripts/release", self.ci)
        self.assertRegex(self.ci, r"needs:\s*\[[^\]]*release-scripts[^\]]*\]")
        self.assertIn("${{ needs.release-scripts.result }}", self.ci)

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

    def test_the_linux_app_engine_archive_comes_off_the_package_build(self):
        # One compile per target stages one engine tree; the deb and the
        # archive are both made from it, so the release never builds the Linux
        # engine twice and the two layouts cannot drift.
        self.assertNotIn("target: linux_x86_64 }", self.release.split("app-engine:")[1])
        self.assertIn(
            "name: app-engine-${{ matrix.target }}\n"
            "          path: packaging/linux/out/packages/fermix_app_engine_"
            "${{ matrix.target }}.tar.gz",
            self.release,
        )
        self.assertIn("app_engine_out/fermix_app_engine_*.tar.gz", self.release)

    def test_both_verification_jobs_run_the_linux_engine_from_the_archive(self):
        for row in (
            "{ name: engine-linux-x64, os: ubuntu-24.04, kind: app_engine, target: linux_x86_64, mode: container }",
            "{ name: engine-linux-arm64, os: ubuntu-24.04-arm, kind: app_engine, target: linux_aarch64, mode: container }",
        ):
            with self.subTest(row=row):
                self.assertEqual(self.release.count(row), 2)

    def test_every_package_is_signed_beside_the_binaries_of_the_same_tag(self):
        self.assertIn("needs: [standalone, linux-packages, app-engine]", self.release)
        self.assertIn("linux_packages/fermix_*.deb", self.release)
        self.assertIn("linux_packages/fermix-*.rpm", self.release)
        self.assertIn('[ "${#unsigned[@]}" -eq 12 ]', self.release)
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

    def test_a_published_engine_release_dispatches_the_linux_desktop_release(self):
        self.assertIn(
            "\n  dispatch-linux-desktop:\n"
            "    name: Dispatch the Linux desktop release\n"
            "    needs: promote\n",
            self.release,
        )
        dispatch = self.release.split("\n  dispatch-linux-desktop:")[1].split(
            "\n  homebrew:"
        )[0]

        # It runs after promote, so every asset the payload names is already
        # downloadable, and the digests come from the published release's own
        # sidecars rather than from this run's artifacts.
        self.assertIn('gh release download "$TAG" --repo "$REPO"', dispatch)
        self.assertIn("targets=(linux_x86_64 linux_aarch64)", dispatch)
        self.assertIn('asset="fermix_app_engine_${target}.tar.gz"', dispatch)
        self.assertIn('--pattern "${asset}.sha256"', dispatch)

        # GITHUB_TOKEN starts no workflow run from the event it produces, so a
        # dispatch sent with it would be accepted and start nothing. That is the
        # silent failure the App installation token exists to avoid.
        self.assertIn("actions/create-github-app-token@", dispatch)
        self.assertIn("app-id: ${{ secrets.FERMIX_RELEASE_APP_ID }}", dispatch)
        self.assertIn(
            "private-key: ${{ secrets.FERMIX_RELEASE_APP_PRIVATE_KEY }}", dispatch
        )
        self.assertIn("repositories: fermix-linux", dispatch)
        self.assertIn("GH_TOKEN: ${{ steps.token.outputs.token }}", dispatch)
        self.assertIn("/repos/tezra-io/fermix-linux/dispatches", dispatch)
        self.assertIn('"event_type": "engine-released"', dispatch)

        # The job reads the release and writes nothing in this repository.
        self.assertRegex(dispatch, r"permissions:\n\s+contents: read\n")
        self.assertNotIn("contents: write", dispatch)

    def test_homebrew_formula_is_installed_and_reports_the_release_version(self):
        self.assertIn("runs-on: macos-15", self.release)
        self.assertIn("brew install tezra-io/tap/fermix", self.release)
        self.assertIn('fermix --version | grep -F "$version"', self.release)


if __name__ == "__main__":
    unittest.main()
