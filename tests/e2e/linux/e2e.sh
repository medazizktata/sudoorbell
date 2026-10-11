#!/bin/sh
# End to end on Linux, with real sudo and a real dialog. Runs inside the image
# from tests/e2e/linux/Dockerfile (run.sh builds and starts it) as user
# "tester", whose password is correct-horse. xdotool plays the user: it finds
# the dialog on the virtual display and types into it.

# shellcheck disable=SC2034 # read by helpers.sh
SD_ROOT=/src
# shellcheck source=../../helpers.sh
. /src/tests/helpers.sh

password=correct-horse
title='Administrator access'
export NO_AT_BRIDGE=1 GDK_BACKEND=x11

Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
export DISPLAY=:99
for _ in 1 2 3 4 5 6 7 8 9 10; do
	xdotool getmouselocation >/dev/null 2>&1 && break
	sleep 0.5
done

/src/bin/sudo-dialog install --shell bash >/dev/null
askpass=$HOME/.local/share/sudo-dialog/libexec/sudo-dialog-askpass

# Record every zenity call (the dialog text), then run the real one.
spy=$(scratch)
log=$spy/zenity.log
cat >"$spy/zenity" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done >>"$log"
printf '%s\n' ---- >>"$log"
exec /usr/bin/zenity "\$@"
EOF
chmod 755 "$spy/zenity"
export PATH="$spy:$PATH"

# answer TEXT|--deny|--ignore: wait for the dialog, then act as the user.
answer() {
	wid=''
	for _ in $(seq 1 40); do
		wid=$(xdotool search --onlyvisible --name "$title" 2>/dev/null | head -1)
		[ -n "$wid" ] && break
		sleep 0.25
	done
	if [ -z "$wid" ]; then
		echo "no dialog appeared" >&2
		return 1
	fi
	sleep 0.5
	xdotool windowfocus --sync "$wid" 2>/dev/null
	case $1 in
	--deny) xdotool key --window "$wid" Escape ;;
	--ignore) ;;
	*)
		xdotool type --delay 40 "$1"
		xdotool key Return
		;;
	esac
	# Wait for it to close, so the next answer goes to the next dialog.
	for _ in $(seq 1 40); do
		xdotool search --onlyvisible --name "$title" >/dev/null 2>&1 || return 0
		sleep 0.25
	done
}

# request: run `sudo -k id -u` with no terminal, as an agent would, from a
# process named fake-agent. Output in $out/$err, status in $status.
agent=$(scratch)/fake-agent
cp "$(command -v dash || command -v sh)" "$agent"
request() {
	run_dir=$(scratch)
	"$agent" -c "setsid -w sh -c 'sudo -k id -u' </dev/null >'$run_dir/out' 2>'$run_dir/err'; echo \$? >'$run_dir/status'" &
	bg=$!
	"$@"
	wait $bg
	out=$(cat "$run_dir/out")
	err=$(cat "$run_dir/err")
	status=$(cat "$run_dir/status")
}
nothing() { :; }

# 1. Without sudo-dialog, sudo has no way to ask: the problem being solved.
#    Also checks this harness really has no terminal.
(
	unset SUDO_ASKPASS
	request nothing
	assert_contains "baseline: without a helper sudo needs a terminal" "$err" "a terminal is required"
	assert_eq "baseline: and fails" "$status" 1
)

export SUDO_ASKPASS="$askpass"

# 2. Plain sudo, no function, no -A: sudo uses the dialog by itself because
#    SUDO_ASKPASS and DISPLAY are set.
: >"$log"
request answer "$password"
assert_eq "right password: sudo runs the command as root" "$out" 0
assert_eq "right password: success" "$status" 0
dialog=$(cat "$log")
assert_contains "dialog names the command" "$dialog" "sudo -k id -u"
assert_contains "dialog names the requester" "$dialog" "Requested by: fake-agent"

# 3. A wrong password, then the right one.
: >"$log"
run_dir=$(scratch)
"$agent" -c "setsid -w sh -c 'sudo -k id -u' </dev/null >'$run_dir/out' 2>'$run_dir/err'; echo \$? >'$run_dir/status'" &
bg=$!
answer wrong-password
answer "$password"
wait $bg
assert_eq "retry: second password accepted" "$(cat "$run_dir/out")" 0
assert_contains "retry: sudo said to try again" "$(cat "$run_dir/err")" "Sorry, try again"
assert_contains "retry: second dialog says attempt 2" "$(cat "$log")" "Wrong password. Attempt 2."

# 4. Deny.
request answer --deny
assert_eq "deny: command not run" "$out" ""
if [ "$status" != 0 ]; then ok "deny: sudo fails"; else not_ok "deny: sudo fails"; fi

# 5. Nobody answers: the dialog gives up and sudo fails, instead of hanging.
started=$(date +%s)
export SUDO_DIALOG_TIMEOUT=3
: >"$log"
request nothing
unset SUDO_DIALOG_TIMEOUT
elapsed=$(($(date +%s) - started))
if [ "$status" != 0 ] && [ "$elapsed" -lt 30 ]; then ok "timeout: sudo fails after ${elapsed}s"; else not_ok "timeout: sudo fails" "status=$status after ${elapsed}s"; fi
assert_eq "timeout: one dialog, not one per sudo retry" "$(grep -c '^----$' "$log")" 1

# 6. The shell function path, through bash reading ~/.bashrc as installed.
run_dir=$(scratch)
BASH_ENV=$HOME/.bashrc "$agent" -c "setsid -w bash -c 'type -t sudo; sudo -k id -u' </dev/null >'$run_dir/out' 2>'$run_dir/err'; echo \$? >'$run_dir/status'" &
bg=$!
answer "$password"
wait $bg
assert_eq "function: bash uses the sudo function and it succeeds" "$(tr '\n' ' ' <"$run_dir/out")" "function 0 "

# 7. Real sudo passes the gate; calling the helper directly does not.
assert_contains "gate: direct call refused" "$("$askpass" Password: 2>&1)" "caller is not sudo"

finish
