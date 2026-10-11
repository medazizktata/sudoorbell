#!/bin/sh
# Touch ID on macOS: when sudo already offered it (with its own "Use
# Password…"), the dialog does not ask again; when Touch ID cannot be used
# here, the dialog is the fallback.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudoorbell.sh"

on=$(scratch)
printf 'auth       sufficient     pam_tid.so\n' >"$on/sudo_local"
off=$(scratch)
printf '# uncomment following line to enable Touch ID for sudo\n#auth       sufficient     pam_tid.so\n' >"$off/sudo_local"
watch=$(scratch)
printf 'auth       include        sudo_local\nauth       sufficient     pam_watchid.so\n' >"$watch/sudo"
none=$(scratch)

check() {
	if "$@"; then echo yes; else echo no; fi
}

assert_eq "on: pam_tid line" "$(SD_PAM_DIR=$on check sd_touch_id_on)" yes
assert_eq "off: commented out" "$(SD_PAM_DIR=$off check sd_touch_id_on)" no
assert_eq "on: Apple Watch in pam.d/sudo" "$(SD_PAM_DIR=$watch check sd_touch_id_on)" yes
assert_eq "off: no PAM files" "$(SD_PAM_DIR=$none check sd_touch_id_on)" no

assert_eq "-A found" "$(check sd_sudo_has_askpass_flag 'sudo -A true')" yes
assert_eq "-A among other flags" "$(check sd_sudo_has_askpass_flag 'sudo -kA true')" yes
assert_eq "--askpass found" "$(check sd_sudo_has_askpass_flag 'sudo --askpass true')" yes
assert_eq "no -A" "$(check sd_sudo_has_askpass_flag 'sudo -k true')" no
assert_eq "the command's own -A is not sudo's" "$(check sd_sudo_has_askpass_flag 'sudo grep -A 2 x f')" no
assert_eq "an option value is skipped" "$(check sd_sudo_has_askpass_flag 'sudo -u -A true')" no
assert_eq "after -- nothing is sudo's" "$(check sd_sudo_has_askpass_flag 'sudo -- -A')" no
here=$(scratch)
: >"$here/-A"
assert_eq "* is not expanded" "$(cd "$here" && check sd_sudo_has_askpass_flag 'sudo *')" no

# sd_touch_id_was_offered reads sudo's command line; give it one.
args="sudo -k true"
sd_proc() { echo "$args"; }
offered() {
	(unset SSH_CONNECTION; check sd_touch_id_was_offered 1)
}
export SD_OS=macos SD_PAM_DIR="$on" SD_TOUCH_ID=available
assert_eq "Touch ID on and usable: it was offered, so do not ask" "$(offered)" yes
SD_TOUCH_ID=unavailable
assert_eq "no usable sensor (lid closed, no Touch ID): ask" "$(offered)" no
SD_TOUCH_ID=available SD_PAM_DIR=$off
assert_eq "Touch ID not on for sudo: ask" "$(offered)" no
SD_PAM_DIR=$on args="sudo -A -k true"
assert_eq "sudo -A skips Touch ID: ask" "$(offered)" no
args="sudo -k true" SD_OS=linux
assert_eq "not macOS: ask" "$(offered)" no
SD_OS=macos
assert_eq "over SSH: ask (no window can appear)" "$(SSH_CONNECTION='1 2 3 4' check sd_touch_id_was_offered 1)" no

# The real check against macOS, when there is one: it must answer, and quickly.
unset SD_TOUCH_ID
if [ "$(uname -s)" = Darwin ]; then
	start=$(date +%s)
	answer=$(check sd_touch_id_available)
	took=$(($(date +%s) - start))
	case $answer in yes | no) ok "macOS answers ($answer)" ;; *) not_ok "macOS answers" "$answer" ;; esac
	if [ "$took" -le 3 ]; then ok "and quickly (${took}s)"; else not_ok "and quickly" "${took}s"; fi
fi

finish
