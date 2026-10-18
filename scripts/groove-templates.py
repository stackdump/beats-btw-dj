#!/usr/bin/env python3
"""Groove templates from the Groove MIDI Dataset (ROADMAP 6.5).

Writes Sources/DJCore/Resources/beats/grooves.json: per genre family, for each drum voice and
each of the 16 sixteenths of a 4/4 bar, the mean offset from the grid (ms, clamped 0...15) and
the velocity scale (mean velocity there / the voice's mean velocity), plus a tempo-scaled swing
model (Linn's ratio, 50...66 %). Stdlib only: the SMF parser is below.

The dataset (MIDI-only zip, CC BY 4.0, Gillick et al. 2019) is fetched into .build/gmd and
checked against a pinned sha256; nothing from it is committed except these averages.

Method, per file of the "beat" type in 4/4:
  1. Onsets in beats from the file's ticks (GMD files are recorded against a click: tick 0 is a
     downbeat and the tempo is the click's).
  2. Swing: the median phase of the off-beat member of each pair (8ths for the jazz family,
     16ths otherwise) is the file's swing ratio. Per family, a weighted least-squares line of
     ratio against bpm is the swing model (Friberg & Sundstrom: swing ratio falls with tempo).
  3. The onsets are de-swung with the file's own ratio, quantised to 16ths, and the residual in
     ms is the microtiming. Means per (family, voice, position) need MIN_HITS hits, or the
     position stays neutral (0 ms, scale 1).
  4. Offsets: the runner never plays a note before its tick, so a template can only hold back.
     Each family's offsets are taken relative to its kick on the downbeat (the drummer's own
     reference, which is where the click is heard), then clamped to 0...15 ms.

Run: make groove-templates   (python3 scripts/groove-templates.py [--zip FILE] [--out FILE])
"""

import argparse
import csv
import hashlib
import io
import json
import os
import struct
import sys
import urllib.request
import zipfile

GMD_URL = "https://storage.googleapis.com/magentadata/datasets/groove/groove-v1.0.0-midionly.zip"
GMD_SHA256 = "651cbc524ffb891be1a3e46d89dc82a1cecb09a57c748c7b45b844c4841dcc1e"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".build", "gmd", "groove-v1.0.0-midionly.zip")
OUT = os.path.join(ROOT, "Sources", "DJCore", "Resources", "beats", "grooves.json")

# GMD's Roland TD-11 mapping (the dataset's paper, table 2), folded to the voices beats plays.
VOICES = ["kick", "snare", "hihat", "openHat", "ride"]
NOTE_VOICE = {
    36: "kick",
    38: "snare", 40: "snare", 37: "snare",
    42: "hihat", 22: "hihat", 44: "hihat",
    46: "openHat", 26: "openHat",
    51: "ride", 59: "ride", 53: "ride",
}

# Family order and names follow beats' structure.js families (tables.json genreFamilies:
# 0 dance, 1 song, 2 jazz, 3 chill). Which GMD styles stand in for each is a judgement call;
# the dance family has few human-played sources (GMD's "dance" is disco), so pop joins it.
FAMILIES = [
    ("dance", 0, "16th", ["dance", "pop"]),
    ("song", 1, "16th", ["rock", "funk", "soul", "blues", "country", "reggae", "punk",
                         "gospel", "afrobeat", "highlife"]),
    ("jazz", 2, "8th", ["jazz", "latin", "afrocuban", "neworleans"]),
    ("chill", 3, "16th", ["hiphop"]),
]

MIN_HITS = 20          # hits a (voice, position) needs before its means count
MIN_OFFBEATS = 8       # off-beat onsets a file needs before its swing ratio counts
SWING_MIN, SWING_MAX = 0.50, 0.66   # Linn's straight ... triplet
OFFSET_MAX_MS = 15.0
VEL_MIN, VEL_MAX = 0.25, 1.75


# --- SMF -------------------------------------------------------------------------------------

def read_vlq(b, i):
    v = 0
    while True:
        c = b[i]
        i += 1
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            return v, i


