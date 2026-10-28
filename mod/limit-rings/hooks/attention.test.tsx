import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import type { Attention } from '../types'
import {
  ATTENTION_TEXT,
  bandSessions,
  markdownText,
  minutesWaiting,
  nextState,
  parseAttention,
  shortTitle,
  stateFileText,
  type AttentionEvent,
  type Tracker,
} from './attention'

const t0 = 1_760_958_000_000
const working: Tracker = { state: 'working', since: t0 }
const step = (t: Tracker, ev: AttentionEvent) => nextState(t, ev, t0 + 5000)

// One test per row of the transitions table in docs/specs/001-attention-bell.md.

test('a prompt or a main-loop turn start is work', () => {
  const done: Tracker = { state: 'done', since: t0 }
  expect(step(done, { kind: 'prompt.submit' })).toEqual({ state: 'working', since: t0 + 5000 })
  expect(step(done, { kind: 'turn.start' })).toEqual({ state: 'working', since: t0 + 5000 })
  expect(step(done, { kind: 'turn.start', agentId: 'a1' })).toBe(done)
})

test('a permission prompt waits for permission, a question tool for an answer', () => {
  expect(step(working, { kind: 'permission', tool: 'Bash' })).toEqual({
    state: 'permission', since: t0 + 5000, waitingTool: 'Bash',
  })
  expect(step(working, { kind: 'permission', tool: 'AskUserQuestion' }).state).toBe('question')
  expect(step(working, { kind: 'permission', tool: 'ExitPlanMode' }).state).toBe('question')
})

test('a question tool waits for an answer before it runs', () => {
  expect(step(working, { kind: 'tool.start', tool: 'AskUserQuestion' })).toEqual({
    state: 'question', since: t0 + 5000, waitingTool: 'AskUserQuestion',
  })
  expect(step(working, { kind: 'tool.start', tool: 'Bash' })).toBe(working)
})

test('the waiting call ending is the answer; another call ending is not', () => {
  const asked: Tracker = { state: 'permission', since: t0, waitingTool: 'Bash' }
  expect(step(asked, { kind: 'tool.end', tool: 'Bash' })).toEqual({ state: 'working', since: t0 + 5000 })
  expect(step(asked, { kind: 'tool.end', tool: 'Read' })).toBe(asked)
  expect(step(working, { kind: 'tool.end', tool: 'Bash' })).toBe(working)
})

test('a main-loop turn that ends is done unless the person stopped it', () => {
  for (const reason of ['answer', 'refusal', 'error']) {
    expect(step(working, { kind: 'turn.complete', reason }).state).toBe('done')
  }
  expect(step(working, { kind: 'turn.complete', reason: 'aborted' })).toBe(working)
  expect(step(working, { kind: 'turn.complete', reason: 'answer', agentId: 'a1' })).toBe(working)
})

test('a session that ends is ended', () => {
  expect(step(working, { kind: 'session.end' }).state).toBe('ended')
})

test('since stays while the state does', () => {
  const asked: Tracker = { state: 'permission', since: t0, waitingTool: 'Bash' }
  expect(step(asked, { kind: 'permission', tool: 'Bash' })).toBe(asked)
  expect(step(asked, { kind: 'permission', tool: 'Write' })).toEqual({
    state: 'permission', since: t0, waitingTool: 'Write',
  })
})

test('the state file', () => {
  expect(JSON.parse(stateFileText('cli-1', { state: 'done', since: t0 + 400 }))).toEqual({
    session_id: 'cli-1', state: 'done', since: t0 / 1000,
  })
})

const link = (n: number) => `claude://claude.ai/epitaxy/local_0000000${n}-aaaa-bbbb-cccc-dddddddddddd`
const entry = (n: number, state = 'permission') => ({
  id: `local_${n}`, cli_id: `cli-${n}`, title: `Session ${n}`, state, since: t0 / 1000 - n, link: link(n),
})

test('reads the gathered list and keeps only links into the Claude app', () => {
  const text = JSON.stringify({
    updated_at: t0 / 1000,
    sessions: [
      entry(1),
      entry(2, 'done'),
      { ...entry(3), link: 'file:///Applications/Calculator.app' },
      { ...entry(4), state: 'working' },
      { ...entry(5), title: 7 },
    ],
  })
  const a = parseAttention(text, t0 + 1000)
  expect(a?.measuredAt).toBe(t0)
  expect(a?.sessions.map(s => s.cliId)).toEqual(['cli-1', 'cli-2'])
  expect(a?.sessions[0]).toEqual({
    id: 'local_1', cliId: 'cli-1', title: 'Session 1', state: 'permission', since: t0 - 1000, link: link(1),
  })
  expect(parseAttention('nope', t0)).toBe(null)
  expect(parseAttention('{"sessions":3}', t0)).toBe(null)
  expect(parseAttention('{"sessions":[]}', t0)?.measuredAt).toBe(t0)
})

