"""djtest_replay / djtest_journal_list against a fake runner: argv, parsing, and the
determinism verdicts of `twice`."""

from __future__ import annotations

import json
import unittest

from djtest_mcp import replay as rp
from djtest_mcp import runner as rn

from .fakes import FakeRepo, write_arg

STATE = {"decks": {"A": {"playing": True}}, "crossfader": 0.5}


def replay_out(state=STATE, seconds="12.34"):
    return json.dumps(state) + f"\nwrote /x/replay-1.wav  {seconds} s\n"


class ReplayArgvTests(unittest.TestCase):
    def test_argv(self):
        self.assertEqual(
            rp.replay_argv("d", "latest", "/o/r.wav"),
            ["d", "journal", "replay", "latest", "--render", "/o/r.wav", "--json"])
        argv = rp.replay_argv("d", "2", "w", to_seq=40, journal_dir="/j", loops="/l")
        self.assertEqual(argv[argv.index("--to") + 1], "40")
        self.assertEqual(argv[argv.index("--dir") + 1], "/j")
        self.assertEqual(argv[argv.index("--loops") + 1], "/l")
        argv = rp.replay_argv("d", "2", "w", at=12.5)
        self.assertEqual(argv[argv.index("--at") + 1], "12.5")

    def test_refuses_to_and_at_together(self):
        with self.assertRaises(rn.ToolError):
            rp.replay_argv("d", "1", "w", to_seq=3, at=1.0)


class ReplayParseTests(unittest.TestCase):
    def test_parses_state_seconds_warnings(self):
        out = rp.parse_replay(replay_out(), "warning: clip 7 missing\nother\n")
        self.assertEqual(out["state"], STATE)
        self.assertEqual(out["renderedSeconds"], 12.34)
        self.assertEqual(out["warnings"], ["clip 7 missing"])

    def test_non_json_is_an_error(self):
        with self.assertRaises(rn.ToolError):
            rp.parse_replay("replayed x to seq 3")


class VerdictTests(unittest.TestCase):
    def test_identical(self):
        v = rp.verdict({"state": STATE, "sha256": "a"}, {"state": STATE, "sha256": "a"})
        self.assertEqual(v["verdict"], "identical")
        self.assertNotIn("note", v)

    def test_audio_differs_carries_the_round_robin_note(self):
        v = rp.verdict({"state": STATE, "sha256": "a"}, {"state": STATE, "sha256": "b"})
        self.assertEqual(v["verdict"], "audio differs")
        self.assertIn("round robin", v["note"])

    def test_state_differs(self):
        v = rp.verdict({"state": STATE, "sha256": "a"}, {"state": {}, "sha256": "a"})
        self.assertEqual(v["verdict"], "state differs")
        self.assertFalse(v["sameState"])


class ReplayToolTests(FakeRepo):
    def _fake(self, payloads):
        it = iter(payloads)

        def run(argv):
            write_arg(argv, "--render", next(it))
            return replay_out()
        return run

    def test_twice_identical(self):
        self.fake.answers = {"journal replay": self._fake([b"same", b"same"])}
        out = rp.replay("latest", twice=True)
        self.assertEqual(len(self.fake.calls), 2)
        self.assertEqual(out["twice"]["verdict"], "identical")
        self.assertEqual(out["sha256"], rp.sha256(out["wav"]))
        self.assertTrue(out["wav"].startswith(str(rn.out_dir() / "replays")))

    def test_twice_audio_differs(self):
        self.fake.answers = {"journal replay": self._fake([b"one", b"two"])}
        out = rp.replay("1", twice=True)
        self.assertEqual(out["twice"]["verdict"], "audio differs")
        self.assertIn("note", out["twice"])

    def test_once(self):
        self.fake.answers = {"journal replay": self._fake([b"x"])}
        out = rp.replay("latest")
        self.assertEqual(len(self.fake.calls), 1)
        self.assertNotIn("twice", out)
        self.assertEqual(out["state"], STATE)


LIST_OUT = """\
1  2026-10-18T10-00-00.jsonl  412 entries  3:05.250  ✎2  88 KB
2  2026-10-17T09-00-00.jsonl  10 entries  0:04.000  1 KB  (last line torn)
3  broken.jsonl  (unreadable)
"""


class JournalListTests(FakeRepo):
    def test_parse_list(self):
        rows = rp.parse_list(LIST_OUT)
        self.assertEqual([r["index"] for r in rows], [1, 2, 3])
        self.assertEqual(rows[0]["entries"], 412)
        self.assertEqual(rows[0]["notes"], 2)
        self.assertAlmostEqual(rows[0]["seconds"], 185.25)
        self.assertEqual(rows[0]["kb"], 88)
        self.assertFalse(rows[0]["torn"])
        self.assertTrue(rows[1]["torn"])
        self.assertEqual(rows[1]["notes"], 0)
        self.assertTrue(rows[2]["unreadable"])

    def test_empty_folder(self):
        self.assertEqual(rp.parse_list("no journals in /x\n"), [])

    def test_tool_passes_dir(self):
        self.fake.answers = {"journal list": LIST_OUT}
        rows = rp.journal_list("/j")
        self.assertEqual(self.fake.calls[0]["argv"][1:], ["journal", "list", "--dir", "/j"])
        self.assertEqual(len(rows), 3)


if __name__ == "__main__":
    unittest.main()
