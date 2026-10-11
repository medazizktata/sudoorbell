import { expect, test } from 'claude-code/testing'
import { question, runsSudo, withoutSudo } from '../hooks/sudoorbell.ts'

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
