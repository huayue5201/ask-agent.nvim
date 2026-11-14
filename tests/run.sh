#!/bin/sh
# Run every headless test. CI and humans use the same entry point:
#   sh tests/run.sh
set -u
cd "$(dirname "$0")/.." || exit 1

# Tests must never touch the real cache. Several of them call ask.setup() and send a
# question, and a send writes the question ledger: the suite used to overwrite
# ~/.cache/nvim/ask-agent/history.json (the user's actual history) with fixtures.
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT
XDG_CACHE_HOME="$cache"
export XDG_CACHE_HOME

fail=0
for test in tests/*.lua; do
	name=$(basename "$test" .lua)
	out=$(nvim --headless --clean -l "$test" 2>&1)
	if printf '%s\n' "$out" | grep -q "OK$"; then
		echo "PASS $name"
	else
		echo "FAIL $name"
		printf '%s\n' "$out" | tail -20
		fail=1
	fi
done

# The MCP server is python3; skip it when python3 is not installed
if command -v python3 >/dev/null 2>&1; then
	out=$(python3 tests/mcp.py 2>&1)
	if printf '%s\n' "$out" | grep -q "OK$"; then
		echo "PASS mcp"
	else
		echo "FAIL mcp"
		printf '%s\n' "$out" | tail -20
		fail=1
	fi
fi
exit $fail
