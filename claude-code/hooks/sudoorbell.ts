import type { Register } from 'claude-code'

// sudoorbell for Claude Code. When Claude runs a Bash command that uses sudo,
// the call waits while you are asked, with the command shown:
//
// - Approve: it runs through Claude Code's own Bash tool, where sudoorbell's
//   shell integration gets the password: Touch ID, the sudoorbell window, or
//   a terminal request. The password never passes through Claude Code.
// - Type password here: a pane takes the password, hidden as in a terminal,
//   and hands it to that one sudo request through `sudoorbell approve
//   --stdin`. Offered only while no other mod hooks the events that would let
//   it read the typing or the hand-over (ui.input, process.run).
// - Deny, or no answer: it does not run.
//
// Approval is for one call. The Bash(sudo:*) deny rule that
// `sudoorbell install --claude-deny` adds still refuses every sudo command
// this mod did not approve, and all of them when the mod is not loaded.

const APPROVE = 'Approve'
const TYPE_HERE = 'Type password here'
const DENY = 'Deny'
const PANE = 'sudoorbell-password'
const FIELD = 'sudoorbell-password-field'
// The rule `sudoorbell install --claude-deny` adds, and other spellings of it.
const SUDO_RULE = /^Bash\(sudo(?:[ :].*)?\)$/
// The events through which another mod could read the password: what is
// typed into the field, and the process the password is handed to.
// prompt.edit too: while a request waits, sudoorbell discards what is typed
// into Claude's prompt, but a mod before it in the chain would see it first.
const WATCHED = ['ui.input', 'process.run', 'prompt.edit']
const REFUSED = 'The user did not approve this sudo command, so it did not run. Do not retry it unless the user asks you to.'

// The calls you approved, by tool_use_id, until they finish.
const approved = new Set<string>()

// Other mods that hook a WATCHED event: while there is one, the field is not
// offered. Filled by scanning the installed plugins once, and by
// plugin.register for every mod that loads later.
const watchers = new Set<string>()
let isScanned = false

// The sudo request the pane is answering, and what has been typed for it.
// The typed text lives here only, and only until it is handed over.
let request: { pid: string; command: string } | null = null
let typed = ''
// What the field holds since it was last drawn. It is drawn with one of two
// invisible characters, alternating, because a redraw with an unchanged value
// leaves what was typed on screen; a changed one clears it. Deleting that
// character is a Backspace.
let fieldText = ''
let flip = false
let note = ''
let isPromptBlocked = false
let attempts = 0
// How to reach sudoorbell, set when a request is served.
let bin = ''
let runtime = ''

