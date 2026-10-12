import type { Register } from 'claude-code'

// sudoorbell for Claude Code. When Claude runs a Bash command that uses sudo,
// the call waits while you are asked, with the command shown:
//
// - Approve: it runs through Claude Code's own Bash tool, where sudoorbell's
//   shell integration gets the password: Touch ID, the sudoorbell window, or
//   a terminal request. The password never passes through Claude Code.
// - Type password here: a panel above the prompt asks for the password, and
//   Claude's own prompt box takes it, masked; Enter hands it to that one sudo
//   request through `sudoorbell approve --stdin`, Esc cancels. Offered only
//   while no other mod hooks the events that would let it read the typing or
//   the hand-over (prompt.edit, process.run).
// - Deny, or no answer: it does not run.
//
// Approval is for one call. The Bash(sudo:*) deny rule that
// `sudoorbell install --claude-deny` adds still refuses every sudo command
// this mod did not approve, and all of them when the mod is not loaded.

const APPROVE = 'Approve'
const TYPE_HERE = 'Type password here'
const DENY = 'Deny'
const MASK = '•'
// The rule `sudoorbell install --claude-deny` adds, and other spellings of it.
const SUDO_RULE = /^Bash\(sudo(?:[ :].*)?\)$/
// The events through which another mod could read the password: each edit of
// the prompt box, where it is typed, and the process it is handed to.
const WATCHED = ['prompt.edit', 'process.run']
const REFUSED = 'The user did not approve this sudo command, so it did not run. Do not retry it unless the user asks you to.'

// The calls you approved, by tool_use_id, until they finish.
const approved = new Set<string>()

// Other mods that hook a WATCHED event: while there is one, the field is not
// offered. Filled by scanning the installed plugins once, and by
// plugin.register for every mod that loads later.
const watchers = new Set<string>()
let isScanned = false

// The sudo request waiting for a password, and what has been typed for it.
// The typed text lives here only, and only until it is handed over; the
// prompt box shows one mask character per character typed.
let request: { pid: string; command: string } | null = null
let typed = ''
let note = ''
let attempts = 0
// The draft that was in the prompt box when a request took it over, given
// back afterwards; and whether the box still shows a mask to clear.
let draft: { text: string; cursor: number } | null = null
let isBoxDirty = false
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
    // `sudoorbell client off claude`: this plugin stands aside, and the
    // command meets the permission rules as if it were not installed.
    if (!clientOn(await setting($, 'clients'), await setting($, 'clients_off'), 'claude')) {
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

  // While a request waits, the prompt box is the password field: each edit
  // goes into the password, never into the box, which shows only masks. So
  // nothing typed then is shown, queued, or sent to Claude.
  on('prompt.edit', ($, e, next) => {
    if (request === null) {
      return next(e)
    }
    typed = edited(typed, e.end - e.start, e.inputText)
    isBoxDirty = true
    return { text: MASK.repeat(typed.length), cursor: typed.length }
  }).catch(($, e, next) => {
    return request === null ? next(e) : { text: MASK.repeat(typed.length), cursor: typed.length }
  })

  // Enter: the password goes to sudo, and the prompt never enters. Enter with
  // nothing typed denies.
  on('prompt.submit', async ($, e, next) => {
    if (request === null) {
      return next(e)
    }
    const pid = request.pid
    const password = typed
    if (password === '') {
      await refuse($, pid)
      return { drop: 'sudoorbell: nothing was typed, so sudo was denied.' }
    }
    await handOver($, pid, password)
    return { drop: 'sudoorbell: your password went to sudo. Claude never saw it.' }
  }).catch(async ($, e, next) => {
    // Never let a prompt typed while sudo waits through to Claude.
    return request === null ? next(e) : { drop: 'sudoorbell: could not hand the password over; sudo will time out.' }
  })

  // The panel above the prompt while a request waits.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (request === null) {
      return next(e)
    }
    const { Box, Text } = $.ui.resolve(e)
    return Box({
      flexDirection: 'column',
      borderStyle: 'round',
      paddingX: 1,
      children: [
        Text({ bold: true, children: ['🔐 Sudo Authentication Required'] }),
        Text({ children: ['Run as root: ' + request.command] }),
        ...(note === '' ? [] : [Text({ color: 'yellow', children: [note] })]),
        Text({ children: ['Password: type it in the prompt below (shown as ' + MASK + ').'] }),
        Text({ dimColor: true, children: ['Press Enter to submit, Escape to cancel. Enter with nothing typed denies.'] }),
        Text({ dimColor: true, italic: true, children: ['Your password goes to sudo only. It is never shown or sent to Claude.'] }),
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
        if (isBoxDirty) {
          // The box still shows the masks a dropped prompt put back.
          isBoxDirty = false
          await $.prompt.fill({ text: '' })
        }
        await serveNext($)
      }
      await $.process.run(['sleep', '0.25'], { timeoutMs: 5000 })
    }
  } finally {
    if (request !== null) {
      // Esc, or the command ended: the waiting sudo gets a no.
      try {
        await refuse($, request.pid)
      } catch {
        // its request is gone already
      }
    }
    typed = ''
    request = null
    note = ''
    $.ui.invalidate('ui.render')
    if (draft !== null) {
      const back = draft
      draft = null
      isBoxDirty = false
      await $.prompt.fill({ text: back.text })
    }
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
  if (draft === null) {
    // Keep what was in the prompt box, to give it back afterwards.
    draft = await $.prompt.read()
  }
  typed = ''
  note = attempts > 1 ? 'Sorry, try again. Attempt ' + attempts + ' of 3.' : ''
  request = { pid: line.slice(0, tab), command: line.slice(tab + 1) }
  await $.prompt.fill({ text: '' })
  $.ui.invalidate('ui.render')
}

// Hands the typed password to the sudo request of process `pid`, on the
// standard input of `sudoorbell approve`: never in an argument or the
// environment, and never kept after.
async function handOver($, pid, password) {
  typed = ''
  request = null
  isBoxDirty = true
  $.ui.invalidate('ui.render')
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
  isBoxDirty = true
  $.ui.invalidate('ui.render')
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

/** Is sudoorbell on for client `name`, by the `clients` and `clients_off` settings? */
export function clientOn(only: string, off: string, name: string): boolean {
  const list = (text: string) => text.split(',').map(x => x.trim()).filter(x => x !== '')
  if (list(off).includes(name)) {
    return false
  }
  return only === '' || only === 'all' || list(only).includes(name)
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

/**
 * The password after one edit of the prompt box: `removed` characters taken
 * off the end (Backspace, a kill), then `inserted` added (typing, a paste;
 * line breaks dropped). The box only ever holds masks, so where in it the
 * edit falls does not matter.
 */
export function edited(password: string, removed: number, inserted: string): string {
  const kept = removed > 0 ? password.slice(0, Math.max(0, password.length - removed)) : password
  return kept + inserted.replace(/[\r\n]/g, '')
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
