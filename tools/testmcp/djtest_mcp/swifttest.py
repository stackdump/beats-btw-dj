"""djtest_swift_test, djtest_lock — filtered Swift test runs, one at a time.

swift_test  `make swift-test-filter FILTER=…` (or `swift-rt-test-filter` with
            release) under the shared lock; parses swift-testing's transcript
            into passed / failed / skipped / issues / seconds and tags each
            failure from known_tests.json (ROADMAP's known-failing and flaky
            lists): known_failing, flaky_under_load or new.
lock_status who holds the lock, if anyone.

The lock is an flock(2) on ~/Library/Caches/dj-vevr-se/swift-test.lock
($DJTEST_LOCK overrides), shared by every worktree's server: two filtered runs
in parallel are what makes the slow tests flaky. The kernel drops an flock when
its holder dies, so a crashed run can't leave it stale; the JSON written into
the file only says who holds it. It covers MCP runs only: a `make` in a
terminal doesn't take it.

There is no unfiltered run: `filter` is required and must name something.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import fcntl
import json
import os
import re
import socket
import time
from dataclasses import dataclass
from pathlib import Path

from . import runner as rn

ENV_LOCK = "DJTEST_LOCK"

#: A filtered debug run builds first (minutes cold); the slow suites take ~15 min.
TEST_TIMEOUT = 3600
#: How long a call waits for another run to finish before giving up.
LOCK_WAIT = 4 * 3600
POLL = 0.25

KNOWN_FILE = Path(__file__).with_name("known_tests.json")


# --- the lock -----------------------------------------------------------------
def lock_path() -> Path:
    if v := os.getenv(ENV_LOCK):
        return Path(v)
    return Path.home() / "Library" / "Caches" / "dj-vevr-se" / "swift-test.lock"


def _now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def _read_holder(fd: int) -> dict | None:
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        raw = os.read(fd, 65536).decode("utf-8", "replace").strip()
        return json.loads(raw) if raw else None
    except (OSError, ValueError):
        return None


def _alive(pid) -> bool | None:
    try:
        os.kill(int(pid), 0)
    except (TypeError, ValueError):
        return None
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _open_lock() -> int:
    p = lock_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    return os.open(p, os.O_RDWR | os.O_CREAT, 0o644)


@dataclass
class LockInfo:
    waited_seconds: float = 0.0
    waited_for: dict | None = None
    path: str = ""

    def as_dict(self) -> dict:
        return {"path": self.path, "waited_seconds": round(self.waited_seconds, 2),
                "waited_for": self.waited_for}


@contextlib.contextmanager
def held(what: dict, *, wait: float = LOCK_WAIT, root: Path | None = None):
    """Hold the test lock for the body; yields a LockInfo saying how long it waited and for
    whom. Raises ToolError when `wait` seconds pass without getting it."""
    fd = _open_lock()
    info = LockInfo(path=str(lock_path()))
    t0 = time.monotonic()
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if info.waited_for is None or info.waited_for.get("unknown"):
                    # The holder writes who it is just after taking the lock: read until then.
                    info.waited_for = _read_holder(fd) or {"unknown": True}
                if time.monotonic() - t0 > wait:
                    raise rn.ToolError(
                        f"swift test lock {info.path} still held after {wait:.0f} s by "
                        f"{json.dumps(info.waited_for)}")
                time.sleep(POLL)
        info.waited_seconds = time.monotonic() - t0
        me = {"pid": os.getpid(), "host": socket.gethostname(), "root": str(root or rn.repo_root()),
              "started": _now(), **what}
        os.ftruncate(fd, 0)
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, (json.dumps(me) + "\n").encode())
        try:
            yield info
        finally:
            with contextlib.suppress(OSError):
                os.ftruncate(fd, 0)
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def lock_status() -> dict:
    """Whether the lock is held and, if so, by whom (pid, worktree root, filter, started)."""
    fd = _open_lock()
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = _read_holder(fd)
            out = {"held": True, "path": str(lock_path()), "holder": holder}
            if holder and "pid" in holder:
                out["pid_alive"] = _alive(holder["pid"])
            if holder and "started" in holder:
                with contextlib.suppress(ValueError):
                    t = _dt.datetime.fromisoformat(holder["started"])
                    out["held_seconds"] = round(
                        (_dt.datetime.now(_dt.timezone.utc) - t).total_seconds(), 1)
            return out
        fcntl.flock(fd, fcntl.LOCK_UN)
        return {"held": False, "path": str(lock_path())}
    finally:
        os.close(fd)


# --- filters ------------------------------------------------------------------
def check_filter(filter: str) -> str:
    """The filter, stripped, or ToolError. It goes inside the Makefile's '…' quotes, so no
    quotes or newlines; and it must name something — no empty alternative ("A|" matches every
    test) and at least one letter, so ".*" can't sneak in an unfiltered run."""
    f = (filter or "").strip()
    if not f:
        raise rn.ToolError("filter is required: no unfiltered swift test runs")
    if any(c in f for c in "'\"\n\r`$\\"):
        raise rn.ToolError(f"filter {f!r}: no quotes, backslashes, $ or newlines")
    for alt in f.split("|"):
        if not re.search(r"[A-Za-z0-9_]", alt):
            raise rn.ToolError(
                f"filter {f!r}: every alternative must name a suite or test ({alt!r} doesn't)")
    return f


