#!/bin/sh
# Checker (exit mode) for the harness feature-addition task.
#
# Runs are BACKGROUND-ONLY (design §23.1): the model launches the coding agent and
# ends its turn, so the vendor CLI is usually still working when this checker
# starts. The end state is therefore WAITED FOR, not assumed — poll until the
# committed tree satisfies every acceptance criterion or the deadline expires.
#
# Acceptance: a git repo with a clean COMMITTED tree whose CLI honors the
# specified --repeat contract (hidden subprocess tests) while original behavior
# stays intact. Delegation is enforced by the task's requires_tools provenance
# gate. cwd = the trial's scoped dir; the hidden tests live OUTSIDE the repo so
# polling never dirties the tree being asserted on.
WAIT_S="${HARNESS_CHECKER_WAIT_S:-480}"
POLL_S=10

[ -d .git ] || { echo "no git repository in the scoped dir"; exit 1; }

HIDDEN=$(mktemp -d) || { echo "cannot create hidden-test dir"; exit 1; }
trap 'rm -rf "$HIDDEN"' EXIT
cat > "$HIDDEN/test_hidden_cli.py" <<'PYEOF'
import subprocess
import sys


def run_cli(*args):
    result = subprocess.run(
        [sys.executable, "greet.py", *args],
        capture_output=True, text=True, timeout=30, check=True,
    )
    return result.stdout.splitlines()


def test_default_single_line():
    assert run_cli("Ada") == ["Hello, Ada!"]


def test_repeat_three():
    assert run_cli("Ada", "--repeat", "3") == ["Hello, Ada!"] * 3


def test_repeat_one_explicit():
    assert run_cli("Grace", "--repeat", "1") == ["Hello, Grace!"]
PYEOF

hidden_tests() {
    env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" uv run --quiet --with pytest \
        python -m pytest -q "$HIDDEN"
}

# Committed AND correct: at least one commit, a clean tree (ignoring the bytecode
# caches the task's own pytest run drops), and the hidden CLI tests passing.
committed_and_correct() {
    commits=$(git rev-list --count HEAD 2>/dev/null) || return 1
    [ "$commits" -ge 1 ] || return 1
    dirty=$(git status --porcelain | grep -vE '(__pycache__|\.pyc$)' || true)
    [ -z "$dirty" ] || return 1
    hidden_tests >/dev/null 2>&1
}

deadline=$(( $(date +%s) + WAIT_S ))
while :; do
    if committed_and_correct; then exit 0; fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep "$POLL_S"
done

echo "timed out after ${WAIT_S}s waiting for a committed, correct feature"
echo "--- git log ---"; git --no-pager log --oneline 2>&1 | head -5
echo "--- git status ---"; git status --porcelain 2>&1 | head -5
echo "--- hidden tests ---"; hidden_tests 2>&1 | tail -15
exit 1
