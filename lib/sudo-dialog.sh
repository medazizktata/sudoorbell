# shellcheck shell=sh
# sudo-dialog library: builds the password dialog and shows it with whatever
# dialog tool the system has. Sourced by libexec/sudo-dialog-askpass and by the
# tests. POSIX sh. Nothing here writes to stdout except the dialog backend
# itself, because stdout is the channel sudo reads the password from.

SD_TITLE=${SUDO_DIALOG_TITLE:-Administrator access}
SD_TIMEOUT=${SUDO_DIALOG_TIMEOUT:-120}
SD_MAX_COMMAND=300
# Where sudo-dialog-prompt lives; the askpass helper sets it.
SD_LIBEXEC=${SD_LIBEXEC:-}

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

# Process details come from /proc on Linux: it is there even where ps is not
# installed (Debian slim) or cannot pick one process (BusyBox). Elsewhere
# (macOS), from ps. Decided by the real platform, never by SD_OS.
sd_use_proc() {
	[ "$(uname -s)" != Darwin ] && [ -r /proc/self/status ]
}

# sd_proc FIELD PID: comm, euid, ppid, args or start (an opaque start time).
# Empty when the process is gone or cannot be inspected.
sd_proc() {
	if sd_use_proc; then
		[ -r "/proc/$2/status" ] || return 0
		case $1 in
		comm) cat "/proc/$2/comm" ;;
		euid) awk '$1 == "Uid:" { print $3 }' "/proc/$2/status" ;;
		ppid) awk '$1 == "PPid:" { print $2 }' "/proc/$2/status" ;;
		args) tr '\000' ' ' <"/proc/$2/cmdline" ;;
		start) sed 's/.*) //' "/proc/$2/stat" | cut -d' ' -f20 ;;
		esac 2>/dev/null | sd_trim
	else
		case $1 in
		comm) sd_ps -o comm= -p "$2" ;;
		euid) sd_ps -o uid= -p "$2" ;;
		ppid) sd_ps -o ppid= -p "$2" ;;
		args) sd_ps -o args= -p "$2" ;;
		start) sd_ps -o lstart= -p "$2" ;;
		esac 2>/dev/null | sd_trim
	fi
}

sd_alive() {
	if sd_use_proc; then
		[ -d "/proc/$1" ]
	else
		sd_ps -p "$1" >/dev/null 2>&1
	fi
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
	sd_proc args "$1" | cut -c1-"$SD_MAX_COMMAND"
}

# Is process $1 a sudo running as root? sudo forks the askpass helper from its
# own process, which keeps root as its effective uid, so a real request always
# passes and a direct call from an ordinary process never does.
sd_parent_is_sudo() {
	comm=$(sd_proc comm "$1")
	euid=$(sd_proc euid "$1")
	case ${comm##*/} in
	sudo | sudo-rs) [ "$euid" = 0 ] ;;
	*) return 1 ;;
	esac
}

# The program that asked for sudo: the first ancestor of process $1 that is not
# a shell or a wrapper, e.g. "codex" or "claude". Empty if none is found.
sd_requester() {
	pid=$(sd_proc ppid "$1")
	i=0
	while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ $i -lt 8 ]; do
		name=$(sd_proc comm "$pid")
		name=${name##*/}
		name=${name#-}
		case $name in
		sh | ash | bash | zsh | dash | ksh | mksh | fish | busybox | env | login | script | sudo | timeout | nohup | xargs | setsid | perl) ;;
		'') return ;;
		*)
			printf '%s\n' "$name"
			return
			;;
		esac
		pid=$(sd_proc ppid "$pid")
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
	started=$(sd_proc start "$1")
	file=$dir/attempt.$1
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
	for f in "$dir"/attempt.*; do
		[ -f "$f" ] || continue
		sd_alive "${f##*/attempt.}" || rm -f "$f"
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

# Can a window be shown from here? On macOS, not from an SSH session: the
# dialog would have no desktop to appear on.
sd_has_gui() {
	case $(sd_os) in
	macos) [ -z "${SSH_CONNECTION:-}" ] ;;
	*) sd_has_display ;;
	esac
}

