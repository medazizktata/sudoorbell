#!/bin/sh
# Only sudo can get a password out of the dialog.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudo-dialog.sh"

SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
: >"$SD_STUB_LOG"
bin=$(stub_bin zenity osascript)

out=$(PATH=$bin:$PATH DISPLAY=:0 "$root/libexec/sudo-dialog-askpass" "Password:" 2>"$SD_STUB_LOG.err")
status=$?
assert_eq "direct call: refused" "$status" 1
assert_eq "direct call: no password printed" "$out" ""
assert_contains "direct call: says why" "$(cat "$SD_STUB_LOG.err")" "caller is not sudo"
assert_eq "direct call: no dialog shown" "$(cat "$SD_STUB_LOG")" ""

if sd_parent_is_sudo $$; then not_ok "this test shell is not taken for sudo"; else ok "this test shell is not taken for sudo"; fi

# A process merely named sudo, not running as root, is not sudo either.
fake=$(scratch)/sudo
cp "$(command -v sleep)" "$fake"
"$fake" 30 &
named=$!
sleep 1
assert_eq "the impostor is named sudo" "$(sd_ps -o comm= -p $named | sed 's|.*/||')" sudo
if sd_parent_is_sudo $named; then not_ok "a non-root process named sudo is refused"; else ok "a non-root process named sudo is refused"; fi
kill $named

finish
