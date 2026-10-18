#!/usr/bin/env python3
"""Measure the reference corpus and turn it into per-family bands (ROADMAP 6.1).

    scripts/references.py [--refs DIR] [--djctl PATH] [--cache DIR] [--no-ffmpeg] [--min N]
                          [--write [--targets PATH]] [--json]
    scripts/references.py --selftest [--djctl PATH]

References are local files Matt plays, three to five per family, laid out as
$DJ_REFERENCES/<family>/<any name>.{wav,aiff,mp3,m4a,flac} (family: dance, song, jazz, chill;
--refs overrides the variable). They are never committed and never published: what leaves this
script is numbers and a hash.

Each file goes through `djctl measure <file> --sections` (the same audio block `djctl render`
prints, so references and renders are measured alike) and, unless --no-ffmpeg, ffmpeg's
ebur128 as a cross-check of loudness, LRA and true peak (a disagreement is printed, not fatal).
Results are cached by the file's sha256 and the djctl build in .build/references/.

Per family and metric (MixTargets.metrics: lufs, lra, truePeak, slope, side) it prints the
median and the p10–p90 band, plus the section lengths beat tracking found. --write fills
targets.json's `bands` for every family with at least --min (3) files: value = median, band =
[p10, p90], source = "ref:<family>/<sha8> (n=K, djctl <build>)", sha8 being the hash of the
family's file hashes. Never a path or a file name. --targets writes into another copy (a
scratch one, say) instead of Sources/DJCore/Resources/beats/targets.json.

--selftest builds synthetic references in a temporary directory, measures them, writes into a
scratch copy of targets.json and checks the bands are there and name no path.
"""
import hashlib
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = os.path.join(ROOT, "Sources", "DJCore", "Resources", "beats", "targets.json")
FAMILIES = ["dance", "song", "jazz", "chill"]  # GrooveTemplate.familyNames, beats' order
# targets.json band name → the key `djctl measure` prints it under
METRICS = {
    "lufs": "lufs",
    "lra": "lra",
    "truePeak": "truePeakDBTP",
    "slope": "slopeDBPerOct",
    "side": "sideDB",
}
AUDIO = (".wav", ".aif", ".aiff", ".mp3", ".m4a", ".flac", ".caf")
# how far ffmpeg may read from djctl before the cross-check says so (LU, LU, dB)
TOLERANCE = {"lufs": 1.0, "lra": 2.0, "truePeak": 1.0}
SOURCE = re.compile(r"^ref:(dance|song|jazz|chill)/[0-9a-f]{8} \(n=\d+, djctl [A-Za-z0-9._-]+\)$")


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_id():
    """The repo's short commit, "-dirty" with tracked changes (bundle-app.sh's rule)."""
    try:
        c = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    dirty = subprocess.run(["git", "-C", ROOT, "diff", "--quiet", "HEAD", "--"]).returncode != 0
    return c + ("-dirty" if dirty else "")


def corpus(refs):
    """{family: [path, …]} for the families present; other directories are reported, skipped."""
    out = {}
    for name in sorted(os.listdir(refs)):
        d = os.path.join(refs, name)
        if not os.path.isdir(d):
            continue
        if name not in FAMILIES:
            print(f"skipping {name}/: not a family ({', '.join(FAMILIES)})", file=sys.stderr)
            continue
        files = []
        for root, _, names in os.walk(d):
            files += [os.path.join(root, n) for n in names
                      if n.lower().endswith(AUDIO) and not n.startswith(".")]
        if files:
            out[name] = sorted(files)
    return out


def ffmpeg_loudness(path):
    """Integrated loudness, LRA and true peak from ffmpeg's ebur128, or None without ffmpeg."""
    try:
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
                            "ebur128=peak=true", "-f", "null", "-"],
                           capture_output=True, text=True)
    except OSError:
        return None
    i = re.findall(r"I:\s+(-?[\d.]+|-inf) LUFS", r.stderr)
    lra = re.findall(r"LRA:\s+(-?[\d.]+) LU", r.stderr)
    peak = re.findall(r"Peak:\s+(-?[\d.]+|-inf) dBFS", r.stderr)

    def num(xs):
        return float(xs[-1]) if xs and xs[-1] != "-inf" else None
    return {"lufs": num(i), "lra": num(lra), "truePeak": num(peak)}


