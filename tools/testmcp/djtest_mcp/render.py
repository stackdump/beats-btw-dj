"""djtest_build, djtest_render, djtest_matrix.

build    `swift build -c release --product djctl`, then copies djctl and its
         resource bundle to build/testmcp/ (as `make mcp-install` does for
         build/mcp/), so a later `swift build -c release` can't swap the
         binary under a running render.
render   `djctl render <genre> <seed> ...` into build/testmcp/renders/<ts>/;
         returns djctl's JSON (MusicalityReport + AudioMetrics) with the WAV
         path and the headline numbers lifted out.
matrix   `scripts/musicality-matrix.py OUTDIR --djctl <copied djctl>`; returns
         the rows of OUTDIR/summary.json.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from . import runner as rn

BUNDLE = "dj-vevr-se_DJCore.bundle"

#: Lifted to the top of a render's result; the rest stays under "audio".
HEADLINE = ("lufs", "lra", "peakDB", "truePeakDBTP", "clippedSamples")


# --- build --------------------------------------------------------------------
def build_argv() -> list[str]:
    return ["swift", "build", "-c", "release", "--product", "djctl"]


def build(worktree: str = "") -> dict:
    run = rn.get_runner().run
    wt = rn.worktree_root(worktree)
    root = str(wt)
    b = run(build_argv(), cwd=root, timeout=rn.BUILD_TIMEOUT).check("swift build")
    p = run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root,
            timeout=120).check("swift build --show-bin-path")
    bin_dir = Path(p.stdout.strip().splitlines()[-1])
    src = bin_dir / "djctl"
    if not src.exists():
        raise rn.ToolError(f"swift build succeeded but {src} is missing")
    dest = rn.out_dir(wt)
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest / "djctl")
    copied = ["djctl"]
    if (bin_dir / BUNDLE).is_dir():
        shutil.rmtree(dest / BUNDLE, ignore_errors=True)
        shutil.copytree(bin_dir / BUNDLE, dest / BUNDLE)
        copied.append(BUNDLE)
    return {"djctl": str(dest / "djctl"), "from": str(bin_dir), "copied": copied,
            "log": b.stdout.strip().splitlines()[-5:]}


# --- render -------------------------------------------------------------------
def render_argv(djctl: str, genre: str, seed: float, wav: str, *, seconds: float = 30,
                structure: str = "", fixes: str = "", sampled: bool = False,
                room: bool = False, balance: bool = False, kit: str = "",
                palette: str = "", notes: str = "") -> list[str]:
    """`djctl render`'s argv. Synth voices unless `sampled` (as the matrix):
    sampled renders depend on what is installed on this Mac."""
    if not genre or any(c.isspace() for c in genre):
        raise rn.ToolError(f"bad genre {genre!r}")
    if not seconds or seconds <= 0:
        raise rn.ToolError("seconds must be > 0")
    argv = [djctl, "render", genre, _num(seed), "--seconds", _num(seconds), "--out", wav]
    if structure:
        argv += ["--structure", structure]
    if fixes:
        argv += ["--fixes", fixes]
    if not sampled:
        argv.append("--synth")
    if room:
        argv.append("--room")
    if balance:
        argv.append("--balance")
    if kit:
        argv += ["--kit", kit]
    if palette:
        argv += ["--palette", palette]
    if notes:
        argv += ["--notes", notes]
    return argv


def _num(v: float) -> str:
    f = float(v)
    return str(int(f)) if f.is_integer() else repr(f)


def parse_render(stdout: str) -> dict:
    """djctl render's stdout is one pretty-printed JSON document."""
    try:
        doc = json.loads(stdout)
    except ValueError:
        raise rn.ToolError(f"djctl render printed non-JSON: {stdout[:300]!r}") from None
    if not isinstance(doc, dict) or "audio" not in doc or "musicality" not in doc:
        raise rn.ToolError("djctl render's JSON has no audio / musicality block")
    return doc


def summarize_render(doc: dict, wav: str) -> dict:
    audio = doc["audio"]
    out = {"wav": wav, "genre": doc.get("genre"), "seed": doc.get("seed"),
           "structure": doc.get("structure"), "seconds": doc.get("seconds"),
           "tempo": doc.get("tempo")}
    for k in HEADLINE:
        out[k] = audio.get(k)
    out["musicality"] = doc["musicality"]
    out["audio"] = audio
    if "groove" in doc:
        out["groove"] = doc["groove"]
    return out


def render(genre: str, seed: float, *, seconds: float = 30, structure: str = "",
           fixes: str = "", sampled: bool = False, room: bool = False,
           balance: bool = False, kit: str = "", palette: str = "",
           notes: bool = False, worktree: str = "") -> dict:
    wt = rn.worktree_root(worktree) if worktree else None
    djctl = rn.require_djctl(wt)
    d = rn.run_dir("renders", wt)
    name = f"{genre}-{_num(seed)}"
    wav = str(d / f"{name}.wav")
    notes_path = str(d / f"{name}.notes.txt") if notes else ""
    argv = render_argv(djctl, genre, seed, wav, seconds=seconds, structure=structure,
                       fixes=fixes, sampled=sampled, room=room, balance=balance, kit=kit,
                       palette=palette, notes=notes_path)
    r = rn.get_runner().run(argv, cwd=str(wt or rn.repo_root()), timeout=rn.RENDER_TIMEOUT)
    r.check("djctl render")
    doc = parse_render(r.stdout)
    (d / f"{name}.json").write_text(json.dumps(doc, indent=1, sort_keys=True))
    out = summarize_render(doc, wav)
    out["wavExists"] = Path(wav).exists()
    out["dir"] = str(d)
    if notes_path:
        out["notes"] = notes_path
    return out


# --- matrix -------------------------------------------------------------------
def matrix_argv(djctl: str, outdir: str, *, seconds: float = 75, sampled: bool = False,
                fixes: str = "") -> list[str]:
    argv = ["python3", "scripts/musicality-matrix.py", outdir, "--seconds", _num(seconds),
            "--djctl", djctl]
    if sampled:
        argv.append("--sampled")
    if fixes:
        argv += ["--fixes", fixes]
    return argv


def summary_rows(summary: dict) -> list[dict]:
    """summary.json ({"techno-42": {...}}) as rows, in the script's order."""
    return [{"track": name, **row} for name, row in summary.items()]


def matrix(*, seconds: float = 75, sampled: bool = False, fixes: str = "") -> dict:
    djctl = rn.require_djctl()
    d = rn.run_dir("matrix")
    argv = matrix_argv(djctl, str(d), seconds=seconds, sampled=sampled, fixes=fixes)
    r = rn.get_runner().run(argv, cwd=str(rn.repo_root()), timeout=rn.MATRIX_TIMEOUT)
    r.check("musicality-matrix.py")
    path = d / "summary.json"
    if not path.exists():
        raise rn.ToolError(f"musicality-matrix.py wrote no {path}")
    return {"dir": str(d), "rows": summary_rows(json.loads(path.read_text())),
            "table": r.stdout}
