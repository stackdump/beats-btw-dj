#!/usr/bin/env python3
"""Read the listening log (docs/listening-log.md, ROADMAP 6.1).

    scripts/listening-log.py check [--log F] [--tables F]
    scripts/listening-log.py missing [--seed 42] [--log F] [--tables F]
    scripts/listening-log.py rank [--build B] [--log F] [--tables F]
    scripts/listening-log.py from-picks PICKS.jsonl [--build B] [--device D]
    scripts/listening-log.py selftest

check    every row of the table under "## Log" is well-formed; errors name the file line, exit 1.
missing  catalogue genres (tables.json "genres") with no row at that seed; exit 0 either way.
rank     counts each row's first complaint (a broken counts twice) and prints the stages
         6.2 … 6.6 in the order the log asks for them; a stage nobody named is a drop candidate.
from-picks  turns blind A/B picks (one JSON object per line: genre, seed, a, b, pick — pick is
         "a" / "b" or one of the two labels; build and device optional) into draft log rows on
         stdout. The verdict and first-wrong cells are left "?": a person fills them in, and
         check rejects a row until they do. Nothing here writes a verdict or edits the log.

Stdlib only.
"""
import argparse
import collections
import json
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LOG = os.path.join(ROOT, "docs", "listening-log.md")
DEFAULT_TABLES = os.path.join(ROOT, "Sources", "DJCore", "Resources", "beats", "tables.json")

COLUMNS = ["genre", "seed", "build", "verdict", "first wrong", "device", "notes"]
VERDICTS = ["track", "loop", "broken"]
DIMENSIONS = ["form", "harmony", "melody", "groove", "arrangement", "sound", "mix"]
DEVICES = ["monitors", "headphones", "phone"]
BUILD = re.compile(r"^(dev|[0-9a-f]{7,40}(-dirty)?)$")

# The stage that owns each dimension (ROADMAP 6.2 … 6.6).
STAGES = collections.OrderedDict([
    ("6.2", ("Form a DJ can mix", ["form", "arrangement"])),
    ("6.3", ("Harmony that goes somewhere", ["harmony"])),
    ("6.4", ("A hook, and an answer", ["melody"])),
    ("6.5", ("A beat in every genre", ["groove"])),
    ("6.6", ("Sound and a mix that translate", ["sound", "mix"])),
])
STAGE_OF = {d: s for s, (_, dims) in STAGES.items() for d in dims}
WEIGHT = {"broken": 2, "loop": 1, "track": 1}


class Row:
    def __init__(self, line, cells):
        self.line = line
        self.genre, self.seed, self.build, self.verdict, self.wrong, self.device, self.notes = cells


def genres(tables):
    with open(tables) as f:
        return list(json.load(f)["genres"])


def split_row(text):
    """Cells of a pipe-table row, or None when the line is not one."""
    text = text.strip()
    if not text.startswith("|"):
        return None
    body = text[1:-1] if text.endswith("|") and len(text) > 1 else text[1:]
    return [c.strip() for c in body.split("|")]


