#!/usr/bin/env python3
"""Render a fixed set of tracks offline and summarise how musical / well-staged they are.

    scripts/musicality-matrix.py OUTDIR [--seconds 75] [--sampled] [--fixes key,timing,…]
                                 [--djctl PATH]

Each track goes through `djctl render` (compose + the deck's net source, nothing on the
speakers); integrated loudness comes from ffmpeg's ebur128. Writes OUTDIR/<genre>-<seed>.wav
and .json, OUTDIR/summary.json and prints a table. Compare two runs with --compare A B.
"""
import json
import os
import re
import subprocess
import sys

GENRES = ["techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz",
          "funk", "bossa", "ambient"]
SEEDS = [42, 7]

COLUMNS = [
    ("lufs", "LUFS", "{:6.1f}"),
    ("peakDB", "peak", "{:5.1f}"),
    ("clippedSamples", "clip", "{:5d}"),
    ("low+sub", "low%", "{:4.0f}"),
    ("high+air", "hi%", "{:4.1f}"),
    ("inKey", "key", "{:4.2f}"),
    ("bassOnRoot", "root", "{:4.2f}"),
    ("bassOnKick", "b@k", "{:4.2f}"),
    ("harmonyInBassRange", "h<b", "{:4.2f}"),
    ("semitoneClashesPer100", "rub", "{:4.1f}"),
    ("melodyVel", "mVel", "{:4.1f}"),
    ("melodyRecurrence", "motif", "{:4.2f}"),
    ("sectionContrast", "contr", "{:4.1f}"),
    ("changesOnBars", "onBar", "{:5.2f}"),
    ("changesOnPhrases", "on2Bar", "{:6.2f}"),
    ("fillsBeforeSections", "fills", "{:5.2f}"),
    ("slotsFromTheTop", "top", "{:4.2f}"),
    ("padMotion", "padMv", "{:5.1f}"),
    ("padColor", "7ths", "{:4.2f}"),
    ("melodyRepeats", "rep", "{:4.2f}"),
    ("arpChordTones", "arpCT", "{:5.2f}"),
    ("arpDoublesMelody", "arpDbl", "{:6.2f}"),
    ("buildupsBuild", "build", "{:5.2f}"),
    ("crashOnSections", "crash", "{:5.2f}"),
    ("bassLeap", "bLeap", "{:5.1f}"),
    ("bassStepwise", "bStep", "{:5.2f}"),
    ("melodyLegato", "legato", "{:6.2f}"),
    ("phraseEndsOnChordTones", "pEnd", "{:4.2f}"),
    ("sectionSpreadDB", "sprd", "{:4.1f}"),
    ("preDropDipDB", "gapDB", "{:6.1f}"),
    ("melodyIdeaRepeats", "idea", "{:4.2f}"),
    ("balanceErrorDB", "balErr", "{:6.1f}"),
    ("kickMinusBass", "k-b", "{:5.1f}"),
    ("sideDB", "side", "{:6.1f}"),
    ("lowSideDB", "lowSd", "{:6.1f}"),
    ("lra", "LRA", "{:4.1f}"),
    ("slopeDBPerOct", "slope", "{:5.1f}"),
    ("hfBumpDB", "hfBump", "{:6.1f}"),
    ("monoFoldDB", "monoLoss", "{:8.1f}"),
    ("harmonicCadences", "cad", "{:4.2f}"),
    ("progressions", "prog", "{:4d}"),
    ("sectionChordAgreement", "secCT", "{:5.2f}"),
    ("hasBeat", "beat", "{:4.2f}"),
    ("answerPhrases", "ans", "{:4.2f}"),
    ("hookRecurrence", "hook", "{:4.2f}"),
    ("barOneChordTones", "b1ct", "{:4.2f}"),
    ("bassIdeaRepeats", "bidea", "{:5.2f}"),
    ("melodyPeakPosition", "peak", "{:4.2f}"),
    ("leapRecovery", "leapR", "{:5.2f}"),
    # M6 (ROADMAP 6.5): the groove as played (`djctl render`'s groove block, GrooveReport)
    ("distinctVelocitiesPerPosition", "velPos", "{:6.2f}"),
    ("grooveConsistency", "gCons", "{:5.2f}"),
    ("swingRatio", "swing", "{:5.3f}"),
    ("microtimingMs", "uTime", "{:5.1f}"),
    # 6.2: the band stop before a chorus (song family; OfflineRender.bandStopDips)
    ("bandStopDipDB", "stopDB", "{:6.1f}"),
]


