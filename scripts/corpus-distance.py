#!/usr/bin/env python3
"""Corpus distance between two musicality-matrix runs, or a run and reference MIDI (ROADMAP 6.1, M8).

    scripts/corpus-distance.py BEFORE AFTER [--threshold 0.1] [--json OUT] [--previous OLD.json]
    scripts/corpus-distance.py RUN --ref MIDIDIR [--ref-bpm N] [--threshold 0.1] [--json OUT]
    scripts/corpus-distance.py --self-test

BEFORE / AFTER / RUN are `scripts/musicality-matrix.py OUTDIR --notes` directories (their
<genre>-<seed>.notes files, one note per line: tick net group note velocity channel steps; a
tick is a sixteenth). MIDIDIR holds reference MIDI (e.g. Basic Pitch on the stems), as
MIDIDIR/<genre>/**/*.mid or MIDIDIR/<genre>-<anything>.mid; a stem's group comes from its file
name (bass, drums, vocals / lead / melody, other / keys / pad ...). Stdlib only.

It is a regression alarm, a trend: it never decides a merge, and it always exits 0.

Method (Yang & Lerch 2020, "On the evaluation of generative models in music", simplified):
  1. Notes are grouped per genre and per group: drum-channel notes are "drums", tonal notes
     keep their mixer group, and every tonal note is also in "all" (so references without
     stems still line up).
  2. Per bar (16 sixteenths) with notes in the group: pitch count, pitch range, mean pitch
     interval, note count, mean inter-onset interval (sixteenths), the pitch-class histogram
     and the note-length histogram (drums: note count and inter-onset interval only).
  3. A scalar feature's distribution is its per-bar values. A histogram feature becomes a
     scalar per bar: its Euclidean distance to the BEFORE (or RUN) set's mean histogram, so a
     shift of the whole set shows as well as a change in spread.
  4. Each distribution gets a Gaussian KDE (Silverman's bandwidth); the overlap area
     integral of min(f, g) is 1 for identical sets and falls toward 0 as they part.
A feature whose overlap is below 1 - threshold is flagged; with --previous (an earlier --json),
so is one whose overlap fell by more than the threshold since then.
"""
import argparse
import json
import math
import os
import random
import struct
import sys
import tempfile

BAR = 16
# note-length classes in sixteenths: 16th triplet ... whole note, dotted values between
LENGTHS = [2 / 3, 1, 4 / 3, 1.5, 2, 8 / 3, 3, 4, 16 / 3, 6, 8, 12, 16]
TONAL = ["pitchCount", "pitchRange", "pitchInterval", "noteCount", "ioi", "pitchClassHist",
         "noteLengthHist"]
RHYTHM = ["noteCount", "ioi"]
HISTOGRAMS = {"pitchClassHist", "noteLengthHist"}


def is_drum(channel):
    """The wave engine's drum channels (WaveSynth.isDrumChannel)."""
    return 10 <= channel <= 15


# --- note sources ---------------------------------------------------------------------------

def read_notes(path):
    """[(tick, group, note, channel, steps)] from a `djctl render --notes` log."""
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 7 or p[2].startswith("<"):
                continue  # a part change: tick net <action> target 0 0 0
            try:
                out.append((int(p[0]), p[2], int(p[3]), int(p[5]), float(p[6])))
            except ValueError:
                continue
    return out


def run_tracks(d):
    """{genre: [notes per track]} from a matrix run's .notes files."""
    out = {}
    for n in sorted(os.listdir(d)):
        if n.endswith(".notes"):
            genre = n[:-len(".notes")].rsplit("-", 1)[0]
            out.setdefault(genre, []).append(read_notes(os.path.join(d, n)))
    return out


def vlq(b, i):
    v = 0
    while True:
        c = b[i]
        i += 1
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            return v, i


