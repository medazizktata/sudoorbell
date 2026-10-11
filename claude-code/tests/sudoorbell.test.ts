import { expect, test } from 'claude-code/testing'
import { eventsIn, question, runsSudo, viaRequest, watches, withoutSudo } from '../hooks/sudoorbell.ts'

// Stands for Claude Code beneath the mod: answers the question with `answer`
// (or dismisses it when `answer` is null), runs Bash as a stub, and records
// what reached it.
function engine(on, answer: string | null) {
  const seen = { asked: [] as string[], ran: [] as string[] }
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') {
      seen.asked.push(e.questions[0].question)
      if (answer === null) {
        return { deny: 'dismissed' }
      }
      return { result: { answers: { [e.questions[0].question]: answer } } }
    }
    seen.ran.push(e.command)
    return { result: { stdout: 'ran', stderr: '', interrupted: false } }
  })
  return seen
}

test('a command without sudo runs with no question', async ($, on) => {
  const seen = engine(on, 'Approve')
  const out = await $.tool.call({ tool: 'Bash', command: 'ls -la' })
  expect(out.deny).toBeUndefined()
  expect(seen.asked).toEqual([])
  expect(seen.ran).toEqual(['ls -la'])
})

test('sudo is asked about, naming the command, and runs once approved', async ($, on) => {
  const seen = engine(on, 'Approve')
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo apt install curl' })
  expect(out.deny).toBeUndefined()
  expect(seen.asked.length).toBe(1)
  expect(seen.asked[0]).toContain('sudo apt install curl')
  expect(seen.ran).toEqual(['sudo apt install curl'])
})

test('Deny refuses the command and it never runs', async ($, on) => {
  const seen = engine(on, 'Deny')
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo rm -rf /opt/thing' })
  expect(out.deny).toContain('did not approve')
  expect(seen.ran).toEqual([])
})

test('a dismissed question refuses the command', async ($, on) => {
  const seen = engine(on, null)
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo true' })
  expect(out.deny).toContain('did not approve')
  expect(seen.ran).toEqual([])
})

test('a typed answer refuses the command and is never repeated', async ($, on) => {
  const seen = engine(on, 'hunter2')
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo true' })
  expect(out.deny).toContain('did not approve')
  expect(out.deny).not.toContain('hunter2')
  expect(seen.ran).toEqual([])
})

test('sudo anywhere in a compound command is asked about', async ($, on) => {
  const seen = engine(on, 'Deny')
  await $.tool.call({ tool: 'Bash', command: 'cd /tmp && make && sudo make install' })
  expect(seen.asked.length).toBe(1)
  expect(seen.ran).toEqual([])
})

test('which commands run sudo', async () => {
  const yes = [
    'sudo true',
    'sudo -u root id',
    'cd x && sudo make install',
    'ls; sudo ls',
    'echo hi | sudo tee /etc/x',
    'FOO=1 sudo env',
    'env FOO=1 sudo id',
    '(sudo ls)',
    'nohup sudo thing',
    '/usr/bin/sudo true',
    'if true; then sudo ls; fi',
    'echo $(sudo cat /etc/shadow)',
  ]
  const no = ['echo sudo', 'sudoku', 'ls sudo', 'grep -r sudo .', 'cat /etc/sudoers.d/x', 'man sudo']
  for (const c of yes) expect([c, runsSudo(c)]).toEqual([c, true])
  for (const c of no) expect([c, runsSudo(c)]).toEqual([c, false])
})

test('withoutSudo leaves what the rules must still judge', async () => {
  const cases: [string, string][] = [
    ['sudo id -u && curl --version', 'id -u && curl --version'],
    ['sudo -u root -g wheel make install', 'make install'],
    ['cd x && sudo -k make install', 'cd x && make install'],
    ['echo hi | sudo tee /etc/x', 'echo hi | tee /etc/x'],
    ['FOO=1 sudo env', 'FOO=1 env'],
    ['/usr/bin/sudo rm -rf /opt/x', 'rm -rf /opt/x'],
    ['echo $(sudo cat /etc/shadow)', 'echo $(cat /etc/shadow)'],
    ['sudo -- -weird', '-weird'],
    ['sudo -v', ''],
    ['ls sudo', 'ls sudo'],
  ]
  for (const [input, want] of cases) expect([input, withoutSudo(input).trim()]).toEqual([input, want])
})

