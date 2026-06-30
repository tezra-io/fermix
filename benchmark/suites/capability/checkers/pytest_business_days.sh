#!/bin/sh
# Checker (exit mode): all tests must pass — the planted bug fixed (FAIL_TO_PASS)
# AND no regression (PASS_TO_PASS). cwd = the trial's scoped dir; PYTHONPATH lets
# `from business_days import ...` resolve the module the agent edited.
exec env PYTHONPATH="$FERMIX_EVAL_WORKSPACE" uv run --quiet --with pytest \
    python -m pytest -q tests/
