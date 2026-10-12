import { expect, test } from 'claude-code/testing'
import { choices, clientOn, edited, newTheme, outcome, shown, withBorder, withoutShown, eventsIn, question, runsSudo, settingIn, viaRequest, watches, withoutSudo } from '../hooks/sudoorbell.ts'

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

test('the password field is withheld while another mod hooks prompt.edit', async ($, on) => {
  const seen = plugins(on, { keylogger: "export function register(on) { on('prompt.edit', h) }" })
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
  expect(watches(['prompt.edit'])).toBe(true)
  expect(watches(['prompt.*'])).toBe(true)
  expect(watches(['process.run'])).toBe(true)
  expect(watches(['ui.input', 'prompt.submit'])).toBe(false)
  expect(watches(['*'])).toBe(true)
  expect(watches(['!tool.describe'])).toBe(true)
  expect(watches(['ui.render', 'tool.call', 'ui.press', 'classic.*'])).toBe(false)
  expect(eventsIn("on('ui.input', { plugin: 'x' }, h)\non(\"tool.call\", h)\non(`*`, h)")).toEqual(['ui.input', 'tool.call', '*'])
})

test('the command is sent to the waiting-request mode, inside a subshell', async () => {
  const c = viaRequest('sudo id -u # a comment', "/tmp/it's")
  expect(c.startsWith("(export SUDOORBELL_BACKEND=terminal SUDOORBELL_TOUCH_ID=off SUDOORBELL_NOTIFY=0 SUDOORBELL_ANSWERED_IN='Claude Code' ")).toBe(true)
  expect(c).toContain("SUDOORBELL_RUNTIME_DIR='/tmp/it'\\''s'")
  expect(c.endsWith('sudo id -u # a comment\n)')).toBe(true)
})

test('the claude_password setting picks the answers offered', async () => {
  expect(choices('', true)).toEqual(['Approve', 'Type password here', 'Deny'])
  expect(choices('choose', true)).toEqual(['Approve', 'Type password here', 'Deny'])
  expect(choices('outside', true)).toEqual(['Approve', 'Deny'])
  expect(choices('inside', true)).toEqual(['Type password here', 'Deny'])
  // The field is never offered while another mod could read it, whatever the setting.
  expect(choices('inside', false)).toEqual(['Approve', 'Deny'])
  expect(settingIn('# x\nclaude_password = inside\ntimeout=9\nclaude_password=outside  \n', 'claude_password')).toBe('outside')
  expect(settingIn('timeout = 9\n', 'claude_password')).toBe('')
})

test('with claude_password inside, Approve is not an answer', async ($, on) => {
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/me' : undefined }))
  on('fs.read', ($, e) => (e.path === '/home/me/.config/sudoorbell/config' ? { value: 'claude_password = inside\n' } : { deny: 'missing' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '[]', stderr: '' } }))
  const offered: string[][] = []
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') {
      offered.push(e.questions[0].options.map(o => (typeof o === 'string' ? o : o.label)))
      return { result: { answers: { [e.questions[0].question]: 'Approve' } } }
    }
    throw new Error('the command must not run')
  })
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(offered[0]).toEqual(['Type password here', 'Deny'])
  expect(out.deny).toContain('did not approve')
})

test('typing into the prompt box builds the password, which only ever shows as masks', async () => {
  let pw = ''
  for (const ch of 'hunter2') pw = edited(pw, 0, ch)
  expect(pw).toBe('hunter2')
  expect(edited(pw, 1, '')).toBe('hunter')        // Backspace
  expect(edited(pw, 99, '')).toBe('')             // a kill of the whole line
  expect(edited('ab', 0, 'cd\nef')).toBe('abcdef') // a paste, line break dropped
  expect(edited('abc', 1, 'X')).toBe('abX')       // a replacement
})

