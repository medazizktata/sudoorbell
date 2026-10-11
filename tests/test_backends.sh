#!/bin/sh
# How each dialog tool is called, and which one is chosen.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudoorbell.sh"

SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
bin=$(stub_bin zenity yad kdialog osascript ssh-askpass)
PATH=$bin:$PATH
message=$(sd_message 'sudo sh -c "echo <b>&</b>"' codex 1)

: >"$SD_STUB_LOG"
out=$(sd_show "$message" zenity)
log=$(cat "$SD_STUB_LOG")
assert_eq "zenity: the password is what the dialog printed" "$out" secret
assert_contains "zenity: hidden entry" "$log" "arg: --hide-text"
assert_contains "zenity: text escaped" "$log" '&lt;b&gt;&amp;&lt;/b&gt;'
assert_not_contains "zenity: no raw markup" "$log" '<b>'
assert_contains "zenity: has a timeout" "$log" "arg: --timeout=120"

: >"$SD_STUB_LOG"
sd_show "$message" kdialog >/dev/null
log=$(cat "$SD_STUB_LOG")
assert_contains "kdialog: password dialog" "$log" "arg: --password"
assert_contains "kdialog: rich text wrapper" "$log" "arg: <qt>Run as root:<br>"
assert_contains "kdialog: text escaped" "$log" '&lt;b&gt;&amp;'

: >"$SD_STUB_LOG"
sd_show "$message" yad >/dev/null
assert_contains "yad: hidden entry" "$(cat "$SD_STUB_LOG")" "arg: --hide-text"

: >"$SD_STUB_LOG"
sd_show "$message" osascript >/dev/null
log=$(cat "$SD_STUB_LOG")
script_text=$(sed -n '/^stdin:$/,$p' "$SD_STUB_LOG")
assert_contains "osascript: command passed as an argument" "$log" 'arg: Run as root:'
assert_not_contains "osascript: command never spliced into the script" "$script_text" 'echo <b>'
assert_contains "osascript: hidden answer" "$script_text" "with hidden answer"

: >"$SD_STUB_LOG"
sd_show "$message" ssh-askpass >/dev/null
assert_contains "ssh-askpass: message is the argument" "$(cat "$SD_STUB_LOG")" "arg: Run as root:"

out=$(SD_STUB_EXIT=1 SD_STUB_REPLY='' sd_show "$message" zenity)
status=$?
assert_eq "cancel: nonzero status" "$status" 1
assert_eq "cancel: nothing on stdout" "$out" ""

bytes=$(SD_STUB_EXIT=5 SD_STUB_REPLY='' sd_ask "$message" zenity | wc -c | tr -d ' ')
assert_eq "timeout: nothing reaches sudo, not even an empty line" "$bytes" 0
assert_eq "allow: the password reaches sudo" "$(sd_ask "$message" zenity)" secret

err=$(sd_show "$message" '' 2>&1 >/dev/null)
assert_contains "no tool: explains" "$err" "no dialog tool found"

assert_eq "backend: macOS uses osascript" "$(SSH_CONNECTION="" SD_OS=macos sd_backend)" osascript
assert_eq "backend: override wins" "$(SD_OS=linux SUDOORBELL_BACKEND=yad sd_backend)" yad
assert_eq "backend: Linux prefers zenity" "$(DISPLAY=:0 SD_OS=linux XDG_CURRENT_DESKTOP=GNOME sd_backend)" zenity
assert_eq "backend: KDE prefers kdialog" "$(DISPLAY=:0 SD_OS=linux XDG_CURRENT_DESKTOP=KDE sd_backend)" kdialog
only_askpass=$(stub_bin ssh-askpass)
assert_eq "backend: falls back to ssh-askpass" "$(PATH=$only_askpass:/usr/bin:/bin && DISPLAY=:0 SD_OS=linux sd_backend)" ssh-askpass

finish
