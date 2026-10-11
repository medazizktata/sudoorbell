import type { Register } from 'claude-code'

// sudoorbell for Claude Code. When Claude runs a Bash command that uses sudo,
// the call waits while you are asked, with the command shown. Approved, it runs
// through Claude Code's own Bash tool, where sudoorbell's shell integration
// gets the password: Touch ID, the sudoorbell window, or a terminal request.
// The password never passes through Claude Code.
//
// Approval is for one call. The Bash(sudo:*) deny rule that
// `sudoorbell install --claude-deny` adds still refuses every sudo command
// this mod did not approve, and all of them when the mod is not loaded.

const APPROVE = 'Approve'
const DENY = 'Deny'
// The rule `sudoorbell install --claude-deny` adds, and other spellings of it.
const SUDO_RULE = /^Bash\(sudo(?:[ :].*)?\)$/

// The calls you approved, by tool_use_id, until they finish.
const approved = new Set<string>()

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = String(e.command ?? '')
    if (!runsSudo(command)) {
      return next(e)
    }
    let answer = DENY
    try {
      answer = await $.ui.ask(question(command, e.agentId !== undefined), { options: [APPROVE, DENY], header: 'sudo' })
    } catch {
      // Dismissed, "Chat about this", or nobody to ask (claude -p): refuse.
    }
    if (answer !== APPROVE) {
      // Never repeat a typed answer: it could be a password typed in the wrong place.
      return { deny: 'The user did not approve this sudo command, so it did not run. Do not retry it unless the user asks you to.' }
    }
    approved.add(e.tool_use_id)
    try {
      return await next(e)
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

/** The question you are asked, naming the command. */
export function question(command: string, bySubagent: boolean): string {
  const shown = command.length > 2000 ? command.slice(0, 2000) + ' …' : command
  const who = bySubagent ? 'A subagent' : 'Claude'
  return `${who} wants to run this with sudo:\n\n${shown}\n\nTouch ID or your password confirms it next, outside Claude Code. Allow it?`
}