def measure(path, djctl, cache, build, use_ffmpeg):
    """One file's numbers, from the cache when this build has measured these bytes before."""
    digest = sha256(path)
    cached = os.path.join(cache, build, digest + ".json")
    if os.path.exists(cached):
        with open(cached) as f:
            doc = json.load(f)
        if doc.get("ffmpeg") is not None or not use_ffmpeg:
            return doc
    r = subprocess.run([djctl, "measure", path, "--sections"], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"djctl measure failed on a {os.path.splitext(path)[1]} file: {r.stderr.strip()}")
    m = json.loads(r.stdout)
    sections = m.get("sections", {})
    doc = {
        "sha256": digest,
        "metrics": {k: m.get(v) for k, v in METRICS.items()},
        "seconds": m.get("seconds"),
        "bpm": sections.get("bpm"),
        "sectionBars": sections.get("sectionBars", []),
        "ffmpeg": ffmpeg_loudness(path) if use_ffmpeg else None,
    }
    os.makedirs(os.path.dirname(cached), exist_ok=True)
    with open(cached, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    return doc


def quantile(xs, q):
    """Linear interpolation between order statistics (numpy's default)."""
    s = sorted(xs)
    if not s:
        return None
    pos = (len(s) - 1) * q
    lo = math.floor(pos)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def family_hash(docs):
    """sha8 over the family's file hashes, sorted: names the set without naming a file."""
    h = hashlib.sha256("\n".join(sorted(d["sha256"] for d in docs)).encode())
    return h.hexdigest()[:8]


def aggregate(measured, build):
    """{family: {"n", "source", "metrics": {metric: {median, p10, p90}}, "sectionBars": …}}"""
    out = {}
    for fam, docs in measured.items():
        bands = {}
        for k in METRICS:
            vs = [d["metrics"][k] for d in docs
                  if isinstance(d["metrics"].get(k), (int, float)) and math.isfinite(d["metrics"][k])
                  and d["metrics"][k] > -190]  # -200 is AudioMetrics' "silent"
            if vs:
                bands[k] = {"median": quantile(vs, 0.5), "p10": quantile(vs, 0.1),
                            "p90": quantile(vs, 0.9), "n": len(vs)}
        bars = [b for d in docs for b in d.get("sectionBars", [])]
        out[fam] = {
            "n": len(docs),
            "source": f"ref:{fam}/{family_hash(docs)} (n={len(docs)}, djctl {build})",
            "metrics": bands,
            "sectionBars": {"median": quantile(bars, 0.5), "p10": quantile(bars, 0.1),
                            "p90": quantile(bars, 0.9), "n": len(bars)} if bars else None,
        }
    return out


def cross_check(measured):
    """Lines where ffmpeg's ebur128 and djctl disagree by more than TOLERANCE."""
    lines = []
    for fam, docs in measured.items():
        for d in docs:
            ff = d.get("ffmpeg") or {}
            for k, tol in TOLERANCE.items():
                a, b = d["metrics"].get(k), ff.get(k)
                if a is None or b is None or a < -190:
                    continue
                if abs(a - b) > tol:
                    lines.append(f"  {fam}/{d['sha256'][:8]} {k}: djctl {a:.2f}, ffmpeg {b:.2f}")
    return lines


def show(bands):
    def f(v):
        return f"{v:7.2f}" if v is not None else "      ·"
    print("family  metric       median     p10     p90   n")
    for fam in FAMILIES:
        if fam not in bands:
            continue
        b = bands[fam]
        for k in METRICS:
            m = b["metrics"].get(k)
            if m:
                print(f"{fam:7} {k:10} {f(m['median'])} {f(m['p10'])} {f(m['p90'])} {m['n']:3}")
        s = b["sectionBars"]
        if s:
            print(f"{fam:7} {'section':10} {f(s['median'])} {f(s['p10'])} {f(s['p90'])} {s['n']:3}"
                  "  (bars, beat tracking)")
        print(f"{fam:7} source     {b['source']}")


def write(bands, targets, minimum):
    """Fill targets.json's bands for families with >= minimum files; returns what was written."""
    with open(targets) as f:
        doc = json.load(f)
    written = []
    for fam, b in sorted(bands.items()):
        if b["n"] < minimum:
            print(f"not writing {fam}: {b['n']} file(s), --min {minimum}", file=sys.stderr)
            continue
        src = b["source"]
        if not SOURCE.match(src):  # privacy: only a family name and hashes go into the repo
            die(f"refusing to write a source that is not a ref: entry: {src!r}")
        for k, m in b["metrics"].items():
            doc.setdefault("bands", {}).setdefault(k, {})[fam] = {
                "value": round(m["median"], 2),
                "band": [round(m["p10"], 2), round(m["p90"], 2)],
                "source": src,
            }
            written.append((k, fam))
    with open(targets, "w") as f:
        f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    return written


def run(refs, djctl, cache, use_ffmpeg, minimum, targets, do_write, as_json):
    if not os.path.isdir(refs):
        die(f"no reference directory (set $DJ_REFERENCES or pass --refs): {refs!r}")
    files = corpus(refs)
    if not files:
        die(f"no audio under <refs>/<family>/ (families: {', '.join(FAMILIES)})")
    build = build_id()
    measured = {fam: [measure(p, djctl, cache, build, use_ffmpeg) for p in paths]
                for fam, paths in files.items()}
    bands = aggregate(measured, build)
    if as_json:
        print(json.dumps(bands, indent=1, sort_keys=True))
    else:
        show(bands)
    checks = cross_check(measured)
    if checks:
        print("ffmpeg cross-check disagrees:", file=sys.stderr)
        print("\n".join(checks), file=sys.stderr)
    if do_write:
        written = write(bands, targets, minimum)
        print(f"wrote {len(written)} band(s) into {os.path.relpath(targets, ROOT)}",
              file=sys.stderr)
    return bands


# MARK: - self-test


def synth_wav(path, seconds, bpm, gain, width, tilt, seed):
    """A stereo 44.1 kHz test signal: a kick-like thump on every beat, a noise wash (brighter
    with `tilt`), `width` of it decorrelated into the side."""
    sr = 44100
    rnd = random.Random(seed)
    n = int(seconds * sr)
    beat = int(sr * 60 / bpm)
    frames = bytearray()
    lp_l = lp_r = 0.0
    for i in range(n):
        t = (i % beat) / sr
        kick = math.sin(2 * math.pi * (50 + 80 * math.exp(-t * 30)) * t) * math.exp(-t * 8)
        wl, wr = rnd.uniform(-1, 1), rnd.uniform(-1, 1)
        lp_l += (wl - lp_l) * tilt
        lp_r += (wr - lp_r) * tilt
        mid = 0.5 * (lp_l + lp_r)
        l = gain * (0.7 * kick + 0.3 * (mid + width * (lp_l - mid)))
        r = gain * (0.7 * kick + 0.3 * (mid + width * (lp_r - mid)))
        frames += struct.pack("<hh", int(max(-1, min(1, l)) * 32767),
                              int(max(-1, min(1, r)) * 32767))
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))