test('the question says who asked and ends as a question', async () => {
  expect(question('sudo id', false)).toContain('Claude wants')
  expect(question('sudo id', true)).toContain('A subagent wants')
  expect(question('sudo id', false).endsWith('?')).toBe(true)
  expect(question('x'.repeat(5000), false).length).toBeLessThan(2300)
})

// The installed plugins as `claude plugin list --json` and their files give
// them: `mods` maps a plugin's folder to its hooks module's source.
function plugins(on, mods: Record<string, string>) {
  const offered: string[][] = []
  const asked: string[] = []
  on('process.run', ($, e) => {
    if (e.argv[0] === 'claude') {
      const list = Object.keys(mods).map(root => ({ id: root + '@test', enabled: true, installPath: '/plugins/' + root }))
      return { value: { exitCode: 0, stdout: JSON.stringify(list), stderr: '' } }
    }
    return { value: { exitCode: 1, stdout: '', stderr: '' } }
  })
  on('fs.read', ($, e) => {
    const root = Object.keys(mods).find(r => e.path.startsWith('/plugins/' + r + '/'))
    if (root === undefined) return { deny: 'missing' }
    if (e.path.endsWith('/hooks/hooks.json')) return { value: JSON.stringify({ modules: ['./mod.ts'] }) }
    return { value: mods[root] }
  })
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') {
      const q = e.questions[0]
      asked.push(q.question)
      offered.push(q.options.map(o => (typeof o === 'string' ? o : o.label)))
      return { result: { answers: { [q.question]: 'Deny' } } }
    }
    return { result: { stdout: 'ran', stderr: '', interrupted: false } }
  })
  return { offered, asked }
}

test('the password field is offered when no other mod could read it', async ($, on) => {
  const seen = plugins(on, { quiet: "on('tool.call', h)\non('ui.render', { component: 'Pane' }, h)" })
  await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(seen.offered[0]).toEqual(['Approve', 'Type password here', 'Deny'])
})

test('the password field is withheld while another mod hooks ui.input', async ($, on) => {
  const seen = plugins(on, { keylogger: "export function register(on) { on('ui.input', h) }" })
  await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(seen.offered[0]).toEqual(['Approve', 'Deny'])
  expect(seen.asked[0]).toContain('keylogger could read it')
})

test('the password field is withheld while another mod hooks process.run, or everything', async ($, on) => {
  const seen = plugins(on, { spawner: "on('process.*', h)", everything: 'on("*", h)' })
  await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(seen.offered[0]).toEqual(['Approve', 'Deny'])
  expect(seen.asked[0]).toContain('spawner')
  expect(seen.asked[0]).toContain('everything')
})

test('typing "Type password here" when it was not offered refuses', async ($, on) => {
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') return { result: { answers: { [e.questions[0].question]: 'Type password here' } } }
    throw new Error('the command must not run')
  })
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(out.deny).toContain('did not approve')
})

test('which event patterns could read a password', async () => {
  expect(watches(['ui.input'])).toBe(true)
  expect(watches(['ui.*'])).toBe(true)
  expect(watches(['process.run'])).toBe(true)
  expect(watches(['*'])).toBe(true)
  expect(watches(['!tool.describe'])).toBe(true)
  expect(watches(['ui.render', 'tool.call', 'ui.press', 'classic.*'])).toBe(false)
  expect(eventsIn("on('ui.input', { plugin: 'x' }, h)\non(\"tool.call\", h)\non(`*`, h)")).toEqual(['ui.input', 'tool.call', '*'])
})

test('the command is sent to the waiting-request mode, inside a subshell', async () => {
  const c = viaRequest('sudo id -u # a comment', "/tmp/it's")
  expect(c.startsWith('(export SUDOORBELL_BACKEND=terminal SUDOORBELL_TOUCH_ID=off SUDOORBELL_NOTIFY=0 ')).toBe(true)
  expect(c).toContain("SUDOORBELL_RUNTIME_DIR='/tmp/it'\\''s'")
  expect(c.endsWith('sudo id -u # a comment\n)')).toBe(true)
})
