"""djtest_measure / djtest_compare / djtest_level_check against a fake runner: argv, parsing,
deltas and pass flags. Nothing builds Swift, renders audio or runs ffmpeg."""

from __future__ import annotations

import json
import unittest

from djtest_mcp import measure as ms
from djtest_mcp import runner as rn

from .fakes import FakeRepo, write_arg

MEASURE_DOC = {
    "file": "x.wav", "sha256": "0123456789abcdef", "sampleRate": 48000, "channels": 2,
    "lufs": -14.2, "lra": 5.1, "peakDB": -1.3, "truePeakDBTP": -1.0, "sideDB": -12.0,
    "lowSideDB": -30.0, "slopeDBPerOct": -4.5, "clippedSamples": 0,
    "bands": {"sub": 0.10, "low": 0.30, "mid": 0.40, "high": 0.15, "air": 0.05},
}

EBUR128 = """\
[Parsed_ebur128_0 @ 0x1] t: 1.0  M: -20.0 S: -20.0  I: -19.0 LUFS  LRA: 0.0 LU
[Parsed_ebur128_0 @ 0x1] Summary:

  Integrated loudness:
    I:         -14.4 LUFS
    Threshold: -24.6 LUFS

  Loudness range:
    LRA:         4.9 LU
"""


def measure_out(doc=MEASURE_DOC, **over):
    return json.dumps({**doc, **over}, indent=2)


