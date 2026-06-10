#!/usr/bin/env python3
"""Sync the bundled plugin catalog seed from fermix-plugins releases (M8.1 §3.4).

The catalog (`apps/fermix_core/priv/plugins/index.json`) is DERIVED state —
mechanically generated, never hand-edited. A maintainer runs this when a plugin
release should ship with the next fermix release; the result is committed via a
normal PR to dev.

The script proves every pin it writes: for each `<name>/v<semver>` tag it reads
the GitHub Release assets, downloads tarball + .sha256 + .sig + .pem, checks the
sha256 locally, and cosign-verifies the signature against the
`release-plugin.yml@refs/tags/<name>/v<version>` identity. Any failure is exit 1
and nothing is written — a broken pin cannot be generated. A tag without a
complete release is an error, not a skip. Yanked versions stay listed in both
`versions[]` and `yanked[]` and are still verified: yank blocks install, it
does not unpublish.

Usage:
  sync_plugin_catalog.py [--repo tezra-io/fermix-plugins]
                         [--out apps/fermix_core/priv/plugins/index.json]

Requires: an authenticated `gh` and `cosign` on PATH. Operates remotely — no
fermix-plugins checkout needed.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

SCHEMA_VERSION = 1
MAX_LOGO_BYTES = 16 * 1024  # mirrors fermix-plugins pluginlib.py — keep in sync
LOGO_MIME_BY_EXT = {".png": "image/png", ".svg": "image/svg+xml"}
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
RELEASE_WORKFLOW = ".github/workflows/release-plugin.yml"
TAG_RE = re.compile(r"^(?P<name>[a-z][a-z0-9_]{0,63})/v(?P<version>\d+\.\d+\.\d+)$")
REQUIRED_MANIFEST_FIELDS = ("display_name", "category", "description", "min_core_version", "plugin_api")


class SyncError(Exception):
    """Catalog sync failed; the message names plugin/version/stage. Nothing is written."""


# --- pure helpers (import-safe; no subprocess, no I/O) ---


def parse_tag(tag):
    """(name, version) for a plugin release tag `<name>/v<semver>`, else None."""
    match = TAG_RE.match(tag)
    return (match["name"], match["version"]) if match else None


def semver_key(version):
    return tuple(int(part) for part in version.split("."))


def identity_regexp(repo, name, version):
    """Cosign certificate-identity pin for one plugin release tag."""
    identity = f"https://github.com/{repo}/{RELEASE_WORKFLOW}@refs/tags/{name}/v{version}"
    return "^" + re.escape(identity) + "$"


def build_logo(rel, data):
    """Inline-logo dict from a manifest logo path + bytes. Catalog rule: png/svg only, ≤16 KB."""
    mime = LOGO_MIME_BY_EXT.get(Path(rel).suffix.lower())
    if mime is None:
        raise SyncError(f"logo {rel!r} must be png or svg for the catalog")
    if len(data) > MAX_LOGO_BYTES:
        raise SyncError(f"logo {rel!r} is {len(data)} bytes, exceeds the {MAX_LOGO_BYTES}-byte cap")
    return {"mime": mime, "data_base64": base64.b64encode(data).decode()}


def parse_yanked(text):
    """Validated version list from a plugins/<name>/yanked.json body."""
    try:
        yanked = json.loads(text)
    except json.JSONDecodeError as err:
        raise SyncError(f"yanked.json is invalid JSON — {err}") from None
    if not isinstance(yanked, list) or not all(isinstance(v, str) and v for v in yanked):
        raise SyncError("yanked.json must be a JSON array of version strings")
    return yanked


def plugin_entry(name, releases, yanked, logo):
    """Catalog entry in exactly the shape FermixCore.Plugins.Dist.Index.parse/1 reads.

    `releases` is [(version, published_at, manifest, artifact)] in any order;
    versions are emitted newest-first and `latest` is the newest.
    """
    if not releases:
        raise SyncError("has no releases to pin")
    ordered = sorted(releases, key=lambda r: semver_key(r[0]), reverse=True)
    for version, _, manifest, _ in ordered:
        missing = [f for f in REQUIRED_MANIFEST_FIELDS if manifest.get(f) in (None, "")]
        if missing:
            raise SyncError(f"v{version}: manifest is missing fields {missing}")
        if manifest.get("name") != name:
            raise SyncError(f"v{version}: manifest name {manifest.get('name')!r} != tag plugin name {name!r}")
    latest_version, _, latest_manifest, _ = ordered[0]
    interface = latest_manifest.get("interface") or {}
    return {
        "name": name,
        "display_name": latest_manifest["display_name"],
        "category": latest_manifest["category"],
        "description": latest_manifest["description"],
        "short_description": interface.get("short_description"),
        "developer_name": interface.get("developer_name"),
        "brand_color": interface.get("brand_color"),
        "logo": logo,
        "auth_type": (latest_manifest.get("auth") or {}).get("type"),
        "rails": sorted({tool.get("rail", "http") for tool in latest_manifest.get("tools", [])}),
        "latest": latest_version,
        "yanked": yanked,
        "versions": [
            {
                "version": version,
                "published_at": published_at,
                "min_core_version": manifest["min_core_version"],
                "plugin_api": manifest["plugin_api"],
                "artifacts": [artifact],
            }
            for version, published_at, manifest, artifact in ordered
        ],
    }


def validate(index):
    """Shape gate (absorbed from build_plugin_index_seed.py) — last check before write."""
    if not isinstance(index, dict):
        raise SyncError("index must be a JSON object")
    if index.get("schema_version") != SCHEMA_VERSION:
        raise SyncError(f"schema_version must be {SCHEMA_VERSION}, got {index.get('schema_version')!r}")
    if not isinstance(index.get("generated_at"), str) or not index["generated_at"]:
        raise SyncError("generated_at must be a non-empty string")
    plugins = index.get("plugins")
    if not isinstance(plugins, list):
        raise SyncError("plugins must be a list")
    for i, plugin in enumerate(plugins):
        _validate_plugin(i, plugin)
    return index


def _validate_plugin(i, plugin):
    if not isinstance(plugin, dict):
        raise SyncError(f"plugins[{i}] must be an object")
    name = plugin.get("name")
    if not isinstance(name, str) or not name:
        raise SyncError(f"plugins[{i}].name must be a non-empty string")
    versions = plugin.get("versions")
    if not isinstance(versions, list):
        raise SyncError(f"plugin {name!r}: versions must be a list")
    for v in versions:
        if not isinstance(v, dict) or not isinstance(v.get("version"), str) or not v["version"]:
            raise SyncError(f"plugin {name!r}: each version needs a non-empty version string")


# --- effectful (gh / cosign / filesystem) ---


def run(cmd):
    """Run a gh/cosign command; SyncError with command + stderr on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SyncError(f"`{' '.join(cmd)}` failed: {result.stderr.strip()}")
    return result.stdout


