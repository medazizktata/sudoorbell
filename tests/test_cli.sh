#!/bin/sh
# install, uninstall and doctor, in a throwaway home directory.
. "$(dirname "$0")/helpers.sh"

home=$(scratch)
cli=$root/bin/sudo-dialog
# Everything the CLI touches lives under $home.
in_home() {
	env HOME="$home" ZDOTDIR="$home" XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" \
		CLAUDE_CONFIG_DIR="$home/.claude" "$@"
}
prefix=$home/.local/share/sudo-dialog

printf 'export EDITOR=vi\n' >"$home/.zshenv"
# Like Ubuntu's default ~/.bashrc: stop early unless interactive. No final
# newline, on purpose.
printf '%s\n%s' 'case $- in *i*) ;; *) return ;; esac' 'alias ll="ls -l"' >"$home/.bashrc"
mkdir -p "$home/.claude"
printf '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}\n' >"$home/.claude/settings.json"
cp "$home/.zshenv" "$home/zshenv.orig"
cp "$home/.claude/settings.json" "$home/settings.orig"

in_home "$cli" install --shell zsh,bash --claude-deny >/dev/null
cp "$home/.zshenv" "$home/zshenv.installed"
in_home "$cli" install --shell zsh,bash --claude-deny >/dev/null

assert_eq "install: one block after two installs" "$(grep -c '>>> sudo-dialog >>>' "$home/.zshenv")" 1
assert_eq "install: a second install changes nothing" "$(cmp -s "$home/.zshenv" "$home/zshenv.installed" && echo same)" same
assert_contains "install: existing settings kept" "$(cat "$home/.zshenv")" "export EDITOR=vi"
assert_eq "install: bash block goes on top" "$(sed -n 1p "$home/.bashrc")" "# >>> sudo-dialog >>>"
assert_contains "install: bashrc keeps its content" "$(cat "$home/.bashrc")" 'alias ll="ls -l"'
# shellcheck disable=SC2016 # expanded by bash
assert_eq "install: non-interactive bash sees it despite the early return" \
	"$(env -i HOME="$home" PATH="$PATH" BASH_ENV="$home/.bashrc" bash -c 'echo "$SUDO_ASKPASS"; type -t sudo' </dev/null | tr '\n' ' ')" \
	"$prefix/libexec/sudo-dialog-askpass function "
assert_eq "install: zsh block goes at the end" "$(tail -1 "$home/.zshenv")" "# <<< sudo-dialog <<<"
assert_eq "install: backup of the original" "$(cmp -s "$home/.zshenv.sudo-dialog.bak" "$home/zshenv.orig" && echo same)" same
if [ -x "$prefix/libexec/sudo-dialog-askpass" ]; then ok "install: helper copied"; else not_ok "install: helper copied"; fi
if [ -L "$home/.local/bin/sudo-dialog" ]; then ok "install: command linked"; else not_ok "install: command linked"; fi
assert_eq "install: deny rule added once" "$(jq -c '.permissions.deny' "$home/.claude/settings.json")" '["Bash(sudo:*)"]'
assert_eq "install: other Claude settings kept" "$(jq -c '[.model, .permissions.allow]' "$home/.claude/settings.json")" '["opus",["Bash(ls:*)"]]'

if command -v zsh >/dev/null 2>&1; then
	# shellcheck disable=SC2016 # expanded by zsh
	got=$(env -i HOME="$home" ZDOTDIR="$home" PATH="$PATH" zsh -c 'echo $SUDO_ASKPASS; whence -w sudo' </dev/null)
	assert_contains "install: a fresh zsh -c sees SUDO_ASKPASS" "$got" "$prefix/libexec/sudo-dialog-askpass"
	assert_contains "install: a fresh zsh -c has the function" "$got" "sudo: function"
fi

doctor=$(in_home "$cli" doctor 2>&1)
assert_contains "doctor: sees the install" "$doctor" "OK   installed: $prefix"
assert_contains "doctor: sees the deny rule" "$doctor" "sudo is denied to the agent"

cp "$home/.zshenv" "$home/zshenv.before-conflict"
printf 'export SUDO_ASKPASS=/elsewhere\n' >>"$home/.zshenv"
assert_contains "doctor: warns about a second SUDO_ASKPASS" "$(in_home "$cli" doctor 2>&1)" "outside the sudo-dialog block"
cp "$home/zshenv.before-conflict" "$home/.zshenv"

in_home "$cli" uninstall --claude-deny >/dev/null
assert_eq "uninstall: zshenv as before" "$(cmp -s "$home/.zshenv" "$home/zshenv.orig" && echo same)" same
assert_eq "uninstall: bashrc keeps its content" "$(sed -n 2p "$home/.bashrc")" 'alias ll="ls -l"'
assert_eq "uninstall: no block left" "$(grep -c 'sudo-dialog' "$home/.bashrc")" 0
if [ -e "$prefix" ]; then not_ok "uninstall: program removed"; else ok "uninstall: program removed"; fi
if [ -e "$home/.local/bin/sudo-dialog" ]; then not_ok "uninstall: command removed"; else ok "uninstall: command removed"; fi
assert_eq "uninstall: deny rule removed, rest kept" \
	"$(jq -c '.' "$home/.claude/settings.json")" \
	"$(jq -c '.permissions.deny = []' "$home/settings.orig")"

err=$(in_home env SUDO_DIALOG_PREFIX="$home/somewhere" "$cli" install 2>&1)
assert_contains "install: refuses a directory not named sudo-dialog" "$err" "refusing to install"

finish
