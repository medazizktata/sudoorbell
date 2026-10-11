# sudo-dialog

A password dialog for `sudo` when there is no terminal to type it in.

AI coding agents (Claude Code, Codex, Cursor), editor tasks and other tools run
commands without a terminal. `sudo` then has nowhere to ask for your password and
fails:

```
sudo: a terminal is required to read the password; either use the -S option to
read from standard input or configure an askpass helper
```

With sudo-dialog, the same command opens a native dialog instead, naming the
command and the program that asked for it:

```
┌ Administrator access ─────────────────────────┐
│  Run as root:                                 │
│                                               │
│  sudo -A apt install curl                     │
│                                               │
│  Requested by: codex                          │
│                                               │
│  Enter your password to allow it.             │
│  [••••••••••••]                               │
│                              [Deny]  [Allow]  │
└───────────────────────────────────────────────┘
```

You type the password into the dialog. It goes straight to `sudo`, never through
the agent, its logs or the conversation.

## Install

```sh
git clone https://github.com/medazizktata/sudo-dialog
cd sudo-dialog
./bin/sudo-dialog install
```

Then open a new terminal and restart any agent that is already running.
`sudo-dialog doctor` checks the setup without running `sudo`.

Options:

| | |
|---|---|
| `--shell zsh,bash,fish` | which shells to set up (default: every one installed) |
| `--claude-deny` | also stop Claude Code's agent from running `sudo` at all (see below) |

`install` copies the program to `~/.local/share/sudo-dialog`, links the command
into `~/.local/bin`, and adds a short, marked block to your shell startup files
(`~/.zshenv`, `~/.bashrc`, `~/.bash_profile`, fish `conf.d`). Each file is backed
up once to `<file>.sudo-dialog.bak`.

Remove everything with `sudo-dialog uninstall` (add `--claude-deny` to remove
that rule too).

## Requirements

- **macOS:** nothing extra; the dialog is AppleScript.
- **Linux:** a desktop session (`DISPLAY` or `WAYLAND_DISPLAY` set) and one of
  `zenity`, `kdialog`, `yad`, or an `ssh-askpass` (`ksshaskpass`,
  `lxqt-openssh-askpass`, `ssh-askpass-gnome`, `x11-ssh-askpass`). On KDE,
  `kdialog` is preferred.
- `jq` only for `--claude-deny`.

## Using it with agents

**Claude Code.** Run `sudo` yourself with the `!` prefix: `! sudo apt install curl`.
The dialog appears and you approve it there. With `--claude-deny`, the agent
itself can no longer run `sudo` (a `Bash(sudo:*)` deny rule in
`~/.claude/settings.json`), so root commands only ever happen when you type
them. Without it, the agent can run `sudo` and each request shows you the
dialog.

**Codex, Cursor and others.** When the agent runs `sudo`, you get the dialog
and decide.

## How it works

`sudo` can get the password from a helper program instead of a terminal: the
*askpass* program, named by `SUDO_ASKPASS` or by `Path askpass` in
`/etc/sudo.conf`. sudo-dialog provides that helper, and two ways for `sudo` to
use it:

1. **`SUDO_ASKPASS` is exported** from your shell startup file, so every program
   started from your shell inherits it. When `sudo` has no terminal and a
   display variable is set (`DISPLAY`, `WAYLAND_DISPLAY` or `WAYLAND_SOCKET`),
   it uses the helper by itself
   ([sudo source](https://github.com/sudo-project/sudo/blob/main/src/tgetpass.c)).
   On a Linux desktop that covers every program, whatever shell or language it
   runs `sudo` from.
2. **A `sudo` shell function** adds `-A` (use the askpass helper) when there is
   no terminal. macOS sets no display variable, so there the function is what
   makes it work, for tools that run commands through your shell. It steps aside
   when a terminal is available, and when you pass `-S`, `-A` or `-n` yourself.

The helper:

- reads the command from its parent process, which is `sudo` itself;
- names the first non-shell ancestor as the requester (`claude`, `codex`, …);
- counts attempts per `sudo` request, and says "Wrong password. Attempt 2." on a
  retry (state in a private `0700` directory);
- closes after 120 seconds unanswered, which counts as Deny, so an unattended
  request cannot hang forever;
- refuses to run unless its parent is a `sudo` process running as root, so other
  programs cannot use it as a ready-made password prompt.

### Settings

| Variable | Default | |
|---|---|---|
| `SUDO_DIALOG_TIMEOUT` | `120` | seconds before an unanswered dialog counts as Deny |
| `SUDO_DIALOG_BACKEND` | auto | force a dialog tool, e.g. `kdialog` |
| `SUDO_DIALOG_TITLE` | `Administrator access` | window title |

## Security

- The password travels from the dialog to `sudo` through a pipe. It is never in
  a command line, an environment variable, a file or the agent's output.
- Approving the dialog is approving the command it shows. Read it.
- `sudo` remembers your password for a few minutes after a success (its
  `timestamp_timeout`). During that window, further `sudo` commands do not ask
  again. That includes commands an agent runs, unless you use `--claude-deny`
  or the agent's own permission rules.
- A program running as you can always draw a fake password dialog of its own.
  No askpass helper can prevent that; sudo-dialog only refuses to *be* that
  dialog for anything but `sudo`.

## Development

```sh
sh tests/run.sh              # unit tests: macOS or Linux, no real sudo, no password
sh tests/e2e/linux/run.sh    # end to end in Docker: real sudo, real zenity on Xvfb
```

The unit tests replace `sudo` and every dialog tool with a stub that records
how it was called. The end-to-end test runs the real thing in a container,
with `xdotool` typing into the dialog: right password, wrong then right, Deny,
timeout, the bash function, and the failure without sudo-dialog as a baseline.
CI runs both, plus `shellcheck`.

## License

MIT
