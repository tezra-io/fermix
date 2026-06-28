#!/usr/bin/env python3
"""Unit tests for sync_plugin_catalog's pure functions.

No network, no gh, no cosign — fixture dicts only. Run with:
  python3 -m unittest scripts.release.test_sync_plugin_catalog
  python3 scripts/release/test_sync_plugin_catalog.py
"""

import base64
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sync_plugin_catalog as sync  # noqa: E402


def manifest_fixture(**overrides):
    manifest = {
        "schema_version": 2,
        "name": "github",
        "display_name": "GitHub",
        "category": "developer",
        "description": "GitHub issues, pull requests, and repositories.",
        "version": "1.2.0",
        "min_core_version": "0.2.0",
        "plugin_api": 1,
        "auth": {"type": "oauth2", "provider": "github", "scopes": ["repo"]},
        "interface": {
            "short_description": "Issues and PRs",
            "developer_name": "Tezra",
            "brand_color": "#181717",
            "logo": "assets/logo.png",
        },
        "tools": [
            {"name": "github_list_issues", "rail": "http"},
            {"name": "github_search", "rail": "http"},
        ],
    }
    manifest.update(overrides)
    return manifest


def artifact_fixture(name="github", version="1.2.0"):
    base = f"https://github.com/tezra-io/fermix-plugins/releases/download/{name}%2Fv{version}"
    return {
        "target": "any",
        "url": f"{base}/{name}-{version}.tar.gz",
        "sha256": "a" * 64,
        "sig_url": f"{base}/{name}-{version}.tar.gz.sig",
        "cert_url": f"{base}/{name}-{version}.tar.gz.pem",
    }


def release_fixture(name="github", version="1.2.0", artifacts=None, **overrides):
    return (version, "2026-06-09T12:00:00Z", manifest_fixture(name=name, version=version, **overrides),
            artifacts if artifacts is not None else [artifact_fixture(name, version)])


class TagParsingTest(unittest.TestCase):
    def test_valid_tags(self):
        self.assertEqual(sync.parse_tag("github/v1.2.3"), ("github", "1.2.3"))
        self.assertEqual(sync.parse_tag("google_drive/v0.1.0"), ("google_drive", "0.1.0"))
        self.assertEqual(sync.parse_tag("a" * 64 + "/v1.0.0"), ("a" * 64, "1.0.0"))

    def test_invalid_tags(self):
        for tag in ("v1.2.3", "github/1.2.3", "Github/v1.0.0", "github/v1.2",
                    "github/v1.2.3.4", "github/v1.2.3-rc1", "github/v1.2.3 ", "",
                    "a" * 65 + "/v1.0.0", "1github/v1.0.0", "mcp-thing/v1.0.0"):
            self.assertIsNone(sync.parse_tag(tag), tag)


class IdentityRegexpTest(unittest.TestCase):
    def test_pins_exact_tag(self):
        pattern = sync.identity_regexp("tezra-io/fermix-plugins", "github", "1.2.0")
        identity = ("https://github.com/tezra-io/fermix-plugins/"
                    ".github/workflows/release-plugin.yml@refs/tags/github/v1.2.0")
        self.assertIsNotNone(re.search(pattern, identity))
        self.assertIsNone(re.search(pattern, identity + "1"))
        self.assertIsNone(re.search(pattern, identity.replace("github/v1.2.0", "github/v1.2.1")))
        self.assertIsNone(re.search(pattern, identity.replace("tezra-io", "evil-io")))


class EntryBuildingTest(unittest.TestCase):
    def test_single_release_entry_shape(self):
        logo = {"mime": "image/png", "data_base64": base64.b64encode(b"png").decode()}
        entry = sync.plugin_entry("github", [release_fixture()], [], logo)
        self.assertEqual(entry["name"], "github")
        self.assertEqual(entry["display_name"], "GitHub")
        self.assertEqual(entry["category"], "developer")
        self.assertEqual(entry["short_description"], "Issues and PRs")
        self.assertEqual(entry["developer_name"], "Tezra")
        self.assertEqual(entry["brand_color"], "#181717")
        self.assertEqual(entry["logo"], logo)
        self.assertEqual(entry["auth_type"], "oauth2")
        self.assertEqual(entry["auth_provider"], "github")
        self.assertEqual(entry["rails"], ["http"])
        self.assertEqual(entry["latest"], "1.2.0")
        self.assertEqual(entry["yanked"], [])
        version = entry["versions"][0]
        self.assertEqual(version["version"], "1.2.0")
        self.assertEqual(version["published_at"], "2026-06-09T12:00:00Z")
        self.assertEqual(version["min_core_version"], "0.2.0")
        self.assertEqual(version["plugin_api"], 1)
        self.assertEqual(version["artifacts"], [artifact_fixture()])

    def test_per_target_artifacts_preserved(self):
        # A native plugin pins one artifact per target; plugin_entry emits the list as-is.
        a1 = {**artifact_fixture(), "target": "macos-aarch64"}
        a2 = {**artifact_fixture(), "target": "linux-x86_64"}
        entry = sync.plugin_entry("github", [release_fixture(artifacts=[a1, a2])], [], None)
        self.assertEqual(entry["versions"][0]["artifacts"], [a1, a2])

    def test_versions_sorted_semver_not_lexicographic(self):
        releases = [release_fixture(version="1.2.0"), release_fixture(version="1.10.0")]
        entry = sync.plugin_entry("github", releases, [], None)
        self.assertEqual(entry["latest"], "1.10.0")
        self.assertEqual([v["version"] for v in entry["versions"]], ["1.10.0", "1.2.0"])

    def test_rails_deduped_and_defaulted(self):
        tools = [{"name": "github_a", "rail": "mcp"}, {"name": "github_b"}, {"name": "github_c", "rail": "http"}]
        entry = sync.plugin_entry("github", [release_fixture(tools=tools)], [], None)
        self.assertEqual(entry["rails"], ["http", "mcp"])

    def test_auth_provider_null_unless_oauth2(self):
        entry = sync.plugin_entry("github", [release_fixture(auth={"type": "none"})], [], None)
        self.assertIsNone(entry["auth_provider"])
        keyed = sync.plugin_entry(
            "github", [release_fixture(auth={"type": "api_key", "provider": "github"})], [], None
        )
        self.assertIsNone(keyed["auth_provider"])

    def test_missing_logo_is_null(self):
        entry = sync.plugin_entry("github", [release_fixture()], [], None)
        self.assertIsNone(entry["logo"])

    def test_manifest_name_mismatch_rejected(self):
        with self.assertRaisesRegex(sync.SyncError, "manifest name"):
            sync.plugin_entry("notion", [release_fixture(name="github")], [], None)

    def test_missing_required_field_rejected(self):
        with self.assertRaisesRegex(sync.SyncError, "display_name"):
            sync.plugin_entry("github", [release_fixture(display_name="")], [], None)

    def test_no_releases_rejected(self):
        with self.assertRaisesRegex(sync.SyncError, "no releases"):
            sync.plugin_entry("github", [], [], None)


