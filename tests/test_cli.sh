#!/bin/sh
# install, uninstall and doctor, in a throwaway home directory.
. "$(dirname "$0")/helpers.sh"

home=$(scratch)
cli=$root/bin/sudoorbell
# Everything the CLI touches lives under $home.
in_home() {
	env HOME="$home" ZDOTDIR="$home" XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" \
		CLAUDE_CONFIG_DIR="$home/.claude" "$@"
}
prefix=$home/.local/share/sudoorbell

printf 'export EDITOR=vi\n' >"$home/.zshenv"
# Like Ubuntu's default ~/.bashrc: stop early unless interactive. No final
# newline, on purpose.
printf '%s\n%s' 'case $- in *i*) ;; *) return ;; esac' 'alias ll="ls -l"' >"$home/.bashrc"
mkdir -p "$home/.claude"
printf '{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}\n' >"$home/.claude/settings.json"
cp "$home/.zshenv" "$home/zshenv.orig"
cp "$home/.claude/settings.json" "$home/settings.orig"

first=$(in_home "$cli" install --shell zsh,bash --claude-deny)
cp "$home/.zshenv" "$home/zshenv.installed"
second=$(in_home "$cli" install --shell zsh,bash --claude-deny)
assert_contains "install: says it added the deny rule" "$first" "added deny rule"
assert_contains "install again: says the deny rule was already there" "$second" "already in"
assert_not_contains "install again: does not claim to add it" "$second" "added deny rule"

assert_eq "install: one block after two installs" "$(grep -c '>>> sudoorbell >>>' "$home/.zshenv")" 1
assert_eq "install: a second install changes nothing" "$(cmp -s "$home/.zshenv" "$home/zshenv.installed" && echo same)" same
assert_contains "install: existing settings kept" "$(cat "$home/.zshenv")" "export EDITOR=vi"
assert_eq "install: bash block goes on top" "$(sed -n 1p "$home/.bashrc")" "# >>> sudoorbell >>>"
assert_contains "install: bashrc keeps its content" "$(cat "$home/.bashrc")" 'alias ll="ls -l"'
# shellcheck disable=SC2016 # expanded by bash
assert_eq "install: non-interactive bash sees it despite the early return" \
	"$(env -i HOME="$home" PATH="$PATH" BASH_ENV="$home/.bashrc" bash -c 'echo "$SUDO_ASKPASS"; type -t sudo' </dev/null | tr '\n' ' ')" \
	"$prefix/libexec/sudoorbell-askpass function "
assert_eq "install: zsh block goes at the end" "$(tail -1 "$home/.zshenv")" "# <<< sudoorbell <<<"
assert_eq "install: backup of the original" "$(cmp -s "$home/.zshenv.sudoorbell.bak" "$home/zshenv.orig" && echo same)" same
if [ -x "$prefix/libexec/sudoorbell-askpass" ]; then ok "install: helper copied"; else not_ok "install: helper copied"; fi
if [ -L "$home/.local/bin/sudoorbell" ]; then ok "install: command linked"; else not_ok "install: command linked"; fi
assert_eq "install: deny rule added once" "$(jq -c '.permissions.deny' "$home/.claude/settings.json")" '["Bash(sudo:*)"]'
assert_eq "install: other Claude settings kept" "$(jq -c '[.model, .permissions.allow]' "$home/.claude/settings.json")" '["opus",["Bash(ls:*)"]]'

if command -v zsh >/dev/null 2>&1; then
	# shellcheck disable=SC2016 # expanded by zsh
	got=$(env -i HOME="$home" ZDOTDIR="$home" PATH="$PATH" zsh -c 'echo $SUDO_ASKPASS; whence -w sudo' </dev/null)
	assert_contains "install: a fresh zsh -c sees SUDO_ASKPASS" "$got" "$prefix/libexec/sudoorbell-askpass"
	assert_contains "install: a fresh zsh -c has the function" "$got" "sudo: function"
fi

