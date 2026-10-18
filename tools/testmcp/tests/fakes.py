"""A runner that never builds or renders: canned answers and a call log."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from djtest_mcp import runner as rn


class FakeRunner:
    """`answers` maps a substring of the joined argv to (rc, stdout, stderr), a bare stdout
    string, or a callable(argv) returning either; the first match wins, anything unmatched
    succeeds with empty output."""

    def __init__(self, answers=None):
        self.answers = answers or {}
        self.calls: list[dict] = []

    def run(self, argv, *, cwd=None, timeout=None):
        line = " ".join(argv)
        self.calls.append({"argv": list(argv), "cwd": cwd, "timeout": timeout})
        for needle, out in self.answers.items():
            if needle in line:
                if callable(out):
                    out = out(argv)
                rc, so, se = out if isinstance(out, tuple) else (0, out, "")
                return rn.Result(list(argv), rc, so, se, cwd)
        return rn.Result(list(argv), 0, "", "", cwd)

    def ran(self, needle: str) -> bool:
        return any(needle in " ".join(c["argv"]) for c in self.calls)


class FakeRepo(unittest.TestCase):
    """A temp repo root ($DJTEST_ROOT) with a dummy build/testmcp/djctl and a FakeRunner."""

    answers: dict = {}

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self._env = {k: os.environ.get(k) for k in (rn.ENV_ROOT, rn.ENV_DJCTL)}
        os.environ[rn.ENV_ROOT] = str(self.root)
        os.environ.pop(rn.ENV_DJCTL, None)
        self.djctl = rn.out_dir() / "djctl"
        self.djctl.parent.mkdir(parents=True)
        self.djctl.write_text("#!/bin/sh\n")
        self.fake = FakeRunner(dict(self.answers))
        self._old = rn.set_runner(self.fake)

    def tearDown(self):
        rn.set_runner(self._old)
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()


def write_arg(argv, flag: str, data: bytes) -> None:
    """Pretend djctl wrote a file: the path after `flag` in argv."""
    Path(argv[argv.index(flag) + 1]).write_bytes(data)
