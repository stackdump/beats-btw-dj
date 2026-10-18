"""djtest_replay and djtest_journal_list.

replay  `djctl journal replay <file> --json --render <wav>` into
        build/testmcp/replays/<ts>/; returns the replayed state and the WAV's
        sha256. `twice` replays again into a second WAV and compares both the
        state and the bytes: GM programs and synth voices replay byte-identical,
        but sampled instruments with round robin or tape / chime modulation
        (some guitars, keys) differ between renders on purpose, so "differs"
        with an identical state is not by itself a replay bug.
list    `djctl journal list`, parsed into rows (index 1 = newest).
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from . import runner as rn

ROUND_ROBIN_NOTE = (
    "sampled instruments with round robin or modulation (some guitars, tape / chime keys) "
    "render differently on purpose: a byte difference with an identical state can be that, "
    "not a replay bug. GM programs and synth voices always replay byte-identical.")


def replay_argv(djctl: str, journal: str, wav: str, *, to_seq: int | None = None,
                at: float | None = None, journal_dir: str = "", loops: str = "") -> list[str]:
    if not journal:
        raise rn.ToolError("journal is required (a file, an index from djtest_journal_list, or 'latest')")
    if to_seq is not None and at is not None:
        raise rn.ToolError("pass to_seq or at, not both")
    argv = [djctl, "journal", "replay", journal]
    if to_seq is not None:
        argv += ["--to", str(int(to_seq))]
    if at is not None:
        argv += ["--at", repr(float(at))]
    argv += ["--render", wav, "--json"]
    if loops:
        argv += ["--loops", loops]
    if journal_dir:
        argv += ["--dir", journal_dir]
    return argv


def parse_replay(stdout: str, stderr: str = "") -> dict:
    """--json prints the state as one JSON document, then `wrote <wav>  N s`."""
    text = stdout.lstrip()
    try:
        state, end = json.JSONDecoder().raw_decode(text)
    except ValueError:
        raise rn.ToolError(f"djctl journal replay printed non-JSON: {stdout[:300]!r}") from None
    rest = text[end:].strip().splitlines()
    seconds = None
    for line in rest:
        if m := re.match(r"wrote .*?\s+([\d.]+) s$", line.strip()):
            seconds = float(m.group(1))
    warnings = [ln.removeprefix("warning: ").strip() for ln in stderr.splitlines()
                if ln.startswith("warning: ")]
    return {"state": state, "renderedSeconds": seconds, "warnings": warnings}


def sha256(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verdict(a: dict, b: dict) -> dict:
    """Compare two replays (each {"state", "sha256"})."""
    same_state = a["state"] == b["state"]
    same_audio = a["sha256"] is not None and a["sha256"] == b["sha256"]
    if same_state and same_audio:
        v = "identical"
    elif not same_state:
        v = "state differs"
    else:
        v = "audio differs"
    out = {"verdict": v, "sameState": same_state, "sameAudio": same_audio,
           "sha256": [a["sha256"], b["sha256"]]}
    if v == "audio differs":
        out["note"] = ROUND_ROBIN_NOTE
    return out


def _once(djctl: str, journal: str, wav: Path, **kw) -> dict:
    argv = replay_argv(djctl, journal, str(wav), **kw)
    r = rn.get_runner().run(argv, cwd=str(rn.repo_root()), timeout=rn.RENDER_TIMEOUT)
    r.check("djctl journal replay")
    out = parse_replay(r.stdout, r.stderr)
    out["wav"] = str(wav)
    out["sha256"] = sha256(wav) if wav.exists() else None
    return out


def replay(journal: str, *, to_seq: int | None = None, at: float | None = None,
           twice: bool = False, journal_dir: str = "", loops: str = "") -> dict:
    djctl = rn.require_djctl()
    d = rn.run_dir("replays")
    kw = dict(to_seq=to_seq, at=at, journal_dir=journal_dir, loops=loops)
    first = _once(djctl, journal, d / "replay-1.wav", **kw)
    out = {"dir": str(d), **first}
    if twice:
        second = _once(djctl, journal, d / "replay-2.wav", **kw)
        out["twice"] = {**verdict(first, second), "wav2": second["wav"]}
    return out


# --- list ---------------------------------------------------------------------
_ROW = re.compile(
    r"^(?P<index>\d+)\s{2}(?P<file>\S+)\s{2}(?:(?P<unreadable>\(unreadable\))|"
    r"(?P<entries>\d+) entries\s{2}(?P<length>\d+:\d+(?:\.\d+)?)"
    r"(?:\s{2}✎(?P<notes>\d+))?\s{2}(?P<kb>\d+) KB(?P<torn>\s{2}\(last line torn\))?)\s*$")


def parse_list(stdout: str) -> list[dict]:
    rows = []
    for line in stdout.splitlines():
        m = _ROW.match(line.rstrip())
        if not m:
            continue
        row = {"index": int(m["index"]), "file": m["file"]}
        if m["unreadable"]:
            row["unreadable"] = True
        else:
            mins, secs = m["length"].split(":")
            row.update(entries=int(m["entries"]), length=m["length"],
                       seconds=int(mins) * 60 + float(secs), notes=int(m["notes"] or 0),
                       kb=int(m["kb"]), torn=bool(m["torn"]))
        rows.append(row)
    return rows


def journal_list(journal_dir: str = "") -> list[dict]:
    argv = [rn.require_djctl(), "journal", "list"]
    if journal_dir:
        argv += ["--dir", journal_dir]
    r = rn.get_runner().run(argv, cwd=str(rn.repo_root()), timeout=120)
    r.check("djctl journal list")
    return parse_list(r.stdout)
