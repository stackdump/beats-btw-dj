"""djtest_swift_test / djtest_lock / djtest_shots against a fake runner: parsing swift-testing's
transcript, tagging failures from known_tests.json, the filter guard, and the lock — held by a
second process, waited for, and gone when its holder is killed. Nothing builds Swift."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

from djtest_mcp import runner as rn
from djtest_mcp import shots as sh
from djtest_mcp import swifttest as st

from .fakes import FakeRepo

FIXTURE = (Path(__file__).parent / "fixtures" / "swift-testing-output.txt").read_text()
PKG = Path(__file__).resolve().parents[1]

PASSING = (
    "Build complete! (3.10s)\n"
    "✔ Test readsTheBundleVersion() passed after 0.012 seconds.\n"
    "✔ Test fallsBackToDev() passed after 0.013 seconds.\n"
    "✔ Suite BuildInfoTests passed after 0.014 seconds.\n"
    "✔ Test run with 2 tests in 1 suite passed after 0.015 seconds.\n"
)


class LockEnv(FakeRepo):
    """FakeRepo plus a private lock file ($DJTEST_LOCK), so tests never touch the real one."""

    def setUp(self):
        super().setUp()
        self._lock_env = os.environ.get(st.ENV_LOCK)
        self.lock = self.root / "locks" / "swift-test.lock"
        os.environ[st.ENV_LOCK] = str(self.lock)

    def tearDown(self):
        if self._lock_env is None:
            os.environ.pop(st.ENV_LOCK, None)
        else:
            os.environ[st.ENV_LOCK] = self._lock_env
        super().tearDown()

    def holder_process(self, seconds: float = 30) -> subprocess.Popen:
        """Another process that takes the lock and sleeps; returns once it holds it."""
        ready = self.root / f"ready-{time.monotonic_ns()}"
        code = ("import sys, time, pathlib\n"
                "from djtest_mcp import swifttest as st\n"
                "with st.held({'tool': 'other', 'filter': 'OtherTests'}):\n"
                f"    pathlib.Path({str(ready)!r}).write_text('1')\n"
                f"    time.sleep({seconds})\n")
        env = dict(os.environ, PYTHONPATH=str(PKG))
        p = subprocess.Popen([sys.executable, "-c", code], env=env, cwd=str(PKG))
        self.addCleanup(lambda: (p.poll() is None and p.kill(), p.wait()))
        deadline = time.monotonic() + 20
        while not ready.exists():
            if p.poll() is not None or time.monotonic() > deadline:
                self.fail("holder process never took the lock")
            time.sleep(0.02)
        return p


class ParseTests(unittest.TestCase):
    def test_counts_from_the_transcript(self):
        p = st.parse(FIXTURE)
        self.assertEqual((p["passed"], p["failed"], p["skipped"], p["issues"]), (3, 3, 1, 4))
        self.assertEqual(p["seconds"], 41.207)
        self.assertEqual(p["run"]["tests"], 7)
        self.assertEqual(p["run"]["suites"], 4)
        self.assertEqual(p["run"]["status"], "failed")
        self.assertIn('"the display name test"', p["passed_tests"])

    def test_failures_carry_their_issues_and_cases(self):
        f = {x["test"]: x for x in st.parse(FIXTURE)["failures"]}
        kick = f["theKickNoLongerIsTheMix(genre:)"]
        self.assertEqual(kick["cases"], 2)
        self.assertEqual(kick["issues"], 1)
        self.assertEqual(kick["recorded"][0]["arguments"], 'genre → "funk"')
        self.assertEqual(kick["recorded"][0]["at"], "BalanceTests.swift:27:5")
        self.assertTrue(kick["recorded"][0]["message"].startswith("Expectation failed"))
        self.assertEqual(len(f["arpFiguresVaryWithTheSeed()"]["recorded"]), 2)

    def test_skips_keep_their_reason(self):
        s = st.parse(FIXTURE)["skipped_tests"]
        self.assertEqual(s, [{"test": "renderDoesNotAllocate()",
                              "reason": "allocation is only meaningful in optimized builds"}])

    def test_tty_glyphs_parse_too(self):
        p = st.parse("\U00101B5B Test a() passed after 0.1 seconds.\n"
                     "\U00101B5B Test run with 1 test in 1 suite passed after 0.2 seconds.\n")
        self.assertEqual((p["passed"], p["run"]["tests"]), (1, 1))

    def test_xctest_and_suite_lines_are_not_tests(self):
        p = st.parse(PASSING)
        self.assertEqual((p["passed"], p["failed"], p["run"]["suites"]), (2, 0, 1))


class TagTests(unittest.TestCase):
    def test_known_flaky_and_new(self):
        tags = {f["test"]: f["tag"] for f in st.tag(st.parse(FIXTURE)["failures"])}
        self.assertEqual(tags["theKickNoLongerIsTheMix(genre:)"], "known_failing")
        self.assertEqual(tags["aReplayWalksTheSamePath()"], "flaky_under_load")
        self.assertEqual(tags["arpFiguresVaryWithTheSeed()"], "new")

    def test_a_known_test_failing_on_another_argument_is_new(self):
        text = FIXTURE.replace('genre → "funk"', 'genre → "house"')
        tags = {f["test"]: f["tag"] for f in st.tag(st.parse(text)["failures"])}
        self.assertEqual(tags["theKickNoLongerIsTheMix(genre:)"], "new")

    def test_known_file_holds_roadmaps_lists(self):
        known = st.load_known()
        self.assertEqual(set(known), {"known_failing", "flaky_under_load"})
        names = {e["test"] for e in known["known_failing"]}
        self.assertIn("tracksPlayAtOneLoudness", names)
        self.assertIn("theWindowInTheDark", names)
        self.assertIn("sampledInstrumentsDoNotAllocate",
                      {e["test"] for e in known["flaky_under_load"]})


class FilterTests(unittest.TestCase):
    def test_no_unfiltered_runs(self):
        for bad in ("", "   ", ".*", "A|", "|B", "A||B", "'; rm -rf /", "a$b", "A\nB"):
            with self.subTest(bad=bad), self.assertRaises(rn.ToolError):
                st.check_filter(bad)

    def test_argv(self):
        self.assertEqual(st.test_argv("BuildInfoTests"),
                         ["make", "swift-test-filter", "FILTER=BuildInfoTests"])
        self.assertEqual(st.test_argv(" A|B.c ", release=True),
                         ["make", "swift-rt-test-filter", "FILTER=A|B.c"])


class SwiftTestToolTests(LockEnv):
    answers = {"swift-test-filter FILTER=BuildInfoTests": PASSING,
               "swift-test-filter FILTER=Mixed": (1, FIXTURE, ""),
               "swift-test-filter FILTER=Broken": (2, "", "Foo.swift:3:1: error: nope\n"),
               "swift-test-filter FILTER=Nothing": "✔ Test run with 0 tests passed after 0.001 seconds.\n"}

    def test_a_passing_run(self):
        r = st.swift_test("BuildInfoTests")
        self.assertEqual(r["status"], "passed")
        self.assertGreater(r["passed"], 0)
        self.assertEqual(r["failed"], 0)
        self.assertTrue(r["run_line"].startswith("✔ Test run with 2 tests"))
        self.assertEqual(self.fake.calls[0]["cwd"], str(self.root))
        self.assertEqual(r["lock"]["waited_for"], None)
        self.assertTrue(Path(r["log"]).read_text().startswith("Build complete!"))
        self.assertFalse(st.lock_status()["held"])

    def test_a_failing_run_is_tagged(self):
        r = st.swift_test("Mixed")
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["new_failures"], ["arpFiguresVaryWithTheSeed()"])

    def test_a_build_failure_says_why(self):
        r = st.swift_test("Broken")
        self.assertEqual(r["status"], "build_failed")
        self.assertIn("Foo.swift:3:1: error: nope", r["errors"])

    def test_a_filter_matching_nothing(self):
        self.assertEqual(st.swift_test("Nothing")["status"], "no_tests")

    def test_release_runs_the_rt_target(self):
        st.swift_test("AllocationCounterTests", release=True)
        self.assertTrue(self.fake.ran("make swift-rt-test-filter FILTER=AllocationCounterTests"))

    def test_the_lock_is_released_when_the_run_raises(self):
        class Boom:
            def run(self, *a, **k):
                raise RuntimeError("boom")
        rn.set_runner(Boom())
        with self.assertRaises(RuntimeError):
            st.swift_test("BuildInfoTests", lock=True)
        self.assertFalse(st.lock_status()["held"])

    def test_two_calls_run_one_after_the_other(self):
        spans, lock = [], threading.Lock()

        class Slow:
            def run(self, argv, *, cwd=None, timeout=None):
                t0 = time.monotonic()
                time.sleep(0.4)
                with lock:
                    spans.append((t0, time.monotonic()))
                return rn.Result(list(argv), 0, PASSING, "", cwd)
        rn.set_runner(Slow())
        results = []
        threads = [threading.Thread(target=lambda: results.append(
            st.swift_test("BuildInfoTests", release=True)))
                   for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(results), 2)
        (a0, a1), (b0, b1) = sorted(spans)
        self.assertGreaterEqual(b0, a1)
        waits = sorted(r["lock"]["waited_seconds"] for r in results)
        self.assertGreater(waits[1], 0.2)
        waited = max(results, key=lambda r: r["lock"]["waited_seconds"])
        self.assertEqual(waited["lock"]["waited_for"]["filter"], "BuildInfoTests")


class LockProcessTests(LockEnv):
    def test_debug_runs_and_shots_do_not_wait_for_the_lock(self):
        self.holder_process()
        self.fake.answers["swift-test-filter"] = PASSING
        r = st.swift_test("BuildInfoTests", lock_wait=0.3)
        self.assertEqual(r["status"], "passed")
        self.assertFalse(r["lock"]["locked"])
        s = sh.shots("WindowShot", lock_wait=0.3)
        self.assertFalse(s["summary"]["lock"]["locked"])
        self.assertTrue(st.lock_status()["held"])  # still the other process's

    def test_release_runs_wait_for_it(self):
        self.holder_process()
        with self.assertRaises(rn.ToolError):
            st.swift_test("AllocationCounterTests", release=True, lock_wait=0.3)

    def test_another_process_holding_it_shows_in_lock_status(self):
        p = self.holder_process()
        s = st.lock_status()
        self.assertTrue(s["held"])
        self.assertEqual(s["holder"]["pid"], p.pid)
        self.assertEqual(s["holder"]["filter"], "OtherTests")
        self.assertTrue(s["pid_alive"])

    def test_a_call_waits_for_the_other_process(self):
        p = self.holder_process(seconds=1.0)
        self.fake.answers["swift-test-filter"] = PASSING
        r = st.swift_test("BuildInfoTests", lock=True)
        self.assertEqual(r["status"], "passed")
        self.assertGreater(r["lock"]["waited_seconds"], 0.3)
        self.assertEqual(r["lock"]["waited_for"]["pid"], p.pid)
        self.assertTrue(self.fake.ran("FILTER=BuildInfoTests"))

    def test_waiting_gives_up_after_lock_wait(self):
        self.holder_process()
        with self.assertRaises(rn.ToolError):
            st.swift_test("BuildInfoTests", release=True, lock_wait=0.3)
        self.assertEqual(self.fake.calls, [])

    def test_a_killed_holder_leaves_no_stale_lock(self):
        p = self.holder_process()
        os.kill(p.pid, signal.SIGKILL)
        p.wait()
        self.assertFalse(st.lock_status()["held"])
        with st.held({"tool": "t"}, wait=1) as info:
            self.assertLess(info.waited_seconds, 0.5)


class ShotsTests(LockEnv):
    PNG = b"\x89PNG\r\n\x1a\nfake"

    def setUp(self):
        super().setUp()

        def write_shots(argv):
            d = Path(next(a for a in argv if a.startswith("SHOT_DIR="))[len("SHOT_DIR="):])
            for i in range(3):
                (d / f"window-{i}.png").write_bytes(self.PNG + bytes([i]))
                os.utime(d / f"window-{i}.png", (1000 + i, 1000 + i))
            return PASSING
        self.fake.answers["swift-shots"] = write_shots

    def test_argv(self):
        self.assertEqual(sh.shots_argv("WindowShot", "/o"),
                         ["make", "swift-shots", "SHOT_DIR=/o", "FILTER=WindowShot"])
        with self.assertRaises(rn.ToolError):
            sh.shots_argv("", "/o")

    def test_returns_limit_pngs_in_test_order(self):
        r = sh.shots("WindowShot", 2)
        self.assertEqual(r["total_pngs"], 3)
        self.assertEqual([Path(i["path"]).name for i in r["images"]],
                         ["window-0.png", "window-1.png"])
        self.assertEqual(r["images"][1]["data"], self.PNG + b"\x01")
        self.assertEqual(r["summary"]["status"], "passed")
        self.assertTrue(r["shot_dir"].startswith(str(rn.out_dir() / "shots")))
        self.assertFalse(st.lock_status()["held"])


if __name__ == "__main__":
    unittest.main()