def parse(path, catalogue):
    """(rows, errors): rows of the first table under "## Log"; errors as (line, message)."""
    rows, errors = [], []
    with open(path) as f:
        lines = f.read().split("\n")
    start = next((i for i, l in enumerate(lines) if l.strip().lower() == "## log"), None)
    if start is None:
        return rows, [(0, 'no "## Log" section')]
    i = start + 1
    while i < len(lines) and split_row(lines[i]) is None:
        if lines[i].startswith("## "):
            break
        i += 1
    header = split_row(lines[i]) if i < len(lines) else None
    if header is None:
        return rows, [(start + 1, 'no table under "## Log"')]
    if [h.lower() for h in header] != COLUMNS:
        errors.append((i + 1, "header must be | " + " | ".join(COLUMNS) + " |"))
        return rows, errors
    sep = split_row(lines[i + 1]) if i + 1 < len(lines) else None
    if sep is None or len(sep) != len(COLUMNS) or not all(re.fullmatch(r":?-+:?", c) for c in sep):
        errors.append((i + 2, "the header needs a |---| separator row"))
        return rows, errors
    seen = {}
    for n in range(i + 2, len(lines)):
        cells = split_row(lines[n])
        if cells is None:
            if lines[n].strip():
                break  # the table ends at the first line that is not a row
            continue
        line = n + 1
        if len(cells) != len(COLUMNS):
            errors.append((line, "%d cells, want %d (no pipes in notes)" % (len(cells), len(COLUMNS))))
            continue
        row = Row(line, cells)
        bad = []
        if row.genre not in catalogue:
            bad.append("genre %r is not in the catalogue" % row.genre)
        if not re.fullmatch(r"\d+", row.seed):
            bad.append("seed %r is not an integer" % row.seed)
        if not BUILD.match(row.build):
            bad.append("build %r is not a short commit (optionally -dirty) or dev" % row.build)
        if row.verdict == "?" or row.wrong == "?":
            bad.append("unfilled draft row: a listener writes the verdict and first wrong")
        else:
            if row.verdict not in VERDICTS:
                bad.append("verdict %r is not one of %s" % (row.verdict, "|".join(VERDICTS)))
            if row.wrong not in DIMENSIONS + ["none"]:
                bad.append("first wrong %r is not one of %s|none" % (row.wrong, "|".join(DIMENSIONS)))
            elif row.wrong == "none" and row.verdict != "track":
                bad.append("a %s has something wrong: name the first dimension" % row.verdict)
        if row.device not in DEVICES:
            bad.append("device %r is not one of %s" % (row.device, "|".join(DEVICES)))
        key = (row.genre, row.seed, row.build, row.device)
        if not bad and key in seen:
            bad.append("duplicate of line %d (same genre, seed, build, device)" % seen[key])
        if bad:
            errors.extend((line, b) for b in bad)
        else:
            seen[key] = line
            rows.append(row)
    return rows, errors


def shown(path):
    rel = os.path.relpath(path)
    return path if rel.startswith("..") else rel


def cmd_check(args):
    catalogue = genres(args.tables)
    rows, errors = parse(args.log, catalogue)
    for line, message in errors:
        print("%s:%d: %s" % (shown(args.log), line, message), file=sys.stderr)
    if errors:
        return 1
    print("%s: %d rows ok" % (shown(args.log), len(rows)))
    return 0


def cmd_missing(args):
    catalogue = genres(args.tables)
    rows, errors = parse(args.log, catalogue)
    if errors:
        print("note: %d malformed rows ignored (run check)" % len(errors), file=sys.stderr)
    have = {r.genre for r in rows if int(r.seed) == args.seed}
    missing = [g for g in catalogue if g not in have]
    for g in missing:
        print(g)
    print("%d of %d genres have no seed-%d entry" % (len(missing), len(catalogue), args.seed),
          file=sys.stderr)
    return 0


def cmd_rank(args):
    catalogue = genres(args.tables)
    rows, errors = parse(args.log, catalogue)
    if errors:
        print("note: %d malformed rows ignored (run check)" % len(errors), file=sys.stderr)
    if args.build:
        rows = [r for r in rows if r.build == args.build]
    score = collections.Counter()
    named = collections.defaultdict(collections.Counter)
    for r in rows:
        if r.wrong in STAGE_OF:
            stage = STAGE_OF[r.wrong]
            score[stage] += WEIGHT[r.verdict]
            named[stage][r.wrong] += 1
    order = sorted(STAGES, key=lambda s: (-score[s], s))
    verdicts = collections.Counter(r.verdict for r in rows)
    print("%d rows: %s" % (len(rows), ", ".join("%d %s" % (verdicts[v], v) for v in VERDICTS)))
    for rank, stage in enumerate(order, 1):
        title = STAGES[stage][0]
        if score[stage]:
            what = ", ".join("%s %d" % kv for kv in named[stage].most_common())
            print("%d. %s  %-32s score %3d  (%s)" % (rank, stage, title, score[stage], what))
        else:
            print("%d. %s  %-32s score   0  (nothing logged: drop candidate)" % (rank, stage, title))
    return 0


def read_picks(path):
    with open(path) as f:
        for n, text in enumerate(f, 1):
            text = text.strip()
            if not text:
                continue
            try:
                yield n, json.loads(text)
            except ValueError as e:
                raise SystemExit("%s:%d: not JSON: %s" % (path, n, e))


