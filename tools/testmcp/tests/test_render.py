"""djtest_build / djtest_render / djtest_matrix against a fake runner: argument building
and parsing djctl's canned output. Nothing builds Swift or renders audio."""

from __future__ import annotations

import asyncio
import json
import unittest
from pathlib import Path

from djtest_mcp import render as rd
from djtest_mcp import runner as rn

from .fakes import FakeRepo, write_arg

RENDER_DOC = {
    "genre": "techno", "seed": 42, "structure": "standard", "seconds": 10.0, "tempo": 128,
    "musicality": {"inKey": 0.97, "bassOnRoot": 0.81},
    "audio": {"lufs": -14.2, "lra": 5.1, "peakDB": -1.3, "truePeakDBTP": -1.0,
              "clippedSamples": 0, "bands": {"low": 0.3}},
    "groove": {"swingRatio": 0.5},
}


def fake_render(argv):
    write_arg(argv, "--out", b"RIFF....WAVE")
    return json.dumps(RENDER_DOC, indent=2)


class RenderArgvTests(unittest.TestCase):
    def test_defaults_are_synth_with_seconds_and_out(self):
        argv = rd.render_argv("/x/djctl", "techno", 42, "/o/a.wav", seconds=10)
        self.assertEqual(argv, ["/x/djctl", "render", "techno", "42", "--seconds", "10",
                                "--out", "/o/a.wav", "--synth"])

    def test_options(self):
        argv = rd.render_argv("d", "house", 7.5, "w", seconds=12.5, structure="loop",
                              fixes="key,timing", sampled=True, room=True, balance=True,
                              kit="k#128:0", palette="minecraft", notes="n.txt")
        self.assertNotIn("--synth", argv)
        for pair in (["--structure", "loop"], ["--fixes", "key,timing"], ["--kit", "k#128:0"],
                     ["--palette", "minecraft"], ["--notes", "n.txt"]):
            i = argv.index(pair[0])
            self.assertEqual(argv[i:i + 2], pair)
        self.assertIn("--room", argv)
        self.assertIn("--balance", argv)
        self.assertEqual(argv[3], "7.5")
        self.assertEqual(argv[argv.index("--seconds") + 1], "12.5")

    def test_refuses_bad_genre_and_seconds(self):
        with self.assertRaises(rn.ToolError):
            rd.render_argv("d", "tech no", 1, "w")
        with self.assertRaises(rn.ToolError):
            rd.render_argv("d", "techno", 1, "w", seconds=0)


class RenderParseTests(unittest.TestCase):
    def test_summary_lifts_headline(self):
        s = rd.summarize_render(rd.parse_render(json.dumps(RENDER_DOC)), "/w.wav")
        self.assertEqual(s["lufs"], -14.2)
        self.assertEqual(s["peakDB"], -1.3)
        self.assertEqual(s["clippedSamples"], 0)
        self.assertEqual(s["musicality"]["inKey"], 0.97)
        self.assertEqual(s["groove"]["swingRatio"], 0.5)
        self.assertEqual(s["wav"], "/w.wav")

    def test_non_json_and_missing_blocks_are_errors(self):
        with self.assertRaises(rn.ToolError):
            rd.parse_render("usage: djctl render ...")
        with self.assertRaises(rn.ToolError):
            rd.parse_render(json.dumps({"audio": {}}))


class RenderToolTests(FakeRepo):
    answers = {" render ": fake_render}

    def test_render_writes_under_build_testmcp(self):
        out = rd.render("techno", 42, seconds=10)
        wav = Path(out["wav"])
        self.assertTrue(out["wavExists"])
        self.assertEqual(wav.name, "techno-42.wav")
        self.assertEqual(wav.parent.parent, rn.out_dir() / "renders")
        self.assertTrue((wav.parent / "techno-42.json").exists())
        self.assertEqual(out["lufs"], -14.2)
        argv = self.fake.calls[0]["argv"]
        self.assertEqual(argv[0], str(self.djctl))
        self.assertIn("--synth", argv)

    def test_render_needs_a_build(self):
        self.djctl.unlink()
        with self.assertRaises(rn.ToolError) as e:
            rd.render("techno", 42)
        self.assertIn("djtest_build", str(e.exception))
        self.assertEqual(self.fake.calls, [])

    def test_failed_render_raises_with_stderr(self):
        self.fake.answers = {" render ": (2, "", "unknown fix bogus")}
        with self.assertRaises(rn.ToolError) as e:
            rd.render("techno", 42, fixes="bogus")
        self.assertIn("unknown fix bogus", str(e.exception))


class BuildToolTests(FakeRepo):
    def test_build_copies_djctl_and_bundle(self):
        bin_dir = self.root / ".build" / "release"
        (bin_dir / rd.BUNDLE).mkdir(parents=True)
        (bin_dir / rd.BUNDLE / "x.json").write_text("{}")
        (bin_dir / "djctl").write_text("new")
        self.fake.answers = {"--show-bin-path": str(bin_dir) + "\n"}
        out = rd.build()
        self.assertTrue(self.fake.ran("swift build -c release --product djctl"))
        self.assertEqual(self.fake.calls[0]["cwd"], str(self.root))
        self.assertEqual(self.djctl.read_text(), "new")
        self.assertTrue((rn.out_dir() / rd.BUNDLE / "x.json").exists())
        self.assertEqual(out["copied"], ["djctl", rd.BUNDLE])

    def test_build_failure_copies_nothing(self):
        self.fake.answers = {"--product djctl": (1, "", "error: boom")}
        with self.assertRaises(rn.ToolError):
            rd.build()
        self.assertEqual(self.djctl.read_text(), "#!/bin/sh\n")


class MatrixToolTests(FakeRepo):
    def test_matrix_returns_summary_rows(self):
        def fake(argv):
            out = Path(argv[2])
            (out / "summary.json").write_text(json.dumps(
                {"techno-42": {"lufs": -14.0}, "techno-7": {"lufs": -13.5}}))
            return "track  LUFS\n"
        self.fake.answers = {"musicality-matrix.py": fake}
        out = rd.matrix(seconds=20, fixes="none")
        argv = self.fake.calls[0]["argv"]
        self.assertEqual(argv[:2], ["python3", "scripts/musicality-matrix.py"])
        self.assertEqual(argv[argv.index("--djctl") + 1], str(self.djctl))
        self.assertEqual(argv[argv.index("--seconds") + 1], "20")
        self.assertNotIn("--sampled", argv)
        self.assertEqual([r["track"] for r in out["rows"]], ["techno-42", "techno-7"])
        self.assertEqual(out["rows"][1]["lufs"], -13.5)

    def test_matrix_without_summary_is_an_error(self):
        with self.assertRaises(rn.ToolError):
            rd.matrix()


class ServerTests(unittest.TestCase):
    def test_lists_every_tool(self):
        try:
            from djtest_mcp import server
        except ImportError:
            self.skipTest("mcp not installed (make testmcp-venv)")
        names = sorted(t.name for t in asyncio.run(server.mcp.list_tools()))
        self.assertEqual(names, sorted(server.TOOLS))


if __name__ == "__main__":
    unittest.main()