def list_plugin_tags(repo):
    """{name: [version, ...]} from `<name>/v<semver>` tags on the repo."""
    out = run(["gh", "api", f"repos/{repo}/git/matching-refs/tags", "--paginate", "--jq", ".[].ref"])
    tags = {}
    for line in out.splitlines():
        parsed = parse_tag(line.strip().removeprefix("refs/tags/"))
        if parsed:
            tags.setdefault(parsed[0], []).append(parsed[1])
    return tags


def file_at_ref(repo, path, ref):
    """Raw bytes of a repo file at a ref via the contents API."""
    payload = json.loads(run(["gh", "api", f"repos/{repo}/contents/{path}?ref={quote(ref, safe='')}"]))
    if payload.get("encoding") != "base64":
        raise SyncError(f"{path}@{ref}: unexpected contents encoding {payload.get('encoding')!r}")
    return base64.b64decode(payload["content"])


def release_assets(repo, name, version):
    """({asset_name: url}, published_at) for the tag's release; incomplete release → SyncError."""
    tag = f"{name}/v{version}"
    try:
        raw = run(["gh", "release", "view", tag, "-R", repo, "--json", "assets,publishedAt"])
    except SyncError as err:
        raise SyncError(f"v{version}: tag has no usable release — {err}") from None
    release = json.loads(raw)
    urls = {asset["name"]: asset["url"] for asset in release["assets"]}
    tarball = f"{name}-{version}.tar.gz"
    missing = [a for a in (tarball, f"{tarball}.sha256", f"{tarball}.sig", f"{tarball}.pem") if a not in urls]
    if missing:
        raise SyncError(f"v{version}: release is missing assets {missing}")
    if not release.get("publishedAt"):
        raise SyncError(f"v{version}: release has no publishedAt")
    return urls, release["publishedAt"]


def manifest_at_tag(repo, name, version):
    raw = file_at_ref(repo, f"plugins/{name}/plugin.json", f"{name}/v{version}")
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as err:
        raise SyncError(f"v{version}: plugin.json at tag is invalid JSON — {err}") from None
    if not isinstance(manifest, dict):
        raise SyncError(f"v{version}: plugin.json at tag must be a JSON object")
    return manifest


