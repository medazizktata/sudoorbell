# shellcheck shell=sh
# Minimal test helpers: no framework to install.

passes=0 fails=0
root=${SD_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}

ok() {
	passes=$((passes + 1))
	printf 'ok    %s\n' "$1"
}
not_ok() {
	fails=$((fails + 1))
	printf 'FAIL  %s\n' "$1"
	[ -z "${2:-}" ] || printf '      %s\n' "$2"
}
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$3], got [$2]"; fi
}
assert_contains() {
	case $2 in
	*"$3"*) ok "$1" ;;
	*) not_ok "$1" "[$3] not found in: $2" ;;
	esac
}
assert_not_contains() {
	case $2 in
	*"$3"*) not_ok "$1" "[$3] unexpectedly found in: $2" ;;
	*) ok "$1" ;;
	esac
}
finish() {
	printf '%s: %s passed, %s failed\n' "${0##*/}" "$passes" "$fails"
	[ "$fails" -eq 0 ]
}

# A fresh scratch directory. Left in place on purpose: nothing here deletes
# directories by variable.
scratch() {
	mktemp -d "${TMPDIR:-/tmp}/sudoorbell-test.XXXXXX"
}

# A bin directory whose dialog tools (and sudo) are all the recording stub.
stub_bin() {
	d=$(scratch)/bin
	mkdir -p "$d"
	for t in "$@"; do
		ln -s "$root/tests/stubs/dialog-stub" "$d/$t"
	done
	printf '%s\n' "$d"
}

# Run a command with no controlling terminal, as an AI agent or editor does.
no_tty() {
	perl -MPOSIX -e 'my $p = fork; if ($p) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV or die "exec: $!"' "$@"
}

# Run script file $1 with a terminal, typing the contents of file $2 (default:
# nothing) into it. A file, because util-linux script takes the command as one
# string. script's own stdin must not be a socket: macOS refuses.
#
# Typing waits a moment, like a person reading the prompt first: input sent
# before the program turns echo off would be echoed, and an early end of input
# would read as an empty answer.
with_tty() {
	if [ -n "${2:-}" ]; then
		{
			sleep 1.5
			cat "$2"
			sleep 1.5
		} | run_script "$1"
	else
		run_script "$1" </dev/null
	fi
}
run_script() {
	if [ "$(uname -s)" = Darwin ]; then
		script -q /dev/null sh "$1"
	else
		script -qec "sh '$1'" /dev/null
	fi
}
