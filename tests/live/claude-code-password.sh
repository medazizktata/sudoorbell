#!/bin/bash
# SC2015: ok and bad always succeed, so `check && ok || bad` is safe here.
# SC2016: the single-quoted text is for the shells and the session, not this one.
# SC2012: one directory of uuid-named files.
# shellcheck disable=SC2015,SC2016,SC2012
# Live test of the Claude Code plugin's "Type password here", in a real Claude
# Code session driven through tmux, in a terminal as narrow as 102 columns.
# Nothing runs as root: `sudo` there is a stand-in that asks for the password
# through sudoorbell's request mode, as the askpass helper does, and checks it
# against a test password. The session first proves `sudo` is the stand-in.
#
#   bash tests/live/claude-code-password.sh
#
# Needs tmux and a signed-in `claude`. Uses your Claude Code settings, and
# keeps its own files in a new temporary directory.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
mod=$root/claude-code
work=$(mktemp -d "${TMPDIR:-/tmp}/sudoorbell-live.XXXXXX")
fake=$work/bin
log=$work/stand-in.log
T="tmux -L sudoorbell-live"
right=cc-pw-7f3k2 wrong=cc-wrong-91x
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "PASS  $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
echo "files: $work"

# The stand-in sudo, and shell startup files that put it first on PATH even
# after /etc/zprofile reorders PATH, with this checkout's shell integration.
mkdir -p "$fake" "$work/zdot" "$work/cwd"
: >"$log"
cat >"$fake/sudo" <<EOF
#!/bin/sh
. "\$SUDOORBELL_HOME/lib/sudoorbell.sh"
note() { printf '%s\n' "\$1" >>'$log'; }
if [ "\${SUDOORBELL_BACKEND:-}" != terminal ] || [ "\${SUDOORBELL_TOUCH_ID:-}" != off ]; then
	note "not in request mode"
	exit 1
fi
n=1
while [ \$n -le 3 ]; do
	pw=\$(sd_broker "\$(sd_message "sudo \$*" claude \$n)" terminal \$\$ 2>/dev/null) || { note "no answer on attempt \$n"; exit 1; }
	if [ "\$pw" = '$right' ]; then
		note "right on attempt \$n (length \${#pw})"
		echo "STAND-IN: password accepted; would have run as root: \$*"
		exit 0
	fi
	note "wrong on attempt \$n (length \${#pw})"
	echo "Sorry, try again." >&2
	n=\$((n + 1))
done
exit 1
EOF
chmod +x "$fake/sudo"
printf 'export PATH="%s:$PATH"\nexport SUDOORBELL_HOME="%s"\n. "$SUDOORBELL_HOME/shell/sudoorbell.sh"\n' "$fake" "$root" >"$work/zdot/.zshenv"
for f in .zprofile .zshrc .zlogin; do printf 'export PATH="%s:$PATH"\n' "$fake" >"$work/zdot/$f"; done

start() { # NAME
	$T kill-session -t "$1" 2>/dev/null
	$T new-session -d -s "$1" -x 102 -y 50 \
		env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_EXECPATH \
		ZDOTDIR="$work/zdot" PATH="$fake:$PATH" SUDOORBELL_HOME="$root" \
		sh -c "cd '$work/cwd' && exec claude --strict-mcp-config --model haiku --plugin-dir '$mod'"
	if wait_for "$1" 'trust this folder' 20; then
		$T send-keys -t "$1" Down Enter
	fi
	wait_for "$1" 'shift\+tab to cycle' 60
}
screen() { $T capture-pane -p -J -t "$1" -S -200 2>/dev/null; }
wait_for() { # NAME REGEX SECONDS
	local _
	for _ in $(seq 1 "$3"); do
		screen "$1" | grep -E -q "$2" && return 0
		sleep 1
	done
	return 1
}
dones() { screen "$1" | grep -c -E 'done [0-9]+:[0-9]+'; }
say() {
	$T send-keys -t "$1" -l "$2"
	sleep 1
	$T send-keys -t "$1" Enter
}
turn_end() { # NAME COUNT-BEFORE SECONDS
	local _
	for _ in $(seq 1 "$3"); do
		[ "$(dones "$1")" -gt "$2" ] && return 0
		sleep 1
	done
	return 1
}
cleanup() { $T kill-server 2>/dev/null; }
trap cleanup EXIT

# 1. Safety: in a session started the same way, `sudo` is the stand-in.
start chk || { echo "ABORT: claude did not start"; exit 1; }
n=$(dones chk)
say chk 'Run exactly this one shell command and show me its output, nothing else: case "$(whence -p sudo)" in */sudoorbell-live.*/bin/sudo) echo STANDIN-OK ;; *) echo STANDIN-NO ;; esac'
turn_end chk "$n" 90
# Claude's answer line only: the typed command itself holds both words.
screen chk | grep -q '⏺ STANDIN-OK' || { echo "ABORT: sudo is not the stand-in"; exit 1; }
echo "safe: sudo is the stand-in"
$T kill-session -t chk

