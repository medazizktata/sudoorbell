#!/bin/sh
# Without a desktop: requests wait for an answer from a terminal
# (`sudoorbell approve`) or a tmux popup.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudoorbell.sh"

XDG_RUNTIME_DIR=$(scratch)
SUDOORBELL_NOTIFY=0
export XDG_RUNTIME_DIR SUDOORBELL_NOTIFY
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET TMUX
dir=$XDG_RUNTIME_DIR/sudoorbell-$(id -u)
work=$(scratch)

# Which way to ask.
assert_eq "backend: Linux without a display waits for a terminal" "$(SD_OS=linux sd_backend)" terminal
assert_eq "backend: macOS over SSH waits for a terminal" "$(SSH_CONNECTION='1 2 3 4' SD_OS=macos sd_backend)" terminal
tmux_bin=$(scratch)
# shellcheck disable=SC2016 # expanded by the stub
printf '#!/bin/sh\necho "tmux $TMUX_VERSION"\n' >"$tmux_bin/tmux"
chmod 755 "$tmux_bin/tmux"
assert_eq "backend: inside tmux 3.4, a popup" "$(PATH=$tmux_bin:$PATH TMUX_VERSION=3.4 TMUX=/tmp/x SD_OS=linux sd_backend)" tmux
assert_eq "backend: inside tmux 3.2a, a popup" "$(PATH=$tmux_bin:$PATH TMUX_VERSION=3.2a TMUX=/tmp/x SD_OS=linux sd_backend)" tmux
assert_eq "backend: tmux 3.1 has no popup" "$(PATH=$tmux_bin:$PATH TMUX_VERSION=3.1c TMUX=/tmp/x SD_OS=linux sd_backend)" terminal

# wait_for PATH: until the request's pipe exists (up to 5 s).
wait_for() {
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ -p "$1" ] && return 0
		sleep 0.25
	done
	return 1
}

# A waiting request, answered by writing to its pipe directly.
sleep 60 &
pid=$!
started=$(date +%s)
(sd_broker "$(sd_message 'sudo apt install curl' codex 1)" terminal $pid >"$work/out" 2>"$work/err"; echo $? >"$work/status") &
broker=$!
wait_for "$dir/fifo.$pid"
assert_contains "request: the text to show is waiting" "$(cat "$dir/req.$pid")" "sudo apt install curl"
# shellcheck disable=SC2012
assert_eq "request: the pipe is private" "$(ls -l "$dir/fifo.$pid" | cut -c1-10)" "prw-------"
printf 'Psecret\n' >"$dir/fifo.$pid"
wait $broker
assert_eq "allow: the password reaches sudo" "$(cat "$work/out")" secret
assert_eq "allow: success" "$(cat "$work/status")" 0
elapsed=$(($(date +%s) - started))
if [ "$elapsed" -le 8 ]; then ok "allow: sudo gets the answer at once (${elapsed}s)"; else not_ok "allow: sudo gets the answer at once" "${elapsed}s"; fi
assert_contains "allow: the agent's output said how to answer" "$(cat "$work/err")" "sudoorbell approve"
if [ -e "$dir/fifo.$pid" ] || [ -e "$dir/req.$pid" ]; then not_ok "allow: request cleaned up"; else ok "allow: request cleaned up"; fi

(sd_broker "msg" terminal $pid >"$work/out" 2>/dev/null; echo $? >"$work/status") &
broker=$!
wait_for "$dir/fifo.$pid"
printf 'D\n' >"$dir/fifo.$pid"
wait $broker
assert_eq "deny: nothing reaches sudo" "$(wc -c <"$work/out" | tr -d ' ')" 0
assert_eq "deny: failure" "$(cat "$work/status")" 1

started=$(date +%s)
(SD_TIMEOUT=1 sd_broker "msg" terminal $pid >"$work/out" 2>/dev/null; echo $? >"$work/status") &
broker=$!
wait $broker
elapsed=$(($(date +%s) - started))
assert_eq "timeout: failure" "$(cat "$work/status")" 1
if [ "$elapsed" -le 4 ]; then ok "timeout: gives up on time (${elapsed}s)"; else not_ok "timeout: gives up on time" "${elapsed}s"; fi
if [ -e "$dir/fifo.$pid" ]; then not_ok "timeout: request cleaned up"; else ok "timeout: request cleaned up"; fi

