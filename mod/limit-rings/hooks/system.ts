// Pure logic for the memory and disk row: parsing ~/.claude/system.json (or what
// `ClaudeLimits --system-json` prints) and the texts the band draws. The levels come computed from the app, so
// the thresholds live in one place (menubar/Sources/SystemCore.swift).

import type { System, SystemLevel, SystemMemory } from '../types'
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
    available: 'available', usedByMonitor: 'Activity Monitor used', gpuHolds: 'holds', gpuAllocated: 'allocated',
    gpuLoad: 'load', queue: 'GPU queue', running: 'running', waiting: 'waiting',
  },
  ru: {
    memory: 'Память', disk: 'Диск', swap: 'своп', free: 'свободно', used: 'занято', of: 'из', unit: 'ГБ',
    compressed: 'сжато', pressure: 'давление', top: 'Больше всего памяти', more: 'Подробнее', less: 'Скрыть',
    pressures: { normal: 'норма', warn: 'высокое', critical: 'критическое' },
    memoryHint: 'память на исходе: закройте лишние сессии и приложения',
    diskHint: 'диск почти заполнен: своп и обновления могут не поместиться',
    available: 'доступно', usedByMonitor: 'в Мониторинге занято', gpuHolds: 'держит', gpuAllocated: 'выделено',
    gpuLoad: 'загрузка', queue: 'Очередь GPU', running: 'идут', waiting: 'ждут',
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
          ...(num(m.available) !== undefined ? { available: m.available } : {}),
        } as const
      : undefined
  const c = raw.cpu
  const cpu = c && num(c.percent) !== undefined ? { percent: c.percent, level: level(c.level) } : undefined
  const g = raw.gpu
  const gpu =
    g && num(g.utilization) !== undefined
      ? { utilization: g.utilization, inUse: num(g.in_use) ?? 0, allocated: num(g.allocated) ?? 0, level: level(g.level) }
      : undefined
  const q = raw.queue
  const queue =
    q && num(q.running) !== undefined && num(q.waiting) !== undefined
      ? { running: q.running, waiting: q.waiting, runningGB: num(q.running_gb) ?? 0, budgetGB: num(q.budget_gb) ?? 30 }
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
  return {
    measuredAt: updated ? updated * 1000 : now,
    ...(memory ? { memory } : {}), ...(disk ? { disk } : {}),
    ...(cpu ? { cpu } : {}), ...(gpu ? { gpu } : {}), ...(queue ? { queue } : {}),
    top,
  }
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

/** What macOS counts as taken (RAM minus its available estimate); Activity Monitor's figure without it. */
export function memoryUsed(m: SystemMemory): number {
  return m.available !== undefined ? m.total - Math.min(m.available, m.total) : m.used
}

export type SystemTexts = {
  cpu?: string
  gpu?: string
  queue?: string
  gpuDetail?: string
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
  if (s.cpu) out.cpu = `CPU ${Math.round(s.cpu.percent)}%`
  if (s.gpu) {
    const g = s.gpu
    out.gpu = `GPU ${Math.round(g.utilization)}% · ${formatSize(g.inUse, 'GiB', lang)} ${t.unit}`
    out.gpuDetail =
      `GPU: ${t.gpuLoad} ${Math.round(g.utilization)}% · ${t.gpuHolds} ${formatSize(g.inUse, 'GiB', lang)} ${t.unit}` +
      ` · ${t.gpuAllocated} ${formatSize(g.allocated, 'GiB', lang)} ${t.unit}`
  }
  if (s.queue && s.queue.running + s.queue.waiting > 0) {
    const q = s.queue
    out.queue = `${t.queue}: ${t.running} ${q.running} · ${t.waiting} ${q.waiting}`
  }
  if (s.memory) {
    const m = s.memory
    const percent = Math.min(99, Math.round((memoryUsed(m) / m.total) * 100))
    const head = m.available !== undefined
      ? `${t.memory}: ${t.available} ${formatSize(m.available, 'GiB', lang)} ${t.unit}`
      : `${t.memory} ${percent}%`
    out.memory = `${head} · ${t.swap} ${formatSize(m.swapUsed, 'GiB', lang)} ${t.unit}`
    out.memoryDetail =
      (m.available !== undefined
        ? `${t.memory}: ${t.available} ${formatSize(m.available, 'GiB', lang)} ${t.of} ${formatSize(m.total, 'GiB', lang)} ${t.unit}` +
          ` · ${t.usedByMonitor} ${formatSize(m.used, 'GiB', lang)} ${t.unit}`
        : `${t.memory}: ${t.used} ${formatSize(m.used, 'GiB', lang)} ${t.of} ${formatSize(m.total, 'GiB', lang)} ${t.unit}`) +
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
