import { expect, mock, test } from 'claude-code/testing'

import { COLORS } from './limits'
import { formatSize, parseSystem, systemTexts, usedRingSvg } from './system'

const GIB = 1_073_741_824
const now = 1_760_958_000_000

// What `ClaudeLimits --system-json` printed on a machine short of memory and disk.
const json = JSON.stringify({
  updated_at: now / 1000 - 3,
  memory: {
    total: 48 * GIB, used: 42 * GIB, compressed: 20.9 * GIB, swap_used: 28.5 * GIB,
    pressure: 'warn', level: 'danger',
  },
  disk: { total: 994_662_584_320, available: 19_200_000_000, level: 'danger' },
  top: [
    { name: 'ChatGPT', count: 292, footprint: 25_340_000_000 },
    { name: 'Xogot', count: 1, footprint: 2 * GIB },
  ],
})

test('parses the app output', () => {
  const s = parseSystem(json, now)
  expect(s?.measuredAt).toBe(now - 3000)
  expect(s?.memory).toEqual({
    total: 48 * GIB, used: 42 * GIB, compressed: 20.9 * GIB, swapUsed: 28.5 * GIB, pressure: 'warn', level: 'danger',
  })
  expect(s?.disk).toEqual({ total: 994_662_584_320, available: 19_200_000_000, level: 'danger' })
  expect(s?.top.length).toBe(2)
})

test('rejects what is not a reading', () => {
  expect(parseSystem('not json', now)).toBe(null)
  expect(parseSystem('{"top":[]}', now)).toBe(null)
  expect(parseSystem('{"disk":{"total":10,"available":5,"level":"odd"}}', now)?.disk?.level).toBe('ok')
  expect(parseSystem('{"disk":{"total":10,"available":5}}', now)?.measuredAt).toBe(now)
})

test('sizes', () => {
  expect(formatSize(45_500_000_000, 'GB', 'ru')).toBe('45,5')
  expect(formatSize(48 * GIB, 'GiB', 'en')).toBe('48')
  expect(formatSize(994_700_000_000, 'GB', 'en')).toBe('995')
})

test('texts in both languages', () => {
  const s = parseSystem(json, now)!
  const ru = systemTexts(s, 'ru')
  expect(ru.memory).toBe('Память 88% · своп 28,5 ГБ')
  expect(ru.disk).toBe('Диск: свободно 19,2 ГБ')
  expect(ru.memoryDetail).toBe('Память: занято 42 из 48 ГБ · сжато 20,9 ГБ · своп 28,5 ГБ · давление: высокое')
  expect(ru.diskDetail).toBe('Диск: свободно 19,2 из 995 ГБ')
  expect(ru.hints.length).toBe(2)
  expect(ru.top).toEqual(['ChatGPT ×292 · 23,6 ГБ', 'Xogot · 2 ГБ'])
  const en = systemTexts(s, 'en')
  expect(en.memory).toBe('Memory 88% · swap 28.5 GB')
  expect(en.disk).toBe('Disk: free 19.2 GB')
})

test('ring colour follows the level, grey when stale', () => {
  expect(usedRingSvg(42, 48, 'danger', false)).toContain(COLORS.danger)
  expect(usedRingSvg(42, 48, 'danger', false)).toContain('>88<')
  expect(usedRingSvg(42, 48, 'ok', true)).toContain(COLORS.muted)
  expect(usedRingSvg(42, 48, 'ok', true)).not.toContain(COLORS.ok)
})

test('the band shows memory and disk and opens the details on press', async ($, on) => {
  const clock = mock.clock(on)
  const reading = { ...parseSystem(json, now)!, measuredAt: clock.now() }
  on('state.get', ($, e, next) =>
    e.plugin === 'limit-rings' && e.key === 'system' ? { value: { value: reading, version: 1 } } : next(e))
  const ui = await $.ui.mount({
    plugin: 'limit-rings',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: {
      hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120,
      scroll: { offset: 0, bodyRows: 19 }, view: {},
    },
  })
  expect(await ui.find({ type: 'Text', text: /swap 28\.5 GB/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /free 19\.2 GB/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /ChatGPT/ })).toBeUndefined()
  await ui.press({ key: 'system-details' })
  expect(await ui.find({ type: 'Text', text: /ChatGPT ×292 · 23\.6 GB/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /pressure: high/ })).toBeDefined()
  await ui.press({ key: 'memory-toggle' })
  expect(await ui.find({ type: 'Text', text: /ChatGPT/ })).toBeUndefined()
  await ui.unmount()
})
