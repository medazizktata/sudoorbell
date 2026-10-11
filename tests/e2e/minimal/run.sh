#!/bin/sh
# End to end on bare systems: real sudo and nothing else installed. Each image
# runs a waiting request the way an agent would (no terminal, no display); the
# answer comes from `sudoorbell approve`, typed from the host through
# `docker exec -it`, so the containers need no terminal tools of their own.
#
#   sh tests/e2e/minimal/run.sh [debian] [alpine] [sudors]
#
# Needs docker and script on the host.

root=$(cd "$(dirname "$0")/../../.." && pwd -P)
flavours=${*:-debian alpine sudors}
password=correct-horse
passes=0 fails=0

ok() {
	passes=$((passes + 1))
	printf 'ok    %s\n' "$1"
}
not_ok() {
	fails=$((fails + 1))
	printf 'FAIL  %s\n' "$1"
	[ -z "${2:-}" ] || printf '      %s\n' "$2"
}
check() { # check NAME GOT WANT
	if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$3], got [$2]"; fi
}
contains() { # contains NAME TEXT PART
	case $2 in *"$3"*) ok "$1" ;; *) not_ok "$1" "[$3] not in: $2" ;; esac
}

# A terminal on the host for `docker exec -it`, typing $1 after a pause.
type_into() {
	input=$1
	shift
	if [ "$(uname -s)" = Darwin ]; then
		{ sleep 2; printf '%s\n' "$input"; sleep 2; } | script -q /dev/null "$@"
	else
		{ sleep 2; printf '%s\n' "$input"; sleep 2; } | script -qec "$*" /dev/null
	fi
}

for flavour in $flavours; do
	printf '\n== %s\n' "$flavour"
	image=sudoorbell-min-$flavour
	docker build -q -t "$image" -f "$root/tests/e2e/minimal/Dockerfile.$flavour" "$root" >/dev/null || {
		not_ok "$flavour: image builds"
		continue
	}
	c=$(docker run -d --rm "$image" sleep 900)
	in_c() { docker exec "$c" sh -c "$1"; }

	case $flavour in
	debian | sudors)
		shell=bash
		# An agent running commands through bash, which reads ~/.bashrc.
		# shellcheck disable=SC2016 # expanded in the container
		agent='BASH_ENV=$HOME/.bashrc setsid bash -c "sudo -k id -u"'
		;;
	alpine)
		shell='sh'
		# An agent running commands through a login sh, which reads ~/.profile.
		agent='setsid sh -lc "sudo -k id -u"'
		;;
	esac

	contains "$flavour: install" "$(in_c "/src/bin/sudoorbell install --shell $shell" 2>&1)" "Installed to"

	# ask: start the request in the background; results in /tmp/out, err, status.
	ask() {
		in_c ': >/tmp/out; : >/tmp/err; : >/tmp/status'
		docker exec -d "$c" sh -c "$agent </dev/null >/tmp/out 2>/tmp/err; echo \$? >/tmp/status"
		i=0
		while [ $i -lt 40 ]; do
			in_c 'ls /tmp/sudoorbell-*/req.* >/dev/null 2>&1' && return 0
			if [ -n "$(in_c 'cat /tmp/status')" ]; then return 1; fi
			sleep 0.25
			i=$((i + 1))
		done
		return 1
	}
	finished() {
		i=0
		while [ $i -lt 40 ] && [ -z "$(in_c 'cat /tmp/status')" ]; do
			sleep 0.25
			i=$((i + 1))
		done
	}

	if ask; then
		ok "$flavour: the request waits for an answer"
		screen=$(type_into "$password" docker exec -it "$c" /home/tester/.local/bin/sudoorbell approve 2>&1)
		finished
		check "$flavour: approve: sudo runs the command as root" "$(in_c 'cat /tmp/out')" 0
		contains "$flavour: approve: shows the command" "$screen" "sudo -A -k id -u"
		case $screen in
		*"$password"*) not_ok "$flavour: approve: password not shown" ;;
		*) ok "$flavour: approve: password not shown" ;;
		esac
	else
		not_ok "$flavour: the request waits for an answer" "status=$(in_c 'cat /tmp/status') err=$(in_c 'cat /tmp/err')"
	fi

	if ask; then
		in_c '/home/tester/.local/bin/sudoorbell approve --deny' >/dev/null
		finished
		check "$flavour: deny: command not run" "$(in_c 'cat /tmp/out')" ""
	else
		not_ok "$flavour: deny: the request waits" "err=$(in_c 'cat /tmp/err')"
	fi

	contains "$flavour: doctor runs" "$(in_c '/home/tester/.local/bin/sudoorbell doctor' 2>&1)" "OK   installed"
	docker stop -t 1 "$c" >/dev/null
done

# /proc mounted with hidepid=2 hides sudo (a root process) from the helper. It
# cannot check its caller then, so it must refuse, and say why.
case " $flavours " in
*" debian "*)
	printf '\n== debian, /proc with hidepid=2\n'
	c=$(docker run -d --rm --privileged sudoorbell-min-debian sleep 300)
	docker exec -u root "$c" mount -o remount,hidepid=2 /proc
	err=$(docker exec "$c" sh -c '/src/bin/sudoorbell install --shell bash >/dev/null; BASH_ENV=$HOME/.bashrc setsid bash -c "sudo -k id -u" </dev/null 2>&1 >/dev/null; true')
	contains "hidepid: refused, naming the cause" "$err" "cannot see the calling process"
	docker stop -t 1 "$c" >/dev/null
	;;
esac

printf '\nminimal: %s passed, %s failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