def read_smf(path):
    """(division, [(name, [(start, end, channel, note, velocity)], tempos)]) from a Standard
    MIDI File: start / end in ticks, channel 0-based; tempos [(tick, µs per quarter)]."""
    b = open(path, "rb").read()
    if b[:4] != b"MThd":
        raise ValueError(f"{path}: not a MIDI file")
    hlen = struct.unpack(">I", b[4:8])[0]
    _, ntrks, division = struct.unpack(">HHh", b[8:14])
    i = 8 + hlen
    tracks = []
    for _ in range(ntrks):
        if b[i:i + 4] != b"MTrk":
            break
        tlen = struct.unpack(">I", b[i + 4:i + 8])[0]
        j, end = i + 8, i + 8 + tlen
        i = end
        t, status, name = 0, 0, ""
        on, notes, tempos = {}, [], []
        while j < end:
            dt, j = vlq(b, j)
            t += dt
            c = b[j]
            if c & 0x80:
                status = c
                j += 1
            if status == 0xFF:
                kind = b[j]
                n, j = vlq(b, j + 1)
                data = b[j:j + n]
                j += n
                if kind == 0x03 and not name:
                    name = data.decode("latin-1")
                elif kind == 0x51 and n == 3:
                    tempos.append((t, int.from_bytes(data, "big")))
                elif kind == 0x2F:
                    break
                continue
            if status in (0xF0, 0xF7):
                n, j = vlq(b, j)
                j += n
                continue
            kind, ch = status & 0xF0, status & 0x0F
            if kind in (0xC0, 0xD0):
                j += 1
                continue
            d1, d2 = b[j], b[j + 1]
            j += 2
            if kind == 0x90 and d2 > 0:
                on.setdefault((ch, d1), []).append((t, d2))
            elif kind in (0x80, 0x90):
                stack = on.get((ch, d1))
                if stack:
                    s, v = stack.pop(0)
                    notes.append((s, t, ch, d1, v))
        tracks.append((name, notes, tempos))
    return division, tracks


def stem_group(name):
    """A reference stem's group from its file or track name."""
    n = name.lower()
    for keys, group in ((("drum", "perc", "kick", "snare", "hat"), "drums"),
                        (("bass",), "bass"),
                        (("vocal", "voice", "lead", "melody"), "melody"),
                        (("arp",), "arp"),
                        (("other", "keys", "piano", "pad", "chord", "guitar", "harmony"),
                         "harmony")):
        if any(k in n for k in keys):
            return group
    return n or "all"


def smf_notes(path, bpm=None):
    """[(tick, group, note, channel, steps)] in sixteenths, the wave engine's 1-based channels.
    Without `bpm`, ticks are musical time (division / 4 per sixteenth); with it, the file's
    seconds are re-gridded at that tempo (Basic Pitch writes real time at a fixed 120)."""
    division, tracks = read_smf(path)
    tempos = sorted(t for _, _, ts in tracks for t in ts) or [(0, 500000)]
    if division < 0:  # SMPTE: ticks per second, re-gridded at bpm (else 120)
        per_sec = -(division >> 8) * (division & 0xFF)
        conv = lambda t: t / per_sec * (bpm or 120) / 15
    elif bpm:
        def conv(t):
            sec, last, us = 0.0, 0, tempos[0][1]
            for at, u in tempos:
                if at >= t:
                    break
                sec += (at - last) / division * us / 1e6
                last, us = at, u
            sec += (t - last) / division * us / 1e6
            return sec * bpm / 15
    else:
        conv = lambda t: t / (division / 4)
    stem = os.path.splitext(os.path.basename(path))[0]
    out = []
    for k, (name, notes, _) in enumerate(tracks):
        group = stem_group(name if len(tracks) > 1 and name else stem)
        for s, e, ch, note, _ in notes:
            channel = 10 if ch == 9 or group == "drums" else ch + 1
            start = conv(s)
            out.append((int(start) + 1, group, note, channel, max(conv(e) - start, 0.0)))
    return out


