#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Specs for bin/private_suites.py: clone or fast-forward the private holdout.
Hermetic: the "remote" is a bare repo under pytest's tmp dir; no network."""

from __future__ import annotations

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import private_suites  # noqa: E402
from evallib.config import PrivateSuitesCfg  # noqa: E402


def _git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"})


@pytest.fixture
def remote(tmp_path):
    """A bare repo with one commit holding a suite file."""
    bare, work = tmp_path / "remote.git", tmp_path / "author"
    _git("init", "-q", "--bare", str(bare))
    _git("clone", "-q", str(bare), str(work))
    (work / "real_use.yaml").write_text("suite: cap_private_x\n")
    _git("add", ".", cwd=work)
    _git("commit", "-q", "-m", "first", cwd=work)
    _git("push", "-q", "origin", "HEAD", cwd=work)
    return bare, work


def test_a_missing_clone_is_cloned_from_the_remote(tmp_path, remote):
    bare, _work = remote
    target = tmp_path / "fermix-eval-private"
    assert private_suites.sync(PrivateSuitesCfg(dir=str(target), remote=str(bare))) == str(target)
    assert (target / "real_use.yaml").is_file()


def test_an_existing_clone_is_fast_forwarded(tmp_path, remote):
    bare, work = remote
    target = tmp_path / "fermix-eval-private"
    private_suites.sync(PrivateSuitesCfg(dir=str(target), remote=str(bare)))
    (work / "second.yaml").write_text("suite: cap_private_y\n")
    _git("add", ".", cwd=work)
    _git("commit", "-q", "-m", "second", cwd=work)
    _git("push", "-q", "origin", "HEAD", cwd=work)
    private_suites.sync(PrivateSuitesCfg(dir=str(target), remote=str(bare)))
    assert (target / "second.yaml").is_file()


@pytest.mark.parametrize("cfg_factory, reason", [
    (lambda t: None, "not set"),
    (lambda t: PrivateSuitesCfg(dir=None, remote=None), "not set"),
    (lambda t: PrivateSuitesCfg(dir=str(t / "absent"), remote=None), "remote is not set"),
])
def test_an_unusable_configuration_is_refused(tmp_path, cfg_factory, reason):
    with pytest.raises(private_suites.SyncError, match=reason):
        private_suites.sync(cfg_factory(tmp_path))


def test_a_plain_directory_in_the_way_is_refused_not_overwritten(tmp_path):
    target = tmp_path / "fermix-eval-private"
    target.mkdir()
    (target / "notes.txt").write_text("mine")
    with pytest.raises(private_suites.SyncError, match="not a git clone"):
        private_suites.sync(PrivateSuitesCfg(dir=str(target), remote="unused"))
    assert (target / "notes.txt").read_text() == "mine"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
