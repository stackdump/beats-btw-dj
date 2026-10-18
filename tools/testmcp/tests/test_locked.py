"""djtest_mcp.locked, the Makefile's full-suite / RT wrapper: runs the command under the lock,
passes its exit code, waits for another holder, and doesn't wait on an ancestor's lock."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time

from djtest_mcp import locked as lk
from djtest_mcp import swifttest as st

from .test_swifttest import PKG, LockEnv


class LockedTests(LockEnv):
    def run_locked(self, *cmd, what="make swift-test", timeout=30):
        env = dict(os.environ, PYTHONPATH=str(PKG))
        return subprocess.run([sys.executable, "-m", "djtest_mcp.locked", "--what", what,
                               "--", *cmd], env=env, capture_output=True, text=True,
                              timeout=timeout)

    def test_runs_the_command_holding_the_lock(self):
        probe = ("import json, sys; sys.path.insert(0, %r); from djtest_mcp import swifttest as st;"
                 " print(json.dumps(st.lock_status()))" % str(PKG))
        r = self.run_locked(sys.executable, "-c", probe)
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads(r.stdout)
        self.assertTrue(s["held"])
        self.assertEqual(s["holder"]["tool"], "make swift-test")
        self.assertFalse(st.lock_status()["held"])

    def test_passes_the_exit_code(self):
        self.assertEqual(self.run_locked(sys.executable, "-c", "raise SystemExit(3)").returncode, 3)

    def test_waits_for_another_holder(self):
        self.holder_process(seconds=1.0)
        t0 = time.monotonic()
        r = self.run_locked("true")
        self.assertEqual(r.returncode, 0)
        self.assertGreater(time.monotonic() - t0, 0.3)

    def test_a_lock_held_by_an_ancestor_does_not_block(self):
        # The outer wrapper holds the lock and runs an inner one (make calling make, or a release
        # djtest_swift_test calling `make swift-rt-test-filter`): the inner runs at once.
        inner = [sys.executable, "-m", "djtest_mcp.locked", "--wait", "2", "--", "true"]
        r = self.run_locked(*inner)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_ancestors_lists_the_parent(self):
        self.assertIn(os.getppid(), lk.ancestors())

    def test_no_command_is_an_error(self):
        self.assertNotEqual(self.run_locked().returncode, 0)
