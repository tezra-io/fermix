#!/bin/sh
# Checker (exit mode) for the harness-delegation bugfix task.
#
# Runs are BACKGROUND-ONLY (design §23.1): the model launches the coding agent and
# ends its turn, so the vendor CLI is usually still working when this checker
# starts. The end state is therefore WAITED FOR, not assumed — poll until the
# committed tree satisfies every acceptance criterion or the deadline expires.
# (Pre-§23.1 the model blocked in-turn, so an instant check worked; it cannot now,
# and a non-waiting checker scores every trial zero no matter how good the fix.)
#
# Acceptance: a real git repo whose COMMITTED tree passes the hidden cases the
# agent never saw, with a clean working tree — the fix was committed, not merely
# edited. Delegation itself is enforced by the task's requires_tools provenance
# gate, not here. cwd = the trial's scoped dir.
#
# The hidden tests live OUTSIDE the repo so polling never dirties the tree it is
# asserting on (and so they can never be committed by a late agent write).
# Fixed wait, deliberately not a knob: the checker subprocess runs under
# run_checker's env allowlist (evallib/checker.py `_ENV_ALLOWLIST`), which never
# forwards HARNESS_CHECKER_WAIT_S — the override this line used to read could not
# be set by anyone, from anywhere. A tuning constant lives in the code that uses
# it; an unsettable env read only advertises control that does not exist.
WAIT_S=480
POLL_S=10

[ -d .git ] || { echo "no git repository in the scoped dir"; exit 1; }

HIDDEN=$(mktemp -d) || { echo "cannot create hidden-test dir"; exit 1; }
trap 'rm -rf "$HIDDEN"' EXIT
cat > "$HIDDEN/test_hidden.py" <<'PYEOF'
from greeter import greeting


def test_plain_unchanged():
    assert greeting("Ada") == "Hello, Ada!"


def test_shout_keeps_greeting_shape():
    assert greeting("Ada", shout=True) == "HELLO, ADA!"


def test_shout_multiword_name():
    assert greeting("Grace Hopper", shout=True) == "HELLO, GRACE HOPPER!"
PYEOF

hidden_tests() {
    env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PWD" uv run --quiet --with pytest \
        python -m pytest -q "$HIDDEN"
}

# Committed AND correct: at least one commit, a clean tree (ignoring the bytecode
# caches the task's own pytest run drops), and the hidden tests passing.
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

echo "timed out after ${WAIT_S}s waiting for a committed, correct fix"
echo "--- git log ---"; git --no-pager log --oneline 2>&1 | head -5
echo "--- git status ---"; git status --porcelain 2>&1 | head -5
echo "--- hidden tests ---"; hidden_tests 2>&1 | tail -15
exit 1
