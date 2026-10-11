# Changelog

What changed in each release of sudoorbell. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Claude Code plugin** (`claude-code/`, installable with
  `/plugin install sudoorbell --marketplace medazizktata/sudoorbell`). When
  Claude runs a Bash command that uses `sudo`, the command waits and Claude
  Code asks you, showing it: **Approve** (Touch ID or the sudoorbell window
  confirms it), **Type password here**, or **Deny**. An approved command gets
  past the `Bash(sudo:*)` deny rule for that one call only; every other `sudo`
  still meets the rule, as does every `sudo` when the plugin isn't loaded.
- **Password field inside Claude Code** ("Type password here"): typing shows
  nothing, as in a terminal, and the password goes to that one sudo request
  through standard input, never to Claude. It is offered only while no other
  enabled mod could read it (one hooking `ui.input`, `process.run` or
  `prompt.edit`), and while it waits, anything typed into Claude's own prompt
  is thrown away.
- **`sudoorbell config`** to list, change and reset saved settings
  (`~/.config/sudoorbell/config`): `touch_id`, `claude_password`, `dialog`,
  `timeout`, `notify` and `title`. Environment variables still win.
- **Touch ID status** in `sudoorbell config` and `sudoorbell doctor`: whether a
  fingerprint is added, whether a sensor can be used, whether Touch ID is
  turned on for sudo in macOS (with the command that turns it on), and the
  `touch_id` setting.
- `sudoorbell approve --pending`, `--pid N` and `--stdin`, for programs that
  answer a waiting request (the plugin uses them).
- `SUDOORBELL_TOUCH_ID=off` and `SUDOORBELL_RUNTIME_DIR` environment variables.

### Fixed

- The plugin no longer lifts another deny rule along with the sudo rule.
  Claude Code names only the first rule that matched, so in
  `sudo id -u && curl --version` with `curl` denied, approving the sudo let
  `curl` run too. Found in a live test before release.

### Changed

- With the plugin, Claude Code no longer needs the MCP `sudo` tool
  (`--claude-mcp`), whose form shows the password while it is typed. The MCP
  tool stays, for Codex, Cursor and other MCP clients.

## [0.1.0] - 2026-10-11

First release.

### Added

- A password dialog for `sudo` when there is no terminal, naming the command
  and the program that asked: AppleScript on macOS; zenity, kdialog, yad or an
  ssh-askpass on Linux.
- A `sudo` shell function for zsh, bash, POSIX sh (dash, BusyBox ash) and
  fish that sends sudo to the dialog when there is no terminal.
- **Touch ID** on macOS when it is turned on for sudo, with the dialog only as
  the fallback when Touch ID cannot be used; Cancel in Apple's prompt is a no.
- **No desktop**: a tmux 3.2+ popup, or `sudoorbell approve` from any terminal.
- **Claude Code**: `--claude-deny` adds a `Bash(sudo:*)` deny rule;
  `--claude-mcp[=form|browser]` registers an MCP `sudo` tool, which also works
  in other MCP clients.
- `sudoorbell install`, `uninstall`, `doctor`, `preview` and `approve`.
- Homebrew formula: `brew install medazizktata/tap/sudoorbell`.
- Works on bare systems: no `ps` (reads `/proc`), BusyBox, `sudo-rs`; refuses,
  saying why, under `/proc` `hidepid` and in sandboxes that hide processes.

### Fixed

- `install` and `uninstall` could delete their own files when the install
  folder was the program itself through a symlink, as in Homebrew's layout.

[Unreleased]: https://github.com/medazizktata/sudoorbell/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/medazizktata/sudoorbell/releases/tag/v0.1.0