def parse_smf(data):
    """(ppq, [(tick, note, velocity)] note-ons, [(tick, usPerBeat)] tempos)."""
    if data[:4] != b"MThd":
        raise ValueError("not a MIDI file")
    hlen = struct.unpack(">I", data[4:8])[0]
    _fmt, ntrk, div = struct.unpack(">HHH", data[8:14])
    if div & 0x8000:
        raise ValueError("SMPTE time division")
    i = 8 + hlen
    notes, tempos = [], []
    for _ in range(ntrk):
        if data[i:i + 4] != b"MTrk":
            raise ValueError("bad track chunk")
        tlen = struct.unpack(">I", data[i + 4:i + 8])[0]
        j, end = i + 8, i + 8 + tlen
        tick, status = 0, 0
        while j < end:
            dt, j = read_vlq(data, j)
            tick += dt
            c = data[j]
            if c == 0xFF:
                kind = data[j + 1]
                ln, j = read_vlq(data, j + 2)
                if kind == 0x51 and ln == 3:
                    tempos.append((tick, int.from_bytes(data[j:j + 3], "big")))
                j += ln
                continue
            if c in (0xF0, 0xF7):
                ln, j = read_vlq(data, j + 1)
                j += ln
                continue
            if c & 0x80:
                status = c
                j += 1
            hi = status & 0xF0
            if hi in (0xC0, 0xD0):
                j += 1
                continue
            d1, d2 = data[j], data[j + 1]
            j += 2
            if hi == 0x90 and d2 > 0:
                notes.append((tick, d1, d2))
        i = end
    notes.sort()
    tempos.sort()
    return div, notes, tempos


# --- analysis --------------------------------------------------------------------------------

def median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def swing_ratio(beats, pair):
    """The off-beat member's median phase within its pair (pair = beats per pair)."""
    ph = [(b % pair) / pair for b in beats]
    off = [p for p in ph if 0.42 <= p <= 0.72]
    return (median(off), len(off)) if len(off) >= MIN_OFFBEATS else (None, len(off))


def deswing(b, pair, s):
    k, r = divmod(b, pair)
    p = r / pair
    p = p * 0.5 / s if p < s else 0.5 + (p - s) * 0.5 / (1 - s)
    return (k + p) * pair


def analyse(z, rows, styles, grid):
    pair = 1.0 if grid == "8th" else 0.5
    acc = {v: [[0.0, 0.0, 0] for _ in range(16)] for v in VOICES}   # offset sum, vel sum, n
    swings = []          # (bpm, ratio, weight)
    files = 0
    for row in rows:
        if row["style"].split("/")[0] not in styles:
            continue
        ppq, notes, tempos = parse_smf(z.read("groove/" + row["midi_filename"]))
        us = tempos[0][1] if tempos else 500000
        if any(t[1] != us for t in tempos):
            continue     # GMD has none; a tempo change would break the ms conversion
        ms_beat = us / 1000.0
        bpm = 60000.0 / ms_beat
        hits = [(t / ppq, NOTE_VOICE[n], v) for t, n, v in notes if n in NOTE_VOICE]
        if not hits:
            continue
        files += 1
        s, n_off = swing_ratio([b for b, _, _ in hits], pair)
        if s is not None:
            swings.append((bpm, s, n_off))
        s_use = min(max(s if s is not None else 0.5, SWING_MIN), SWING_MAX)
        for b, voice, vel in hits:
            d = deswing(b, pair, s_use)
            q = round(d * 4)
            off = (d - q / 4) * ms_beat
            a = acc[voice][q % 16]
            a[0] += off
            a[1] += vel
            a[2] += 1
    return acc, swings, files


def fit(swings):
    """Weighted least squares ratio = a + b * bpm; (a, b, lo, hi)."""
    w = sum(n for _, _, n in swings)
    mx = sum(x * n for x, _, n in swings) / w
    my = sum(y * n for _, y, n in swings) / w
    sxx = sum(n * (x - mx) ** 2 for x, _, n in swings)
    sxy = sum(n * (x - mx) * (y - my) for x, y, n in swings)
    b = sxy / sxx if sxx > 0 else 0.0
    return my - b * mx, b, min(x for x, _, _ in swings), max(x for x, _, _ in swings)


def r(x, d):
    v = round(x, d)
    return 0.0 if v == 0 else v


