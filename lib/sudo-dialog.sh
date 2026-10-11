# shellcheck shell=sh
# sudo-dialog library: builds the password dialog and shows it with whatever
# dialog tool the system has. Sourced by libexec/sudo-dialog-askpass and by the
# tests. POSIX sh. Nothing here writes to stdout except the dialog backend
# itself, because stdout is the channel sudo reads the password from.

SD_TITLE=${SUDO_DIALOG_TITLE:-Administrator access}
SD_TIMEOUT=${SUDO_DIALOG_TIMEOUT:-120}
SD_MAX_COMMAND=300

sd_err() {
	printf 'sudo-dialog: %s\n' "$*" >&2
}

# The ps binary, by absolute path: the gate must not trust the caller's PATH.
sd_ps() {
	for p in /bin/ps /usr/bin/ps; do
		if [ -x "$p" ]; then
			"$p" "$@"
			return
		fi
	done
	return 127
}

sd_trim() {
	sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# SD_OS lets the tests exercise one platform's logic on the other.
sd_os() {
	if [ -n "${SD_OS:-}" ]; then
		echo "$SD_OS"
		return
	fi
	case $(uname -s) in
	Darwin) echo macos ;;
	*) echo linux ;;
	esac
}

# The command line of process $1, shortened to fit a dialog.
sd_command_of() {
	sd_ps -o args= -p "$1" 2>/dev/null | sd_trim | cut -c1-"$SD_MAX_COMMAND"
}

# Is process $1 a sudo running as root? sudo forks the askpass helper from its
# own process, which keeps root as its effective uid, so a real request always
# passes and a direct call from an ordinary process never does.
sd_parent_is_sudo() {
	comm=$(sd_ps -o comm= -p "$1" 2>/dev/null | sd_trim)
	euid=$(sd_ps -o uid= -p "$1" 2>/dev/null | sd_trim)
	case ${comm##*/} in
	sudo | sudo-rs) [ "$euid" = 0 ] ;;
	*) return 1 ;;
	esac
}

# The program that asked for sudo: the first ancestor of process $1 that is not
# a shell or a wrapper, e.g. "codex" or "claude". Empty if none is found.
sd_requester() {
	pid=$(sd_ps -o ppid= -p "$1" 2>/dev/null | sd_trim)
	i=0
	while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ $i -lt 8 ]; do
		name=$(sd_ps -o comm= -p "$pid" 2>/dev/null | sd_trim)
		name=${name##*/}
		name=${name#-}
		case $name in
		sh | bash | zsh | dash | ksh | mksh | fish | env | login | script | sudo | timeout | nohup | xargs | setsid | perl) ;;
		'') return ;;
		*)
			printf '%s\n' "$name"
			return
			;;
		esac
		pid=$(sd_ps -o ppid= -p "$pid" 2>/dev/null | sd_trim)
		i=$((i + 1))
	done
}

# A private directory for per-request state, owned by us and closed to others.
sd_state_dir() {
	base=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
	dir=${base%/}/sudo-dialog-$(id -u)
	if [ ! -d "$dir" ]; then
		(umask 077 && mkdir "$dir") 2>/dev/null || return 1
	fi
	# Refuse a directory someone else made, or opened up to others.
	[ -L "$dir" ] && return 1
	# shellcheck disable=SC2012,SC2046 # one known path, split on purpose; ls -n is the portable way to read owner and mode
	set -- $(ls -nd "$dir")
	[ "$3" = "$(id -u)" ] || return 1
	case $1 in
	drwx------*) ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$dir"
}

# Which attempt this is for the sudo process $1: 1 for the first dialog, 2 after
# one wrong password, and so on. sudo does not say, so count per sudo process,
# keyed by its pid and start time so a reused pid starts again at 1.
sd_attempt() {
	dir=$(sd_state_dir) || {
		echo 1
		return
	}
	started=$(sd_ps -o lstart= -p "$1" 2>/dev/null | sd_trim)
	file=$dir/$1
	count=0
	if [ -f "$file" ]; then
		{
			read -r saved_start
			read -r count
		} <"$file"
		[ "$saved_start" = "$started" ] || count=0
	fi
	count=$((count + 1))
	printf '%s\n%s\n' "$started" "$count" >"$file"
	# Forget requests whose sudo has exited.
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		sd_ps -p "${f##*/}" >/dev/null 2>&1 || rm -f "$f"
	done
	echo "$count"
}