class LogoGatingTest(unittest.TestCase):
    def test_png_and_svg_accepted(self):
        png = sync.build_logo("assets/logo.png", b"\x89PNG fake")
        self.assertEqual(png["mime"], "image/png")
        self.assertEqual(base64.b64decode(png["data_base64"]), b"\x89PNG fake")
        svg = sync.build_logo("assets/logo.SVG", b"<svg/>")
        self.assertEqual(svg["mime"], "image/svg+xml")

    def test_jpg_rejected(self):
        with self.assertRaisesRegex(sync.SyncError, "png or svg"):
            sync.build_logo("assets/logo.jpg", b"jpeg")

    def test_oversize_rejected_at_cap_boundary(self):
        self.assertEqual(sync.MAX_LOGO_BYTES, 16 * 1024)
        at_cap = sync.build_logo("logo.png", b"x" * sync.MAX_LOGO_BYTES)
        self.assertEqual(len(base64.b64decode(at_cap["data_base64"])), sync.MAX_LOGO_BYTES)
        with self.assertRaisesRegex(sync.SyncError, "exceeds"):
            sync.build_logo("logo.png", b"x" * (sync.MAX_LOGO_BYTES + 1))


class ShapeValidationTest(unittest.TestCase):
    def good_index(self):
        return {
            "schema_version": 1,
            "generated_at": "2026-06-09T12:00:00Z",
            "plugins": [{"name": "github", "versions": [{"version": "1.2.0"}]}],
        }

    def test_accepts_good_and_empty_index(self):
        self.assertEqual(sync.validate(self.good_index()), self.good_index())
        empty = {"schema_version": 1, "generated_at": "2026-06-09T12:00:00Z", "plugins": []}
        self.assertEqual(sync.validate(empty), empty)

    def test_rejects_bad_shapes(self):
        cases = [
            ([], "JSON object"),
            ({**self.good_index(), "schema_version": 2}, "schema_version"),
            ({**self.good_index(), "generated_at": ""}, "generated_at"),
            ({**self.good_index(), "plugins": "nope"}, "plugins must be a list"),
            ({**self.good_index(), "plugins": [{"versions": []}]}, "name"),
            ({**self.good_index(), "plugins": [{"name": "github", "versions": "x"}]}, "versions must be a list"),
            ({**self.good_index(), "plugins": [{"name": "github", "versions": [{"version": ""}]}]},
             "non-empty version"),
        ]
        for index, message in cases:
            with self.assertRaisesRegex(sync.SyncError, message):
                sync.validate(index)


class YankedHandlingTest(unittest.TestCase):
    def test_parse_yanked_accepts_version_list(self):
        self.assertEqual(sync.parse_yanked('["1.1.0", "1.0.0"]'), ["1.1.0", "1.0.0"])
        self.assertEqual(sync.parse_yanked("[]"), [])

    def test_parse_yanked_rejects_bad_payloads(self):
        for text in ('{"v": "1.0.0"}', '["1.0.0", 2]', '[""]', "not json"):
            with self.assertRaises(sync.SyncError):
                sync.parse_yanked(text)

    def test_yanked_versions_stay_listed(self):
        releases = [release_fixture(version="1.2.0"), release_fixture(version="1.1.0")]
        entry = sync.plugin_entry("github", releases, ["1.1.0"], None)
        self.assertEqual(entry["yanked"], ["1.1.0"])
        self.assertIn("1.1.0", [v["version"] for v in entry["versions"]])


if __name__ == "__main__":
    unittest.main()