test('the clients settings decide whether the plugin acts for Claude', async () => {
  expect(clientOn('', '', 'claude')).toBe(true)
  expect(clientOn('all', '', 'claude')).toBe(true)
  expect(clientOn('', 'cursor-agent', 'claude')).toBe(true)
  expect(clientOn('', 'cursor-agent,claude', 'claude')).toBe(false)
  expect(clientOn('codex', '', 'claude')).toBe(false)
  expect(clientOn('codex, claude', '', 'claude')).toBe(true)
})

test('with claude switched off, the plugin asks nothing and lets the rules decide', async ($, on) => {
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/me' : undefined }))
  on('fs.read', ($, e) => (e.path === '/home/me/.config/sudoorbell/config' ? { value: 'clients_off = claude\n' } : { deny: 'missing' }))
  const asked: string[] = []
  on('tool.call', ($, e) => {
    if (e.tool === 'AskUserQuestion') {
      asked.push(e.questions[0].question)
      return { result: { answers: { [e.questions[0].question]: 'Deny' } } }
    }
    return { result: { stdout: 'went to the rules', stderr: '', interrupted: false } }
  })
  const out = await $.tool.call({ tool: 'Bash', command: 'sudo id -u' })
  expect(asked).toEqual([])
  expect(out.deny).toBeUndefined()
})

test('after the password, the message says what sudo did', async () => {
  expect(outcome(true, '')).toContain('the command is running')
  expect(outcome(false, 'Sorry, try again.\nsudo: 3 incorrect password attempts')).toContain('sudo gave up after 3 tries')
  expect(outcome(false, 'uid=0')).toContain('the command has finished')
})

test('the prompt box shows a painted mask per character, never the password', async () => {
  expect(shown('')).toMatchObject({ text: '🔒 ', cursor: 3 })
  expect(shown('pass word')).toMatchObject({ text: '🔒 •••••••••', cursor: 12 })
  expect(shown('pass word').decorations).toEqual([{ start: 0, end: 12, color: 'warning', bold: true }])
})

test('the history loses only the entries Enter left in the field', async () => {
  const lines = [
    JSON.stringify({ display: 'run the tests', sessionId: 's' }),
    JSON.stringify({ display: '••••••••', sessionId: 's' }),
    JSON.stringify({ display: 'what does •••••••• mean', sessionId: 's' }),
    'not json ••••••••',
    JSON.stringify({ display: '•••', sessionId: 's' }),
    JSON.stringify({ display: '🔒 •••', sessionId: 's' }),
    JSON.stringify({ display: '🔒', sessionId: 's' }),
    JSON.stringify({ display: '🔒 the vault', sessionId: 's' }),
    '',
  ]
  const kept = withoutShown(lines.join('\n')).split('\n')
  expect(kept).toEqual([lines[0], lines[2], lines[3], lines[7], ''])
})

test('the plugin theme starts like the theme in use', async () => {
  expect(JSON.parse(newTheme('light'))).toEqual({ name: 'sudoorbell', base: 'light', overrides: {} })
  expect(JSON.parse(newTheme('auto')).base).toBe('dark')
  expect(JSON.parse(newTheme('custom:mine')).base).toBe('dark')
})

test('the prompt border turns amber while the field is open, and back', async () => {
  const plain = JSON.stringify({ name: 'sudoorbell', base: 'dark', overrides: { claude: '#bd93f9' } })
  const on = withBorder(plain, true) ?? ''
  expect(JSON.parse(on).overrides).toEqual({ claude: '#bd93f9', promptBorder: '#ffaf00' })
  expect(withBorder(on, true)).toBeNull()
  expect(JSON.parse(withBorder(on, false) ?? '').overrides).toEqual({ claude: '#bd93f9' })
  expect(withBorder(plain, false)).toBeNull()
  // A border the person chose is theirs: not taken off.
  expect(withBorder(JSON.stringify({ base: 'dark', overrides: { promptBorder: '#00ff00' } }), false)).toBeNull()
  expect(withBorder('not json', true)).toBeNull()
  expect(withBorder('[1]', true)).toBeNull()
})
