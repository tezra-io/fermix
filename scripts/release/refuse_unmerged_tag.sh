#!/usr/bin/env bash
# Fail closed when a release tag names a commit that is not on main.
#
# A release is the merge commit of its release pull request to main, tagged
# after the merge; a hotfix merges to main before it is tagged too. release.yml
# signs whatever commit a v* tag names under the same keyless identity, so a
# tag on any other commit is refused here, before anything is built. Needs a
# checkout with the full history of main (actions/checkout, fetch-depth: 0).

set -euo pipefail

release_branch="main"
release_ref="refs/remotes/origin/$release_branch"

fail() {
  printf 'refuse_unmerged_tag.sh: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <commit-sha>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage

commit="$1"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
  fail "the tagged commit must be a full commit SHA"

[ "$(git rev-parse --is-shallow-repository)" = false ] ||
  fail "the checkout is shallow; check out with fetch-depth: 0 so the tag's ancestry can be decided"
git rev-parse --verify --quiet "$release_ref^{commit}" >/dev/null ||
  fail "the checkout has no $release_ref to compare the tag against"
git cat-file -e "$commit^{commit}" 2>/dev/null ||
  fail "the tagged commit $commit is not in the checkout"

status=0
git merge-base --is-ancestor "$commit" "$release_ref" || status=$?
case "$status" in
  0)
    printf 'Tagged commit %s is on %s\n' "$commit" "$release_branch"
    ;;
  1)
    fail "the tagged commit $commit is not on $release_branch; merge the release pull request to $release_branch and tag its merge commit"
    ;;
  *)
    fail "cannot decide whether $commit is on $release_branch (git exit $status)"
    ;;
esac
