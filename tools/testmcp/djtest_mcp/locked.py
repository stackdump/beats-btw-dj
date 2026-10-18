"""Run a command under the shared swift test lock: the Makefile's full-suite and RT targets.

    python3 -m djtest_mcp.locked [--what NAME] -- swift test ...

Waits for the lock (swifttest.held), records NAME and the cwd as the holder, runs the command
and exits with its code. If the lock is already held by one of this process's ancestors (a
release djtest_swift_test that called `make swift-rt-test-filter`, or a make target calling
another), the command runs at once: waiting on its own parent would deadlock. Stdlib only, so
the Makefile runs it with the system python3.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import subprocess
import sys
from pathlib import Path

from . import swifttest as st


def _parent(pid: int) -> int | None:
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True,
                             text=True, timeout=5).stdout.strip()
        return int(out) if out else None
    except (ValueError, OSError, subprocess.SubprocessError):
        return None


def ancestors(pid: int | None = None) -> list[int]:
    """This process's ancestors, nearest first (stops at launchd)."""
    out, p = [], _parent(pid or os.getpid())
    while p and p > 1 and p not in out:
        out.append(p)
        p = _parent(p)
    return out


def held_by_ancestor() -> bool:
    """The lock is held right now, by a process this one descends from."""
    fd = st._open_lock()
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = st._read_holder(fd) or {}
            return isinstance(holder.get("pid"), int) and holder["pid"] in ancestors()
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="djtest_mcp.locked")
    ap.add_argument("--what", default="make")
    ap.add_argument("--wait", type=float, default=st.LOCK_WAIT)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("no command")
    if held_by_ancestor():
        return subprocess.run(cmd).returncode
    with st.held({"tool": a.what, "filter": " ".join(cmd)[-200:]}, wait=a.wait,
                 root=Path.cwd()) as info:
        if info.waited_seconds > 1:
            print(f"[test lock] waited {info.waited_seconds:.0f} s for {info.waited_for}",
                  file=sys.stderr, flush=True)
        return subprocess.run(cmd).returncode


if __name__ == "__main__":
    sys.exit(main())
