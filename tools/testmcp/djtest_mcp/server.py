"""dj-vevr-se-test — the test MCP server (stdio).

Shaped like ~/Workspace/mcp/workbit_mcp: a thin MCPServer whose tools call
plain functions (render.py, replay.py, measure.py) that go through one swappable runner
(runner.py). Tool names are `djtest_<verb>`.

Nothing here touches the running DJApp, its control socket or the speakers:
every render is offline (`djctl render`, `djctl journal replay --render`).
"""

from __future__ import annotations

import json

from mcp.server.mcpserver import Image, MCPServer

from . import measure as ms
from . import render as rd
from . import replay as rp
from . import shots as sh
from . import swifttest as st

VERSION = "0.1.0"

mcp = MCPServer(
    "dj-vevr-se-test",
    version=VERSION,
    instructions=(
        "Offline test tools for dj-vevr-se: nothing plays on the speakers and the running "
        "app is never touched. Call djtest_build first: it builds a release djctl and copies "
        "it to build/testmcp/djctl, which every other tool runs. djtest_render renders one "
        "track (synth voices unless sampled=true) and returns its MusicalityReport, "
        "AudioMetrics (lufs, peakDB, ...) and the WAV path. djtest_matrix runs the 24-track "
        "musicality matrix (minutes). djtest_journal_list lists the app's journals; "
        "djtest_replay replays one offline, twice=true checks it replays byte-identical. "
        "djtest_measure measures any audio file like a render; djtest_compare diffs two files "
        "(sha256 identity, LUFS / peak / band / side deltas with pass flags); "
        "djtest_level_check renders genres × seeds and reports the LUFS spread. `lufs` is "
        "always Swift's BS.1770 loudness; `ffmpegLufs` is ffmpeg ebur128, the matrix's. "
        "djtest_swift_test runs one filtered swift test (never unfiltered); release runs hold a "
        "lock shared by every worktree (filtered debug runs go in parallel); djtest_lock says "
        "who holds it. "
        "djtest_shots returns the view tests' PNGs. "
        "Report numbers; never claim a render sounds better."
    ),
)


@mcp.tool()
def djtest_build(worktree: str = "") -> dict:
    """Build djctl in release (`swift build -c release --product djctl`) and copy it, with
    its resource bundle, to build/testmcp/. Run it after changing Swift; the other tools use
    the copy, so a later build can't swap the binary under them. Takes minutes cold.
    worktree: another checkout of this repo (a git worktree path) to work in instead of the server's own; its files go under that tree's build/testmcp."""
    return rd.build(worktree)


@mcp.tool()
def djtest_render(genre: str, seed: float, seconds: float = 30, structure: str = "",
                  fixes: str = "", sampled: bool = False, room: bool = False,
                  balance: bool = False, kit: str = "", palette: str = "",
                  notes: bool = False, worktree: str = "") -> dict:
    """Render a track offline with `djctl render` into build/testmcp/renders/<ts>/ and return
    its musicality report and audio metrics, with lufs / lra / peakDB / truePeakDBTP lifted
    to the top and the WAV's path. structure: a structure name, or "loop" (default standard).
    fixes: DJMusicality fixes, "all" / "none" / "key,timing,…" (default all). sampled: use
    the Mac's sampled instruments (default synth voices, reproducible anywhere). room /
    balance: also measure the reverb return / per-part levels. notes: also write the note log.
    worktree: render with that checkout's djctl (djtest_build it with the same worktree first)."""
    return rd.render(genre, seed, seconds=seconds, structure=structure, fixes=fixes,
                     sampled=sampled, room=room, balance=balance, kit=kit, palette=palette,
                     notes=notes, worktree=worktree)


@mcp.tool()
def djtest_matrix(seconds: float = 75, sampled: bool = False, fixes: str = "") -> dict:
    """Run scripts/musicality-matrix.py (12 genres × seeds 42 and 7) with the copied djctl into
    build/testmcp/matrix/<ts>/ and return summary.json's rows (one per track) and the printed
    table. Slow: 24 renders, each `seconds` long, plus ffmpeg loudness."""
    return rd.matrix(seconds=seconds, sampled=sampled, fixes=fixes)


@mcp.tool()
def djtest_replay(journal: str = "latest", to_seq: int | None = None, at: float | None = None,
                  twice: bool = False, journal_dir: str = "", loops: str = "") -> dict:
    """Replay a journal offline (`djctl journal replay --json --render`) into
    build/testmcp/replays/<ts>/: the replayed state, the WAV and its sha256. journal: a file,
    an index from djtest_journal_list (1 = newest) or "latest". to_seq / at: stop at a seq or
    at a time in seconds. twice: replay again and compare state and sha256 (a sampler with
    round robin can make the audio differ on purpose; the result says so)."""
    return rp.replay(journal, to_seq=to_seq, at=at, twice=twice, journal_dir=journal_dir,
                     loops=loops)


@mcp.tool()
def djtest_journal_list(journal_dir: str = "") -> list[dict]:
    """The app's journals (`djctl journal list`), newest first: index, file, entries, length,
    notes, size. journal_dir: another folder (default the app's, $DJ_JOURNAL_DIR)."""
    return rp.journal_list(journal_dir)