def selftest(djctl):
    tmp = tempfile.mkdtemp(prefix="dj-references-")
    try:
        refs = os.path.join(tmp, "refs")
        plan = {"dance": (128, 0.9, 0.3, 0.5), "chill": (80, 0.4, 0.6, 0.15)}
        for fam, (bpm, gain, width, tilt) in plan.items():
            os.makedirs(os.path.join(refs, fam))
            for k in range(3):
                name = f"private name {fam} {k}.wav"  # must never reach targets.json
                synth_wav(os.path.join(refs, fam, name), 24, bpm, gain * (1 - 0.1 * k), width,
                          tilt, seed=10 * FAMILIES.index(fam) + k)
        os.makedirs(os.path.join(refs, "notafamily"))
        scratch = os.path.join(tmp, "targets.json")
        shutil.copy(TARGETS, scratch)
        bands = run(refs, djctl, os.path.join(tmp, "cache"), True, 3, scratch, True, False)
        with open(scratch) as f:
            text = f.read()
        doc = json.loads(text)
        fail = []
        for fam in plan:
            for k in METRICS:
                b = doc["bands"][k][fam]
                if not SOURCE.match(b["source"]):
                    fail.append(f"{k}.{fam} source {b['source']!r}")
                if not (b["band"][0] <= b["value"] <= b["band"][1]):
                    fail.append(f"{k}.{fam} median outside its band")
        for k in METRICS:
            for fam in ("song", "jazz"):
                if "band" in doc["bands"][k][fam]:
                    fail.append(f"{k}.{fam} written without references")
        if doc["bands"]["lufs"]["dance"]["value"] <= doc["bands"]["lufs"]["chill"]["value"]:
            fail.append("the louder synthetic family did not measure louder")
        if tmp in text or "private name" in text or ".wav" in text:
            fail.append("a path or file name reached targets.json")
        # the cache is reused on a second run, with the same numbers
        again = run(refs, djctl, os.path.join(tmp, "cache"), True, 3, scratch, False, True)
        if again != bands:
            fail.append("a cached run measured differently")
        if fail:
            print("selftest FAILED:\n  " + "\n  ".join(fail), file=sys.stderr)
            return 1
        print("selftest ok: 2 families, 3 synthetic references each, bands written as ref: "
              "entries, no path", file=sys.stderr)
        return 0
    finally:
        shutil.rmtree(tmp)


def main(argv):
    args = list(argv)

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            if i + 1 >= len(args):
                die(f"{name} needs a value")
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return default

    def flag(name):
        if name in args:
            args.remove(name)
            return True
        return False

    djctl = opt("--djctl", os.path.join(ROOT, ".build", "release", "djctl"))
    refs = opt("--refs", os.environ.get("DJ_REFERENCES"))
    cache = opt("--cache", os.path.join(ROOT, ".build", "references"))
    targets = opt("--targets", TARGETS)
    minimum = int(opt("--min", "3"))
    do_write, as_json = flag("--write"), flag("--json")
    no_ffmpeg, self_test = flag("--no-ffmpeg"), flag("--selftest")
    if args:
        die(__doc__)
    if self_test:
        return selftest(djctl)
    if not refs:
        die("set $DJ_REFERENCES (or pass --refs DIR): <dir>/<family>/<audio files>")
    run(refs, djctl, cache, not no_ffmpeg, minimum, targets, do_write, as_json)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