def loudness(path):
    """Integrated loudness (LUFS) and loudness range (LU), from ffmpeg's ebur128."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128",
                        "-f", "null", "-"], capture_output=True, text=True)
    i = re.findall(r"I:\s+(-?[\d.]+) LUFS", r.stderr)
    lra = re.findall(r"LRA:\s+(-?[\d.]+) LU", r.stderr)
    return (float(i[-1]) if i else None, float(lra[-1]) if lra else None)


def flat(doc):
    a = doc["audio"]
    m = doc["musicality"]
    b = a.get("bands", {})
    row = {
        "lufs": doc.get("lufs"),
        "lra": doc.get("lra"),
        "sectionSpreadDB": a.get("sectionSpreadDB"),
        "preDropDipDB": a.get("preDropDipDB"),
        "bandStopDipDB": a.get("bandStopDipDB"),
        "peakDB": a["peakDB"],
        "clippedSamples": a["clippedSamples"],
        "low+sub": 100 * (b.get("low", 0) + b.get("sub", 0)),
        "high+air": 100 * (b.get("high", 0) + b.get("air", 0)),
        "melodyVel": m.get("velocitySpread", {}).get("melody"),
        "sideDB": a.get("sideDB"),
        "lowSideDB": a.get("lowSideDB"),
        "balanceErrorDB": a.get("balanceErrorDB"),
        "slopeDBPerOct": a.get("slopeDBPerOct"),
        "hfBumpDB": a.get("hfBumpDB"),
        "monoFoldDB": a.get("monoFoldDB"),
    }
    g = doc.get("groove", {})
    row["distinctVelocitiesPerPosition"] = g.get("distinctVelocitiesPerPosition")
    row["grooveConsistency"] = g.get("consistency")
    row["swingRatio"] = g.get("swingRatio")
    row["microtimingMs"] = g.get("microtimingMs")
    bal = a.get("balanceDB", {})
    if "kick" in bal and "bass" in bal:
        row["kickMinusBass"] = bal["kick"] - bal["bass"]
    for k in ("inKey", "bassOnRoot", "bassOnKick", "harmonyInBassRange", "semitoneClashesPer100",
              "melodyRecurrence", "sectionContrast", "changesOnBars", "changesOnPhrases",
              "fillsBeforeSections", "slotsFromTheTop", "padMotion", "melodyRepeats", "padColor",
              "arpChordTones", "arpDoublesMelody", "buildupsBuild",
              "crashOnSections", "bassLeap", "bassStepwise", "melodyLegato",
              "phraseEndsOnChordTones", "melodyIdeaRepeats", "harmonicCadences",
              "progressions", "sectionChordAgreement", "hasBeat", "answerPhrases",
              "hookRecurrence", "barOneChordTones", "bassIdeaRepeats", "melodyPeakPosition",
              "leapRecovery"):
        row[k] = m.get(k)
    return row


def fmt(v, f):
    if v is None:
        return " " * len(f.format(0) if "d" in f else f.format(0.0))
    return f.format(int(v)) if "d" in f else f.format(v)


def table(rows):
    print("track          " + " ".join(h.rjust(len(fmt(0, f))) for _, h, f in COLUMNS))
    for name, row in rows:
        print(name.ljust(15) + " ".join(fmt(row.get(k), f) for k, _, f in COLUMNS))


def run(outdir, seconds, sampled, djctl, fixes=None):
    os.makedirs(outdir, exist_ok=True)
    summary = {}
    for g in GENRES:
        for s in SEEDS:
            name = f"{g}-{s}"
            wav = os.path.join(outdir, name + ".wav")
            cmd = [djctl, "render", g, str(s), "--seconds", str(seconds), "--out", wav, "--balance"]
            if not sampled:
                cmd.append("--synth")
            if fixes:
                cmd += ["--fixes", fixes]
            doc = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
            doc["lufs"], doc["lra"] = loudness(wav)
            with open(os.path.join(outdir, name + ".json"), "w") as f:
                json.dump(doc, f, indent=1, sort_keys=True)
            summary[name] = flat(doc)
    with open(os.path.join(outdir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
    table(summary.items())


def compare(a, b):
    sa = json.load(open(os.path.join(a, "summary.json")))
    sb = json.load(open(os.path.join(b, "summary.json")))
    for name in sa:
        if name not in sb:
            continue
        table([(name, sa[name]), ("  after", sb[name])])
    def mean(s, k):
        v = [r[k] for r in s.values() if r.get(k) is not None]
        return sum(v) / len(v) if v else None
    print("\nmeans (before → after)")
    for k, h, f in COLUMNS:
        x, y = mean(sa, k), mean(sb, k)
        print(f"  {h:6} {fmt(x, f)} → {fmt(y, f)}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--compare":
        compare(args[1], args[2])
        sys.exit(0)
    seconds = 75
    djctl = ".build/release/djctl"
    if "--seconds" in args:
        i = args.index("--seconds")
        seconds = float(args[i + 1])
        del args[i:i + 2]
    if "--djctl" in args:
        i = args.index("--djctl")
        djctl = args[i + 1]
        del args[i:i + 2]
    fixes = None
    if "--fixes" in args:
        i = args.index("--fixes")
        fixes = args[i + 1]
        del args[i:i + 2]
    sampled = "--sampled" in args
    args = [a for a in args if a != "--sampled"]
    run(args[0], seconds, sampled, djctl, fixes)