def test_argv(filter: str, *, release: bool = False) -> list[str]:
    target = "swift-rt-test-filter" if release else "swift-test-filter"
    return ["make", target, f"FILTER={check_filter(filter)}"]


# --- parsing swift-testing's transcript -----------------------------------------
# Piped (not a tty), swift-testing marks lines ✔ passed, ✘ failed, ➜ skipped, ◇ started; on a
# tty they are SF Symbols. Match on the words, not the glyph.
_MARK = r"^\s*\S+\s+"
_NAME = r"(?P<name>\"[^\"]*\"|\S+?\(.*?\))"
_CASES = r"(?: with (?P<cases>\d+) test cases?)?"
RE_PASSED = re.compile(_MARK + r"Test " + _NAME + _CASES + r" passed after (?P<s>[\d.]+) seconds")
RE_FAILED = re.compile(_MARK + r"Test " + _NAME + _CASES +
                       r" failed after (?P<s>[\d.]+) seconds(?: with (?P<n>\d+) issues?)?")
RE_SKIPPED = re.compile(_MARK + r"Test " + _NAME + r" skipped(?:: \"(?P<why>.*)\")?")
RE_ISSUE = re.compile(_MARK + r"Test " + _NAME + r" recorded an issue"
                      r"(?: with \d+ arguments? (?P<args>.*?))?"
                      r" at (?P<at>[^\s:]+:\d+(?::\d+)?): (?P<msg>.*)$")
RE_KNOWN_ISSUE = re.compile(_MARK + r"Test " + _NAME + r" recorded a known issue")
RE_RUN = re.compile(_MARK + r"Test run with (?P<tests>\d+) tests?"
                    r"(?: in (?P<suites>\d+) suites?)? (?P<status>passed|failed) after "
                    r"(?P<s>[\d.]+) seconds(?: with (?P<n>\d+) issues?)?")
RE_ERROR = re.compile(r"(?:^|\s)error: ")


def base_name(name: str) -> str:
    """`theKickNoLongerIsTheMix(genre:)` → `theKickNoLongerIsTheMix`."""
    return name.split("(", 1)[0]


