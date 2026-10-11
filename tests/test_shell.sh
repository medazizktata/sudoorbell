#!/bin/sh
# The sudo function: -A only when there is no terminal, and only when the
# caller did not choose another way to give the password.
. "$(dirname "$0")/helpers.sh"

SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
bin=$(stub_bin sudo)
work=$(scratch)

# run SHELL TTY|NOTTY ARGS...: call sudo ARGS through the function in SHELL,
# and print the arguments the real sudo would have received, on one line.
run() {
	sh_name=$1 mode=$2
	shift 2
	: >"$SD_STUB_LOG"
	printf '%s\n' \
		"export PATH='$bin':\"\$PATH\" SUDO_DIALOG_HOME='$root' SD_STUB_LOG='$SD_STUB_LOG'" \
		"exec $sh_name -c '. \"\$SUDO_DIALOG_HOME/shell/sudo-dialog.sh\"; sudo $*'" >"$work/scenario"
	if [ "$mode" = TTY ]; then
		with_tty "$work/scenario" >/dev/null 2>&1
	else
		no_tty sh "$work/scenario" </dev/null >/dev/null 2>&1
	fi
	sed -n 's/^arg: //p' "$SD_STUB_LOG" | tr '\n' ' ' | sed 's/ $//'
}

for sh_name in bash zsh; do
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
	# shellcheck disable=SC2016 # expanded by the shell under test
	assert_eq "$sh_name: SUDO_ASKPASS is exported" \
		"$(env SUDO_DIALOG_HOME="$root" $sh_name -c '. "$SUDO_DIALOG_HOME/shell/sudo-dialog.sh"; sh -c "echo \$SUDO_ASKPASS"' </dev/null)" \
		"$root/libexec/sudo-dialog-askpass"
done

finish
