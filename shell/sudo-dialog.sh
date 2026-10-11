# shellcheck shell=sh
# sudo-dialog shell integration for POSIX shells (sh, dash, BusyBox ash) and for
# bash and zsh, sourced from your shell's startup file by `sudo-dialog install`,
# which also sets SUDO_DIALOG_HOME.
#
# Two parts:
#  - SUDO_ASKPASS is exported, so sudo and every program started from this
#    shell knows where the dialog is. On a Linux desktop that alone is enough:
#    sudo uses it by itself when it has no terminal and a display is set.
#  - A sudo function adds -A when there is no terminal, for systems with no
#    display variable (macOS, servers) and for tools that run commands through
#    your shell, such as AI coding agents.

if [ -n "${SUDO_DIALOG_HOME:-}" ] && [ -x "$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass" ]; then
	SUDO_ASKPASS="$SUDO_DIALOG_HOME/libexec/sudo-dialog-askpass"
	export SUDO_ASKPASS

	_sudo_dialog_sudo() {
		# A terminal is available: sudo asks there, as usual.
		if (exec </dev/tty) 2>/dev/null; then
			command sudo "$@"
			return
		fi
		# Leave callers alone that chose how sudo gets the password, or chose
		# that it must not ask: -S/--stdin, -A/--askpass, -n/--non-interactive.
		_sd_skip=
		for _sd_arg in "$@"; do
			if [ -n "$_sd_skip" ]; then
				_sd_skip=
				continue
			fi
			case $_sd_arg in
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
			-[ugpCDRTUrth]) _sd_skip=1 ;;
			-*) ;;
			*) break ;;
			esac
		done
		command sudo -A "$@"
	}

	# bash and zsh: `function sudo`, so an alias named sudo cannot break the
	# definition. Plain POSIX shells only know `sudo()`.
	if [ -n "${ZSH_VERSION:-}${BASH_VERSION:-}" ]; then
		eval 'function sudo { _sudo_dialog_sudo "$@"; }'
	else
		eval 'sudo() { _sudo_dialog_sudo "$@"; }'
	fi
fi