def family_template(name, index, grid, styles, acc, swings, files):
    a, b, lo, hi = fit(swings)
    kick = acc["kick"][0]
    ref = kick[0] / kick[2] if kick[2] >= MIN_HITS else 0.0
    voices = {}
    for v in VOICES:
        cells = acc[v]
        total = sum(c[2] for c in cells)
        mean_vel = sum(c[1] for c in cells) / total if total else 0
        offs, vels, counts = [], [], []
        for c in cells:
            counts.append(c[2])
            if c[2] < MIN_HITS or not mean_vel:
                offs.append(0.0)
                vels.append(1.0)
                continue
            offs.append(r(min(max(c[0] / c[2] - ref, 0.0), OFFSET_MAX_MS), 1))
            vels.append(r(min(max(c[1] / c[2] / mean_vel, VEL_MIN), VEL_MAX), 3))
        voices[v] = {"offsetMs": offs, "velocity": vels, "hits": counts}
    lo_r = min(max(a + b * lo, SWING_MIN), SWING_MAX)
    hi_r = min(max(a + b * hi, SWING_MIN), SWING_MAX)
    return {
        "index": index,
        "styles": styles,
        "files": files,
        "swing": {
            "grid": grid,
            "intercept": r(a, 5),
            "perBpm": r(b, 7),
            "bpmRange": [r(lo, 1), r(hi, 1)],
            "atRange": [r(lo_r, 4), r(hi_r, 4)],
            "files": len(swings),
        },
        "referenceMs": r(ref, 2),
        "voices": voices,
    }


def dump(v, ind=""):
    """JSON, one key per line, every array of scalars on one line."""
    if isinstance(v, dict):
        inner = ind + "  "
        items = [f"{inner}{json.dumps(k)}: {dump(x, inner)}" for k, x in v.items()]
        return "{\n" + ",\n".join(items) + "\n" + ind + "}"
    if isinstance(v, list) and any(isinstance(x, (dict, list)) for x in v):
        inner = ind + "  "
        return "[\n" + ",\n".join(inner + dump(x, inner) for x in v) + "\n" + ind + "]"
    return json.dumps(v, ensure_ascii=True, separators=(", ", ": "))


def fetch(path):
    if not os.path.exists(path) or sha256(path) != GMD_SHA256:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print(f"downloading {GMD_URL}", file=sys.stderr)
        tmp = path + ".part"
        with urllib.request.urlopen(GMD_URL) as resp, open(tmp, "wb") as f:
            f.write(resp.read())
        got = sha256(tmp)
        if got != GMD_SHA256:
            os.remove(tmp)
            sys.exit(f"sha256 mismatch: got {got}, want {GMD_SHA256}")
        os.replace(tmp, path)
    return path


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--zip", help="a local copy of the GMD MIDI-only zip (sha256-checked)")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    path = args.zip or fetch(CACHE)
    if sha256(path) != GMD_SHA256:
        sys.exit(f"{path}: sha256 is not {GMD_SHA256}")
    with zipfile.ZipFile(path) as z:
        rows = list(csv.DictReader(io.TextIOWrapper(z.open("groove/info.csv"), "utf-8")))
        rows = [x for x in rows if x["beat_type"] == "beat" and x["time_signature"] == "4-4"]
        rows.sort(key=lambda x: x["midi_filename"])
        families = {}
        for name, index, grid, styles in FAMILIES:
            acc, swings, files = analyse(z, rows, set(styles), grid)
            families[name] = family_template(name, index, grid, styles, acc, swings, files)
    out = {
        "provenance": {
            "source": "Groove MIDI Dataset v1.0.0, MIDI-only (Gillick, Roberts, Engel, Eck, "
                      "Bamman 2019, \"Learning to Groove with Inverse Sequence Transformations\")",
            "url": GMD_URL,
            "sha256": GMD_SHA256,
            "license": "CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
            "generator": "scripts/groove-templates.py (make groove-templates)",
            "selection": "beat_type beat, time_signature 4-4",
            "noteMap": "Roland TD-11: kick 36; snare 38 40 37; hihat 42 22 44; openHat 46 26; "
                       "ride 51 59 53",
            "minHits": MIN_HITS,
            "offset": "ms after the grid once de-swung, relative to the family's downbeat kick, "
                      "clamped 0...15 (the runner never plays early)",
            "velocity": "mean velocity at the position / the voice's mean velocity, clamped "
                        f"{VEL_MIN}...{VEL_MAX}",
            "swing": "Linn ratio of the pair's off-beat member = intercept + perBpm * bpm, bpm "
                     "clamped to bpmRange, ratio clamped 0.50...0.66",
        },
        "voices": VOICES,
        "families": families,
    }
    text = dump(out) + "\n"
    with open(args.out, "w") as f:
        f.write(text)
    for name, fam in families.items():
        sw = fam["swing"]
        print(f"{name}: {fam['files']} files, swing {sw['atRange'][0]:.3f}..{sw['atRange'][1]:.3f} "
              f"over {sw['bpmRange'][0]:.0f}..{sw['bpmRange'][1]:.0f} bpm, ref {fam['referenceMs']} ms",
              file=sys.stderr)


if __name__ == "__main__":
    main()
