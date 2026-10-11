#!/bin/sh
# The Claude Code MCP server (Python, standard library only).
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
	echo "skip  python3 not installed"
	exit 0
fi
exec python3 test_mcp.py
