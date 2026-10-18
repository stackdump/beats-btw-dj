"""djtest — the dj-vevr-se test MCP server.

Wraps the offline tools (`djctl render`, `scripts/musicality-matrix.py`,
`djctl journal replay|list`) so a Claude session can build, render and replay
without the running app or the speakers. Nothing here imports `mcp` except
server.py, so the unit tests run on a bare python3.
"""