# POSIX login shells (sh -l, dash, BusyBox ash) read ~/.profile.
printf 'echo profile-ran >/dev/null\n' >"$home/.profile"
in_home "$cli" install --shell sh >/dev/null
assert_eq "sh: block on top of ~/.profile" "$(sed -n 1p "$home/.profile")" "# >>> sudoorbell >>>"
for login_sh in sh dash; do
	command -v $login_sh >/dev/null 2>&1 || continue
	# shellcheck disable=SC2016 # expanded by the login shell
	assert_eq "sh: a fresh '$login_sh -lc' has SUDO_ASKPASS and the function" \
		"$(env -i HOME="$home" PATH="$PATH" $login_sh -lc 'echo "$SUDO_ASKPASS"; type sudo | grep -c function' </dev/null 2>/dev/null | tr '\n' ' ')" \
		"$prefix/libexec/sudoorbell-askpass 1 "
done

# The installed command is a symlink; it must find its library through it.
assert_eq "installed command: runs through its symlink" "$(in_home "$home/.local/bin/sudoorbell" version 2>&1)" "$(sh "$cli" version)"
assert_contains "installed command: approve works through it" "$(in_home "$home/.local/bin/sudoorbell" approve </dev/null 2>&1)" "No sudo request is waiting."

doctor=$(in_home "$cli" doctor 2>&1)
assert_contains "doctor: sees the install" "$doctor" "OK   installed: $prefix"
assert_contains "doctor: sees the deny rule" "$doctor" "sudo is denied to the agent"

cp "$home/.zshenv" "$home/zshenv.before-conflict"
# Without jq, doctor says it cannot check Claude Code rather than guessing.
nojq=$(scratch)
for t in sh cat sed awk grep tr cut head tail ls id uname env mktemp dirname readlink stat; do
	p=$(command -v $t) && ln -s "$p" "$nojq/$t"
done
assert_contains "doctor: without jq, says it cannot check Claude Code" \
	"$(in_home env PATH="$nojq" sh "$cli" doctor 2>&1)" "cannot read its settings without jq"

printf 'export SUDO_ASKPASS=/elsewhere\n' >>"$home/.zshenv"
assert_contains "doctor: warns about a second SUDO_ASKPASS" "$(in_home "$cli" doctor 2>&1)" "outside the sudoorbell block"
cp "$home/zshenv.before-conflict" "$home/.zshenv"

in_home "$cli" uninstall --claude-deny >/dev/null
assert_eq "uninstall: zshenv as before" "$(cmp -s "$home/.zshenv" "$home/zshenv.orig" && echo same)" same
assert_eq "uninstall: bashrc keeps its content" "$(sed -n 2p "$home/.bashrc")" 'alias ll="ls -l"'
assert_eq "uninstall: no block left" "$(grep -c 'sudoorbell' "$home/.bashrc")" 0
if [ -e "$prefix" ]; then not_ok "uninstall: program removed"; else ok "uninstall: program removed"; fi
if [ -e "$home/.local/bin/sudoorbell" ]; then not_ok "uninstall: command removed"; else ok "uninstall: command removed"; fi
assert_eq "uninstall: deny rule removed, rest kept" \
	"$(jq -c '.' "$home/.claude/settings.json")" \
	"$(jq -c '.permissions.deny = []' "$home/settings.orig")"

# The Claude Code sudo tool is registered through the claude command.
SD_STUB_LOG=$home/claude.log
export SD_STUB_LOG
claude_bin=$(stub_bin claude)
in_home env PATH="$claude_bin:$PATH" "$cli" install --shell zsh --claude-mcp=browser >/dev/null
calls=$(tr '\n' ' ' <"$SD_STUB_LOG")
assert_contains "claude-mcp: registered for the user, browser mode" "$calls" "arg: mcp arg: add arg: sudoorbell arg: --scope arg: user arg: -e arg: SUDOORBELL_MCP_MODE=browser arg: -- arg: $prefix/mcp/sudoorbell-mcp"
if [ -x "$prefix/mcp/sudoorbell-mcp" ]; then ok "claude-mcp: server installed"; else not_ok "claude-mcp: server installed"; fi
: >"$SD_STUB_LOG"
in_home env PATH="$claude_bin:$PATH" "$cli" uninstall --claude-mcp >/dev/null
assert_contains "claude-mcp: uninstall removes it" "$(tr '\n' ' ' <"$SD_STUB_LOG")" "arg: mcp arg: remove arg: --scope arg: user arg: sudoorbell"

