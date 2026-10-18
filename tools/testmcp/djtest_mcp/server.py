"""dj-vevr-se-test — the test MCP server (stdio).

Shaped like ~/Workspace/mcp/workbit_mcp: a thin MCPServer whose tools call
plain functions (render.py, replay.py) that go through one swappable runner
(runner.py). Tool names are `djtest_<verb>`.

Nothing here touches the running DJApp, its control socket or the speakers:
every render is offline (`djctl render`, `djctl journal replay --render`).
"""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from . import render as rd
from . import replay as rp

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
        "Report numbers; never claim a render sounds better."
    ),
)


@mcp.tool()
def djtest_build() -> dict:
    """Build djctl in release (`swift build -c release --product djctl`) and copy it, with
    its resource bundle, to build/testmcp/. Run it after changing Swift; the other tools use
    the copy, so a later build can't swap the binary under them. Takes minutes cold."""
    return rd.build()


@mcp.tool()
def djtest_render(genre: str, seed: float, seconds: float = 30, structure: str = "",
                  fixes: str = "", sampled: bool = False, room: bool = False,
                  balance: bool = False, kit: str = "", palette: str = "",
                  notes: bool = False) -> dict:
    """Render a track offline with `djctl render` into build/testmcp/renders/<ts>/ and return
    its musicality report and audio metrics, with lufs / lra / peakDB / truePeakDBTP lifted
    to the top and the WAV's path. structure: a structure name, or "loop" (default standard).
    fixes: DJMusicality fixes, "all" / "none" / "key,timing,…" (default all). sampled: use
    the Mac's sampled instruments (default synth voices, reproducible anywhere). room /
    balance: also measure the reverb return / per-part levels. notes: also write the note log."""
    return rd.render(genre, seed, seconds=seconds, structure=structure, fixes=fixes,
                     sampled=sampled, room=room, balance=balance, kit=kit, palette=palette,
                     notes=notes)


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


TOOLS = ("djtest_build", "djtest_render", "djtest_matrix", "djtest_replay",
         "djtest_journal_list")


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
