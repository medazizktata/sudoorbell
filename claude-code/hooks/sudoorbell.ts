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
    // keep a deny that comes from any other rule.
    if (decided.decision === 'deny' && !SUDO_RULE.test(decided.rule ?? '')) {
      return decided
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

/** The question you are asked, naming the command. */
export function question(command: string, bySubagent: boolean): string {
  const shown = command.length > 2000 ? command.slice(0, 2000) + ' …' : command
  const who = bySubagent ? 'A subagent' : 'Claude'
  return `${who} wants to run this with sudo:\n\n${shown}\n\nTouch ID or your password confirms it next, outside Claude Code. Allow it?`
}
