#!/bin/sh
# `sudoorbell config`: saved settings, read by the library and the shell
# function, with environment variables still winning.
. "$(dirname "$0")/helpers.sh"

home=$(scratch)
cli=$root/bin/sudoorbell
in_home() {
	env -u XDG_CONFIG_HOME -u SUDOORBELL_TIMEOUT -u SUDOORBELL_BACKEND -u SUDOORBELL_NOTIFY -u SUDOORBELL_TITLE -u SUDOORBELL_TOUCH_ID \
		HOME="$home" "$@"
}
file=$home/.config/sudoorbell/config

assert_contains "list: every setting, at its default" "$(in_home "$cli" config)" "claude_password  choose                 (default)"
assert_contains "set: saved" "$(in_home "$cli" config claude_password inside)" "claude_password  inside                 (saved)"
in_home "$cli" config timeout 300 >/dev/null
in_home "$cli" config title "My Mac" >/dev/null
assert_eq "set: one line per setting, in the file" "$(grep -c -v '^#' "$file")" 3
in_home "$cli" config timeout 45 >/dev/null
assert_eq "set again: replaces the line" "$(grep -c '^timeout' "$file")" 1
assert_contains "set again: the new value" "$(cat "$file")" "timeout = 45"
assert_contains "show one: what it does" "$(in_home "$cli" config claude_password)" "only the hidden field"
err=$(in_home "$cli" config timeout 2 2>&1)
assert_contains "refused: a timeout out of range" "$err" "5 to 3600 seconds"
err=$(in_home "$cli" config dialog fancy 2>&1)
assert_contains "refused: an unknown dialog" "$err" "not a value for dialog"
err=$(in_home "$cli" config bogus 2>&1)
assert_contains "refused: an unknown setting" "$err" "unknown setting: bogus"
assert_eq "refused values were not saved" "$(grep -c -E 'fancy|= 2$|bogus' "$file")" 0
assert_contains "the environment wins, and says so" "$(in_home env SUDOORBELL_TIMEOUT=60 "$cli" config timeout)" "60                     (SUDOORBELL_TIMEOUT in the environment)"
in_home "$cli" config --reset timeout >/dev/null
assert_eq "reset: the line is gone" "$(grep -c '^timeout' "$file")" 0
assert_contains "reset: back to the default" "$(in_home "$cli" config timeout)" "120                    (default)"

# The library reads what was saved.
in_home "$cli" config timeout 77 >/dev/null
in_home "$cli" config dialog terminal >/dev/null
in_home "$cli" config notify off >/dev/null
# shellcheck disable=SC2016 # expanded by the inner shell
lib='. "$1/lib/sudoorbell.sh"; echo "$SD_TIMEOUT $SD_TITLE"; sd_backend'
assert_eq "library: timeout, title and dialog from the file" "$(in_home sh -c "$lib" sh "$root" | tr '\n' '|')" "77 My Mac|terminal|"
assert_eq "library: the environment still wins" "$(in_home env SUDOORBELL_TIMEOUT=9 SUDOORBELL_BACKEND=zenity sh -c "$lib" sh "$root" | tr '\n' '|')" "9 My Mac|zenity|"
# shellcheck disable=SC2016
said=$(in_home sh -c '. "$1/lib/sudoorbell.sh"; sd_notify_ttys "hello"; echo done' sh "$root" 2>&1)
assert_eq "library: notify off sends no notice" "$said" "done"

# The shell function: touch_id off means -A, as without Touch ID.
SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
bin=$(stub_bin sudo)
pam=$(scratch)
printf 'auth       sufficient     pam_tid.so\n' >"$pam/sudo_local"
args() { # the arguments the stub sudo got, on one line
	: >"$SD_STUB_LOG"
	# shellcheck disable=SC2016
	in_home env PATH="$bin:$PATH" SUDOORBELL_HOME="$root" SD_OS=macos SD_PAM_DIR="$pam" "$@" \
		perl -MPOSIX -e 'my $p = fork; if ($p) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV' \
		sh -c '. "$SUDOORBELL_HOME/shell/sudoorbell.sh"; sudo -k true' </dev/null >/dev/null 2>&1
	sed -n 's/^arg: //p' "$SD_STUB_LOG" | tr '\n' ' ' | sed 's/ $//'
}
assert_eq "touch_id auto (default): no -A, so Touch ID comes first" "$(args)" "-k true"
in_home "$cli" config touch_id off >/dev/null
assert_eq "touch_id off: -A, straight to the dialog" "$(args)" "-A -k true"
assert_eq "touch_id off, overridden by the environment" "$(args SUDOORBELL_TOUCH_ID=auto)" "-k true"

# Touch ID status, as `sudoorbell config` reports it on a Mac (macOS's own
# answer stood in by SD_TOUCH_ID).
off_pam=$(scratch)
report() { # STATE PAM-DIR
	in_home env SD_OS=macos SD_TOUCH_ID="$1" SD_PAM_DIR="$2" "$cli" config
}
in_home "$cli" config --reset touch_id >/dev/null
r=$(report available "$pam")
assert_contains "status: fingerprint and sensor" "$r" "OK   Touch ID: a fingerprint is set up"
assert_contains "status: on for sudo" "$r" "OK   Touch ID for sudo: turned on"
assert_contains "status: used first" "$r" "asks Touch ID first"
r=$(report not-enrolled "$pam")
assert_contains "status: no fingerprint" "$r" "WARN Touch ID: no fingerprint added"
assert_contains "status: then not used" "$r" "Touch ID is not used for now"
assert_contains "status: no sensor" "$(report unavailable "$pam")" "WARN Touch ID: no sensor can be used now"
assert_contains "status: locked out" "$(report locked-out "$pam")" "locked after failed tries"
r=$(report available "$off_pam")
assert_contains "status: not on for sudo, with the command to turn it on" "$r" "sudo tee /etc/pam.d/sudo_local"
assert_contains "status: then not used" "$r" "Touch ID is not used for now"
in_home "$cli" config touch_id off >/dev/null
assert_contains "status: the setting turns it off" "$(report available "$pam")" "touch_id is off"
assert_not_contains "status: not on other systems" "$(in_home env SD_OS=linux "$cli" config)" "Touch ID"

finish
