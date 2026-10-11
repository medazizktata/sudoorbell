# shellcheck shell=sh
# sudoorbell shell integration for POSIX shells (sh, dash, BusyBox ash) and for
# bash and zsh, sourced from your shell's startup file by `sudoorbell install`,
# which also sets SUDOORBELL_HOME.
#
# Two parts:
#  - SUDO_ASKPASS is exported, so sudo and every program started from this
#    shell knows where the dialog is. On a Linux desktop that alone is enough:
#    sudo uses it by itself when it has no terminal and a display is set.
#  - A sudo function adds -A when there is no terminal, for systems with no
#    display variable (macOS, servers) and for tools that run commands through
#    your shell, such as AI coding agents. On a Mac with Touch ID turned on
#    for sudo, it sets DISPLAY instead, so that Touch ID is tried first.

if [ -n "${SUDOORBELL_HOME:-}" ] && [ -x "$SUDOORBELL_HOME/libexec/sudoorbell-askpass" ]; then
	SUDO_ASKPASS="$SUDOORBELL_HOME/libexec/sudoorbell-askpass"
	export SUDO_ASKPASS
	case ${SD_OS:-$(uname -s 2>/dev/null)} in
	macos | Darwin) _sd_macos=1 ;;
	*) _sd_macos= ;;
	esac

	# Touch ID (or Apple Watch) turned on for sudo, in /etc/pam.d/sudo_local
	# or /etc/pam.d/sudo. Checked on every call: it can be turned on later.
	# SUDOORBELL_TOUCH_ID=off skips it for a command, as the Claude Code
	# plugin does when you choose to type the password there, and
	# `sudoorbell config touch_id off` skips it always.
	_sudoorbell_touch_id() {
		[ -n "$_sd_macos" ] || return 1
		_sd_touch=${SUDOORBELL_TOUCH_ID:-$(sed -n 's/^[[:space:]]*touch_id[[:space:]]*=[[:space:]]*//p' \
			"${XDG_CONFIG_HOME:-$HOME/.config}/sudoorbell/config" 2>/dev/null | sed 's/[[:space:]]*$//' | tail -n 1)}
		[ "$_sd_touch" != off ] || return 1
		_sd_pam=${SD_PAM_DIR:-/etc/pam.d}
		grep -q -E '^[[:space:]]*auth[[:space:]].*pam_(tid|watchid)\.so' \
			"$_sd_pam/sudo_local" "$_sd_pam/sudo" 2>/dev/null
	}

	_sudoorbell_sudo() {
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
		# macOS skips Touch ID when sudo is given -A. So with Touch ID on,
		# start sudo without -A and with DISPLAY set: with no terminal and a
		# display, sudo uses SUDO_ASKPASS by itself, after Touch ID has had
		# its turn.
		if _sudoorbell_touch_id; then
			(
				DISPLAY=${DISPLAY:-sudoorbell}
				export DISPLAY
				command sudo "$@"
			)
			return
		fi
		command sudo -A "$@"
	}

	# bash and zsh: `function sudo`, so an alias named sudo cannot break the
	# definition. Plain POSIX shells only know `sudo()`.
	if [ -n "${ZSH_VERSION:-}${BASH_VERSION:-}" ]; then
		eval 'function sudo { _sudoorbell_sudo "$@"; }'
	else
		eval 'sudo() { _sudoorbell_sudo "$@"; }'
	fi
fi