def ref_tracks(d, bpm=None):
    """{genre: [notes per piece]}: each MIDIDIR/<genre>/<piece>/ folder (or file) is a piece,
    its stems merged; MIDIDIR/<genre>-*.mid files are pieces too."""
    out = {}

    def bpm_for(folder):
        try:
            return float(open(os.path.join(folder, "bpm.txt")).read().split()[0])
        except (OSError, ValueError, IndexError):
            return bpm

    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if os.path.isdir(p):
            pieces = {}
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    if f.lower().endswith((".mid", ".midi")):
                        key = os.path.relpath(root, p)
                        key = f if key == "." else key.split(os.sep)[0]
                        pieces.setdefault(key, []).extend(
                            smf_notes(os.path.join(root, f), bpm_for(root)))
            out.setdefault(n, []).extend(pieces[k] for k in sorted(pieces))
        elif n.lower().endswith((".mid", ".midi")) and "-" in n:
            out.setdefault(n.split("-", 1)[0], []).append(smf_notes(p, bpm_for(d)))
    return out


# --- features ------------------------------------------------------------------------------

def length_class(steps):
    if steps <= 0:
        return 0
    return min(range(len(LENGTHS)), key=lambda k: abs(math.log(steps / LENGTHS[k])))


def bar_features(notes):
    """{(group, feature): [per-bar values]} for one track."""
    bars = {}
    for tick, group, note, channel, steps in notes:
        g = "drums" if is_drum(channel) else group
        bar = (tick - 1) // BAR
        bars.setdefault((g, bar), []).append((tick, note, steps))
        if g != "drums":
            bars.setdefault(("all", bar), []).append((tick, note, steps))
    out = {}
    for (g, _), ns in sorted(bars.items()):
        ns.sort()
        onsets = sorted({t for t, _, _ in ns})
        f = {"noteCount": len(ns)}
        if len(onsets) > 1:
            f["ioi"] = (onsets[-1] - onsets[0]) / (len(onsets) - 1)
        if g != "drums":
            pitches = [n for _, n, _ in ns]
            f["pitchCount"] = len(set(pitches))
            f["pitchRange"] = max(pitches) - min(pitches)
            if len(pitches) > 1:
                f["pitchInterval"] = sum(abs(b - a) for a, b in zip(pitches, pitches[1:])) / (
                    len(pitches) - 1)
            pch = [0.0] * 12
            nlh = [0.0] * len(LENGTHS)
            for _, n, s in ns:
                pch[n % 12] += 1 / len(ns)
                nlh[length_class(s)] += 1 / len(ns)
            f["pitchClassHist"] = pch
            f["noteLengthHist"] = nlh
        for k, v in f.items():
            out.setdefault((g, k), []).append(v)
    return out


def corpus_features(tracks):
    """{genre: {(group, feature): [values over every bar of every track]}}."""
    out = {}
    for genre, ts in tracks.items():
        acc = out.setdefault(genre, {})
        for notes in ts:
            for k, vs in bar_features(notes).items():
                acc.setdefault(k, []).extend(vs)
    return out


def centroid(vs):
    return [sum(c) / len(vs) for c in zip(*vs)]


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


# --- overlap -------------------------------------------------------------------------------

def bandwidth(xs, floor):
    n = len(xs)
    m = sum(xs) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1)) if n > 1 else 0.0
    return max(1.06 * sd * n ** -0.2, floor)


def overlap(a, b, points=256):
    """Overlap area of the Gaussian KDEs of samples `a` and `b`, in [0, 1]."""
    lo, hi = min(min(a), min(b)), max(max(a), max(b))
    span = hi - lo
    if span == 0:
        return 1.0
    floor = 0.02 * span
    ha, hb = bandwidth(a, floor), bandwidth(b, floor)
    lo, hi = lo - 4 * max(ha, hb), hi + 4 * max(ha, hb)
    dx = (hi - lo) / (points - 1)

    def kde(xs, h):
        c = 1 / (len(xs) * h * math.sqrt(2 * math.pi))
        return [c * sum(math.exp(-0.5 * ((lo + i * dx - x) / h) ** 2) for x in xs)
                for i in range(points)]

    fa, fb = kde(a, ha), kde(b, hb)
    return min(1.0, sum(min(x, y) for x, y in zip(fa, fb)) * dx)


