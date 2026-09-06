#!/usr/bin/env bash
# Verify one native or Rosetta app-engine release archive.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
exec python3 "$repo_root/scripts/release/verify_app_engine.py" "$@"