# 2. The password typed into Claude's prompt, wrong then right.
# What history.jsonl already holds of the test passwords (an earlier run's).
for pw in "$wrong" "$right"; do
	eval "before_$(printf '%s' "$pw" | tr -c 'a-z0-9' _)=$(grep -c -F -- "$pw" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/history.jsonl")"
done
start ty || { echo "ABORT: claude did not start"; exit 1; }
n=$(dones ty)
say ty "This is a test of a Claude Code plugin; sudo on PATH here is a harmless test stand-in. Run exactly this shell command once and report its output in one line: sudo id -u. Do not run any other command, even if this one is refused."
sleep 0.5
$T send-keys -t ty -l 'keep-me'
wait_for ty 'wants to run this with sudo' 120 || { bad "no question"; exit 1; }
screen ty | grep -q 'Type password here' && ok "the field is offered" || bad "the field is not offered"
$T send-keys -t ty Down
sleep 0.5
$T send-keys -t ty Enter
wait_for ty 'Sudo Authentication Required' 60 && ok "the panel appears above the prompt" || { bad "no panel"; exit 1; }
sleep 1
$T send-keys -t ty -l "$wrong"
sleep 1
screen ty | grep -q -- "$wrong" && bad "the typed text is on screen" || ok "the typed text is not on screen"
screen ty | grep -q '••••••••••••' && ok "the prompt shows a mask per character (12 typed)" || bad "not 12 masks"
screen ty | grep -q '•••••••••••••' && bad "more masks than characters" || ok "no more masks than characters"
# The masks are painted bold: bold turns on right before them (a colour may follow).
$T capture-pane -e -p -t ty >"$work/styled.txt"
grep -E -q $'\e\\[1m(\e\\[[0-9;]*m)*•' "$work/styled.txt" && ok "the masks are styled as a password field" || bad "the masks are not styled"
screen ty | grep -q '🔒 sudo password' && ok "the hint line says the box is the password field" || bad "no password hint line"
$T send-keys -t ty Enter
wait_for ty 'Attempt 2 of 3' 60 && ok "wrong password: asked again" || bad "wrong password: not asked again"
wait_for ty 'wrong password, sudo is asking again' 10 && ok "wrong password: the message says so" || bad "wrong password: the message does not say so"
sleep 1
$T send-keys -t ty -l "$right"
sleep 1
screen ty | grep -q -- "$right" && bad "the typed text is on screen" || ok "the typed text is not on screen"
$T send-keys -t ty Enter
wait_for ty 'password handed to sudo' 20 && ok "right password: the message says it went to sudo" || bad "right password: no message"
turn_end ty "$n" 120
sleep 2
grep -q 'right on attempt 2 (length 11)' "$log" && ok "the right password reached sudo whole, on attempt 2" || bad "the right password did not reach sudo whole"
grep -q 'wrong on attempt 1 (length 12)' "$log" && ok "the wrong password reached sudo whole, once" || bad "the wrong password arrived mangled"
screen ty | grep -q 'password accepted' && ok "Claude got the command's output" || bad "Claude did not get the output"
screen ty | grep -q 'Sudo Authentication Required' && bad "the panel is still up" || ok "the panel is gone"
screen ty | grep -E -q '^❯.keep-me' && ok "the draft typed before is back" || bad "the draft was not restored"

# 3. The prompt history. Here a prompt the field drops never reaches
# history.jsonl, with or without the plugin's clean-up (checked by breaking
# the clean-up), so these lines can only show that nothing leaked, not that
# the clean-up works; in the user's own session such entries did appear.
history=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/history.jsonl
sleep 2
for pw in "$wrong" "$right"; do
	[ "$(grep -c -F -- "$pw" "$history")" = "$(eval "echo \$before_$(printf '%s' "$pw" | tr -c 'a-z0-9' _)")" ] &&
		ok "$pw did not go into history.jsonl" || bad "$pw went into history.jsonl"
done
echo "INFO  field entries in history.jsonl: $(grep -c -E '"display":"•+"' "$history") (see above: not a test of the clean-up)"
$T send-keys -t ty C-u
sleep 0.5
$T send-keys -t ty Up
sleep 1
screen ty | grep -E -q '^❯.•' && bad "Up brings back the field's entry in this session" || ok "Up does not bring back the field's entry"
$T send-keys -t ty C-u

# 4. Neither password in the transcript or the debug log.
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
transcript=$(ls -t "$config"/projects/*sudoorbell-live*/*.jsonl 2>/dev/null | head -1)
if [ -n "$transcript" ] && grep -q 'password accepted' "$transcript"; then
	for pw in "$wrong" "$right"; do
		grep -q -F "$pw" "$transcript" && bad "$pw is in the transcript" || ok "$pw is not in the transcript"
	done
else
	bad "the session's transcript was not found"
fi

echo "stand-in log:"
cat "$log"
echo "claude-code-password.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