def compare(base, other, threshold, previous=None):
    """Rows [{genre, group, feature, overlap, nBefore, nAfter, flag}] for every (genre, group,
    feature) both corpora have."""
    rows = []
    prev = {(r["genre"], r["group"], r["feature"]): r["overlap"] for r in previous or []}
    for genre in sorted(set(base) & set(other)):
        fa, fb = base[genre], other[genre]
        for (group, feature) in sorted(set(fa) & set(fb)):
            if feature not in (RHYTHM if group == "drums" else TONAL):
                continue
            a, b = fa[(group, feature)], fb[(group, feature)]
            if not a or not b:
                continue
            if feature in HISTOGRAMS:
                c = centroid(a)
                a, b = [dist(v, c) for v in a], [dist(v, c) for v in b]
            oa = overlap(a, b)
            flags = []
            if oa < 1 - threshold:
                flags.append("low")
            was = prev.get((genre, group, feature))
            if was is not None and was - oa > threshold:
                flags.append(f"fell {was - oa:.2f}")
            rows.append({"genre": genre, "group": group, "feature": feature,
                         "overlap": round(oa, 4), "nBefore": len(a), "nAfter": len(b),
                         "flag": ", ".join(flags)})
    return rows


def report(rows):
    print(f"{'genre':10} {'group':10} {'feature':15} {'overlap':>7} {'bars':>11}  flag")
    for r in rows:
        bars = f"{r['nBefore']}/{r['nAfter']}"
        print(f"{r['genre']:10} {r['group']:10} {r['feature']:15} {r['overlap']:7.3f} "
              f"{bars:>11}  {r['flag']}")
    by = {}
    for r in rows:
        by.setdefault(r["feature"], []).append(r["overlap"])
    print("\nmean overlap per feature")
    for k in TONAL:
        if k in by:
            print(f"  {k:15} {sum(by[k]) / len(by[k]):5.3f}  (min {min(by[k]):5.3f}, "
                  f"{len(by[k])} genre x group)")
    flagged = [r for r in rows if r["flag"]]
    print(f"\n{len(flagged)} of {len(rows)} flagged")


# --- self test ------------------------------------------------------------------------------

