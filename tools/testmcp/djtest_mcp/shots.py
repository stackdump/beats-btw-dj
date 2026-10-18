"""djtest_shots — the render tests' PNGs (debug view tests: no lock unless asked).

`make swift-shots SHOT_DIR=build/testmcp/shots/<ts> FILTER=…` runs the filtered view tests
with DJ_SHOT_DIR set, so `savePNG` writes what each test rendered; this returns the newest
`limit` PNGs (server.py turns them into image content) with the test summary.
"""

from __future__ import annotations

from pathlib import Path

from . import runner as rn
from . import swifttest as st

DEFAULT_LIMIT = 4
MAX_LIMIT = 16


def shots_argv(filter: str, shot_dir: str) -> list[str]:
    return ["make", "swift-shots", f"SHOT_DIR={shot_dir}", f"FILTER={st.check_filter(filter)}"]


def pngs(shot_dir: Path, limit: int) -> list[Path]:
    """The PNGs under shot_dir, oldest first by write time (the tests' order), at most limit."""
    found = sorted(shot_dir.rglob("*.png"), key=lambda p: (p.stat().st_mtime, p.name))
    return found[:limit]


def shots(filter: str, limit: int = DEFAULT_LIMIT, *, timeout: float = st.TEST_TIMEOUT,
          lock_wait: float = st.LOCK_WAIT, worktree: str = "", lock: bool = False) -> dict:
    """Run the shots and return {"summary": swift_test-shaped dict, "images": [{path, bytes,
    data}], "total_pngs": n}. data is the PNG's bytes; the server makes Image content of it."""
    f = st.check_filter(filter)
    limit = max(1, min(int(limit), MAX_LIMIT))
    wt = rn.worktree_root(worktree)
    d = rn.run_dir("shots", wt)
    argv = shots_argv(f, str(d))
    with st.maybe_held(lock, {"tool": "djtest_shots", "filter": f}, wait=lock_wait,
                       root=wt) as lock:
        res = rn.get_runner().run(argv, cwd=str(wt), timeout=timeout)
    log = d / "output.txt"
    log.write_text((res.stdout or "") + "\n--- stderr ---\n" + (res.stderr or ""))
    summary = st.summarize(res, f, False, log)
    summary["lock"] = lock.as_dict()
    all_pngs = list(d.rglob("*.png"))
    picked = pngs(d, limit)
    return {"summary": summary, "shot_dir": str(d), "total_pngs": len(all_pngs),
            "images": [{"path": str(p), "bytes": p.stat().st_size, "data": p.read_bytes()}
                       for p in picked]}
