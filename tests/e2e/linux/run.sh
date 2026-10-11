#!/bin/sh
# Build the Linux test image and run the end-to-end tests in it: with a
# desktop (e2e.sh) and without one (e2e-headless.sh).
set -e
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
docker build -q -t sudoorbell-e2e -f "$root/tests/e2e/linux/Dockerfile" "$root" >/dev/null
status=0
for t in e2e.sh e2e-headless.sh; do
	printf '\n== %s\n' "$t"
	docker run --rm sudoorbell-e2e sh "/src/tests/e2e/linux/$t" || status=1
done
exit $status