def verify_release(repo, name, version):
    """Download tarball + sha256 + sig + pem, check the digest, cosign-verify. Returns the hex sha256."""
    tag = f"{name}/v{version}"
    tarball = f"{name}-{version}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="fermix-catalog-sync-") as tmp:
        try:
            run(["gh", "release", "download", tag, "-R", repo, "--pattern", f"{tarball}*", "--dir", tmp])
        except SyncError as err:
            raise SyncError(f"v{version}: artifact download failed — {err}") from None
        paths = {ext: Path(tmp) / f"{tarball}{ext}" for ext in ("", ".sha256", ".sig", ".pem")}
        missing = [p.name for p in paths.values() if not p.is_file()]
        if missing:
            raise SyncError(f"v{version}: download incomplete — missing {missing}")
        digest = hashlib.sha256(paths[""].read_bytes()).hexdigest()
        sha_words = paths[".sha256"].read_text().split()
        if not sha_words or digest != sha_words[0]:
            raise SyncError(f"v{version}: sha256 mismatch — computed {digest}, release pins {sha_words[:1]}")
        cosign = [
            "cosign", "verify-blob",
            "--certificate", str(paths[".pem"]),
            "--signature", str(paths[".sig"]),
            "--certificate-identity-regexp", identity_regexp(repo, name, version),
            "--certificate-oidc-issuer", OIDC_ISSUER,
            str(paths[""]),
        ]
        try:
            run(cosign)
        except SyncError as err:
            raise SyncError(f"v{version}: cosign verification failed — {err}") from None
        return digest


def fetch_yanked(repo, name):
    """plugins/<name>/yanked.json at HEAD, or [] when absent (the one legitimate 404)."""
    endpoint = f"repos/{repo}/contents/plugins/{name}/yanked.json"
    result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if "HTTP 404" in result.stderr:
            return []
        raise SyncError(f"yanked.json read failed: {result.stderr.strip()}")
    payload = json.loads(result.stdout)
    if payload.get("encoding") != "base64":
        raise SyncError("yanked.json: unexpected contents encoding")
    return parse_yanked(base64.b64decode(payload["content"]).decode())


def fetch_logo(repo, name, version, manifest):
    """Inline {mime, data_base64} for the latest manifest's interface.logo, or None when undeclared."""
    rel = (manifest.get("interface") or {}).get("logo")
    if not rel:
        return None
    data = file_at_ref(repo, f"plugins/{name}/{rel}", f"{name}/v{version}")
    try:
        return build_logo(rel, data)
    except SyncError as err:
        raise SyncError(f"v{version}: {err} (the publish-side gate should have caught this)") from None


def sync_plugin(repo, name, versions):
    """Verified catalog entry for one plugin across all its release tags."""
    releases = []
    for version in sorted(versions, key=semver_key, reverse=True):
        urls, published_at = release_assets(repo, name, version)
        manifest = manifest_at_tag(repo, name, version)
        sha256 = verify_release(repo, name, version)
        tarball = f"{name}-{version}.tar.gz"
        artifact = {
            "target": "any",
            "url": urls[tarball],
            "sha256": sha256,
            "sig_url": urls[f"{tarball}.sig"],
            "cert_url": urls[f"{tarball}.pem"],
        }
        releases.append((version, published_at, manifest, artifact))
    latest_version, _, latest_manifest, _ = releases[0]
    logo = fetch_logo(repo, name, latest_version, latest_manifest)
    return plugin_entry(name, releases, fetch_yanked(repo, name), logo)


def write_atomic(out, index):
    """tmp-write + rename in the destination dir, so a failed run never leaves a torn file."""
    tmp = out.parent / (out.name + ".tmp")
    tmp.write_text(json.dumps(index, indent=2) + "\n")
    os.replace(tmp, out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default="tezra-io/fermix-plugins", help="GitHub owner/repo to sync from")
    parser.add_argument("--out", type=Path, default=Path("apps/fermix_core/priv/plugins/index.json"))
    args = parser.parse_args(argv)
    try:
        tags = list_plugin_tags(args.repo)
        entries = []
        for name in sorted(tags):
            try:
                entries.append(sync_plugin(args.repo, name, tags[name]))
            except SyncError as err:
                raise SyncError(f"plugin {name} {err}") from None
        index = {
            "schema_version": SCHEMA_VERSION,
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "plugins": entries,
        }
        validate(index)
    except SyncError as err:
        print(f"catalog sync failed: {err} — nothing written", file=sys.stderr)
        return 1
    write_atomic(args.out, index)
    pins = sum(len(p["versions"]) for p in entries)
    print(f"wrote {args.out}: {len(entries)} plugin(s), {pins} verified version pin(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