err=$(in_home env SUDOORBELL_PREFIX="$home/somewhere" "$cli" install 2>&1)
assert_contains "install: refuses a directory not named sudoorbell" "$err" "refusing to install"

# Packaged like Homebrew: the files live in a versioned directory, reached
# through a stable symlink (opt/sudoorbell -> Cellar/sudoorbell/VERSION).
pkg=$(scratch)
pkg_home=$(scratch)
mkdir -p "$pkg/cellar/sudoorbell" "$pkg/opt"
for d in bin lib libexec shell mcp; do cp -R "$root/$d" "$pkg/cellar/sudoorbell/$d"; done
: >"$pkg/cellar/sudoorbell/lib/marker"
ln -s "$pkg/cellar/sudoorbell" "$pkg/opt/sudoorbell"
in_pkg_home() {
	env HOME="$pkg_home" ZDOTDIR="$pkg_home" XDG_DATA_HOME="$pkg_home/.local/share" \
		XDG_CONFIG_HOME="$pkg_home/.config" CLAUDE_CONFIG_DIR="$pkg_home/.claude" \
		SUDOORBELL_PREFIX="$pkg/opt/sudoorbell" "$@"
}
pkg_files_intact() {
	c=$pkg/cellar/sudoorbell
	[ -f "$c/lib/marker" ] && [ -x "$c/bin/sudoorbell" ] && [ -x "$c/libexec/sudoorbell-askpass" ] &&
		[ -f "$c/shell/sudoorbell.sh" ] && [ -x "$c/mcp/sudoorbell-mcp" ] && [ -L "$pkg/opt/sudoorbell" ]
}

# Without saying it is packaged: the install directory is the program itself,
# through a symlink. It must not be copied over or removed.
in_pkg_home "$pkg/cellar/sudoorbell/bin/sudoorbell" install --shell zsh >/dev/null 2>&1
if pkg_files_intact; then ok "symlinked to itself: install leaves the files alone"; else not_ok "symlinked to itself: install leaves the files alone"; fi
in_pkg_home "$pkg/cellar/sudoorbell/bin/sudoorbell" uninstall >/dev/null 2>&1
if pkg_files_intact; then ok "symlinked to itself: uninstall leaves the files alone"; else not_ok "symlinked to itself: uninstall leaves the files alone"; fi

# Packaged (SUDOORBELL_PACKAGED=1, as the Homebrew formula sets): use the
# files in place, link nothing into ~/.local/bin, and never remove them.
out=$(in_pkg_home env SUDOORBELL_PACKAGED=1 "$pkg/cellar/sudoorbell/bin/sudoorbell" install --shell zsh 2>&1)
if pkg_files_intact; then ok "packaged: install leaves the files alone"; else not_ok "packaged: install leaves the files alone"; fi
if [ -e "$pkg_home/.local/bin/sudoorbell" ] || [ -L "$pkg_home/.local/bin/sudoorbell" ]; then
	not_ok "packaged: no command linked into ~/.local/bin"
else
	ok "packaged: no command linked into ~/.local/bin"
fi
assert_contains "packaged: the shell block uses the stable path" "$(cat "$pkg_home/.zshenv")" "SUDOORBELL_HOME=\"$pkg/opt/sudoorbell\""
assert_contains "packaged: says where the files are" "$out" "$pkg/opt/sudoorbell"
out=$(in_pkg_home env SUDOORBELL_PACKAGED=1 "$pkg/cellar/sudoorbell/bin/sudoorbell" uninstall 2>&1)
if pkg_files_intact; then ok "packaged: uninstall leaves the files alone"; else not_ok "packaged: uninstall leaves the files alone"; fi
assert_not_contains "packaged: uninstall removed the shell block" "$(cat "$pkg_home/.zshenv")" ">>> sudoorbell >>>"
assert_contains "packaged: uninstall says how to remove the program" "$out" "package manager"

finish
