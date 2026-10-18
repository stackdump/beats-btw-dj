#!/usr/bin/env python3
"""Blind A/B over the listening panel (ROADMAP 6.1): play pairs in hidden order, record picks.

    scripts/listen-ab.py [DIR] [--seed N] [--genres g,…] [--seconds N] [--device D]
                         [--picks FILE] [--dry-run]

DIR is what `scripts/listen-panel.py` wrote (default .build/listen; its manifest.json names the
pairs). The seed fixes the trial order and which side of each pair is A: the same seed and
panel give the same mapping, so a session can be re-checked after the fact. Each trial plays A
then B with afplay (--seconds N cuts each to N s) and asks a / b / r(eplay) / s(kip) / q(uit).
A pick is appended to FILE (default DIR/picks.jsonl) as one JSON object per line — genre, seed,
a, b (the hidden labels in play order), pick (the winning label), build, device, abSeed, trial,
at — the shape `scripts/listening-log.py from-picks` reads.

--dry-run prints the mapping as JSON lines and plays and writes nothing. $GENRES and $SECONDS
are the defaults for --genres / --seconds. The verdict is the listener's: nothing here judges.
Stdlib only.
"""
import argparse
import datetime
import json
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, ".build", "listen")
DEVICES = ["monitors", "headphones", "phone"]


def load_pairs(directory):
    """(build, pairs) from DIR/manifest.json, or found by name (<g>-<s>.all.wav + .prev.wav)."""
    path = os.path.join(directory, "manifest.json")
    if os.path.exists(path):
        with open(path) as f:
            doc = json.load(f)
        return doc.get("build", "dev"), doc["pairs"]
    pairs = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".all.wav"):
            continue
        stem = name[: -len(".all.wav")]
        genre, _, seed = stem.rpartition("-")
        if not genre or not seed.isdigit():
            continue
        prev = stem + ".prev.wav"
        if os.path.exists(os.path.join(directory, prev)):
            pairs.append({"genre": genre, "seed": int(seed), "a": "all", "b": "prev",
                          "files": {"all": name, "prev": prev}})
    return "dev", pairs


def mapping(pairs, seed):
    """The trials for this seed: pairs shuffled, each side order drawn. Pure in (pairs, seed)."""
    rng = random.Random(seed)
    order = sorted(pairs, key=lambda p: (p["genre"], p["seed"]))
    rng.shuffle(order)
    trials = []
    for n, p in enumerate(order, 1):
        labels = [p["a"], p["b"]]
        if rng.random() < 0.5:
            labels.reverse()
        trials.append({"trial": n, "genre": p["genre"], "seed": p["seed"], "a": labels[0],
                       "b": labels[1], "files": {"a": p["files"][labels[0]],
                                                 "b": p["files"][labels[1]]}})
    return trials


def play(path, seconds):
    cmd = ["afplay", path]
    if seconds:
        cmd += ["-t", str(seconds)]
    try:
        subprocess.run(cmd, check=False)
    except KeyboardInterrupt:
        pass


def ask(prompt):
    try:
        return input(prompt).strip().lower()
    except EOFError:
        return "q"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dir", nargs="?", default=DEFAULT_DIR)
    ap.add_argument("--seed", type=int, help="trial-order seed (default: drawn and printed)")
    ap.add_argument("--genres", default=os.environ.get("GENRES") or "")
    ap.add_argument("--seconds", type=float, default=float(os.environ.get("SECONDS") or 0),
                    help="play only the first N s of each side (0: whole file)")
    ap.add_argument("--device", choices=DEVICES)
    ap.add_argument("--picks")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.dir):
        raise SystemExit("no panel at %s: run make listen first" % args.dir)
    build, pairs = load_pairs(args.dir)
    genres = [g for g in args.genres.replace(" ", ",").split(",") if g]
    if genres:
        pairs = [p for p in pairs if p["genre"] in genres]
    if not pairs:
        raise SystemExit("no all/prev pairs in %s" % args.dir)
    seed = args.seed if args.seed is not None else random.SystemRandom().randrange(1 << 31)
    trials = mapping(pairs, seed)
    print("abSeed %d: %d trials (re-run with --seed %d for the same order)"
          % (seed, len(trials), seed), file=sys.stderr)

    if args.dry_run:
        for t in trials:
            print(json.dumps({"abSeed": seed, "trial": t["trial"], "genre": t["genre"],
                              "seed": t["seed"], "a": t["a"], "b": t["b"]}, sort_keys=True))
        return 0

    picks = args.picks or os.path.join(args.dir, "picks.jsonl")
    device = args.device or ask("device (%s): " % "/".join(DEVICES))
    if device not in DEVICES:
        raise SystemExit("device must be one of %s" % ", ".join(DEVICES))
    seconds = args.seconds or None
    recorded = 0
    for t in trials:
        print("\ntrial %d/%d: %s seed %d" % (t["trial"], len(trials), t["genre"], t["seed"]))
        while True:
            for side in ("a", "b"):
                print("  playing %s" % side.upper())
                play(os.path.join(args.dir, t["files"][side]), seconds)
            answer = ask("  pick a / b, r replay, s skip, q quit: ")
            if answer in ("a", "b", "s", "q"):
                break
        if answer == "q":
            break
        if answer == "s":
            continue
        row = {"genre": t["genre"], "seed": t["seed"], "a": t["a"], "b": t["b"],
               "pick": t[answer], "build": build, "device": device, "abSeed": seed,
               "trial": t["trial"],
               "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
        with open(picks, "a") as f:
            f.write(json.dumps(row, sort_keys=True) + "\n")
        recorded += 1
    print("%d picks appended to %s; draft log rows: scripts/listening-log.py from-picks %s"
          % (recorded, picks, picks), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
