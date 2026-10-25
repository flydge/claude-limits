// Pure logic for the memory and disk row: parsing ~/.claude/system.json (or what
// `ClaudeLimits --system-json` prints) and the texts the band draws. The levels come computed from the app, so
// the thresholds live in one place (menubar/Sources/SystemCore.swift).

import type { System, SystemLevel } from '../types'
import { COLORS, ringSvgOf, type Lang } from './limits'

export const SYSTEM_POLL_MS = 5_000
export const STALE_MS = 30_000

export const SYSTEM_TEXT = {
  en: {
    memory: 'Memory', disk: 'Disk', swap: 'swap', free: 'free', used: 'used', of: 'of', unit: 'GB',
    compressed: 'compressed', pressure: 'pressure', top: 'Top memory', more: 'Details', less: 'Hide',
    pressures: { normal: 'normal', warn: 'high', critical: 'critical' },
    memoryHint: 'memory is running out: close the sessions and apps you do not need',
    diskHint: 'disk almost full: swap and updates may not fit',
  },
  ru: {
    memory: 'Память', disk: 'Диск', swap: 'своп', free: 'свободно', used: 'занято', of: 'из', unit: 'ГБ',
    compressed: 'сжато', pressure: 'давление', top: 'Больше всего памяти', more: 'Подробнее', less: 'Скрыть',
    pressures: { normal: 'норма', warn: 'высокое', critical: 'критическое' },
    memoryHint: 'память на исходе: закройте лишние сессии и приложения',
    diskHint: 'диск почти заполнен: своп и обновления могут не поместиться',
  },
} as const

const GIB = 1_073_741_824
const GB = 1_000_000_000

const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)
const level = (v: unknown): SystemLevel => (v === 'danger' || v === 'warn' ? v : 'ok')

export function parseSystem(stdout: string, now: number): System | null {
  let raw: any
  try {
    raw = JSON.parse(stdout)
  } catch {
    return null
  }
  if (!raw || typeof raw !== 'object') return null
  const m = raw.memory
  const d = raw.disk
  const memory =
    m && num(m.total) && num(m.used) !== undefined
      ? {
          total: m.total, used: m.used, compressed: num(m.compressed) ?? 0, swapUsed: num(m.swap_used) ?? 0,
          pressure: m.pressure === 'critical' || m.pressure === 'warn' ? m.pressure : 'normal',
          level: level(m.level),
        } as const
      : undefined
  const disk =
    d && num(d.total) && num(d.available) !== undefined
      ? { total: d.total, available: d.available, level: level(d.level) }
      : undefined
  if (!memory && !disk) return null
  const top = Array.isArray(raw.top)
    ? raw.top
        .filter((p: any) => typeof p?.name === 'string' && num(p.footprint) !== undefined)
        .map((p: any) => ({ name: p.name, count: num(p.count) ?? 1, footprint: p.footprint }))
    : []
  const updated = num(raw.updated_at)
  return { measuredAt: updated ? updated * 1000 : now, ...(memory ? { memory } : {}), ...(disk ? { disk } : {}), top }
}

/** Gigabytes with one decimal below 100, whole above, a decimal comma in Russian. */
export function formatSize(bytes: number, unit: 'GiB' | 'GB', lang: Lang): string {
  const value = bytes / (unit === 'GiB' ? GIB : GB)
  const tenths = Math.round(value * 10) / 10
  const text = value >= 100 || Number.isInteger(tenths) ? String(Math.round(value)) : tenths.toFixed(1)
  return lang === 'ru' ? text.replace('.', ',') : text
}

export function levelColorOf(l: SystemLevel, stale: boolean): string {
  return stale ? COLORS.muted : COLORS[l]
}

export function usedRingSvg(used: number, total: number, l: SystemLevel, stale: boolean): string {
  const fraction = total > 0 ? Math.min(1, Math.max(0, used / total)) : 0
  return ringSvgOf(fraction, levelColorOf(l, stale), String(Math.min(99, Math.round(fraction * 100))))
}

export type SystemTexts = {
  memory?: string
  disk?: string
  memoryDetail?: string
  diskDetail?: string
  hints: string[]
  top: string[]
}

export function systemTexts(s: System, lang: Lang): SystemTexts {
  const t = SYSTEM_TEXT[lang]
  const out: SystemTexts = { hints: [], top: [] }
  if (s.memory) {
    const m = s.memory
    const percent = Math.min(99, Math.round((m.used / m.total) * 100))
    out.memory = `${t.memory} ${percent}% · ${t.swap} ${formatSize(m.swapUsed, 'GiB', lang)} ${t.unit}`
    out.memoryDetail =
      `${t.memory}: ${t.used} ${formatSize(m.used, 'GiB', lang)} ${t.of} ${formatSize(m.total, 'GiB', lang)} ${t.unit}` +
      ` · ${t.compressed} ${formatSize(m.compressed, 'GiB', lang)} ${t.unit}` +
      ` · ${t.swap} ${formatSize(m.swapUsed, 'GiB', lang)} ${t.unit}` +
      ` · ${t.pressure}: ${t.pressures[m.pressure]}`
    if (m.level === 'danger') out.hints.push(t.memoryHint)
  }
  if (s.disk) {
    const d = s.disk
    out.disk = `${t.disk}: ${t.free} ${formatSize(d.available, 'GB', lang)} ${t.unit}`
    out.diskDetail = `${t.disk}: ${t.free} ${formatSize(d.available, 'GB', lang)} ${t.of} ${formatSize(d.total, 'GB', lang)} ${t.unit}`
    if (d.level === 'danger') out.hints.push(t.diskHint)
  }
  out.top = s.top.map(p => `${p.name}${p.count > 1 ? ` ×${p.count}` : ''} · ${formatSize(p.footprint, 'GiB', lang)} ${t.unit}`)
  return out
}
