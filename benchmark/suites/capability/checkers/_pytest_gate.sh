# Shared gate for the pytest bugfix checkers (sourced, never executed).
#
# Three rules every one of those tasks states and none of them could previously
# enforce:
#
#   1. "Do not edit the tests." The visible tests are seeded from a repo fixture,
#      so integrity is checkable: any seeded test file that differs from (or is
#      missing against) its fixture copy fails the trial. Rewriting the test to
#      match the bug is the oldest shortcut there is, and hidden cases alone
#      cannot see it.
#   2. The grader collects ONLY its own directory. It used to also collect
#      $FERMIX_EVAL_WORKSPACE/tests, which the agent can add files to: a new
#      test module declaring `pytest_plugins = ['hack']` loaded an agent-written
#      hookwrapper that rewrote every report to "passed", and the unfixed bug
#      scored 1.0. --noconftest blocks a conftest.py, not that. So the visible
#      PASS_TO_PASS cases are run from the EVALUATOR's fixture copy instead, and
#      no agent-authored file is ever collected.
#   3. The grader imports ONLY the modules under test. PYTHONPATH used to be the
#      whole workspace, so any agent-supplied module on it could execute inside
#      the grader — `sitecustomize.py` is imported by the interpreter itself
#      before anything else runs. Each named module is copied into a staging dir
#      that holds nothing else, and that dir is the entire import path.

gate_visible_tests() {
    fixture_tests="$1"
    if [ ! -d "$fixture_tests" ]; then
        echo "checker bug: fixture tests not found at $fixture_tests"
        return 2
    fi
    for seeded in "$fixture_tests"/*.py; do
        name=$(basename "$seeded")
        if ! cmp -s "$seeded" "$FERMIX_EVAL_WORKSPACE/tests/$name"; then
            echo "seeded test tests/$name was modified or removed (the task forbids editing the tests)"
            return 1
        fi
    done
    return 0
}

# run_pytest <hidden dir> <fixture tests dir> <module.py> [module.py ...]
run_pytest() {
    hidden="$1"
    fixture_tests="$2"
    shift 2
    cp "$fixture_tests"/*.py "$hidden"/ || {
        echo "checker bug: cannot stage the fixture's visible tests"
        return 2
    }
    # A dot-directory: pytest's default norecursedirs skips it, so the staged
    # modules are importable without being collected.
    stage="$hidden/.modules"
    mkdir -p "$stage" || { echo "checker bug: cannot create the module stage"; return 2; }
    for module in "$@"; do
        if [ ! -f "$FERMIX_EVAL_WORKSPACE/$module" ]; then
            echo "the module under test is missing from the workspace: $module"
            return 1
        fi
        cp "$FERMIX_EVAL_WORKSPACE/$module" "$stage/$module" || {
            echo "checker bug: cannot stage $module"
            return 2
        }
    done
    ( cd "$hidden" || exit 2
      PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$stage" pytest_verdict \
        -p no:cacheprovider --noconftest --rootdir "$hidden" "$hidden" )
}

# Reserve child exit 10 for an observed pytest failure: uv's own startup failures
# may exit 1, so forwarding that code would blame the candidate for broken tooling.
# Collection errors from submitted code remain test failures through pytest's flag.
pytest_verdict() {
    if uv run --quiet --with pytest python -c '
import sys
import pytest
result = pytest.main(sys.argv[1:])
sys.exit(10 if result == pytest.ExitCode.TESTS_FAILED else result)
' -q --continue-on-collection-errors "$@"; then
        return 0
    else
        pytest_status=$?
    fi
    if [ "$pytest_status" -eq 10 ]; then return 1; fi
    echo "pytest evaluator failed (exit=$pytest_status)" >&2
    return 2
}