# `sudoorbell approve` in a terminal: shows the request, reads the password
# without echoing it.
(sd_broker "$(sd_message 'sudo apt install curl' codex 1)" terminal $pid >"$work/out" 2>/dev/null; echo $? >"$work/status") &
broker=$!
wait_for "$dir/fifo.$pid"
printf 'secret-typed\n' >"$work/typed"
printf '%s\n' "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' '$root/bin/sudoorbell' approve" >"$work/approve"
screen=$(with_tty "$work/approve" "$work/typed" 2>&1)
wait $broker
assert_eq "approve: the password reaches sudo" "$(cat "$work/out")" secret-typed
assert_contains "approve: shows the command" "$screen" "sudo apt install curl"
assert_not_contains "approve: the password is not shown" "$screen" "secret-typed"

(sd_broker "msg" terminal $pid >"$work/out" 2>/dev/null; echo $? >"$work/status") &
broker=$!
wait_for "$dir/fifo.$pid"
said=$("$root/bin/sudoorbell" approve --deny </dev/null)
wait $broker
assert_eq "approve --deny: failure" "$(cat "$work/status")" 1
assert_contains "approve --deny: says what it denied" "$said" "Denied"
assert_eq "approve: nothing waiting" "$("$root/bin/sudoorbell" approve </dev/null)" "No sudo request is waiting."

# For programs (the Claude Code plugin): list what waits, then answer one
# request by its sudo process id, with the password on standard input.
(sd_broker "$(sd_message 'sudo apt install curl' claude 1)" terminal $pid >"$work/out" 2>/dev/null; echo $? >"$work/status") &
broker=$!
wait_for "$dir/fifo.$pid"
assert_eq "approve --pending: the pid and the command" "$("$root/bin/sudoorbell" approve --pending)" "$(printf '%s\tsudo apt install curl' $pid)"
err=$(printf 'pw\n' | "$root/bin/sudoorbell" approve --stdin 2>&1)
assert_contains "approve --stdin: refused without --pid" "$err" "needs --pid"
err=$(printf 'pw\n' | "$root/bin/sudoorbell" approve --pid 999999 --stdin 2>&1)
assert_contains "approve --pid: another process's id answers nothing" "$err" "no sudo request is waiting for process 999999"
printf 'stdin-secret\n' | "$root/bin/sudoorbell" approve --pid $pid --stdin
wait $broker
assert_eq "approve --stdin: the password reaches sudo" "$(cat "$work/out")" stdin-secret
assert_eq "approve --stdin: success" "$(cat "$work/status")" 0
assert_eq "approve --pending: nothing left" "$("$root/bin/sudoorbell" approve --pending)" ""

# The prompt never leaves the password in a plain file when the request has
# gone: the pipe path is checked before writing.
printf 'msg\n' >"$work/req"
err=$(printf 'pw\n' | "$root/libexec/sudoorbell-prompt" "$work/req" "$work/gone" 2>&1)
assert_contains "prompt: a request that is gone is refused" "$err" "no longer waiting"
if [ -e "$work/gone" ]; then not_ok "prompt: no file left holding the password"; else ok "prompt: no file left holding the password"; fi

# tmux: the popup is opened on the request's pipe.
SD_STUB_LOG=$work/tmux.log
export SD_STUB_LOG
popup_bin=$(stub_bin tmux)
(PATH=$popup_bin:$PATH SD_LIBEXEC=$root/libexec sd_broker "msg" tmux $pid >/dev/null 2>&1) &
broker=$!
wait_for "$dir/fifo.$pid"
sleep 0.5
printf 'D\n' >"$dir/fifo.$pid"
wait $broker
log=$(cat "$SD_STUB_LOG")
assert_contains "tmux: opens a popup" "$log" "arg: display-popup"
assert_contains "tmux: the popup runs the prompt on this request" "$log" "sudoorbell-prompt' '$dir/req.$pid' '$dir/fifo.$pid'"

kill $pid
finish