def synth_run(d, rng_seed, spread=7, density=4, length=2.0):
    """A fake matrix run: two genres x two seeds of random-walk melody, bass and drums."""
    os.makedirs(d, exist_ok=True)
    for genre in ("techno", "jazz"):
        for seed in (42, 7):
            rng = random.Random(f"{rng_seed}-{genre}-{seed}")
            lines = []
            for bar in range(32):
                p = 60
                for k in range(density):
                    t = bar * BAR + 1 + k * (BAR // density) + rng.choice((0, 0, 1))
                    p += rng.randint(-spread // 2, spread // 2)
                    lines.append(f"{t} lead melody {p} 100 1 {length * rng.choice((1, 1, 2))}")
                lines.append(f"{bar * BAR + 1} bass bass {36 + rng.choice((0, 7, 5))} 100 2 4")
                for k in range(0, BAR, 4):
                    lines.append(f"{bar * BAR + 1 + k} kick drums 36 100 10 1")
                lines.append(f"{bar * BAR + 1} ctl <mute> lead 0 0 0")
            with open(os.path.join(d, f"{genre}-{seed}.notes"), "w") as f:
                f.write("\n".join(lines) + "\n")


def write_smf(path, notes, division=480):
    """A format-0 file of [(start16, len16, channel0, note)] at 120 bpm (self test only)."""
    ev = []
    for s, n, ch, note in notes:
        ev.append((s * division // 4, 0x90 | ch, note, 100))
        ev.append(((s + n) * division // 4, 0x80 | ch, note, 0))
    ev.sort(key=lambda e: (e[0], e[1] & 0xF0 == 0x90))
    body, last = bytearray(), 0

    def v(x):
        out = [x & 0x7F]
        x >>= 7
        while x:
            out.insert(0, (x & 0x7F) | 0x80)
            x >>= 7
        return bytes(out)

    body += v(0) + b"\xFF\x51\x03" + (500000).to_bytes(3, "big")
    for t, st, d1, d2 in ev:
        body += v(t - last) + bytes((st, d1, d2))
        last = t
    body += v(0) + b"\xFF\x2F\x00"
    with open(path, "wb") as f:
        f.write(b"MThd" + struct.pack(">IHHh", 6, 0, 1, division))
        f.write(b"MTrk" + struct.pack(">I", len(body)) + body)


def self_test():
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        a, b, c = (os.path.join(tmp, x) for x in "abc")
        synth_run(a, 1)
        synth_run(b, 1)
        synth_run(c, 2, spread=13, density=8, length=1.0)
        fa = corpus_features(run_tracks(a))
        same = compare(fa, corpus_features(run_tracks(b)), 0.1)
        worst = min(r["overlap"] for r in same)
        print(f"identical runs: {len(same)} rows, min overlap {worst:.4f} (want >= 0.99)")
        ok &= bool(same) and worst >= 0.99
        diff = compare(fa, corpus_features(run_tracks(c)), 0.1)
        worst = min(r["overlap"] for r in diff)
        print(f"different runs: min overlap {worst:.4f} (want < 0.95)")
        ok &= worst < 0.95
        ref = os.path.join(tmp, "ref", "techno", "song")
        os.makedirs(ref)
        write_smf(os.path.join(ref, "bass.mid"), [(0, 4, 0, 36), (4, 2, 0, 43)])
        write_smf(os.path.join(ref, "drums.mid"), [(0, 1, 9, 36), (4, 1, 9, 38)])
        got = sorted(ref_tracks(os.path.join(tmp, "ref"))["techno"][0])
        want = [(1, "bass", 36, 1, 4.0), (1, "drums", 36, 10, 1.0), (5, "bass", 43, 1, 2.0),
                (5, "drums", 38, 10, 1.0)]
        print(f"SMF read: {got}")
        ok &= got == want
    print("self test", "passed" if ok else "FAILED")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("before", nargs="?", help="a matrix run (--notes), the baseline")
    ap.add_argument("after", nargs="?", help="a second matrix run")
    ap.add_argument("--ref", help="reference MIDI directory, in place of AFTER")
    ap.add_argument("--ref-bpm", type=float, help="re-grid reference MIDI seconds at this tempo")
    ap.add_argument("--threshold", type=float, default=0.1)
    ap.add_argument("--json", help="write the rows here")
    ap.add_argument("--previous", help="an earlier --json, to flag overlaps that fell")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    try:
        if not args.before or not (args.after or args.ref):
            ap.print_usage()
            return
        base = corpus_features(run_tracks(args.before))
        if args.ref:
            other = corpus_features(ref_tracks(args.ref, args.ref_bpm))
        else:
            other = corpus_features(run_tracks(args.after))
        if not base or not other:
            print("no notes: run scripts/musicality-matrix.py OUTDIR --notes first "
                  "(and give --ref .mid files)")
            return
        previous = None
        if args.previous:
            previous = json.load(open(args.previous)).get("rows")
        rows = compare(base, other, args.threshold, previous)
        report(rows)
        if args.json:
            with open(args.json, "w") as f:
                json.dump({"before": args.before, "after": args.after or args.ref,
                           "threshold": args.threshold, "rows": rows}, f, indent=1)
    except Exception as e:  # a trend, not a gate: report and carry on
        print(f"corpus-distance: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
    sys.exit(0)