# tmux 3.2 added display-popup.
sd_tmux_has_popup() {
	version=$(tmux -V 2>/dev/null | sed 's/^tmux //; s/^next-//; s/[^0-9.].*//')
	major=${version%%.*} minor=${version#*.}
	minor=${minor%%.*}
	[ -n "$major" ] && [ -n "$minor" ] || return 1
	[ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; }
}

# How to ask. SUDO_DIALOG_BACKEND overrides the choice. With a desktop: a
# dialog window. Without one: a tmux popup when the request comes from inside
# tmux, otherwise "terminal", where you answer with `sudo-dialog approve`.
sd_backend() {
	if [ -n "${SUDO_DIALOG_BACKEND:-}" ]; then
		echo "$SUDO_DIALOG_BACKEND"
		return
	fi
	if sd_has_gui; then
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
	fi
	if [ -n "${TMUX:-}" ] && sd_tmux_has_popup; then
		echo tmux
		return
	fi
	echo terminal
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

# Show the dialog and print the password only if the user allowed the request.
# Some tools print an empty line when they time out; passed on, sudo would
# take it for a wrong password and show the dialog again.
sd_ask() {
	if answer=$(sd_show "$1" "$2"); then
		printf '%s\n' "$answer"
	else
		return 1
	fi
}

# ── Without a desktop ────────────────────────────────────────
#
# The request waits in the private state directory: req.<pid> holds the text
# to show and fifo.<pid> is the pipe the answer comes back through. Whoever
# answers (`sudo-dialog approve` in any terminal, or the tmux popup) writes one
# line to the pipe: "P" and the password to allow, "D" to deny.

# Tell the user's terminals that a request is waiting: an agent usually shows
# a command's output only once it finishes, so this may be the only sign.
# SUDO_DIALOG_NOTIFY=0 turns it off.
sd_notify_ttys() {
	[ "${SUDO_DIALOG_NOTIFY:-1}" = 0 ] && return 0
	notice=$1
	uid=$(id -u)
	for t in /dev/pts/[0-9]* /dev/ttys[0-9]*; do
		[ -c "$t" ] && [ -w "$t" ] || continue
		# shellcheck disable=SC2012,SC2046 # one known path; ls -n reads the owner portably
		owner=$(set -- $(ls -nd "$t") && echo "$3")
		[ "$owner" = "$uid" ] || continue
		# In the background: a terminal with output paused must not hold us up.
		(printf '\a\r\n%s\r\n' "$notice" >"$t") 2>/dev/null &
	done
	return 0
}

# Wait up to $2 seconds for one line on pipe $1 and print it ("T" on timeout).
sd_read_answer() {
	fifo=$1
	# Nobody answering would block the read forever; this writer ends it. Its
	# own output goes nowhere: holding our stdout open would make a caller's
	# $(...) wait for the whole timeout.
	(sleep "$2" && [ -p "$fifo" ] && printf 'T\n' >"$fifo") >/dev/null 2>&1 &
	watchdog=$!
	IFS= read -r line <"$fifo"
	kill "$watchdog" 2>/dev/null
	printf '%s\n' "$line"
}

# sd_broker MESSAGE BACKEND SUDO_PID: wait for an answer from a terminal and
# print the password if the request was allowed.
sd_broker() {
	message=$1 backend=$2 pid=$3
	dir=$(sd_state_dir) || {
		sd_err "no private state directory; cannot wait for an answer"
		return 1
	}
	req=$dir/req.$pid fifo=$dir/fifo.$pid
	rm -f "$fifo" "$req"
	mkfifo -m 600 "$fifo" || return 1
	(umask 077 && printf '%s\n' "$message" >"$req")
	# shellcheck disable=SC2064 # expand now: these paths are fixed
	trap "rm -f '$fifo' '$req'" EXIT
	trap 'exit 1' INT TERM HUP

	command=$(printf '%s\n' "$message" | sed -n 3p)
	if [ "$backend" = tmux ]; then
		tmux display-popup -E -T " $SD_TITLE " -w 80 -h 16 \
			"'$SD_LIBEXEC/sudo-dialog-prompt' '$req' '$fifo'" >/dev/null 2>&1 &
	else
		sd_notify_ttys "sudo-dialog: a program wants to run as root: $command -- answer with: sudo-dialog approve"
	fi
	sd_err "waiting for approval to run as root: $command"
	sd_err "answer in any terminal with: sudo-dialog approve (gives up after ${SD_TIMEOUT}s)"

	answer=$(sd_read_answer "$fifo" "$SD_TIMEOUT")
	case $answer in
	P*) printf '%s\n' "${answer#P}" ;;
	*) return 1 ;;
	esac
}
