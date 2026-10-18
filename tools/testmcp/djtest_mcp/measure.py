"""djtest_measure, djtest_compare, djtest_level_check.

measure      `djctl measure <file> [--start S] [--seconds N] [--note N] [--sections]`: the
             audio block `djctl render` prints, for any local audio file, plus the file's
             full sha256. ffmpeg=true also runs ffmpeg's ebur128 over the same file.
compare      measures two files and reports whether they are byte-identical (sha256) and the
             b − a deltas of LUFS, LRA, peak, true peak, side levels, spectral slope and each
             band's share, each with a pass flag against `DEFAULTS` (or the caller's).
level_check  renders every genre × seed (`djctl render`, synth voices) and reports each
             track's LUFS, its distance from the target (or the median) and the spread.

Which LUFS is which: `lufs` is always Swift's (`IntegratedLoudness`, BS.1770 gating, the same
code the app and `djctl render` use). `ffmpegLufs` / `ffmpegLra` are ffmpeg's ebur128, which
is what scripts/musicality-matrix.py puts in its `lufs` column. Pass flags judge `lufs` (Swift);
the ffmpeg numbers are there to cross-check against the matrix.
"""

from __future__ import annotations

import json
import re
import statistics
from pathlib import Path

from . import render as rd
from . import replay as rp
from . import runner as rn

#: Default pass thresholds for compare. Deltas are b − a.
DEFAULTS = {
    "lufs": 0.5,  # LU, |Δ|
    "lra": 1.0,  # LU, |Δ|
    "peakDB": 0.0,  # dBFS: both files' sample peak must be below this (absolute, not a Δ)
    "truePeakDBTP": 1.0,  # dB, |Δ|
    "sideDB": 1.0,  # dB, |Δ|
    "lowSideDB": 1.0,  # dB, |Δ|
    "slopeDBPerOct": 0.5,  # dB/oct, |Δ|
    "band": 0.02,  # |Δ| of a band's share of the energy (0…1), each band
}

#: Scalar keys of the audio block compared as b − a.
DELTA_KEYS = ("lufs", "lra", "peakDB", "truePeakDBTP", "sideDB", "lowSideDB", "slopeDBPerOct")

LUFS_SOURCE = ("lufs: Swift IntegratedLoudness (BS.1770, as djctl render and the app); "
               "ffmpegLufs: ffmpeg ebur128 (what musicality-matrix.py reports)")


# --- measure ------------------------------------------------------------------
def measure_argv(djctl: str, file: str, *, start: float = 0, seconds: float | None = None,
                 note: int | None = None, sections: bool = False) -> list[str]:
    if not file:
        raise rn.ToolError("file is required")
    if start < 0:
        raise rn.ToolError("start must be >= 0")
    if seconds is not None and seconds <= 0:
        raise rn.ToolError("seconds must be > 0")
    if note is not None and not 0 <= int(note) <= 127:
        raise rn.ToolError("note must be a MIDI note, 0…127")
    argv = [djctl, "measure", file]
    if start:
        argv += ["--start", rd._num(start)]
    if seconds is not None:
        argv += ["--seconds", rd._num(seconds)]
    if note is not None:
        argv += ["--note", str(int(note))]
    if sections:
        argv.append("--sections")
    return argv


def parse_measure(stdout: str) -> dict:
    """djctl measure's stdout is one pretty-printed JSON object."""
    try:
        doc = json.loads(stdout)
    except ValueError:
        raise rn.ToolError(f"djctl measure printed non-JSON: {stdout[:300]!r}") from None
    if not isinstance(doc, dict) or "lufs" not in doc:
        raise rn.ToolError("djctl measure's JSON has no lufs")
    return doc


def ffmpeg_argv(file: str) -> list[str]:
    return ["ffmpeg", "-hide_banner", "-nostats", "-i", file, "-af", "ebur128", "-f", "null",
            "-"]


def parse_ebur128(stderr: str) -> tuple[float | None, float | None]:
    """ebur128's summary (the last `I:` / `LRA:` lines), as musicality-matrix.py reads it."""
    i = re.findall(r"I:\s+(-?[\d.]+) LUFS", stderr)
    lra = re.findall(r"LRA:\s+(-?[\d.]+) LU", stderr)
    return (float(i[-1]) if i else None, float(lra[-1]) if lra else None)


def ffmpeg_loudness(file: str) -> dict:
    """{"ffmpegLufs", "ffmpegLra"}, or {"ffmpegError"} when ffmpeg is missing or fails."""
    r = rn.get_runner().run(ffmpeg_argv(file), cwd=str(rn.repo_root()), timeout=rn.RENDER_TIMEOUT)
    if not r.ok:
        return {"ffmpegError": (r.stderr or r.stdout).strip()[-300:] or f"exit {r.returncode}"}
    lufs, lra = parse_ebur128(r.stderr)
    return {"ffmpegLufs": lufs, "ffmpegLra": lra}


def _existing(file: str) -> Path:
    p = Path(file).expanduser()
    if not p.is_absolute():
        p = rn.repo_root() / p
    if not p.is_file():
        raise rn.ToolError(f"no such file {p}")
    return p


def measure(file: str, *, start: float = 0, seconds: float | None = None,
            note: int | None = None, sections: bool = False, ffmpeg: bool = False) -> dict:
    djctl = rn.require_djctl()
    p = _existing(file)
    argv = measure_argv(djctl, str(p), start=start, seconds=seconds, note=note,
                        sections=sections)
    r = rn.get_runner().run(argv, cwd=str(rn.repo_root()), timeout=rn.RENDER_TIMEOUT)
    r.check("djctl measure")
    doc = parse_measure(r.stdout)
    doc["path"] = str(p)
    doc["sha256Full"] = rp.sha256(p)
    doc["lufsSource"] = LUFS_SOURCE
    if ffmpeg:
        doc.update(ffmpeg_loudness(str(p)))
    return doc


