// Pure logic for the limits band: the engine's rate-limit windows, the ring SVG,
// clock text, the exhaustion forecast, and the ~/.claude/limits.json shape the
// menu bar app reads. No `$` here, so it can be tested on its own.

import type { LimitWindow, Limits } from '../types'

export type RateLimitLike = { kind: string; percentUsed: number; resetsAt?: string }

export const FIVE_HOUR_MS = 18_000_000
export const SEVEN_DAY_MS = 604_800_000
const FORECAST_MIN_ELAPSED_MS = 600_000
const WEEKDAYS = ['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб']

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
  let fraction = 0
  let label = '–'
  let color = COLORS.muted
  if (w && w.resetsAt > now) {
    if (w.percentUsed >= 100) {
      fraction = 1
      label = '!'
      color = COLORS.danger
    } else {
      fraction = Math.max(0, w.percentUsed) / 100
      label = String(Math.min(99, Math.round(w.percentUsed)))
      color = levelColor(w.percentUsed)
    }
  }
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

export function formatClock(time: number, now: number): string {
  const d = new Date(time)
  const n = new Date(now)
  const clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  const isSameDay =
    d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()
  return isSameDay ? clock : `${WEEKDAYS[d.getDay()]} ${clock}`
}

export function forecastExhaustion(w: LimitWindow, lengthMs: number, now: number): number | undefined {
  const used = w.percentUsed
  const elapsed = now - (w.resetsAt - lengthMs)
  if (elapsed < FORECAST_MIN_ELAPSED_MS || used <= 0 || used >= 100) return undefined
  const end = now + ((100 - used) * elapsed) / used
  return end < w.resetsAt ? end : undefined
}

export type WindowText = { detail: string; warning?: string }

export function windowText(w: LimitWindow | undefined, lengthMs: number, now: number): WindowText {
  if (!w) return { detail: 'нет данных' }
  if (w.resetsAt <= now) return { detail: 'сброшен' }
  const detail = `сброс ${formatClock(w.resetsAt, now)}`
  const end = forecastExhaustion(w, lengthMs, now)
  return end === undefined ? { detail } : { detail, warning: `кончится ~${formatClock(end, now)}` }
}
