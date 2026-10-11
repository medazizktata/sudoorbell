#!/bin/sh
# Build the Linux test image and run the end-to-end test in it.
set -e
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
docker build -q -t sudo-dialog-e2e -f "$root/tests/e2e/linux/Dockerfile" "$root" >/dev/null
exec docker run --rm sudo-dialog-e2e
