# sudoorbell

A doorbell for `sudo`: when a program without a terminal (an AI agent, an
editor task) asks for root, you get a dialog, a Touch ID prompt or a terminal
request naming the command, and nothing runs until you answer.

AI coding agents (Claude Code, Codex, Cursor), editor tasks and other tools run
commands without a terminal. `sudo` then has nowhere to ask for your password and
fails:

```
sudo: a terminal is required to read the password; either use the -S option to
read from standard input or configure an askpass helper
```

With sudoorbell, the same command opens a native dialog instead, naming the
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

With Homebrew (macOS or Linux):

```sh
brew install medazizktata/tap/sudoorbell
sudoorbell install
```

Or from a clone:

```sh
git clone https://github.com/medazizktata/sudoorbell
cd sudoorbell
./bin/sudoorbell install
```

Then open a new terminal and restart any agent that is already running.
`sudoorbell doctor` checks the setup without running `sudo`.

Options:

| | |
|---|---|
| `--shell zsh,bash,fish,sh` | which shells to set up (default: every one installed; `sh` covers POSIX login shells such as dash and BusyBox ash, through `~/.profile`) |
| `--claude-deny` | also stop Claude Code's agent from running `sudo` at all (see below) |
| `--claude-mcp[=form\|browser]` | give Claude Code a `sudo` tool that asks for the password itself ([Claude Code mode](#claude-code-mode-the-password-asked-inside-claude-code)) |

`install` copies the program to `~/.local/share/sudoorbell`, links the command
into `~/.local/bin`, and adds a short, marked block to your shell startup files
(`~/.zshenv`, `~/.bashrc`, `~/.bash_profile`, fish `conf.d`). Each file is backed
up once to `<file>.sudoorbell.bak`. Installed with Homebrew, it uses Homebrew's
copy in place instead, through its stable `opt/` path, so upgrades need no
reinstall.

Remove everything with `sudoorbell uninstall` (add `--claude-deny` to remove
that rule too). With Homebrew, `brew uninstall sudoorbell` then removes the
program itself.

## Requirements

- **macOS:** nothing extra; the dialog is AppleScript.
- **Linux desktop:** one of `zenity`, `kdialog`, `yad`, or an `ssh-askpass`
  (`ksshaskpass`, `lxqt-openssh-askpass`, `ssh-askpass-gnome`,
  `x11-ssh-askpass`). On KDE, `kdialog` is preferred.
- **No desktop** (SSH, servers, containers): nothing extra. tmux 3.2 or later
  gives you a popup; see [Without a desktop](#without-a-desktop).
- `jq` only for `--claude-deny`.

Nothing else: a POSIX shell and the basic utilities (`sed`, `awk`, `cut`, `tr`,
`mkfifo`), from coreutils or BusyBox. On Linux, process details come from
`/proc`, so `ps` is not needed. Tested end to end with real `sudo` on bare
images: Debian slim (no `ps`, `/bin/sh` is dash), Alpine (BusyBox only, ash,
no bash), and Ubuntu 26.04 with `sudo-rs` instead of the classic `sudo`.

Not supported: `doas`, and a `/proc` mounted with `hidepid`, which hides the
`sudo` process from the helper; it then refuses, saying so (the mount's `gid=`
option can exempt a group).

## Without a desktop

Over SSH, on a server, in a container or in CI there is no screen for a dialog.
The request waits for you instead:

- **Inside tmux (3.2 or later):** a popup opens on your tmux session, showing
  the command; type the password there. This is the natural setup for running
  an agent on a remote machine.
- **Anywhere else:** the agent's output says a request is waiting, your other
  terminals get a one-line notice, and you answer from any terminal:

  ```
  $ sudoorbell approve

  Run as root:

  sudo -A apt install curl

  Requested by: codex

  Enter your password to allow it.

  Password (leave empty to deny):
  ```

  `sudoorbell approve --deny` refuses everything waiting.

The password goes from your terminal to `sudo` through a pipe in a private
(`0700`) directory; it is never echoed or written to a file. An unanswered
request gives up after `SUDOORBELL_TIMEOUT` seconds. A Mac reached over SSH
counts as having no desktop.

Two limits:

- Without a display, `sudo` does not call the helper on its own (it only does
  that when `DISPLAY` or `WAYLAND_DISPLAY` is set), so only commands run
  through your shell, where the `sudo` function adds `-A`, get this. A program
  that starts `sudo` directly, not through a shell, still needs `sudo -A`.
- Some agent sandboxes forbid reading process information (Codex's on macOS).
  The helper then cannot check that `sudo` called it, and refuses.

## Touch ID on macOS

macOS can let sudo accept Touch ID. Turn it on with:

```
sed 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local
```

(`sudo_local` survives macOS updates.) With it on, a `sudo` without a terminal
shows Apple's Touch ID prompt first, also for agents and Claude Code's `!`
commands. That prompt has its own **Use Password…**, so:

- **Touch ID** or **Use Password…** in Apple's prompt: sudo runs.
- **Cancel** in Apple's prompt: sudo does not run. No second prompt follows.
- **Touch ID cannot be used** (a Mac without a sensor, the lid closed with no
  Touch ID keyboard): the sudoorbell window asks for the password instead.

Why the shell function changes for this: macOS skips Touch ID when `sudo` is
given `-A`. With Touch ID on, the function starts `sudo` without `-A` and sets
`DISPLAY` (to `sudoorbell`, if it was not set); with no terminal and a
display, `sudo` calls the dialog by itself, after Touch ID. That `DISPLAY` may
reach the command run as root, depending on your sudoers `env_keep`.

Tested on macOS 26.5.1 (MacBook Pro, M3 Pro) from Claude Code's `!`
commands, through the installed shell function: **Use Password…** ran the
command, and **Cancel** stopped it with `sudoorbell: not asking: Touch ID was
cancelled` and no second prompt. A fingerprint worked with the same `sudo`
call (no `-A`, `DISPLAY` set) made by hand. Measured along the way: with `-A`,
no Touch ID prompt appears at all. Not tested on real hardware: a Mac where
Touch ID cannot be used, where the sudoorbell window should take over.

Apple's prompt does not say which command will run; it only says that sudo
wants to run a command as administrator. The sudoorbell window does. If seeing
the command matters more to you than the fingerprint, leave Touch ID off.

## Using it with agents

**Claude Code.** Run `sudo` yourself with the `!` prefix: `! sudo apt install curl`.
The dialog appears and you approve it there. With `--claude-deny`, the agent
itself can no longer run `sudo` (a `Bash(sudo:*)` deny rule in
`~/.claude/settings.json`), so root commands only ever happen when you type
them. Without it, the agent can run `sudo` and each request shows you the
dialog.

**Codex, Cursor and others.** When the agent runs `sudo`, you get the dialog
and decide.

## The Claude Code plugin: approve each sudo command

With `--claude-deny` alone, Claude can never run `sudo`. The plugin keeps that
rule and adds a way through it, one command at a time: when Claude runs a Bash
command that uses `sudo`, the command waits and Claude Code asks you, showing
it.

```
 ☐ sudo
│ Claude wants to run this with sudo:
│
│ sudo id -u
│
│ Touch ID or your password confirms it next, outside Claude Code. Allow it?
❯ 1. Approve
  2. Deny
```

- **Approve**: the command runs through Claude Code's own Bash tool, past the
  deny rule for that one call, and sudoorbell then asks for Touch ID or your
  password as usual. The password never passes through Claude Code.
- **Deny**, Esc, or no one to ask (`claude -p`): the command doesn't run, and
  Claude is told not to retry it. Anything typed into the dialog's free-text
  row also refuses, and is never shown to Claude, in case it was a password.

Every `sudo` the plugin did not approve still meets the deny rule, and so does
every `sudo` when the plugin isn't loaded. The plugin also recognises
`/usr/bin/sudo` and `sudo` inside `$( )`, `( )` and pipelines.

Install it after `sudoorbell install --claude-deny`, which sets up the shell
integration it relies on:

```
/plugin install sudoorbell --marketplace medazizktata/sudoorbell
```

Needs Claude Code 2.1.287 or later (plugins with code, called mods). The
plugin lifts only the `Bash(sudo:*)` rule: a deny from any other rule still
stands. On a Team or Enterprise plan, or a machine with managed settings, deny
rules hold over plugins by default, so there the rule wins and approved
commands are still refused.

Tested in a real Claude Code 2.1.296 session, with the `Bash(sudo:*)` deny
rule in force, auto mode on, and a stand-in `sudo` that runs nothing as root:
Deny kept the command from running; Approve ran it through the shell
function's Touch ID path; and with the plugin's override switched off, the
same Approve was refused by the deny rule. Not yet tested: a real Touch ID
prompt after Approve.

## Claude Code mode: the password asked inside Claude Code

Everything above works for any tool. For Claude Code there is also a mode that
needs no dialog window: a `sudo` tool (an MCP server) whose password prompt
Claude Code itself shows.

```sh
sudoorbell install --claude-mcp --claude-deny           # form inside Claude Code
sudoorbell install --claude-mcp=browser --claude-deny   # local page, hidden field
```

With `--claude-deny` the agent cannot run `sudo` in the shell, so the tool is
its only way to root, and every call needs your password again (it runs
`sudo -k`, ignoring any cached session). When Claude wants to run, say,
`apt-get install curl` as root, it calls the tool and you see:

```
MCP server "sudoorbell" requests your input
Run as root: sudo apt-get install curl
Reason: install curl for the build
❯ * Password: Type something…
  Accept    Decline
```

The password goes from Claude Code to the tool and on to `sudo -S` through a
pipe. The tool's result, which is all the model sees, holds the command's
output and exit code, never the password. A wrong password asks again (up to
three times); Decline or Esc runs nothing.

Two ways to ask, because Claude Code has no hidden input field yet:

| | `form` (default) | `browser` |
|---|---|---|
| where you type | a form inside Claude Code | a page Claude Code opens, on `127.0.0.1` |
| password on screen while typing | **visible** | hidden (`type=password`) |
| passes through Claude Code | yes | no |
| MCP specification | says not to send passwords through forms | the specified way for secrets |

Measured with Claude Code 2.1.287 and 2.1.296 (a fake `sudo`, a dummy
password): in both modes the password was absent from the session transcript,
from Claude Code's MCP log (which records the form answer as `[REDACTED]`) and
from the terminal scrollback once the form closed. In form mode it is plainly
readable on screen while you type, so mind screen sharing and recording. In
browser mode the one-time page address appears in Claude Code's MCP log; it
only lets someone answer that one request while it is open.

Claude Code still asks its usual permission for the tool call, before the
password form. Allow `mcp__sudoorbell__sudo` in `/permissions` if you want the
password form to be the only question.

Needs `python3`. Remove with `sudoorbell uninstall --claude-mcp`.

### Other MCP clients

The tool is a plain MCP server, so any client that supports elicitation can use
it. Tested with a stand-in `sudo` and a dummy password:

| Client | Declares at connect | `form` | `browser` |
|---|---|---|---|
| MCP Python SDK 2.3.0 (reference client) | – | works | works |
| Claude Code 2.1.296 | form + url | works, visible while typed | works, hidden field |
| Codex 0.160.0 | form + url | works, visible while typed; not kept in its session file or logs | declined without showing anything |
| cursor-agent 2026.09.02 (terminal) | form only | declined without showing a form | refused: no URL support |

Register it in another client the way that client adds stdio MCP servers, with
the command `~/.local/share/sudoorbell/mcp/sudoorbell-mcp` and, for browser
mode, the environment variable `SUDOORBELL_MCP_MODE=browser`. For Codex:

```sh
codex mcp add sudoorbell -- ~/.local/share/sudoorbell/mcp/sudoorbell-mcp
```

## How it works

`sudo` can get the password from a helper program instead of a terminal: the
*askpass* program, named by `SUDO_ASKPASS` or by `Path askpass` in
`/etc/sudo.conf`. sudoorbell provides that helper, and two ways for `sudo` to
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
| `SUDOORBELL_TIMEOUT` | `120` | seconds before an unanswered dialog counts as Deny |
| `SUDOORBELL_BACKEND` | auto | force a dialog tool, e.g. `kdialog` |
| `SUDOORBELL_TITLE` | `Administrator access` | window title |
| `SUDOORBELL_NOTIFY` | `1` | without a desktop, `0` stops the notice to your terminals |

## Security

- The password travels from the dialog to `sudo` through a pipe. It is never in
  a command line, an environment variable, a file or the agent's output.
- Approving the dialog is approving the command it shows. Read it.
- `sudo` remembers your password for a few minutes after a success (its
  `timestamp_timeout`). During that window, further `sudo` commands do not ask
  again. That includes commands an agent runs, unless you use `--claude-deny`
  or the agent's own permission rules.
- A program running as you can always draw a fake password dialog of its own.
  No askpass helper can prevent that; sudoorbell only refuses to *be* that
  dialog for anything but `sudo`.

## Development

```sh
sh tests/run.sh              # unit tests: macOS or Linux, no real sudo, no password (MCP server included)
sh tests/e2e/linux/run.sh    # end to end in Docker: real sudo; zenity on Xvfb, then no display at all
sh tests/e2e/minimal/run.sh  # bare images: Debian slim, Alpine/BusyBox, sudo-rs, hidepid
python tests/clients/sdk_client.py  # the MCP server under the official MCP SDK client (pip install mcp)
claude plugin test claude-code      # the Claude Code plugin: no session, no sign-in
claude plugin validate .            # the plugin and its marketplace, as Claude Code reads them
```

The unit tests replace `sudo` and every dialog tool with a stub that records
how it was called. The end-to-end test runs the real thing in a container,
with `xdotool` typing into the dialog: right password, wrong then right, Deny,
timeout, the bash function, and the failure without sudoorbell as a baseline.
A second run has no display: requests answered with `sudoorbell approve` and
in a real tmux popup.
CI runs both, plus `shellcheck`.

## License

MIT
