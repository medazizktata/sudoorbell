#!/bin/sh
# Which programs sudoorbell works for: naming them, `sudoorbell client`,
# `install --clients`, and what the shell function does for one that is off.
. "$(dirname "$0")/helpers.sh"
. "$root/lib/sudoorbell.sh"

home=$(scratch)
cli=$root/bin/sudoorbell
in_home() {
	env -u XDG_CONFIG_HOME -u SUDOORBELL_CLIENTS -u SUDOORBELL_CLIENTS_OFF HOME="$home" "$@"
}

# Naming: an interpreter is named from its command line.
assert_eq "name: cursor-agent runs as node" "$(sd_client_name node 'node --use-system-ca /Users/me/.local/share/cursor-agent/versions/2026.09.02-c22c1a3/index.js')" cursor-agent
assert_eq "name: codex installed with npm" "$(sd_client_name node 'node /opt/homebrew/bin/codex exec')" codex
assert_eq "name: gemini's package" "$(sd_client_name node 'node /usr/lib/node_modules/@google/gemini-cli/dist/index.js')" gemini
assert_eq "name: a program by its own name" "$(sd_client_name claude 'claude --resume x')" claude
assert_eq "name: an unknown script keeps the interpreter's name" "$(sd_client_name node 'node server.js')" node
assert_eq "name: a word inside another word is not a client" "$(sd_client_name python3 'python3 /srv/claudette/app.py')" python3

# The rules, from the environment (as the settings file would give them).
# shellcheck disable=SC2016 # expanded by the inner shell
on_off() { if env "$@" sh -c '. "$1/lib/sudoorbell.sh"; sd_client_enabled "$2"' sh "$root" "$NAME"; then echo on; else echo off; fi; }
NAME=cursor-agent
assert_eq "rules: on by default" "$(on_off HOME="$home")" on
assert_eq "rules: off when clients_off names it" "$(on_off HOME="$home" SUDOORBELL_CLIENTS_OFF=codex,cursor-agent)" off
assert_eq "rules: off when clients names others only" "$(on_off HOME="$home" SUDOORBELL_CLIENTS=claude,codex)" off
assert_eq "rules: on when clients names it" "$(on_off HOME="$home" SUDOORBELL_CLIENTS=claude,cursor-agent)" on
assert_eq "rules: clients_off wins over clients" "$(on_off HOME="$home" SUDOORBELL_CLIENTS=cursor-agent SUDOORBELL_CLIENTS_OFF=cursor-agent)" off
assert_eq "rules: clients all" "$(on_off HOME="$home" SUDOORBELL_CLIENTS=all)" on
NAME=''
assert_eq "rules: a program with no name is on by default" "$(on_off HOME="$home")" on
assert_eq "rules: a program with no name, with others off" "$(on_off HOME="$home" SUDOORBELL_CLIENTS_OFF=cursor-agent)" on
assert_eq "rules: a program with no name, with clients a list" "$(on_off HOME="$home" SUDOORBELL_CLIENTS=claude)" off

# `sudoorbell client`
file=$home/.config/sudoorbell/config
in_home "$cli" client off cursor-agent >/dev/null
assert_contains "client off: saved" "$(cat "$file")" "clients_off = cursor-agent"
assert_contains "client: lists it as off" "$(in_home "$cli" client)" "cursor-agent   off"
assert_contains "client: the others stay on" "$(in_home "$cli" client)" "claude         on"
in_home "$cli" client off codex >/dev/null
in_home "$cli" client off codex >/dev/null
assert_contains "client off twice: listed once" "$(cat "$file")" "clients_off = cursor-agent,codex"
in_home "$cli" client on cursor-agent >/dev/null
assert_contains "client on: taken off the list" "$(cat "$file")" "clients_off = codex"
in_home "$cli" client only claude >/dev/null
assert_contains "client only: everything else is off" "$(in_home "$cli" client)" "(any other)    off"
in_home "$cli" client on gemini >/dev/null
assert_contains "client on with a list: added to it" "$(cat "$file")" "clients = claude,gemini"
in_home "$cli" client all >/dev/null
assert_eq "client all: both settings gone" "$(grep -c -E '^clients' "$file")" 0
err=$(in_home "$cli" client off 'bad name' 2>&1)
assert_contains "client: refuses a bad name" "$err" "not a program name"

# install --clients
inst=$(scratch)
out=$(env -u XDG_CONFIG_HOME HOME="$inst" ZDOTDIR="$inst" XDG_DATA_HOME="$inst/.local/share" "$cli" install --shell zsh --clients claude,codex)
assert_contains "install --clients: says so" "$out" "for claude,codex only"
assert_contains "install --clients: saved" "$(cat "$inst/.config/sudoorbell/config")" "clients = claude,codex"
err=$(env -u XDG_CONFIG_HOME HOME="$inst" "$cli" install --clients 'bad name' 2>&1)
assert_contains "install --clients: refuses a bad list" "$err" "not a list of program names"

# The shell function, for a program that is off: plain sudo, no -A.
SD_STUB_LOG=$(scratch)/log
export SD_STUB_LOG
bin=$(stub_bin sudo)
nopam=$(scratch)
args() { # the arguments the stub sudo got, on one line
	: >"$SD_STUB_LOG"
	# shellcheck disable=SC2016
	in_home env PATH="$bin:$PATH" SUDOORBELL_HOME="$root" SD_PAM_DIR="$nopam" "$@" \
		perl -MPOSIX -e 'my $p = fork; if ($p) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV' \
		sh -c '. "$SUDOORBELL_HOME/shell/sudoorbell.sh"; sudo -k true' </dev/null >/dev/null 2>&1
	sed -n 's/^arg: //p' "$SD_STUB_LOG" | tr '\n' ' ' | sed 's/ $//'
}
in_home "$cli" client off cursor-agent >/dev/null
assert_eq "shell: a program that is off gets plain sudo" "$(args SD_CLIENT=cursor-agent)" "-k true"
assert_eq "shell: another program still gets the dialog" "$(args SD_CLIENT=codex)" "-A -k true"
in_home "$cli" client all >/dev/null
assert_eq "shell: without client settings, nothing is looked up and all get it" "$(args SD_CLIENT=cursor-agent)" "-A -k true"

# A program that brings its own askpass keeps it; an old sudoorbell one is replaced.
# shellcheck disable=SC2016
askpass() { in_home env "$@" SUDOORBELL_HOME="$root" sh -c '. "$SUDOORBELL_HOME/shell/sudoorbell.sh"; echo "$SUDO_ASKPASS"' </dev/null; }
assert_eq "askpass: someone else's is kept" "$(askpass SUDO_ASKPASS=/opt/cursor/cursor-askpass)" /opt/cursor/cursor-askpass
assert_eq "askpass: an older sudoorbell's is replaced" "$(askpass SUDO_ASKPASS=/old/place/libexec/sudoorbell-askpass)" "$root/libexec/sudoorbell-askpass"
assert_eq "askpass: none set, sudoorbell's" "$(askpass -u SUDO_ASKPASS)" "$root/libexec/sudoorbell-askpass"

finish