const five: Attention = parseAttention(JSON.stringify({ updated_at: t0 / 1000, sessions: [1, 2, 3, 4, 5].map(n => entry(n)) }), t0)!

test('the band leaves out its own session and counts what does not fit', () => {
  const { shown, hidden, isBlocking } = bandSessions(five, 'cli-2')
  expect(shown.map(s => s.cliId)).toEqual(['cli-1', 'cli-3', 'cli-4'])
  expect(hidden).toBe(1)
  expect(isBlocking).toBe(true)
  expect(bandSessions(null, 'cli-1')).toEqual({ shown: [], hidden: 0, isBlocking: false })
})

test('heading, minutes and the rest in both languages', () => {
  expect([1, 2, 5, 11, 21].map(ATTENTION_TEXT.ru.header)).toEqual(
    ['1 ждёт ответа', '2 ждут ответа', '5 ждут ответа', '11 ждут ответа', '21 ждёт ответа'])
  expect(ATTENTION_TEXT.en.header(3)).toBe('3 waiting for you')
  expect(ATTENTION_TEXT.ru.more(2)).toBe('ещё 2')
  expect(ATTENTION_TEXT.en.minutes(4)).toBe('4 min')
  expect(minutesWaiting(t0, t0 + 119_000)).toBe(1)
  expect(minutesWaiting(t0, t0 - 5000)).toBe(0)
})

test('a title stays one link in markdown', () => {
  expect(markdownText('Fix [bug] (urgent) *now*')).toBe('Fix \\[bug\\] \\(urgent\\) \\*now\\*')
  expect(markdownText('Зона: анимации бойцов')).toBe('Зона: анимации бойцов')
})

test('titles', () => {
  expect(shortTitle('  ', 'ru')).toBe('Сессия без названия')
  expect(shortTitle('', 'en')).toBe('Untitled session')
  expect(shortTitle('База персонажей из конструктора Space Marine 2', 'ru')).toBe('База персонажей из конструктора Space Marine 2')
  expect(shortTitle('x'.repeat(70), 'en')).toBe('x'.repeat(59) + '…')
  expect(shortTitle('Пепельная дорога', 'ru')).toBe('Пепельная дорога')
})

// The engine beneath: HOME, the session's id and the file writes, recorded.
function engine(on: On, writes: { path: string; text: string }[]) {
  mock.clock(on)
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? '/Users/t' : undefined }))
  on('session.id', () => ({ value: 'cli-own' }))
  on('fs.write', (_, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('tool.call', () => ({ result: {} }))
  on('classic.PermissionRequest', () => ({}))
}

test('a permission prompt and its answer reach the state file', async ($, on) => {
  const writes: { path: string; text: string }[] = []
  engine(on, writes)
  await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'ls' } })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(writes.map(w => w.path)).toEqual(['/Users/t/.claude/attention/cli-own.json', '/Users/t/.claude/attention/cli-own.json'])
  expect(writes.map(w => JSON.parse(w.text).state)).toEqual(['permission', 'working'])
})

test('a question reaches the state file once', async ($, on) => {
  const writes: { path: string; text: string }[] = []
  engine(on, writes)
  await $.classic.PermissionRequest({ tool_name: 'AskUserQuestion', tool_input: {} })
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] })
  expect(writes.map(w => JSON.parse(w.text).state)).toEqual(['question', 'working'])
})

test('the band lists the other waiting sessions as links that open them', async ($, on) => {
  const clock = mock.clock(on)
  const runs: (readonly string[])[] = []
  on('session.id', () => ({ value: 'cli-2' }))
  on('process.run', (_, e) => {
    runs.push(e.argv)
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('state.get', ($, e, next) =>
    e.plugin === 'limit-rings' && e.key === 'attention'
      ? { value: { value: { ...five, measuredAt: clock.now() }, version: 1 } }
      : next(e))
  const ui = await $.ui.mount({
    plugin: 'limit-rings',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: {
      hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120,
      scroll: { offset: 0, bodyRows: 19 }, view: {},
    },
  })
  expect((await ui.find({ type: 'Text', text: /waiting/ }))?.text).toBe('4 waiting for you')
  const rows = await ui.findAll({ type: 'Markdown' })
  expect(rows.map(r => r.key)).toEqual(['attention-open-local_1', 'attention-open-local_3', 'attention-open-local_4'])
  expect((rows[1]?.props as { text: string }).text).toBe('[Session 3](https://limit-rings.invalid/open/local_3)')
  await ui.press({ key: 'attention-open-local_3', link: { href: 'https://limit-rings.invalid/open/local_3' } })
  expect(runs).toEqual([['open', link(3)]])
  expect(await ui.find({ type: 'Text', text: /done|permission/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^1 more$/ }))?.text).toBe('1 more')
  expect(await ui.findAll({ type: 'Button' })).toHaveLength(0)
  await ui.unmount()
})
