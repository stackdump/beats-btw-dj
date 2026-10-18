"""The one place a real command runs, and where the files go.

Every tool builds an argv and hands it to `get_runner().run(...)`. Tests swap
the runner (`set_runner(FakeRunner(...))`, tests/fakes.py), so they never
build Swift or render audio.

Paths: the repo root is three levels above this package (tools/testmcp/
djtest_mcp → repo), `DJTEST_ROOT` overrides. Everything the server writes is
under <root>/build/testmcp (ignored): the copied release `djctl`, renders/<ts>/,
matrix/<ts>/, replays/<ts>/.
"""

from __future__ import annotations

import datetime as _dt
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

ENV_ROOT = "DJTEST_ROOT"
ENV_DJCTL = "DJTEST_DJCTL"

#: A 90 s sampled render with --balance takes a few minutes; the matrix is 24 of them.
RENDER_TIMEOUT = 900
MATRIX_TIMEOUT = 3 * 3600
BUILD_TIMEOUT = 1800


class ToolError(RuntimeError):
    pass


@dataclass
class Result:
    argv: list[str]
    returncode: int = 0
    stdout: str = ""
    stderr: str = ""
    cwd: str | None = None

    @property
    def ok(self) -> bool:
        return self.returncode == 0

    def check(self, what: str) -> "Result":
        if not self.ok:
            tail = (self.stderr or self.stdout).strip()[-2000:]
            raise ToolError(f"{what} failed (exit {self.returncode}): {tail}")
        return self


class SubprocessRunner:
    """Actually run things. The default."""

    def run(self, argv: list[str], *, cwd: str | None = None,
            timeout: float = RENDER_TIMEOUT) -> Result:
        try:
            p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                               timeout=timeout)
        except subprocess.TimeoutExpired as e:
            return Result(argv, 124, e.stdout or "", f"timed out after {timeout} s", cwd)
        except FileNotFoundError as e:
            return Result(argv, 127, "", str(e), cwd)
        return Result(argv, p.returncode, p.stdout, p.stderr, cwd)


@dataclass
class _State:
    runner: object = field(default_factory=SubprocessRunner)


_state = _State()


def get_runner():
    return _state.runner


def set_runner(runner) -> object:
    """Swap the runner; returns the previous one (for tests to restore)."""
    old, _state.runner = _state.runner, runner
    return old


# --- paths --------------------------------------------------------------------
def repo_root() -> Path:
    if v := os.getenv(ENV_ROOT):
        return Path(v)
    return Path(__file__).resolve().parents[3]


def worktree_root(worktree: str = "") -> Path:
    """The tree a tool works in: `worktree` (another checkout of this repo, e.g. a fix agent's
    git worktree) or, when empty, repo_root(). Must hold a Package.swift."""
    if not worktree:
        return repo_root()
    p = Path(worktree).expanduser().resolve()
    if not (p / "Package.swift").is_file():
        raise ToolError(f"worktree {worktree!r}: no Package.swift at {p}")
    return p


def out_dir(root: Path | None = None) -> Path:
    return (root or repo_root()) / "build" / "testmcp"


def djctl_path(root: Path | None = None) -> Path:
    """The copied release djctl (djtest_build), or $DJTEST_DJCTL (only without a root)."""
    if root is None and (v := os.getenv(ENV_DJCTL)):
        return Path(v)
    return out_dir(root) / "djctl"


def require_djctl(root: Path | None = None) -> str:
    p = djctl_path(root)
    if not p.exists():
        hint = " with the same worktree" if root is not None else ""
        raise ToolError(f"no djctl at {p}: run djtest_build{hint} first")
    return str(p)


def stamp() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def run_dir(kind: str, root: Path | None = None) -> Path:
    """A fresh build/testmcp/<kind>/<ts>/ for one call's files."""
    d = out_dir(root) / kind / stamp()
    d.mkdir(parents=True, exist_ok=True)
    return d
