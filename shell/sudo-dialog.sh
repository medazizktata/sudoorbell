# shellcheck shell=bash
# sudo-dialog shell integration for bash and zsh, sourced from your shell's
# startup file by `sudo-dialog install`, which also sets SUDO_DIALOG_HOME.
#
# Two parts:
#  - SUDO_ASKPASS is exported, so sudo and every program started from this
#    shell knows where the dialog is. On a Linux desktop that alone is enough:
#    sudo uses it by itself when it has no terminal and a display is set.
#  - A sudo function adds -A when there is no terminal, for systems with no
#    display variable (macOS) and for tools that run commands through your
#    shell, such as AI coding agents.

if [ -n "${SUDO_DIALOG_HOME:-}" ] && [ -x "$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass" ]; then
	export SUDO_ASKPASS="$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass"

	# `function sudo` rather than `sudo()`, so an alias named sudo cannot break
	# the definition in zsh.
	function sudo {
		# A terminal is available: sudo asks there, as usual.
		if (exec </dev/tty) 2>/dev/null; then
			command sudo "$@"
			return
		fi
		# Leave callers alone that chose how sudo gets the password, or chose
		# that it must not ask: -S/--stdin, -A/--askpass, -n/--non-interactive.
		local arg skip=
		for arg in "$@"; do
			if [ -n "$skip" ]; then
				skip=
				continue
			fi
			case $arg in
			--) break ;;
			--stdin | --askpass | --non-interactive)
				command sudo "$@"
				return
				;;
			--*) ;;
			-*[SAn]*)
				command sudo "$@"
				return
				;;
			# Options that take a value: skip the value.
			-[ugpCDRTUrth]) skip=1 ;;
			-*) ;;
			*) break ;;
			esac
		done
		command sudo -A "$@"
	}
fi
