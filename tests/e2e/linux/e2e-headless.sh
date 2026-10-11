#!/bin/sh
# End to end without a desktop, with real sudo: a server or container where
# requests are answered with `sudo-dialog approve`, or in a tmux popup. Runs in
# the image from tests/e2e/linux/Dockerfile as user "tester" (password
# correct-horse), with no display at all.

# shellcheck disable=SC2034 # read by helpers.sh
SD_ROOT=/src
# shellcheck source=../../helpers.sh
. /src/tests/helpers.sh

password=correct-horse
unset DISPLAY WAYLAND_DISPLAY
export TERM=xterm-256color

/src/bin/sudo-dialog install --shell bash >/dev/null
cli=$HOME/.local/bin/sudo-dialog
state=/tmp/sudo-dialog-$(id -u)

agent=$(scratch)/fake-agent
cp "$(command -v dash || command -v sh)" "$agent"

# ask DIR: the agent runs `sudo -k id -u` with no terminal, through bash and
# the installed startup file, in the background. Results land in DIR.
ask() {
	BASH_ENV=$HOME/.bashrc "$agent" -c "setsid -w bash -c 'sudo -k id -u' </dev/null >'$1/out' 2>'$1/err'; echo \$? >'$1/status'" &
	asker=$!
}

waiting() {
	for _ in $(seq 1 40); do
		ls "$state"/req.* >/dev/null 2>&1 && return 0
		sleep 0.25
	done
	return 1
}

# 1. Answer with `sudo-dialog approve` in another terminal. A second terminal
#    of the same user is open meanwhile, to receive the notice.
run=$(scratch)
printf '%s\n' "sleep 6" >"$run/idle"
run_script "$run/idle" </dev/null >"$run/other-terminal" 2>&1 &
other=$!
sleep 1
ask "$run"
if waiting; then ok "approve: the request waits"; else not_ok "approve: the request waits"; fi
printf '%s\n' "$password" >"$run/typed"
printf '%s\n' "'$cli' approve" >"$run/approve"
screen=$(with_tty "$run/approve" "$run/typed" 2>&1)
wait $asker
wait $other
assert_eq "approve: sudo runs the command as root" "$(cat "$run/out")" 0
assert_contains "approve: shows the command" "$screen" "sudo -A -k id -u"
assert_contains "approve: shows who asked" "$screen" "Requested by: fake-agent"
assert_not_contains "approve: password not shown" "$screen" "$password"
assert_contains "approve: the agent's output said how to answer" "$(cat "$run/err")" "sudo-dialog approve"
assert_contains "notice: the user's other terminal was told" "$(cat "$run/other-terminal")" "wants to run as root"

# 2. Deny from a terminal.
run=$(scratch)
ask "$run"
waiting
"$cli" approve --deny >/dev/null
wait $asker
assert_eq "deny: command not run" "$(cat "$run/out")" ""
if [ "$(cat "$run/status")" != 0 ]; then ok "deny: sudo fails"; else not_ok "deny: sudo fails"; fi

# 3. Nobody answers.
run=$(scratch)
started=$(date +%s)
export SUDO_DIALOG_TIMEOUT=3
ask "$run"
wait $asker
unset SUDO_DIALOG_TIMEOUT
elapsed=$(($(date +%s) - started))
if [ "$(cat "$run/status")" != 0 ] && [ "$elapsed" -lt 30 ]; then ok "timeout: sudo fails after ${elapsed}s"; else not_ok "timeout: sudo fails" "after ${elapsed}s"; fi
if ls "$state"/req.* >/dev/null 2>&1; then not_ok "timeout: nothing left waiting"; else ok "timeout: nothing left waiting"; fi

# 4. Inside tmux: a popup on the attached client. The client runs in a
#    terminal whose keyboard is the pipe $keys.
run=$(scratch)
tmux new-session -d -s main -x 120 -y 40
keys=$run/keys
mkfifo "$keys"
printf '%s\n' "tmux attach -t main" >"$run/client"
run_script "$run/client" <"$keys" >"$run/client.log" 2>&1 &
exec 7>"$keys"
sleep 1
tmux new-window -t main "BASH_ENV=$HOME/.bashrc setsid -w bash -c 'sudo -k id -u' </dev/null >'$run/out' 2>'$run/err'; echo \$? >'$run/status'"
waiting
sleep 2
printf '%s\r' "$password" >&7
for _ in $(seq 1 40); do
	[ -s "$run/status" ] && break
	sleep 0.25
done
assert_eq "tmux: the popup's answer reaches sudo" "$(cat "$run/out" 2>/dev/null)" 0
assert_contains "tmux: the popup showed the command" "$(cat "$run/client.log")" "sudo -A -k id -u"
exec 7>&-
tmux kill-server 2>/dev/null

finish