# --- compare ------------------------------------------------------------------
def _delta(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return round(float(b) - float(a), 3)
    return None


def compare_docs(a: dict, b: dict, thresholds: dict | None = None) -> dict:
    """Deltas (b − a) and pass flags for two measure docs (each with sha256Full)."""
    th = {**DEFAULTS, **(thresholds or {})}
    identical = a.get("sha256Full") is not None and a.get("sha256Full") == b.get("sha256Full")
    deltas: dict = {}
    for k in DELTA_KEYS:
        d = _delta(a.get(k), b.get(k))
        entry = {"a": a.get(k), "b": b.get(k), "delta": d}
        if k == "peakDB":
            pa, pb = a.get(k), b.get(k)
            entry["pass"] = (isinstance(pa, (int, float)) and isinstance(pb, (int, float))
                             and pa < th[k] and pb < th[k])
            entry["threshold"] = f"both < {th[k]} dBFS"
        else:
            entry["pass"] = d is not None and abs(d) <= th[k]
            entry["threshold"] = th[k]
        deltas[k] = entry
    bands = {}
    ba, bb = a.get("bands") or {}, b.get("bands") or {}
    for name in sorted(set(ba) | set(bb)):
        d = _delta(ba.get(name, 0), bb.get(name, 0))
        bands[name] = {"a": ba.get(name), "b": bb.get(name), "delta": d,
                       "pass": d is not None and abs(d) <= th["band"]}
    failed = [k for k, v in deltas.items() if not v["pass"]]
    failed += [f"bands.{k}" for k, v in bands.items() if not v["pass"]]
    out = {"identical": identical, "sha256": [a.get("sha256Full"), b.get("sha256Full")],
           "deltas": deltas, "bands": bands, "bandThreshold": th["band"],
           "pass": not failed, "failed": failed, "lufsSource": LUFS_SOURCE}
    if "ffmpegLufs" in a and "ffmpegLufs" in b:
        out["ffmpegLufs"] = {"a": a["ffmpegLufs"], "b": b["ffmpegLufs"],
                             "delta": _delta(a["ffmpegLufs"], b["ffmpegLufs"])}
    return out


def compare(a: str, b: str, *, thresholds: dict | None = None, start: float = 0,
            seconds: float | None = None, ffmpeg: bool = False) -> dict:
    unknown = set(thresholds or {}) - set(DEFAULTS)
    if unknown:
        raise rn.ToolError(f"unknown thresholds {sorted(unknown)}; known: {sorted(DEFAULTS)}")
    ma = measure(a, start=start, seconds=seconds, ffmpeg=ffmpeg)
    mb = measure(b, start=start, seconds=seconds, ffmpeg=ffmpeg)
    out = compare_docs(ma, mb, thresholds)
    out["files"] = [ma["path"], mb["path"]]
    return out


# --- level check --------------------------------------------------------------
def spread_report(rows: list[dict], target_lufs: float | None, tolerance: float) -> dict:
    """Per-track distance from the target (the median when none) and the spread, Swift LUFS."""
    vals = [r["lufs"] for r in rows if isinstance(r.get("lufs"), (int, float))]
    if not vals:
        raise rn.ToolError("no render reported a lufs")
    ref = float(target_lufs) if target_lufs is not None else statistics.median(vals)
    for r in rows:
        v = r.get("lufs")
        r["offset"] = round(v - ref, 3) if isinstance(v, (int, float)) else None
        r["pass"] = r["offset"] is not None and abs(r["offset"]) <= tolerance
    out = {"reference": round(ref, 3),
           "referenceIs": "target_lufs" if target_lufs is not None else "median",
           "tolerance": tolerance, "spread": round(max(vals) - min(vals), 3),
           "min": min(vals), "max": max(vals), "median": round(statistics.median(vals), 3),
           "pass": all(r["pass"] for r in rows), "rows": rows, "lufsSource": LUFS_SOURCE}
    ff = [r["ffmpegLufs"] for r in rows if isinstance(r.get("ffmpegLufs"), (int, float))]
    if ff:
        out["ffmpegSpread"] = round(max(ff) - min(ff), 3)
    return out


def level_check(genres: list[str], seeds: list[float], *, seconds: float = 20,
                target_lufs: float | None = None, tolerance: float = 1.0, structure: str = "",
                fixes: str = "", sampled: bool = False, ffmpeg: bool = True) -> dict:
    if not genres or not seeds:
        raise rn.ToolError("genres and seeds must be non-empty")
    if tolerance < 0:
        raise rn.ToolError("tolerance must be >= 0")
    rows = []
    for g in genres:
        for s in seeds:
            r = rd.render(g, s, seconds=seconds, structure=structure, fixes=fixes,
                          sampled=sampled)
            row = {"track": f"{g}-{rd._num(s)}", "genre": g, "seed": s, "lufs": r.get("lufs"),
                   "lra": r.get("lra"), "peakDB": r.get("peakDB"),
                   "truePeakDBTP": r.get("truePeakDBTP"), "wav": r["wav"]}
            if ffmpeg and r.get("wavExists"):
                row.update(ffmpeg_loudness(r["wav"]))
                if isinstance(row.get("ffmpegLufs"), (int, float)) and \
                        isinstance(row["lufs"], (int, float)):
                    row["swiftMinusFfmpeg"] = round(row["lufs"] - row["ffmpegLufs"], 3)
            rows.append(row)
    return spread_report(rows, target_lufs, tolerance)
