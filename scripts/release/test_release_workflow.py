#!/usr/bin/env python3
"""Structural tests for native app-engine release automation."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
CI_WORKFLOW = ROOT / ".github/workflows/ci.yml"
FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.ci = CI_WORKFLOW.read_text(encoding="utf-8")

    def test_external_actions_are_pinned_in_release_and_ci(self):
        for path, contents in ((RELEASE_WORKFLOW, self.release), (CI_WORKFLOW, self.ci)):
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

    def test_homebrew_formula_is_installed_and_reports_the_release_version(self):
        self.assertIn("runs-on: macos-15", self.release)
        self.assertIn("brew install tezra-io/tap/fermix", self.release)
        self.assertIn('fermix --version | grep -F "$version"', self.release)


if __name__ == "__main__":
    unittest.main()