def cmd_from_picks(args):
    tally = collections.OrderedDict()
    for n, p in read_picks(args.picks):
        try:
            genre, seed, a, b, pick = p["genre"], int(p["seed"]), p["a"], p["b"], p["pick"]
        except (KeyError, TypeError, ValueError):
            raise SystemExit("%s:%d: a pick needs genre, seed, a, b, pick" % (args.picks, n))
        winner = {"a": a, "b": b, "A": a, "B": b}.get(pick, pick)
        if winner not in (a, b):
            raise SystemExit("%s:%d: pick %r is neither a, b, %r nor %r" % (args.picks, n, pick, a, b))
        build = args.build or p.get("build") or "dev"
        device = args.device or p.get("device") or "?"
        key = (genre, seed, build, device)
        tally.setdefault(key, collections.Counter())
        tally[key][a] += 0
        tally[key][b] += 0
        tally[key][winner] += 1
    print("| " + " | ".join(COLUMNS) + " |")
    print("|" + "---|" * len(COLUMNS))
    for (genre, seed, build, device), c in tally.items():
        votes = ", ".join("%s %d" % kv for kv in c.most_common())
        print("| %s | %d | %s | ? | ? | %s | blind A/B: %s |" % (genre, seed, build, device, votes))
    print("%d draft rows: fill verdict and first wrong by ear before they go in the log"
          % len(tally), file=sys.stderr)
    return 0


def cmd_selftest(args):
    catalogue = genres(args.tables)
    failures = []

    def expect(cond, what):
        if not cond:
            failures.append(what)

    rows, errors = parse(DEFAULT_LOG, catalogue)
    expect(not errors and not rows, "the template parses clean and empty: %r" % errors)

    def table(*body):
        return "# t\n\n## Log\n\n| " + " | ".join(COLUMNS) + " |\n|" + "---|" * len(COLUMNS) + "\n" \
            + "".join(b + "\n" for b in body)

    good = "| techno | 42 | 1a2b3c4 | loop | form | monitors | intro too short |"
    bad = "| techno | 42 | 1a2b3c4 | great | form | monitors | not a verdict |"
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "log.md")
        with open(path, "w") as f:
            f.write(table(good, bad, "| polka | x | main | ? | ? | car | |"))
        rows, errors = parse(path, catalogue)
        expect(len(rows) == 1 and rows[0].line == 7, "the good row parses at line 7")
        lines = sorted({line for line, _ in errors})
        expect(lines == [8, 9], "bad rows fail at their own lines: %r" % errors)
        expect(any("great" in m for _, m in errors), "the bad verdict is named")
        expect(any("unfilled" in m for _, m in errors), "a draft row is rejected as unfilled")

        rc = cmd_check(argparse.Namespace(log=path, tables=args.tables))
        expect(rc == 1, "check exits 1 on a bad row")
        rc = cmd_check(argparse.Namespace(log=DEFAULT_LOG, tables=args.tables))
        expect(rc == 0, "check exits 0 on the template")

        with open(path, "w") as f:
            f.write(table(good, good.replace("monitors", "phone"),
                          "| house | 7 | dev | broken | mix | headphones | |"))
        rows, errors = parse(path, catalogue)
        have = {r.genre for r in rows if int(r.seed) == 42}
        expect(not errors and have == {"techno"}, "seed-42 coverage is techno only")
        expect([g for g in catalogue if g not in have] == [g for g in catalogue if g != "techno"],
               "missing lists every other genre")

        picks = os.path.join(tmp, "picks.jsonl")
        with open(picks, "w") as f:
            f.write('{"genre":"jazz","seed":42,"a":"all","b":"prev","pick":"a"}\n')
            f.write('{"genre":"jazz","seed":42,"a":"prev","b":"all","pick":"all"}\n')
        tally = list(read_picks(picks))
        expect(len(tally) == 2, "picks read line by line")

    expect(sorted(STAGE_OF) == sorted(DIMENSIONS), "every dimension maps to a stage")
    for f in failures:
        print("FAIL: " + f, file=sys.stderr)
    print("selftest: %d failures" % len(failures))
    return 1 if failures else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--tables", default=DEFAULT_TABLES)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    m = sub.add_parser("missing")
    m.add_argument("--seed", type=int, default=42)
    r = sub.add_parser("rank")
    r.add_argument("--build", help="only rows from this build")
    p = sub.add_parser("from-picks")
    p.add_argument("picks")
    p.add_argument("--build")
    p.add_argument("--device", choices=DEVICES)
    sub.add_parser("selftest")
    args = ap.parse_args(argv)
    return {"check": cmd_check, "missing": cmd_missing, "rank": cmd_rank,
            "from-picks": cmd_from_picks, "selftest": cmd_selftest}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
