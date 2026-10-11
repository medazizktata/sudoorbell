#!/bin/sh
# Run every test file; exit nonzero if any test failed.
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.sh; do
	printf '\n== %s\n' "$t"
	sh "$t" || status=1
done
exit $status
