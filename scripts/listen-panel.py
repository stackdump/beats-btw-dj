#!/usr/bin/env python3
"""Render the fixed listening panel (ROADMAP 6.1) into .build/listen/.

    scripts/listen-panel.py [OUTDIR] [--genres g,…] [--seconds 90] [--seed 42] [--prev-fixes a,…]
                            [--synth] [--no-stems] [--djctl PATH] [--dry-run]

Every panel genre at the panel seed, plus every (genre, seed) the listening log names, is
rendered twice through `djctl render` (offline, nothing on the speakers): `--fixes all` as
<genre>-<seed>.all.wav and the previous part as <genre>-<seed>.prev.wav. The previous part is
all fixes minus part F's (subtractive, unison, echo, kickTune, motif, balance) unless
--prev-fixes / $PREV_FIXES names it. Each genre also gets a stem set at the panel seed under
`--fixes all` (`--solo` drums, bass, harmony, melody, arp → <genre>-<seed>.stem-<group>.wav).
OUTDIR/manifest.json lists every file and the pairs `scripts/listen-ab.py` plays.

$GENRES and $SECONDS are the defaults for --genres / --seconds (`make listen GENRES=techno
SECONDS=5`). --dry-run prints the commands and writes nothing. WAVs are never committed
(.build/ is ignored). Stdlib only.
"""
import argparse
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, ".build", "listen")
DEFAULT_DJCTL = os.path.join(ROOT, ".build", "release", "djctl")
MUSICALITY = os.path.join(ROOT, "Sources", "DJCore", "Musicality", "DJMusicality.swift")

GENRES = ["techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz",
          "funk", "bossa", "ambient"]
PANEL_SEED = 42
STEMS = ["drums", "bass", "harmony", "melody", "arp"]
# Part F (CLAUDE.md "Musicality"): what the default previous part leaves out.
PART_F = ["subtractive", "unison", "echo", "kickTune", "motif", "balance"]


def fix_names(path=MUSICALITY):
    """The names `djctl render --fixes` takes, in `Fixes.named` order (from the Swift source)."""
    with open(path) as f:
        src = f.read()
    m = re.search(r"static let named: \[String: Fixes\] = \[(.*?)\n\s*\]", src, re.S)
    if not m:
        raise SystemExit("%s: no Fixes.named table" % path)
    names = re.findall(r'"(\w+)":\s*\.', m.group(1))
    if not names:
        raise SystemExit("%s: Fixes.named is empty" % path)
    return names


def previous_fixes(names):
    missing = [n for n in PART_F if n not in names]
    if missing:
        raise SystemExit("part F fixes not in Fixes.named: %s" % ", ".join(missing))
    return ",".join(n for n in names if n not in PART_F)


def logged_seeds(genres):
    """(genre, seed) pairs the listening log names beyond the panel seed, for panel genres."""
    path = os.path.join(ROOT, "scripts", "listening-log.py")
    spec = importlib.util.spec_from_file_location("listening_log", path)
    log = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(log)
    rows, _ = log.parse(log.DEFAULT_LOG, log.genres(log.DEFAULT_TABLES))
    seen = []
    for r in rows:
        key = (r.genre, int(r.seed))
        if r.genre in genres and key[1] != PANEL_SEED and key not in seen:
            seen.append(key)
    return seen


def build_id():
    try:
        r = subprocess.run(["git", "-C", ROOT, "describe", "--always", "--dirty", "--abbrev=7"],
                           capture_output=True, text=True, check=True)
        return r.stdout.strip() or "dev"
    except (OSError, subprocess.CalledProcessError):
        return "dev"


def plan(genres, seconds, prev, synth, stems, seed=PANEL_SEED, extra=()):
    """Every render: dicts with name, genre, seed, label, fixes, solo (or None), file."""
    jobs = []

    def job(genre, s, label, fixes, solo=None):
        name = "%s-%d.%s" % (genre, s, label)
        jobs.append({"name": name, "genre": genre, "seed": s, "label": label, "fixes": fixes,
                     "solo": solo, "file": name + ".wav", "seconds": seconds, "synth": synth})

    tracks = [(g, seed) for g in genres] + [k for k in extra if k[0] in genres]
    for g, s in tracks:
        job(g, s, "all", "all")
        job(g, s, "prev", prev)
    if stems:
        for g in genres:
            for group in STEMS:
                job(g, seed, "stem-" + group, "all", group)
    return jobs


def command(djctl, outdir, j):
    cmd = [djctl, "render", j["genre"], str(j["seed"]), "--seconds", str(j["seconds"]),
           "--out", os.path.join(outdir, j["file"]), "--fixes", j["fixes"]]
    if j["solo"]:
        cmd += ["--solo", j["solo"]]
    if j["synth"]:
        cmd.append("--synth")
    return cmd


def manifest(jobs, build, prev):
    pairs = [{"genre": j["genre"], "seed": j["seed"], "a": "all", "b": "prev",
              "files": {"all": j["file"], "prev": j["file"].replace(".all.wav", ".prev.wav")}}
             for j in jobs if j["label"] == "all"]
    return {"build": build, "prevFixes": prev, "partF": PART_F, "renders": jobs, "pairs": pairs}


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("outdir", nargs="?", default=DEFAULT_OUT)
    ap.add_argument("--genres", default=os.environ.get("GENRES") or ",".join(GENRES))
    ap.add_argument("--seconds", type=float, default=float(os.environ.get("SECONDS") or 90))
    ap.add_argument("--seed", type=int, default=PANEL_SEED)
    ap.add_argument("--prev-fixes", default=os.environ.get("PREV_FIXES") or None)
    ap.add_argument("--synth", action="store_true", help="skip sampled instruments")
    ap.add_argument("--no-stems", action="store_true")
    ap.add_argument("--djctl", default=DEFAULT_DJCTL)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    genres = [g for g in args.genres.replace(" ", ",").split(",") if g]
    seconds = int(args.seconds) if args.seconds == int(args.seconds) else args.seconds
    prev = args.prev_fixes or previous_fixes(fix_names())
    jobs = plan(genres, seconds, prev, args.synth, not args.no_stems, args.seed,
                logged_seeds(genres))
    doc = manifest(jobs, build_id(), prev)

    if args.dry_run:
        for j in jobs:
            print(" ".join(shlex.quote(c) for c in command(args.djctl, args.outdir, j)))
        print("%d renders, %d pairs (dry run: nothing written)" % (len(jobs), len(doc["pairs"])),
              file=sys.stderr)
        return 0

    if not os.access(args.djctl, os.X_OK):
        raise SystemExit("no djctl at %s (swift build -c release --product djctl)" % args.djctl)
    os.makedirs(args.outdir, exist_ok=True)
    for n, j in enumerate(jobs, 1):
        print("[%d/%d] %s" % (n, len(jobs), j["name"]), file=sys.stderr)
        r = subprocess.run(command(args.djctl, args.outdir, j), capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            raise SystemExit("render failed: %s" % j["name"])
        with open(os.path.join(args.outdir, j["name"] + ".json"), "w") as f:
            f.write(r.stdout)
    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    print("%d renders in %s; next: scripts/listen-ab.py %s" % (len(jobs), args.outdir,
                                                              args.outdir), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