@mcp.tool()
def djtest_measure(file: str, start: float = 0, seconds: float | None = None,
                   note: int | None = None, sections: bool = False,
                   ffmpeg: bool = False) -> dict:
    """Measure any local audio file (wav, aiff, mp3, m4a, flac) with `djctl measure`: the same
    audio block djtest_render returns (lufs, lra, peakDB, truePeakDBTP, bands, sideDB, ...),
    plus the file's sha256. lufs is Swift's (BS.1770, as the app); ffmpeg=true adds ffmpegLufs /
    ffmpegLra from ffmpeg's ebur128 (the matrix's numbers). start / seconds: the part to
    measure. note: also the pitch error of the first second against MIDI note N. sections:
    also section boundaries in the file's bars."""
    return ms.measure(file, start=start, seconds=seconds, note=note, sections=sections,
                      ffmpeg=ffmpeg)


@mcp.tool()
def djtest_compare(a: str, b: str, thresholds: dict | None = None, start: float = 0,
                   seconds: float | None = None, ffmpeg: bool = False) -> dict:
    """Compare two audio files: identical (same sha256) and the b − a deltas of lufs, lra,
    peakDB, truePeakDBTP, sideDB, lowSideDB, slopeDBPerOct and each band's share, each with a
    pass flag. Defaults: |Δlufs| ≤ 0.5 LU, both peaks < 0 dBFS, |Δlra| ≤ 1 LU, |Δside| ≤ 1 dB,
    |Δband| ≤ 0.02; override any with thresholds {"lufs": 0.2, ...}. Judged on Swift's lufs;
    ffmpeg=true also reports ffmpeg's ebur128 lufs for both."""
    return ms.compare(a, b, thresholds=thresholds, start=start, seconds=seconds, ffmpeg=ffmpeg)


@mcp.tool()
def djtest_level_check(genres: list[str], seeds: list[float], seconds: float = 20,
                       target_lufs: float | None = None, tolerance: float = 1.0,
                       structure: str = "", fixes: str = "", sampled: bool = False,
                       ffmpeg: bool = True) -> dict:
    """Render every genre × seed offline (synth voices unless sampled) and report each track's
    lufs (Swift) and its offset from target_lufs (the median when none), pass when within
    tolerance LU, and the spread (max − min). ffmpeg (default on): also each track's ffmpeg
    ebur128 lufs, swiftMinusFfmpeg and ffmpegSpread, to cross-check the matrix."""
    return ms.level_check(genres, seeds, seconds=seconds, target_lufs=target_lufs,
                          tolerance=tolerance, structure=structure, fixes=fixes,
                          sampled=sampled, ffmpeg=ffmpeg)


@mcp.tool()
def djtest_swift_test(filter: str, release: bool = False, timeout: float = st.TEST_TIMEOUT,
                      worktree: str = "", lock: bool | None = None) -> dict:
    """Run `make swift-test-filter FILTER=<filter>` (release: `make swift-rt-test-filter`, the
    optimised build the audio-thread allocation tests need) and parse swift-testing's output:
    status, passed / failed / skipped / issues, seconds, the `Test run with N tests` line, and
    each failure with its recorded issues, tagged known_failing / flaky_under_load (ROADMAP's
    lists, known_tests.json) or new. filter is required (a suite or test name, `A|B` for
    several). Release runs hold the lock shared by every worktree (~/Library/Caches/dj-vevr-se),
    as do the Makefile's full-suite and RT targets: a call waits for the one before it, and
    `lock.waited_seconds` / `waited_for` say so. Filtered debug runs run in parallel unless
    lock=true. The full transcript is at `log`. timeout: seconds for the run itself (it builds first).
    worktree: another checkout of this repo (a git worktree path) to work in instead of the server's own; its files go under that tree's build/testmcp. The lock is the same for every worktree."""
    return st.swift_test(filter, release=release, timeout=timeout, worktree=worktree)


@mcp.tool()
def djtest_lock() -> dict:
    """Whether a run holds the swift test lock (a release djtest_swift_test, or a full-suite /
    RT make target) and, if so,
    whose: pid (and whether it is alive), worktree root, filter, started, held_seconds. The
    lock is shared with `make swift-test` / `swift-rt-test` / `swift-rt-test-filter`."""
    return st.lock_status()


@mcp.tool()
def djtest_shots(filter: str, limit: int = sh.DEFAULT_LIMIT, worktree: str = "",
                 lock: bool = False):
    """Run the view tests matching filter with DJ_SHOT_DIR set (`make swift-shots`; lock=true
    holds djtest_swift_test's lock), and return up to `limit` of the PNGs they wrote as images
    you can see, then a JSON summary (test counts, every PNG's path). e.g. filter
    "WindowShotTests". worktree: another checkout of this repo (a git worktree path) to work in instead of the server's own; its files go under that tree's build/testmcp."""
    r = sh.shots(filter, limit, worktree=worktree, lock=lock)
    meta = {"summary": r["summary"], "shot_dir": r["shot_dir"], "total_pngs": r["total_pngs"],
            "images": [{"path": i["path"], "bytes": i["bytes"]} for i in r["images"]]}
    return [*(Image(data=i["data"], format="png") for i in r["images"]),
            json.dumps(meta, indent=1)]


TOOLS = ("djtest_build", "djtest_render", "djtest_matrix", "djtest_replay",
         "djtest_journal_list", "djtest_measure", "djtest_compare", "djtest_level_check",
         "djtest_swift_test", "djtest_lock", "djtest_shots")


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
