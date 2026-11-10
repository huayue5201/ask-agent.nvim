#!/bin/sh
# Run every headless test. CI and humans use the same entry point:
#   sh tests/run.sh
set -u
cd "$(dirname "$0")/.." || exit 1

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