def parse(text: str) -> dict:
    """swift-testing's transcript → counts, per-test failures with their issues, skips and the
    `Test run with N tests …` line. Parameterised tests count once (cases are under `cases`)."""
    passed, failed, skipped, issues = [], {}, [], []
    run = None
    errors = []
    for line in text.splitlines():
        if m := RE_RUN.match(line):
            run = {"line": line.strip(), "tests": int(m["tests"]),
                   "suites": int(m["suites"] or 0), "status": m["status"],
                   "seconds": float(m["s"]), "issues": int(m["n"] or 0)}
        elif m := RE_ISSUE.match(line):
            issue = {"test": m["name"], "at": m["at"], "message": m["msg"].strip()}
            if m["args"]:
                issue["arguments"] = m["args"].strip()
            issues.append(issue)
        elif m := RE_FAILED.match(line):
            failed[m["name"]] = {"test": m["name"], "seconds": float(m["s"]),
                                 "issues": int(m["n"] or 0),
                                 **({"cases": int(m["cases"])} if m["cases"] else {})}
        elif m := RE_PASSED.match(line):
            passed.append(m["name"])
        elif m := RE_SKIPPED.match(line):
            skipped.append({"test": m["name"], **({"reason": m["why"]} if m["why"] else {})})
        elif RE_ERROR.search(line) and len(errors) < 20:
            errors.append(line.strip())
    for f in failed.values():
        f["recorded"] = [i for i in issues if i["test"] == f["test"]]
    return {"passed": len(passed), "failed": len(failed), "skipped": len(skipped),
            "issues": len(issues), "seconds": run["seconds"] if run else None,
            "run": run, "failures": list(failed.values()), "skipped_tests": skipped,
            "passed_tests": passed, "errors": errors}


# --- tagging --------------------------------------------------------------------
def load_known(path: Path | None = None) -> dict:
    data = json.loads((path or KNOWN_FILE).read_text())
    return {k: v for k, v in data.items() if isinstance(v, list)}


def _matches(entry: dict, failure: dict) -> bool:
    if base_name(entry["test"]) != base_name(failure["test"]):
        return False
    want = entry.get("arguments")
    if not want:
        return True
    # Parameterised: the known case must be among the issues' arguments ("genre → \"funk\"").
    return any(want in i.get("arguments", "") for i in failure.get("recorded", []))


def tag(failures: list[dict], known: dict | None = None) -> list[dict]:
    """Set each failure's `tag` (the known_tests.json list it is on, or "new") and `note`."""
    known = load_known() if known is None else known
    for f in failures:
        f["tag"] = "new"
        for kind, entries in known.items():
            hit = next((e for e in entries if _matches(e, f)), None)
            if hit:
                f["tag"] = kind
                if hit.get("note"):
                    f["note"] = hit["note"]
                break
    return failures


# --- the tool -----------------------------------------------------------------
def _status(rc: int, parsed: dict) -> str:
    run = parsed["run"]
    if rc == 124:
        return "timed_out"
    if run is None:
        return "build_failed" if rc != 0 else "no_run"
    if run["tests"] == 0:
        return "no_tests"
    if run["status"] == "passed" and parsed["failed"] == 0 and rc == 0:
        return "passed"
    return "failed"


def summarize(res: rn.Result, filter: str, release: bool, log: Path,
              known: dict | None = None) -> dict:
    text = (res.stdout or "") + "\n" + (res.stderr or "")
    p = parse(text)
    failures = tag(p["failures"], known)
    out = {
        "status": _status(res.returncode, p), "filter": filter, "release": release,
        "returncode": res.returncode,
        "passed": p["passed"], "failed": p["failed"], "skipped": p["skipped"],
        "issues": p["issues"], "seconds": p["seconds"],
        "run_line": p["run"]["line"] if p["run"] else None,
        "tests": p["run"]["tests"] if p["run"] else 0,
        "new_failures": [f["test"] for f in failures if f["tag"] == "new"],
        "failures": failures, "skipped_tests": p["skipped_tests"], "log": str(log),
    }
    if out["status"] in ("build_failed", "no_run", "timed_out"):
        out["errors"] = p["errors"] or text.strip().splitlines()[-15:]
    return out


def swift_test(filter: str, *, release: bool = False, timeout: float = TEST_TIMEOUT,
               lock_wait: float = LOCK_WAIT, worktree: str = "") -> dict:
    f = check_filter(filter)
    wt = rn.worktree_root(worktree)
    argv = test_argv(f, release=release)
    d = rn.run_dir("swift-tests", wt)
    with held({"tool": "djtest_swift_test", "filter": f, "release": release},
              wait=lock_wait, root=wt) as lock:
        res = rn.get_runner().run(argv, cwd=str(wt), timeout=timeout)
    log = d / "output.txt"
    log.write_text((res.stdout or "") + "\n--- stderr ---\n" + (res.stderr or ""))
    out = summarize(res, f, release, log)
    out["lock"] = lock.as_dict()
    return out