class MeasureArgvTests(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(ms.measure_argv("d", "/f.wav"), ["d", "measure", "/f.wav"])

    def test_options(self):
        argv = ms.measure_argv("d", "f", start=1.5, seconds=20, note=57, sections=True)
        self.assertEqual(argv, ["d", "measure", "f", "--start", "1.5", "--seconds", "20",
                                "--note", "57", "--sections"])

    def test_refuses_bad_arguments(self):
        for kw in ({"start": -1}, {"seconds": 0}, {"note": 128}):
            with self.assertRaises(rn.ToolError):
                ms.measure_argv("d", "f", **kw)
        with self.assertRaises(rn.ToolError):
            ms.measure_argv("d", "")


class ParseTests(unittest.TestCase):
    def test_parse_measure(self):
        self.assertEqual(ms.parse_measure(measure_out())["lufs"], -14.2)
        with self.assertRaises(rn.ToolError):
            ms.parse_measure("usage: djctl measure <file>")
        with self.assertRaises(rn.ToolError):
            ms.parse_measure(json.dumps({"peakDB": -1}))

    def test_parse_ebur128_takes_the_summary(self):
        self.assertEqual(ms.parse_ebur128(EBUR128), (-14.4, 4.9))
        self.assertEqual(ms.parse_ebur128("no audio"), (None, None))


class CompareDocsTests(unittest.TestCase):
    def doc(self, sha="aa", **over):
        return {**MEASURE_DOC, "sha256Full": sha, **over}

    def test_same_doc_is_identical_with_zero_deltas(self):
        c = ms.compare_docs(self.doc(), self.doc())
        self.assertTrue(c["identical"])
        self.assertTrue(c["pass"])
        self.assertEqual(c["failed"], [])
        for k, v in c["deltas"].items():
            self.assertEqual(v["delta"], 0, k)
        for k, v in c["bands"].items():
            self.assertEqual(v["delta"], 0, k)

    def test_lufs_threshold(self):
        c = ms.compare_docs(self.doc(), self.doc("bb", lufs=-13.8))
        self.assertFalse(c["identical"])
        self.assertAlmostEqual(c["deltas"]["lufs"]["delta"], 0.4)
        self.assertTrue(c["deltas"]["lufs"]["pass"])
        c = ms.compare_docs(self.doc(), self.doc("bb", lufs=-13.6))
        self.assertFalse(c["deltas"]["lufs"]["pass"])
        self.assertIn("lufs", c["failed"])
        self.assertFalse(c["pass"])
        c = ms.compare_docs(self.doc(), self.doc("bb", lufs=-13.6), {"lufs": 1.0})
        self.assertTrue(c["deltas"]["lufs"]["pass"])

    def test_peak_is_absolute(self):
        c = ms.compare_docs(self.doc(), self.doc("bb", peakDB=0.2))
        self.assertFalse(c["deltas"]["peakDB"]["pass"])
        c = ms.compare_docs(self.doc(peakDB=-0.1), self.doc("bb", peakDB=-6.0))
        self.assertTrue(c["deltas"]["peakDB"]["pass"])

    def test_band_and_side_deltas(self):
        bands = {**MEASURE_DOC["bands"], "low": 0.35, "mid": 0.35}
        c = ms.compare_docs(self.doc(), self.doc("bb", bands=bands, sideDB=-10.5))
        self.assertAlmostEqual(c["bands"]["low"]["delta"], 0.05)
        self.assertIn("bands.low", c["failed"])
        self.assertIn("bands.mid", c["failed"])
        self.assertNotIn("bands.sub", c["failed"])
        self.assertIn("sideDB", c["failed"])

    def test_missing_value_fails(self):
        a = self.doc()
        del a["lowSideDB"]
        c = ms.compare_docs(a, self.doc())
        self.assertIsNone(c["deltas"]["lowSideDB"]["delta"])
        self.assertIn("lowSideDB", c["failed"])


class SpreadTests(unittest.TestCase):
    def rows(self, *lufs):
        return [{"track": f"t{i}", "lufs": v} for i, v in enumerate(lufs)]

    def test_against_median(self):
        r = ms.spread_report(self.rows(-14.0, -13.0, -15.5), None, 1.0)
        self.assertEqual(r["referenceIs"], "median")
        self.assertEqual(r["reference"], -14.0)
        self.assertEqual(r["spread"], 2.5)
        self.assertEqual([x["pass"] for x in r["rows"]], [True, True, False])
        self.assertFalse(r["pass"])

    def test_against_target(self):
        r = ms.spread_report(self.rows(-12.2, -11.7), -12.0, 0.5)
        self.assertEqual(r["referenceIs"], "target_lufs")
        self.assertEqual([x["offset"] for x in r["rows"]], [-0.2, 0.3])
        self.assertTrue(r["pass"])

    def test_no_lufs_is_an_error(self):
        with self.assertRaises(rn.ToolError):
            ms.spread_report([{"track": "x", "lufs": None}], None, 1.0)


class MeasureToolTests(FakeRepo):
    answers = {" measure ": measure_out(), "ffmpeg": (0, "", EBUR128)}

    def setUp(self):
        super().setUp()
        self.wav = self.root / "a.wav"
        self.wav.write_bytes(b"RIFF....WAVE")

    def test_measure_adds_full_sha_and_lufs_source(self):
        out = ms.measure(str(self.wav))
        self.assertEqual(out["lufs"], -14.2)
        self.assertEqual(len(out["sha256Full"]), 64)
        self.assertIn("Swift", out["lufsSource"])
        self.assertNotIn("ffmpegLufs", out)
        self.assertFalse(self.fake.ran("ffmpeg"))
        self.assertEqual(self.fake.calls[0]["argv"][:3], [str(self.djctl), "measure",
                                                           str(self.wav)])

    def test_measure_with_ffmpeg(self):
        out = ms.measure("a.wav", ffmpeg=True)  # relative to the repo root
        self.assertEqual(out["ffmpegLufs"], -14.4)
        self.assertEqual(out["ffmpegLra"], 4.9)

    def test_ffmpeg_missing_is_reported_not_raised(self):
        self.fake.answers = {" measure ": measure_out(), "ffmpeg": (127, "", "No such file")}
        out = ms.measure(str(self.wav), ffmpeg=True)
        self.assertIn("ffmpegError", out)

    def test_missing_file(self):
        with self.assertRaises(rn.ToolError):
            ms.measure(str(self.root / "nope.wav"))
        self.assertEqual(self.fake.calls, [])

    def test_compare_a_file_with_itself(self):
        out = ms.compare(str(self.wav), str(self.wav))
        self.assertTrue(out["identical"])
        self.assertTrue(out["pass"])
        self.assertTrue(all(v["delta"] == 0 for v in out["deltas"].values()))
        self.assertTrue(all(v["delta"] == 0 for v in out["bands"].values()))

    def test_compare_two_files(self):
        other = self.root / "b.wav"
        other.write_bytes(b"RIFF..other..WAVE")

        def answer(argv):
            return measure_out(lufs=-12.0) if argv[2] == str(other) else measure_out()
        self.fake.answers = {" measure ": answer}
        out = ms.compare(str(self.wav), str(other))
        self.assertFalse(out["identical"])
        self.assertAlmostEqual(out["deltas"]["lufs"]["delta"], 2.2)
        self.assertEqual(out["failed"], ["lufs"])

    def test_compare_refuses_unknown_thresholds(self):
        with self.assertRaises(rn.ToolError):
            ms.compare(str(self.wav), str(self.wav), thresholds={"loudness": 1})


class LevelCheckToolTests(FakeRepo):
    def setUp(self):
        super().setUp()
        lufs = {"techno": -12.4, "house": -11.9}

        def render(argv):
            write_arg(argv, "--out", b"RIFF....WAVE")
            doc = {"genre": argv[2], "seed": float(argv[3]), "musicality": {},
                   "audio": {"lufs": lufs[argv[2]], "lra": 4.0, "peakDB": -2.0,
                             "truePeakDBTP": -1.8, "clippedSamples": 0}}
            return json.dumps(doc)
        self.fake.answers = {" render ": render, "ffmpeg": (0, "", EBUR128)}

    def test_level_check_renders_every_pair(self):
        out = ms.level_check(["techno", "house"], [42], seconds=20, target_lufs=-12.0,
                             tolerance=0.5)
        renders = [c["argv"] for c in self.fake.calls if c["argv"][1:2] == ["render"]]
        self.assertEqual([a[2] for a in renders], ["techno", "house"])
        self.assertTrue(all(a[a.index("--seconds") + 1] == "20" for a in renders))
        self.assertEqual([r["track"] for r in out["rows"]], ["techno-42", "house-42"])
        self.assertEqual(out["spread"], 0.5)
        self.assertTrue(out["pass"])
        self.assertEqual(out["rows"][0]["ffmpegLufs"], -14.4)
        self.assertEqual(out["rows"][0]["swiftMinusFfmpeg"], 2.0)
        self.assertEqual(out["ffmpegSpread"], 0)

    def test_level_check_without_ffmpeg(self):
        out = ms.level_check(["techno"], [42, 7], ffmpeg=False)
        self.assertFalse(self.fake.ran("ffmpeg"))
        self.assertEqual(len(out["rows"]), 2)
        self.assertEqual(out["referenceIs"], "median")

    def test_level_check_needs_genres_and_seeds(self):
        with self.assertRaises(rn.ToolError):
            ms.level_check([], [42])


if __name__ == "__main__":
    unittest.main()