# The dialog text, as plain lines.
sd_message() {
	command=$1 requester=$2 attempt=$3
	printf 'Run as root:\n\n%s\n' "$command"
	if [ -n "$requester" ]; then
		printf '\nRequested by: %s\n' "$requester"
	fi
	if [ "$attempt" -gt 1 ]; then
		printf '\nWrong password. Attempt %s.\n' "$attempt"
	fi
	printf '\nEnter your password to allow it.'
}

# Escape text for Pango (zenity, yad) and Qt rich text (kdialog).
sd_escape_markup() {
	sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

sd_has_display() {
	[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}${WAYLAND_SOCKET:-}" ]
}

# The dialog tool to use. SUDO_DIALOG_BACKEND overrides the choice.
sd_backend() {
	if [ -n "${SUDO_DIALOG_BACKEND:-}" ]; then
		echo "$SUDO_DIALOG_BACKEND"
		return
	fi
	if [ "$(sd_os)" = macos ]; then
		echo osascript
		return
	fi
	candidates="zenity yad kdialog ksshaskpass lxqt-openssh-askpass ssh-askpass-gnome x11-ssh-askpass ssh-askpass"
	case "${XDG_CURRENT_DESKTOP:-}" in
	*KDE*) candidates="kdialog ksshaskpass $candidates" ;;
	esac
	for c in $candidates; do
		if command -v "$c" >/dev/null 2>&1; then
			echo "$c"
			return
		fi
	done
	for c in /usr/lib/ssh/x11-ssh-askpass /usr/libexec/openssh/ssh-askpass /usr/lib/openssh/gnome-ssh-askpass; do
		if [ -x "$c" ]; then
			echo "$c"
			return
		fi
	done
}

# Show the dialog for message $1 with backend $2. The password goes to stdout;
# the exit status is 0 only when the user allowed the request.
sd_show() {
	message=$1 backend=$2
	case ${backend##*/} in
	osascript)
		# The text travels as an argument, never inside the script source.
		osascript - "$SD_TITLE" "$message" "$SD_TIMEOUT" 2>/dev/null <<'APPLESCRIPT'
on run argv
	set theTitle to item 1 of argv
	set theMessage to item 2 of argv
	set theTimeout to (item 3 of argv) as integer
	set lockIcon to POSIX file "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/LockedIcon.icns"
	set reply to display dialog theMessage default answer "" with hidden answer with title theTitle with icon lockIcon buttons {"Deny", "Allow"} default button "Allow" cancel button "Deny" giving up after theTimeout
	if gave up of reply then error number -128
	return text returned of reply
end run
APPLESCRIPT
		;;
	zenity)
		zenity --entry --hide-text --title="$SD_TITLE" \
			--text="$(printf '%s' "$message" | sd_escape_markup)" \
			--ok-label=Allow --cancel-label=Deny --width=440 \
			--timeout="$SD_TIMEOUT" 2>/dev/null
		;;
	yad)
		yad --entry --hide-text --title="$SD_TITLE" \
			--text="$(printf '%s' "$message" | sd_escape_markup)" \
			--button=Deny:1 --button=Allow:0 --width=440 \
			--timeout="$SD_TIMEOUT" 2>/dev/null
		;;
	kdialog)
		# Wrapped in <qt> so kdialog renders the escaped text as rich text.
		text="<qt>$(printf '%s' "$message" | sd_escape_markup | awk '{printf "%s%s", (NR > 1 ? "<br>" : ""), $0}')</qt>"
		if command -v timeout >/dev/null 2>&1; then
			timeout "$SD_TIMEOUT" kdialog --title "$SD_TITLE" --password "$text" 2>/dev/null
		else
			kdialog --title "$SD_TITLE" --password "$text" 2>/dev/null
		fi
		;;
	'')
		sd_err "no dialog tool found; install zenity, kdialog, yad or an ssh-askpass"
		return 1
		;;
	*)
		# The ssh-askpass family takes the prompt as its only argument.
		"$backend" "$message" 2>/dev/null
		;;
	esac
}
