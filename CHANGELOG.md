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
- **Password field inside Claude Code** ("Type password here"): a panel above
  the prompt, like Cursor's "Sudo Authentication Required" box, and Claude's
  prompt box becomes the password field, showing `•` per character. Enter
  hands the password to that one sudo request through standard input, never
  to Claude; Esc cancels; the draft that was in the box comes back. Works at
  any terminal width. Offered only while no other enabled mod could read it
  (one hooking `prompt.edit` or `process.run`).
- **`sudoorbell config`** to list, change and reset saved settings
  (`~/.config/sudoorbell/config`): `touch_id`, `claude_password`, `dialog`,
  `timeout`, `notify` and `title`. Environment variables still win.
- **Touch ID status** in `sudoorbell config` and `sudoorbell doctor`: whether a
  fingerprint is added, whether a sensor can be used, whether Touch ID is
  turned on for sudo in macOS (with the command that turns it on), and the
  `touch_id` setting.
- **Choose which programs sudoorbell works for**: `sudoorbell client` lists
  them, `sudoorbell client off cursor-agent` (or `on`) switches one at any
  time, `sudoorbell client only claude,codex` keeps to some, and
  `sudoorbell install --clients claude,codex` chooses at install time. For a
  program that is off, sudo goes on as if sudoorbell were not installed.
  Programs run by an interpreter are named from their command line, so
  Cursor's agent (`node .../cursor-agent/...`) is `cursor-agent`, also in the
  dialog's "Requested by" line.
- `sudoorbell approve --pending`, `--pid N` and `--stdin`, for programs that
  answer a waiting request (the plugin uses them).
- `SUDOORBELL_TOUCH_ID=off` and `SUDOORBELL_RUNTIME_DIR` environment variables.

### Fixed

- The password field showed one `•` per character, and Claude Code kept each
  submitted field in its prompt history, so the history told the password's
  length. The box now shows a fixed `••••••••`, and after a hand-over the
  plugin takes those entries out of `history.jsonl`.
- After Enter in the password field, the message said the password went to
  sudo even when it was wrong. It now waits for sudo's answer: "wrong
  password, sudo is asking again (attempt 2 of 3)", or that it was handed to
  sudo.
- When the plugin answers a request, sudo's output no longer tells Claude to
  run `sudoorbell approve` in a terminal.
- A program with no name above sudo (as under `docker exec`) was treated as
  switched off, so the helper refused every request there.
- The password field first used a pane, which Claude Code only places in a
  terminal at least 144 columns wide. In a narrower one the field never
  appeared, and the prompt became unusable while sudo waited. Found by the
  user in a 102-column terminal; replaced by the panel and prompt box above.
- A program's own `SUDO_ASKPASS` (Cursor's agent sets one) is no longer
  replaced by sudoorbell's.
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
