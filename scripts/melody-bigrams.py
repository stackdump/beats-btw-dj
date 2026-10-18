#!/usr/bin/env python3
"""A melody scale-degree bigram table from the RS200 rock corpus (ROADMAP 6.4).

Writes Sources/DJCore/Resources/beats/melody-bigrams.json: for each of the 7 diatonic degrees
of the key, how often a vocal melody's next note is each degree (P(next | current), rows sum
to 1), the same with repeated notes left out ("moves"), the degree counts behind them, and the
interval shares the corpus actually has. Stdlib only.

The corpus is de Clercq & Temperley's RS200 melodic transcriptions (CC BY 4.0), as the timed
note lists their own scripts made (process-mel5.pl, add-timings.pl): one line per note onset,
"seconds  measure  midi-pitch  chromatic-degree". The zip is fetched into .build/rs200 and
checked against a pinned sha256; nothing from it is committed except these counts.

Method:
  1. Each song's notes in order (unpitched songs have none). A gap of more than one measure
     between onsets ends a phrase: no bigram spans it.
  2. Chromatic degrees (0 = the local key's tonic; the transcriptions follow modulations) fold
     onto the 7 diatonic degrees: b2 -> 2, b3 -> 3, #4/b5 -> 4, b6 -> 6, b7 -> 7. Rock mixes
     major and minor thirds and sevenths freely, so one table covers both.
  3. Counts per (degree, next degree), over every song (note-weighted). The interval shares are
     taken from the pitches: a repeat is 0 semitones, a step 1-2, a leap anything more.

Run: make melody-bigrams   (python3 scripts/melody-bigrams.py [--zip FILE] [--out FILE])
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.request
import zipfile

RS200_URL = "https://rockcorpus.midside.com/melodic_transcriptions/rs200_melody_nlt.zip"
RS200_SHA256 = "92d2c3cf901533e146c69466e16826e0f49e353f25c1236b40dac4149cddd415"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".build", "rs200", "rs200_melody_nlt.zip")
OUT = os.path.join(ROOT, "Sources", "DJCore", "Resources", "beats", "melody-bigrams.json")

DEGREES = ["1", "2", "3", "4", "5", "6", "7"]
# Chromatic degree (semitones above the tonic) -> diatonic degree index (0 = tonic).
FOLD = [0, 1, 1, 2, 2, 3, 3, 4, 5, 5, 6, 6]
PHRASE_GAP = 1.0       # measures between onsets that end a phrase


def songs(z):
    """[(name, [(measure, pitch, chromatic degree)])], sorted by file name."""
    out = []
    for n in sorted(z.namelist()):
        if not n.startswith("rs200_melody_nlt/") or not n.endswith(".nlt"):
            continue      # the zip also carries __MACOSX resource forks
        notes = []
        for line in z.read(n).decode("latin-1").splitlines():
            p = line.split()
            if len(p) != 4:
                continue  # blank, or the converter's own error lines (billie_jean_dt)
            try:
                notes.append((float(p[1]), int(p[2]), int(p[3])))
            except ValueError:
                continue
        out.append((os.path.basename(n)[:-4], notes))
    return out


def count(all_songs):
    counts = [[0] * 7 for _ in range(7)]
    unigram = [0] * 7
    shares = {"repeats": 0, "steps": 0, "leaps": 0}
    pitched = 0
    for _, notes in all_songs:
        if notes:
            pitched += 1
        for _, _, deg in notes:
            unigram[FOLD[deg % 12]] += 1
        for a, b in zip(notes, notes[1:]):
            if b[0] - a[0] > PHRASE_GAP:
                continue
            counts[FOLD[a[2] % 12]][FOLD[b[2] % 12]] += 1
            d = abs(b[1] - a[1])
            shares["repeats" if d == 0 else "steps" if d <= 2 else "leaps"] += 1
    return counts, unigram, shares, pitched


def r(x, d=4):
    v = round(x, d)
    return 0.0 if v == 0 else v


def rows(counts, skip_diagonal=False):
    out = []
    for i, row in enumerate(counts):
        cells = [0 if skip_diagonal and j == i else c for j, c in enumerate(row)]
        total = sum(cells)
        out.append([r(c / total) if total else 0.0 for c in cells])
    return out


def table_stats(counts, shares):
    total = sum(map(sum, counts))
    rep = sum(counts[i][i] for i in range(7))
    step = sum(counts[i][(i + 1) % 7] + counts[i][(i - 1) % 7] for i in range(7))
    n = sum(shares.values())
    return {
        # From the 7x7 table: same degree / a neighbouring degree (7 -> 1 is a step).
        "repeats": r(rep / total),
        "steps": r(step / total),
        "stepsOfMoves": r(step / (total - rep)),
        # From the pitches (semitones): 0 / 1-2 / more.
        "pitch": {k: r(v / n) for k, v in shares.items()},
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


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(path):
    if not os.path.exists(path) or sha256(path) != RS200_SHA256:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print(f"downloading {RS200_URL}", file=sys.stderr)
        tmp = path + ".part"
        with urllib.request.urlopen(RS200_URL) as resp, open(tmp, "wb") as f:
            f.write(resp.read())
        got = sha256(tmp)
        if got != RS200_SHA256:
            os.remove(tmp)
            sys.exit(f"sha256 mismatch: got {got}, want {RS200_SHA256}")
        os.replace(tmp, path)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--zip", help="a local copy of rs200_melody_nlt.zip (sha256-checked)")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    path = args.zip or fetch(CACHE)
    if sha256(path) != RS200_SHA256:
        sys.exit(f"{path}: sha256 is not {RS200_SHA256}")
    with zipfile.ZipFile(path) as z:
        all_songs = songs(z)
    counts, unigram, shares, pitched = count(all_songs)
    total = sum(unigram)
    default = {
        "songs": pitched,
        "notes": total,
        "bigrams": sum(map(sum, counts)),
        "unigram": [r(c / total) for c in unigram],
        "next": rows(counts),
        "moves": rows(counts, skip_diagonal=True),
        "counts": counts,
        "stats": table_stats(counts, shares),
    }
    out = {
        "provenance": {
            "source": "RS200 melodic transcriptions v2.1, timed note lists (Trevor de Clercq and "
                      "David Temperley, \"A Corpus Study of Rock Music\", Popular Music 30/1, "
                      "2011; rockcorpus.midside.com)",
            "url": RS200_URL,
            "sha256": RS200_SHA256,
            "license": "CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
            "generator": "scripts/melody-bigrams.py (make melody-bigrams)",
            "selection": f"every song with pitched notes ({pitched} of {len(all_songs)}); no "
                         f"bigram across a gap of more than {PHRASE_GAP:g} measure",
            "fold": "chromatic degree to diatonic: b2 -> 2, b3 -> 3, #4/b5 -> 4, b6 -> 6, "
                    "b7 -> 7",
            "next": "P(next degree | degree), rows sum to 1 (4 decimals)",
            "moves": "the same with repeated degrees left out",
        },
        "degrees": DEGREES,
        "tables": {"default": default},
    }
    text = dump(out) + "\n"
    with open(args.out, "w") as f:
        f.write(text)
    s = default["stats"]
    print(f"default: {pitched} songs, {default['bigrams']} bigrams, repeats {s['repeats']}, "
          f"steps {s['steps']} ({s['stepsOfMoves']} of moves); pitch {s['pitch']}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