export const register: Register = on => {
  on('plugin.register', async ($, e, next) => {
    if (e.name !== $.plugin.name && watches(e.uses.events)) {
      watchers.add(e.name)
    }
    return next(e)
  }).catch(async ($, e, next) => {
    // The check failed: count the plugin as watching, so the field stays off.
    watchers.add(String(e.name ?? '(a plugin)'))
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = String(e.command ?? '')
    if (!runsSudo(command)) {
      return next(e)
    }
    if (!isScanned) {
      await scanPlugins($)
      isScanned = true
    }
    const canType = watchers.size === 0 && request === null
    const options = choices(await setting($, 'claude_password'), canType)
    let answer = DENY
    try {
      answer = await $.ui.ask(question(command, e.agentId !== undefined, canType ? null : [...watchers]), {
        options,
        header: 'sudo',
      })
    } catch {
      // Dismissed, "Chat about this", or nobody to ask (claude -p): refuse.
    }
    if (answer === DENY || !options.includes(answer)) {
      // Never repeat a typed answer: it could be a password typed in the wrong place.
      return { deny: REFUSED }
    }
    approved.add(e.tool_use_id)
    try {
      if (answer === APPROVE) {
        return await next(e)
      }
      return await typeHere($, e, next)
    } finally {
      approved.delete(e.tool_use_id)
    }
  }).catch(async ($, e, next) => {
    // The hook failed. After the call ran, keep its result; before, refuse.
    if (next.called) {
      return next(e)
    }
    return runsSudo(String(e.command ?? ''))
      ? { deny: `sudoorbell could not ask the user (${next.error.kind}), so this sudo command did not run.` }
      : next(e)
  })

  on('tool.check', { tool: 'Bash' }, async ($, e, next) => {
    const decided = await next(e)
    if (e.tool_use_id === undefined || !approved.has(e.tool_use_id)) {
      return decided
    }
    // You approved this very call: lift the sudo deny rule and any ask, but
    // keep a deny that comes from any other rule or check.
    if (decided.decision === 'deny' && !SUDO_RULE.test(decided.rule ?? '')) {
      return decided
    }
    // Claude Code names one rule, the first that matched, so the sudo rule
    // can hide another: `sudo id && curl x` reports Bash(sudo:*) even when
    // curl is denied too. Ask about the command without sudo, and keep any
    // deny that remains.
    const rest = withoutSudo(String((e.input as { command?: unknown }).command ?? ''))
    if (rest.trim() !== '') {
      const other = await $.tool.check({ tool: 'Bash', input: { command: rest } })
      if (other.decision === 'deny') {
        return other
      }
    }
    return { decision: 'allow', reason: 'approved in sudoorbell' }
  }).catch(async ($, e, next) => {
    // The hook failed: the rules' own decision stands, sudo deny rule included.
    return next(e)
  })

  // While a request waits for a password, what is typed into Claude's prompt
  // is thrown away: it never shows, is never queued, never reaches Claude or
  // the transcript. A password typed there by mistake goes nowhere.
  on('prompt.edit', ($, e, next) => {
    if (request === null) {
      return next(e)
    }
    if (!isPromptBlocked) {
      isPromptBlocked = true
      $.ui.invalidate('ui.render')
    }
    return { text: e.text, cursor: e.cursor }
  }).catch(($, e, next) => {
    return request === null ? next(e) : { text: e.text, cursor: e.cursor }
  })

  // The field's keystrokes: kept here and passed on to no one, so a mod
  // after this one in the chain never sees them, and the field is drawn
  // empty again at once, as a terminal shows nothing while you type.
  on('ui.input', { plugin: 'sudoorbell', element: FIELD }, async ($, e) => {
    take(String(e.value ?? ''))
    if (e.kind === 'submit' && request !== null) {
      await handOver($, request.pid, typed)
    }
    $.ui.invalidate('ui.render')
    return { element: FIELD, value: '' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (request === null) {
      return next(e)
    }
    // Drawn with a value unlike the last one, so whatever the field held is
    // gone from the screen.
    flip = !flip
    fieldText = flip ? '\u200b' : '\u200c'
    const { Box, Text, Input, Button } = $.ui.resolve(e)
    const pid = request.pid
    return Box({
      flexDirection: 'column',
      children: [
        Text({ children: ['Run as root: ' + request.command] }),
        ...(note === '' ? [] : [Text({ children: [note] })]),
        ...(isPromptBlocked
          ? [Text({ children: ["Typing in Claude's prompt is blocked and thrown away while sudo waits. Type here."] })]
          : []),
        Text({
          dimColor: true,
          children: [
            typed === ''
              ? 'Typing is hidden, as in a terminal. Enter hands it to sudo; Claude never sees it.'
              : 'Typing is hidden. Enter hands it to sudo; Clear starts over.',
          ],
        }),
        Input({
          key: FIELD,
          label: 'Password',
          value: fieldText,
          autoFocus: true,
          submitLabel: 'to sudo',
          onSubmit: () => {},
        }),
        Box({
          flexDirection: 'row',
          columnGap: 2,
          children: [
            Button({
              key: 'sudoorbell-clear',
              label: 'Clear',
              onPress: () => {
                typed = ''
                $.ui.invalidate('ui.render')
              },
            }),
            Button({
              key: 'sudoorbell-deny',
              label: 'Deny',
              onPress: async () => {
                await refuse($, pid)
              },
            }),
          ],
        }),
      ],
    })
  })
}

// Approved with "Type password here": run the command so that its sudo asks
// sudoorbell's waiting-request mode instead of Touch ID or a window, answer
// each request it makes from the pane, and give back what the command did.
async function typeHere($, e, next) {
  bin = await findSudoorbell($)
  if (bin === '') {
    return { deny: 'sudoorbell is not installed where its Claude Code plugin can find it, so the password cannot be typed here. Ask the user to approve it with Touch ID or the password window instead.' }
  }
  runtime = (await $.env.get('TMPDIR')) ?? '/tmp'
  attempts = 0
  let isDone = false
  const ran = next({ ...e, command: viaRequest(String(e.command), runtime) }).finally(() => {
    isDone = true
  })
  try {
    while (!isDone && !next.signal.aborted) {
      if (request === null) {
        await serveNext($)
      }
      await $.process.run(['sleep', '0.25'], { timeoutMs: 5000 })
    }
  } finally {
    typed = ''
    request = null
    note = ''
    isPromptBlocked = false
    await closePane($)
  }
  return await ran
}

// Picks up the next sudo request waiting for an answer, and opens the pane on it.
async function serveNext($) {
  const pending = await $.process.run([bin, 'approve', '--pending'], { env: { SUDOORBELL_RUNTIME_DIR: runtime }, timeoutMs: 10000 })
  const line = pending.stdout.split('\n').find(l => /^\d+\t/.test(l))
  if (line === undefined) {
    return
  }
  const tab = line.indexOf('\t')
  attempts += 1
  request = { pid: line.slice(0, tab), command: line.slice(tab + 1) }
  typed = ''
  note = attempts > 1 ? 'Wrong password. Attempt ' + attempts + '.' : ''
  await $.ui.open({ id: PANE, title: 'sudoorbell', focus: true })
  $.ui.invalidate('ui.render')
  // The keyboard goes to the field, not Claude's prompt.
  try {
    await $.ui.focus({ requestId: PANE, key: FIELD })
  } catch {
    // the prompt guard still keeps typing away from Claude
  }
}

async function closePane($) {
  try {
    await $.ui.close({ id: PANE })
  } catch {
    // the pane is already gone
  }
}

// Hands the typed password to the sudo request of process `pid`, on the
// standard input of `sudoorbell approve`: never in an argument or the
// environment, and never kept after.
async function handOver($, pid, password) {
  typed = ''
  request = null
  isPromptBlocked = false
  await closePane($)
  try {
    await $.process.run([bin, 'approve', '--pid', pid, '--stdin'], {
      env: { SUDOORBELL_RUNTIME_DIR: runtime },
      stdin: password + '\n',
      timeoutMs: 10000,
    })
  } finally {
    password = ''
  }
}

async function refuse($, pid) {
  typed = ''
  request = null
  isPromptBlocked = false
  await closePane($)
  await $.process.run([bin, 'approve', '--pid', pid, '--deny'], { env: { SUDOORBELL_RUNTIME_DIR: runtime }, timeoutMs: 10000 })
}

// A saved setting (`sudoorbell config`), or '' when it is not set.
async function setting($, key) {
  try {
    const base = (await $.env.get('XDG_CONFIG_HOME')) || ((await $.env.get('HOME')) ?? '') + '/.config'
    return settingIn(await $.fs.read(base + '/sudoorbell/config'), key)
  } catch {
    return ''
  }
}

// Where sudoorbell is: its own install, or Homebrew's.
async function findSudoorbell($) {
  const home = (await $.env.get('HOME')) ?? ''
  const own = (await $.env.get('SUDOORBELL_HOME')) ?? ''
  const candidates = [
    ...(own === '' ? [] : [own + '/bin/sudoorbell']),
    home + '/.local/bin/sudoorbell',
    home + '/.local/share/sudoorbell/bin/sudoorbell',
    '/opt/homebrew/bin/sudoorbell',
    '/usr/local/bin/sudoorbell',
    '/home/linuxbrew/.linuxbrew/bin/sudoorbell',
  ]
  for (const path of candidates) {
    if (await $.fs.exists(path)) {
      return path
    }
  }
  return ''
}

// Reads every enabled plugin's hooks module, as Claude Code itself does (it
// takes the event names from the `on('...')` calls in the source), and notes
// those that hook a WATCHED event. Anything it cannot read counts as watching.
async function scanPlugins($) {
  let list = []
  try {
    const out = await $.process.run(['claude', 'plugin', 'list', '--json'], { timeoutMs: 30000 })
    list = JSON.parse(out.stdout)
  } catch {
    watchers.add('(the other plugins could not be checked)')
    return
  }
  for (const plugin of list) {
    if (plugin.enabled !== true) {
      continue
    }
    const name = String(plugin.id ?? '').split('@')[0]
    if (name === $.plugin.name) {
      continue
    }
    const root = plugin.readFromFolder ?? plugin.installPath
    let modules = []
    try {
      modules = JSON.parse(await $.fs.read(root + '/hooks/hooks.json')).modules ?? []
    } catch {
      continue // no hooks module: not a mod
    }
    for (const module of modules) {
      try {
        if (watches(eventsIn(await $.fs.read(root + '/hooks/' + module)))) {
          watchers.add(name)
        }
      } catch {
        watchers.add(name)
      }
    }
  }
}

/** The event names a hooks module's source registers with `on('...')`. */
export function eventsIn(source: string): string[] {
  return [...source.matchAll(/\bon\(\s*['"`]([^'"`]+)['"`]/g)].map(m => m[1])
}

/** The value of `key` in a sudoorbell config file's text: its last `key = value` line. */
export function settingIn(text: string, key: string): string {
  let value = ''
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*([a-z_]+)\s*=\s*(.*?)\s*$/)
    if (m !== null && m[1] === key) {
      value = m[2]
    }
  }
  return value
}

/**
 * The answers offered, by the `claude_password` setting: `outside` never
 * offers the field, `inside` offers only the field, and `choose` (the
 * default) offers both. The field only while no other mod could read it.
 */
export function choices(claudePassword: string, canType: boolean): string[] {
  if (canType && claudePassword === 'inside') {
    return [TYPE_HERE, DENY]
  }
  if (canType && claudePassword !== 'outside') {
    return [APPROVE, TYPE_HERE, DENY]
  }
  return [APPROVE, DENY]
}

/** Does any of these event patterns cover an event a password could be read from? */
export function watches(patterns: readonly string[]): boolean {
  return patterns.some(pattern => {
    if (pattern.startsWith('!')) {
      return true // an exclusion pattern covers everything else
    }
    const re = new RegExp('^' + pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$')
    return WATCHED.some(event => re.test(event))
  })
}

/** Takes the field's text into `typed`, the field having been empty when last drawn. */
function take(value: string) {
  if (value.startsWith(fieldText)) {
    typed += value.slice(fieldText.length)
  } else if (fieldText.startsWith(value)) {
    typed = typed.slice(0, Math.max(0, typed.length - (fieldText.length - value.length)))
  } else {
    typed += value
  }
  fieldText = value
}

/**
 * The command, run so that its sudo asks sudoorbell's waiting-request mode
 * (no Touch ID, no window, no notices in other terminals) in a folder both
 * ends agree on. A subshell, so nothing it sets outlives the command.
 */
export function viaRequest(command: string, runtimeDir: string): string {
  return `(export SUDOORBELL_BACKEND=terminal SUDOORBELL_TOUCH_ID=off SUDOORBELL_NOTIFY=0 SUDOORBELL_RUNTIME_DIR=${quote(runtimeDir)}; ${command}\n)`
}

function quote(text: string): string {
  return "'" + text.replace(/'/g, `'\\''`) + "'"
}

// Words that can stand before the command a shell segment runs.
const PREFIXES = new Set(['command', 'exec', 'env', 'nohup', 'time', 'nice', 'then', 'do', 'else', 'if', 'while', 'until', '!'])

/** Does the shell command run sudo in any of its parts? */
export function runsSudo(command: string): boolean {
  // Each part that starts a command: after ; && || | & or a newline, and
  // inside ( ), $( ) and backticks.
  for (const segment of command.split(/&&|\|\||\$\(|[;|&\n`(]/)) {
    const words = segment.trim().split(/\s+/).map(w => w.replace(/^\{+/, ''))
    let i = 0
    while (i < words.length && (PREFIXES.has(words[i]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i]) || words[i] === '')) {
      i += 1
    }
    const first = words[i]
    if (first !== undefined && /(?:^|\/)sudo$/.test(first.replace(/^\\/, ''))) {
      return true
    }
  }
  return false
}

// sudo options that take a value, so the value is not read as the command.
const SUDO_VALUE_OPTIONS = new Set(['-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-T', '-U'])

/**
 * The command with each `sudo` and its own options taken out, so the
 * permission rules can judge what it runs: `cd x && sudo -u root make install`
 * becomes `cd x && make install`.
 */
export function withoutSudo(command: string): string {
  return command
    .split(/(&&|\|\||\$\(|[;|&\n`(])/)
    .map((part, index) => {
      if (index % 2 === 1) {
        return part // a separator, kept as it is
      }
      const lead = part.match(/^\s*/)?.[0] ?? ''
      const words = part.trim().split(/\s+/).filter(w => w !== '')
      let i = 0
      while (i < words.length && (PREFIXES.has(words[i]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i]))) {
        i += 1
      }
      if (i < words.length && /(?:^|\/)sudo$/.test(words[i].replace(/^[\\{]+/, ''))) {
        let j = i + 1
        while (j < words.length && words[j].startsWith('-')) {
          const option = words[j]
          j += SUDO_VALUE_OPTIONS.has(option) ? 2 : 1
          if (option === '--') {
            break
          }
        }
        words.splice(i, j - i)
      }
      return words.length > 0 ? lead + words.join(' ') + (part.match(/\s*$/)?.[0] ?? '') : part.replace(/\S+/g, '')
    })
    .join('')
}

/** The question you are asked, naming the command, and why typing here is off when it is. */
export function question(command: string, bySubagent: boolean, watching: readonly string[] | null = null): string {
  const shown = command.length > 2000 ? command.slice(0, 2000) + ' …' : command
  const who = bySubagent ? 'A subagent' : 'Claude'
  const off = watching === null || watching.length === 0
    ? ''
    : `\n\n(Typing the password here is off: ${watching.join(', ')} could read it.)`
  return `${who} wants to run this with sudo:\n\n${shown}\n\nApprove: Touch ID or your password confirms it next, outside Claude Code.${off} Allow it?`
}
