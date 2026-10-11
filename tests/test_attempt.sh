#!/bin/sh
# The attempt counter, and the private directory it keeps state in.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudoorbell.sh"

XDG_RUNTIME_DIR=$(scratch)
export XDG_RUNTIME_DIR

sleep 30 &
target=$!
assert_eq "first dialog for a request is attempt 1" "$(sd_attempt $target)" 1
assert_eq "next dialog for the same request is attempt 2" "$(sd_attempt $target)" 2
sleep 30 &
other=$!
assert_eq "another request starts at 1" "$(sd_attempt $other)" 1

dir=$XDG_RUNTIME_DIR/sudoorbell-$(id -u)
# shellcheck disable=SC2012
assert_eq "state directory is private" "$(ls -ld "$dir" | cut -c1-10)" "drwx------"

kill $other
wait $other 2>/dev/null
sd_attempt $target >/dev/null
if [ -e "$dir/attempt.$other" ]; then not_ok "state of a finished request is removed"; else ok "state of a finished request is removed"; fi

# A state directory others can write to is not trusted: no state is kept.
XDG_RUNTIME_DIR=$(scratch)
mkdir -m 777 "$XDG_RUNTIME_DIR/sudoorbell-$(id -u)"
sd_attempt $target >/dev/null
assert_eq "open directory: refused, every dialog is attempt 1" "$(sd_attempt $target)" 1

kill $target
finish
