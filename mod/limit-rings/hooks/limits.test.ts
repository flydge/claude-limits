import { expect, test } from 'claude-code/testing'

import {
  COLORS,
  FIVE_HOUR_MS,
  SEVEN_DAY_MS,
  formatClock,
  resolveLang,
  forecastExhaustion,
  levelColor,
  limitsFileText,
  ringSvg,
  toLimits,
  windowText,
} from './limits'

// Local times, so the expectations hold in any time zone.
const now = new Date(2025, 9, 20, 11, 0).getTime() // Mon 20 Oct 2025 11:00
const at = (h: number, m: number, day = 20) => new Date(2025, 9, day, h, m).getTime()

test('reads both windows from the engine', () => {
  const limits = toLimits(
    [
      { kind: 'five_hour', percentUsed: 42.5, resetsAt: new Date(at(13, 10)).toISOString() },
      { kind: 'seven_day', percentUsed: 18, resetsAt: new Date(at(14, 0, 24)).toISOString() },
      { kind: 'spend_limit', percentUsed: 5 },
    ],
    now,
  )
  expect(limits).toEqual({
    measuredAt: now,
    fiveHour: { percentUsed: 42.5, resetsAt: at(13, 10) },
    sevenDay: { percentUsed: 18, resetsAt: at(14, 0, 24) },
  })
})

test('no windows means no reading', () => {
  expect(toLimits([], now)).toBe(null)
  expect(toLimits([{ kind: 'five_hour', percentUsed: 3 }], now)).toBe(null)
})

test('file text matches what the status line script writes', () => {
  const text = limitsFileText({ measuredAt: 1_760_958_000_500, fiveHour: { percentUsed: 42, resetsAt: 1_760_965_800_000 } })
  expect(JSON.parse(text)).toEqual({ updated_at: 1_760_958_000, five_hour: { used_percentage: 42, resets_at: 1_760_965_800 } })
})

test('thresholds', () => {
  expect(levelColor(59.9)).toBe(COLORS.ok)
  expect(levelColor(60)).toBe(COLORS.warn)
  expect(levelColor(84.9)).toBe(COLORS.warn)
  expect(levelColor(85)).toBe(COLORS.danger)
})

test('ring states', () => {
  const normal = ringSvg({ percentUsed: 62, resetsAt: now + 60_000 }, now)
  expect(normal).toContain('>62</text>')
  expect(normal).toContain(`stroke="${COLORS.warn}"`)
  expect(ringSvg({ percentUsed: 99.75, resetsAt: now + 60_000 }, now)).toContain('>99</text>')
  const full = ringSvg({ percentUsed: 104, resetsAt: now + 60_000 }, now)
  expect(full).toContain('>!</text>')
  expect(full).toContain(`stroke="${COLORS.danger}"`)
  expect(ringSvg({ percentUsed: 62, resetsAt: now }, now)).toContain('>–</text>')
  expect(ringSvg(undefined, now)).toContain('>–</text>')
})

test('clock text', () => {
  expect(formatClock(at(13, 10), now, 'ru')).toBe('13:10')
  expect(formatClock(at(14, 0, 24), now, 'ru')).toBe('пт 14:00')
})

test('forecast', () => {
  const fast = { percentUsed: 62, resetsAt: now + 3 * 3_600_000 } // 2h into the 5h window
  expect(Math.round(forecastExhaustion(fast, FIVE_HOUR_MS, now) ?? 0)).toBe(Math.round(now + (38 * 7_200_000) / 62))
  expect(forecastExhaustion({ percentUsed: 30, resetsAt: now + FIVE_HOUR_MS - 300_000 }, FIVE_HOUR_MS, now)).toBe(undefined)
  expect(forecastExhaustion({ percentUsed: 18, resetsAt: now + 356_400_000 }, SEVEN_DAY_MS, now)).toBe(undefined)
  expect(forecastExhaustion({ percentUsed: 0, resetsAt: now + 3 * 3_600_000 }, FIVE_HOUR_MS, now)).toBe(undefined)
})

test('window text', () => {
  expect(windowText({ percentUsed: 62, resetsAt: at(14, 0) }, FIVE_HOUR_MS, now, 'ru')).toEqual({
    detail: 'сброс 14:00',
    warning: 'кончится ~12:13',
  })
  expect(windowText({ percentUsed: 18, resetsAt: at(14, 0, 24) }, SEVEN_DAY_MS, now, 'ru')).toEqual({ detail: 'сброс пт 14:00' })
  expect(windowText({ percentUsed: 5, resetsAt: now - 1 }, FIVE_HOUR_MS, now, 'ru')).toEqual({ detail: 'сброшен' })
  expect(windowText(undefined, FIVE_HOUR_MS, now, 'ru')).toEqual({ detail: 'нет данных' })
})

test('language', () => {
  const english = '(\n    "en-US",\n    "ru-BY"\n)\n'
  const russian = '(\n    "ru-BY",\n    "en-US"\n)\n'
  expect(resolveLang(undefined, english)).toBe('en')
  expect(resolveLang(undefined, russian)).toBe('ru')
  expect(resolveLang('ru', english)).toBe('ru')
  expect(resolveLang(undefined, '(\n    "de-DE"\n)')).toBe('en')
  expect(resolveLang(undefined, undefined)).toBe('en')
})

test('english text', () => {
  expect(formatClock(at(14, 0, 24), now, 'en')).toBe('Fri 14:00')
  expect(windowText({ percentUsed: 62, resetsAt: at(14, 0) }, FIVE_HOUR_MS, now, 'en')).toEqual({
    detail: 'resets 14:00',
    warning: 'runs out ~12:13',
  })
  expect(windowText({ percentUsed: 5, resetsAt: now - 1 }, FIVE_HOUR_MS, now, 'en')).toEqual({ detail: 'reset' })
  expect(windowText(undefined, FIVE_HOUR_MS, now, 'en')).toEqual({ detail: 'no data' })
})
