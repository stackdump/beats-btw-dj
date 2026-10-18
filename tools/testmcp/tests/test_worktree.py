"""The `worktree` argument of djtest_build / djtest_render / djtest_swift_test / djtest_shots:
the tool runs in another checkout (a fix agent's git worktree), writes under that tree's
build/testmcp, and shares the one swift test lock. Fake runner; nothing builds Swift."""

from __future__ import annotations

import inspect
import json
import os
import tempfile
from pathlib import Path

from djtest_mcp import render as rd
from djtest_mcp import runner as rn
from djtest_mcp import server as sv
from djtest_mcp import shots as sh
from djtest_mcp import swifttest as st

from .fakes import write_arg
from .test_swifttest import PASSING, LockEnv

RENDER_JSON = json.dumps({"genre": "techno", "seed": 42, "audio": {"lufs": -12.0},
                          "musicality": {}})


class WorktreeEnv(LockEnv):
    """LockEnv plus a second checkout (a temp dir with a Package.swift)."""

    def setUp(self):
        super().setUp()
        self._wt = tempfile.TemporaryDirectory()
        self.wt = Path(self._wt.name).resolve()
        (self.wt / "Package.swift").write_text("// swift-tools-version:6.0\n")
        self.addCleanup(self._wt.cleanup)


class ResolveTests(WorktreeEnv):
    def test_empty_is_the_repo_root(self):
        self.assertEqual(rn.worktree_root(""), rn.repo_root())

    def test_a_checkout_resolves(self):
        self.assertEqual(rn.worktree_root(str(self.wt)), self.wt)

    def test_a_dir_without_package_swift_is_refused(self):
        with self.assertRaises(rn.ToolError) as e:
            rn.worktree_root(str(self.wt / "nope"))
        self.assertIn("no Package.swift", str(e.exception))

    def test_out_dir_and_djctl_follow_the_root(self):
        self.assertEqual(rn.out_dir(self.wt), self.wt / "build" / "testmcp")
        self.assertEqual(rn.djctl_path(self.wt), self.wt / "build" / "testmcp" / "djctl")
        self.assertEqual(rn.out_dir(), self.root / "build" / "testmcp")

    def test_djctl_env_override_only_applies_to_the_own_tree(self):
        os.environ[rn.ENV_DJCTL] = "/elsewhere/djctl"
        self.addCleanup(os.environ.pop, rn.ENV_DJCTL, None)
        self.assertEqual(rn.djctl_path(), Path("/elsewhere/djctl"))
        self.assertEqual(rn.djctl_path(self.wt), self.wt / "build" / "testmcp" / "djctl")


class SwiftTestWorktreeTests(WorktreeEnv):
    answers = {"swift-test-filter FILTER=BuildInfoTests": PASSING}

    def test_runs_in_the_worktree_and_logs_there(self):
        r = st.swift_test("BuildInfoTests", worktree=str(self.wt))
        self.assertEqual(r["status"], "passed")
        self.assertEqual(self.fake.calls[0]["cwd"], str(self.wt))
        self.assertTrue(r["log"].startswith(str(self.wt / "build" / "testmcp" / "swift-tests")))

    def test_the_lock_names_the_worktree(self):
        seen = {}

        def peek(argv):
            seen.update(st.lock_status())
            return PASSING
        self.fake.answers = {"swift-rt-test-filter": peek}
        st.swift_test("BuildInfoTests", release=True, worktree=str(self.wt))
        self.assertTrue(seen["held"])
        self.assertEqual(seen["holder"]["root"], str(self.wt))
        self.assertEqual(Path(seen["path"]), self.lock)

    def test_a_bad_worktree_runs_nothing(self):
        with self.assertRaises(rn.ToolError):
            st.swift_test("BuildInfoTests", worktree=str(self.wt / "missing"))
        self.assertEqual(self.fake.calls, [])


class ShotsWorktreeTests(WorktreeEnv):
    def test_shots_run_and_land_in_the_worktree(self):
        def write_shots(argv):
            d = Path(next(a for a in argv if a.startswith("SHOT_DIR="))[len("SHOT_DIR="):])
            (d / "w.png").write_bytes(b"\x89PNG")
            return PASSING
        self.fake.answers = {"swift-shots": write_shots}
        r = sh.shots("WindowShot", worktree=str(self.wt))
        self.assertEqual(self.fake.calls[0]["cwd"], str(self.wt))
        self.assertTrue(r["shot_dir"].startswith(str(self.wt / "build" / "testmcp" / "shots")))
        self.assertEqual(r["total_pngs"], 1)


class BuildRenderWorktreeTests(WorktreeEnv):
    def test_build_copies_into_the_worktree(self):
        bin_dir = self.wt / ".build" / "release"
        bin_dir.mkdir(parents=True)
        (bin_dir / "djctl").write_text("wt")
        self.fake.answers = {"--show-bin-path": str(bin_dir) + "\n"}
        out = rd.build(str(self.wt))
        self.assertEqual(self.fake.calls[0]["cwd"], str(self.wt))
        self.assertEqual(out["djctl"], str(self.wt / "build" / "testmcp" / "djctl"))
        self.assertEqual((self.wt / "build" / "testmcp" / "djctl").read_text(), "wt")
        self.assertEqual(self.djctl.read_text(), "#!/bin/sh\n")  # own tree's copy untouched

    def test_render_needs_the_worktrees_own_build(self):
        with self.assertRaises(rn.ToolError) as e:
            rd.render("techno", 42, worktree=str(self.wt))
        self.assertIn("same worktree", str(e.exception))

    def test_render_uses_the_worktrees_djctl(self):
        wt_djctl = rn.djctl_path(self.wt)
        wt_djctl.parent.mkdir(parents=True)
        wt_djctl.write_text("#!/bin/sh\n")

        def answer(argv):
            write_arg(argv, "--out", b"RIFF")
            return RENDER_JSON
        self.fake.answers = {"render techno": answer}
        out = rd.render("techno", 42, worktree=str(self.wt))
        call = self.fake.calls[0]
        self.assertEqual(call["argv"][0], str(wt_djctl))
        self.assertEqual(call["cwd"], str(self.wt))
        self.assertTrue(out["wav"].startswith(str(self.wt / "build" / "testmcp" / "renders")))
        self.assertTrue(out["wavExists"])


class ServerSignatureTests(WorktreeEnv):
    def test_the_four_tools_take_worktree(self):
        for tool in (sv.djtest_build, sv.djtest_render, sv.djtest_swift_test, sv.djtest_shots):
            fn = getattr(tool, "fn", tool)
            p = inspect.signature(fn).parameters.get("worktree")
            self.assertIsNotNone(p, tool)
            self.assertEqual(p.default, "")
