// Pure logic for the limits band: the engine's rate-limit windows, the ring SVG,
// clock text, the exhaustion forecast, and the ~/.claude/limits.json shape the
// menu bar app reads. No `$` here, so it can be tested on its own.

import type { LimitWindow, Limits } from '../types'

export type RateLimitLike = { kind: string; percentUsed: number; resetsAt?: string }

export const FIVE_HOUR_MS = 18_000_000
export const SEVEN_DAY_MS = 604_800_000
const FORECAST_MIN_ELAPSED_MS = 600_000

export type Lang = 'en' | 'ru'

export const TEXT = {
  en: {
    fiveHours: '5 hours', week: 'Week', resets: 'resets', wasReset: 'reset', noData: 'no data',
    runsOut: 'runs out ~', weekdays: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
  },
  ru: {
    fiveHours: '5 часов', week: 'Неделя', resets: 'сброс', wasReset: 'сброшен', noData: 'нет данных',
    runsOut: 'кончится ~', weekdays: ['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'],
  },
} as const

// `override` is $CLAUDE_LIMITS_LANG; `appleLanguages` is the output of
// `defaults read -g AppleLanguages`, whose first entry is the system language.
export function resolveLang(override: string | undefined, appleLanguages: string | undefined): Lang {
  const code = override || appleLanguages?.match(/[A-Za-z]{2}[A-Za-z-]*/)?.[0] || ''
  return code.toLowerCase().startsWith('ru') ? 'ru' : 'en'
}

export const COLORS = { ok: '#34C759', warn: '#FF9500', danger: '#FF3B30', muted: '#8E8E93' }

export function toLimits(rateLimits: readonly RateLimitLike[], now: number): Limits | null {
  const pick = (kind: string): LimitWindow | undefined => {
    const w = rateLimits.find(r => r.kind === kind)
    const resetsAt = w?.resetsAt ? Date.parse(w.resetsAt) : NaN
    return w && Number.isFinite(resetsAt) ? { percentUsed: w.percentUsed, resetsAt } : undefined
  }
  const fiveHour = pick('five_hour')
  const sevenDay = pick('seven_day')
  if (!fiveHour && !sevenDay) return null
  return { measuredAt: now, ...(fiveHour ? { fiveHour } : {}), ...(sevenDay ? { sevenDay } : {}) }
}

export function limitsFileText(limits: Limits): string {
  const file = (w: LimitWindow) => ({ used_percentage: w.percentUsed, resets_at: Math.floor(w.resetsAt / 1000) })
  return JSON.stringify({
    updated_at: Math.floor(limits.measuredAt / 1000),
    ...(limits.fiveHour ? { five_hour: file(limits.fiveHour) } : {}),
    ...(limits.sevenDay ? { seven_day: file(limits.sevenDay) } : {}),
  }) + '\n'
}

export function levelColor(used: number): string {
  if (used < 60) return COLORS.ok
  if (used < 85) return COLORS.warn
  return COLORS.danger
}

export function ringSvg(w: LimitWindow | undefined, now: number): string {
  if (!w || w.resetsAt <= now) return ringSvgOf(0, COLORS.muted, '–')
  if (w.percentUsed >= 100) return ringSvgOf(1, COLORS.danger, '!')
  return ringSvgOf(
    Math.max(0, w.percentUsed) / 100,
    levelColor(w.percentUsed),
    String(Math.min(99, Math.round(w.percentUsed))),
  )
}

export function ringSvgOf(fraction: number, color: string, label: string): string {
  const r = 8.5
  const length = 2 * Math.PI * r
  const ring = (extra: string) =>
    `<circle cx="10" cy="10" r="${r}" fill="none" stroke-width="1.8" ${extra}/>`
  const arc =
    fraction <= 0 ? ''
    : fraction >= 1 ? ring(`stroke="${color}"`)
    : ring(`stroke="${color}" stroke-linecap="round" stroke-dasharray="${(length * fraction).toFixed(2)} ${length.toFixed(2)}" transform="rotate(-90 10 10)"`)
  return (
    '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20">' +
    ring(`stroke="${COLORS.muted}" stroke-opacity="0.35"`) +
    arc +
    `<text x="10" y="13" text-anchor="middle" font-family="-apple-system, system-ui, sans-serif" font-size="8.5" font-weight="600" fill="${color}">${label}</text>` +
    '</svg>'
  )
}

const pad = (n: number) => String(n).padStart(2, '0')

export function formatClock(time: number, now: number, lang: Lang): string {
  const d = new Date(time)
  const n = new Date(now)
  const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  const isSameDay =
    d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()
  return isSameDay ? clock : `${TEXT[lang].weekdays[d.getDay()]} ${clock}`
}

export function forecastExhaustion(w: LimitWindow, lengthMs: number, now: number): number | undefined {
  const used = w.percentUsed
  const elapsed = now - (w.resetsAt - lengthMs)
  if (elapsed < FORECAST_MIN_ELAPSED_MS || used <= 0 || used >= 100) return undefined
  const end = now + ((100 - used) * elapsed) / used
  return end < w.resetsAt ? end : undefined
}

export type WindowText = { detail: string; warning?: string }

export function windowText(w: LimitWindow | undefined, lengthMs: number, now: number, lang: Lang): WindowText {
  const text = TEXT[lang]
  if (!w) return { detail: text.noData }
  if (w.resetsAt <= now) return { detail: text.wasReset }
  const detail = `${text.resets} ${formatClock(w.resetsAt, now, lang)}`
  const end = forecastExhaustion(w, lengthMs, now)
  return end === undefined ? { detail } : { detail, warning: `${text.runsOut}${formatClock(end, now, lang)}` }
}
