#!/bin/sh
# The sudo function: -A only when there is no terminal, and only when the
# caller did not choose another way to give the password.
. "$(dirname "$0")/helpers.sh"

SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
bin=$(stub_bin sudo)
work=$(scratch)
# PAM settings for sudo: none by default, so the Mac running the tests (which
# may have Touch ID on) does not change the results.
no_pam=$(scratch)
touch_id=$(scratch)
printf 'auth       sufficient     pam_tid.so\n' >"$touch_id/sudo_local"
touch_id_off=$(scratch)
printf '#auth       sufficient     pam_tid.so\n' >"$touch_id_off/sudo_local"
watch=$(scratch)
printf 'auth       include        sudo_local\nauth       sufficient     pam_watchid.so\n' >"$watch/sudo"
PAM=$no_pam OS=''

# How to start SHELL without its startup files: zsh reads ~/.zshenv even for
# -c, and a real install there would replace the copy under test.
shell_cmd() {
	if [ "$1" = zsh ]; then echo "zsh -f"; else echo "$1"; fi
}

# run SHELL TTY|NOTTY ARGS...: call sudo ARGS through the function in SHELL,
# and print the arguments the real sudo would have received, on one line.
run() {
	sh_name=$1 mode=$2
	shift 2
	: >"$SD_STUB_LOG"
	if [ -n "${DISP+set}" ]; then
		display_line="export DISPLAY='$DISP'"
	else
		display_line="unset DISPLAY"
	fi
	printf '%s\n' \
		"export PATH='$bin':\"\$PATH\" SUDOORBELL_HOME='$root' SD_STUB_LOG='$SD_STUB_LOG' SD_PAM_DIR='$PAM' SD_OS='$OS'" \
		"$display_line" \
		"exec $(shell_cmd "$sh_name") -c '. \"\$SUDOORBELL_HOME/shell/sudoorbell.sh\"; sudo $*'" >"$work/scenario"
	if [ "$mode" = TTY ]; then
		with_tty "$work/scenario" >/dev/null 2>&1
	else
		no_tty sh "$work/scenario" </dev/null >/dev/null 2>&1
	fi
	sed -n 's/^arg: //p' "$SD_STUB_LOG" | tr '\n' ' ' | sed 's/ $//'
}

# The DISPLAY the real sudo would have received, from the last run.
display_seen() {
	sed -n 's/^display: //p' "$SD_STUB_LOG"
}

for sh_name in bash zsh dash sh; do
	command -v $sh_name >/dev/null 2>&1 || {
		printf 'skip  %s not installed\n' $sh_name
		continue
	}
	assert_eq "$sh_name: no terminal adds -A" "$(run $sh_name NOTTY -k true)" "-A -k true"
	assert_eq "$sh_name: with a terminal sudo is unchanged" "$(run $sh_name TTY -k true)" "-k true"
	assert_eq "$sh_name: -S is left alone" "$(run $sh_name NOTTY -S true)" "-S true"
	assert_eq "$sh_name: --stdin is left alone" "$(run $sh_name NOTTY --stdin true)" "--stdin true"
	assert_eq "$sh_name: -n is left alone" "$(run $sh_name NOTTY -n true)" "-n true"
	assert_eq "$sh_name: -A is not doubled" "$(run $sh_name NOTTY -A true)" "-A true"
	assert_eq "$sh_name: -S after an option value is found" "$(run $sh_name NOTTY -u root -S true)" "-u root -S true"
	assert_eq "$sh_name: a command's own -n is not sudo's" "$(run $sh_name NOTTY -u root head -n 1 /etc/hosts)" "-A -u root head -n 1 /etc/hosts"
	# SC2016: expanded by the shell under test. SC2046: "zsh -f" is two words.
	# shellcheck disable=SC2016,SC2046
	assert_eq "$sh_name: SUDO_ASKPASS is exported" \
		"$(env SUDOORBELL_HOME="$root" $(shell_cmd "$sh_name") -c '. "$SUDOORBELL_HOME/shell/sudoorbell.sh"; sh -c "echo \$SUDO_ASKPASS"' </dev/null)" \
		"$root/libexec/sudoorbell-askpass"
done

# Touch ID: macOS skips it when sudo gets -A. So with Touch ID on, no -A, and a
# DISPLAY instead, which makes sudo use the dialog by itself after Touch ID.
for sh_name in bash zsh dash sh; do
	command -v $sh_name >/dev/null 2>&1 || continue
	OS=macos PAM=$touch_id
	assert_eq "$sh_name touch id: no -A" "$(run $sh_name NOTTY -k true)" "-k true"
	assert_eq "$sh_name touch id: DISPLAY set" "$(display_seen)" "sudoorbell"
	DISP=:5
	run $sh_name NOTTY -k true >/dev/null
	assert_eq "$sh_name touch id: an existing DISPLAY is kept" "$(display_seen)" ":5"
	unset DISP
	assert_eq "$sh_name touch id: with a terminal sudo is unchanged" "$(run $sh_name TTY -k true)" "-k true"
	assert_eq "$sh_name touch id: -S is left alone" "$(run $sh_name NOTTY -S true)" "-S true"
	assert_eq "$sh_name touch id: an explicit -A is kept" "$(run $sh_name NOTTY -A true)" "-A true"
	PAM=$watch
	assert_eq "$sh_name apple watch in pam.d/sudo: no -A" "$(run $sh_name NOTTY -k true)" "-k true"
	PAM=$touch_id_off
	assert_eq "$sh_name touch id commented out: -A" "$(run $sh_name NOTTY -k true)" "-A -k true"
	assert_eq "$sh_name touch id commented out: DISPLAY untouched" "$(display_seen)" "(unset)"
	OS=linux PAM=$touch_id
	assert_eq "$sh_name not macOS: -A" "$(run $sh_name NOTTY -k true)" "-A -k true"
	OS='' PAM=$no_pam
done

finish
