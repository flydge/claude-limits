import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Attention, AttentionSession, LimitWindow, Limits, System } from '../types'
import {
  ATTENTION_POLL_MS,
  ATTENTION_STALE_MS,
  ATTENTION_TEXT,
  COLUMN_TITLE_MAX,
  asksOf,
  bandSessions,
  dotSvg,
  isOpenableLink,
  markdownText,
  minutesWaiting,
  nextState,
  openHref,
  parseAttention,
  sameSessions,
  shortTitle,
  stateColor,
  stateFileText,
  type AttentionEvent,
  workingBand,
  type Tracker,
} from './attention'
import {
  COLORS,
  FIVE_HOUR_MS,
  SEVEN_DAY_MS,
  TEXT,
  limitsFileText,
  resolveLang,
  ringSvg,
  toLimits,
  windowCaption,
  windowText,
  type Lang,
  type RateLimitLike,
} from './limits'
import { STALE_MS, SYSTEM_POLL_MS, SYSTEM_TEXT, memoryUsed, parseSystem, systemTexts, usedRingSvg } from './system'

// Rings with the 5-hour and weekly limits above the prompt in the desktop app.
// The terminal already has the status line, so the band draws on `desktop` only.
// Each reading is also saved to ~/.claude/limits.json for the menu bar app.
// Beside them CPU, GPU, memory and disk, read every 5 s from ~/.claude/system.json that the
// menu bar app writes, all in one row against the prompt (the top apps are in the app's menu).
// Above it two columns, the other sessions at work and those waiting on the person, read every
// 2 s from ~/.claude/attention.json; each session's own state goes to ~/.claude/attention/<id>.json.

const limits = atom({ plugin: 'limit-rings', key: 'limits' } as const, null as Limits | null)
const minute = atom({ plugin: 'limit-rings', key: 'minute' } as const, 0)
const system = atom({ plugin: 'limit-rings', key: 'system' } as const, null as System | null)
const attention = atom({ plugin: 'limit-rings', key: 'attention' } as const, null as Attention | null)

const APP_BIN = 'Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits'

function openSession($: Engine, link: string) {
  if (isOpenableLink(link)) void $.process.run(['open', link], { timeoutMs: 5000 }).catch(() => undefined)
}

type Engine = EngineInterface

// `save` only for a fresh reading: at session start the engine may still hold a
// resumed session's old numbers, which must not overwrite a newer file.
async function take($: Engine, rateLimits: readonly RateLimitLike[], save: boolean) {
  const reading = toLimits(rateLimits, await $.clock.now())
  if (!reading) return
  await update($, limits, () => reading)
  const home = save ? await $.env.get('HOME') : undefined
  if (home) {
    await $.fs.write(`${home}/.claude/limits.json`, limitsFileText(reading)).catch(() => undefined)
  }
}

// $CLAUDE_LIMITS_LANG, else the first macOS system language.
async function systemLang($: Engine): Promise<Lang> {
  const override = await $.env.get('CLAUDE_LIMITS_LANG')
  if (override) return resolveLang(override, undefined)
  const run = await $.process
    .run(['defaults', 'read', '-g', 'AppleLanguages'], { timeoutMs: 5000 })
    .catch(() => undefined)
  return resolveLang(undefined, run?.stdout)
}

// The menu bar app's file; when it is missing or stale (the app not running), the
// app's binary asked directly, in desktop sessions only.
async function readSystem($: Engine): Promise<System | null> {
  const home = await $.env.get('HOME')
  if (!home) return null
  const now = await $.clock.now()
  const text = await $.fs.read(`${home}/.claude/system.json`).catch(() => undefined)
  const fromFile = text ? parseSystem(text, now) : null
  if (fromFile && now - fromFile.measuredAt <= STALE_MS) return fromFile
  if ((await $.env.get('CLAUDE_CODE_ENTRYPOINT')) !== 'claude-desktop') return fromFile
  const run = await $.process.run([`${home}/${APP_BIN}`, '--system-json'], { timeoutMs: 4000 }).catch(() => undefined)
  return (run?.exitCode === 0 ? parseSystem(run.stdout, now) : null) ?? fromFile
}

let isPolling = false

async function poll($: Engine) {
  if (isPolling) return
  isPolling = true
  try {
    const reading = await readSystem($)
    await update($, system, () => reading)
  } finally {
    isPolling = false
  }
}

let tracker: Tracker | null = null

// The file is written only when the state changes, so a busy turn writes nothing.
async function track($: Engine, ev: AttentionEvent) {
  const now = await $.clock.now()
  const before = tracker
  const after = nextState(before ?? { state: 'working', since: now }, ev, now)
  tracker = after
  if (before && before.state === after.state) return
  const home = await $.env.get('HOME')
  const id = await $.session.id()
  if (home && id) await $.fs.write(`${home}/.claude/attention/${id}.json`, stateFileText(id, after))
}

// Tracking never holds up the event it heard.
const quietly = (p: Promise<unknown>) => p.catch(() => undefined)

let lastAsked = 0

// As with system.json: the binary is asked when the file is stale, in desktop sessions only,
// and at most every 10 s so a stopped menu bar app costs a session little.
async function readAttention($: Engine): Promise<Attention | null> {
  const home = await $.env.get('HOME')
  if (!home) return null
  const now = await $.clock.now()
  const text = await $.fs.read(`${home}/.claude/attention.json`).catch(() => undefined)
  const fromFile = text ? parseAttention(text, now) : null
  if (fromFile && now - fromFile.measuredAt <= ATTENTION_STALE_MS) return fromFile
  if ((await $.env.get('CLAUDE_CODE_ENTRYPOINT')) !== 'claude-desktop') return fromFile
  if (now - lastAsked < ATTENTION_STALE_MS) return await read($, attention)
  lastAsked = now
  const run = await $.process.run([`${home}/${APP_BIN}`, '--attention-json'], { timeoutMs: 4000 }).catch(() => undefined)
  return (run?.exitCode === 0 ? parseAttention(run.stdout, now) : null) ?? fromFile
}

let isPollingAttention = false

async function pollAttention($: Engine) {
  if (isPollingAttention) return
  isPollingAttention = true
  try {
    const reading = await readAttention($)
    if (!sameSessions(reading, await read($, attention))) await update($, attention, () => reading)
  } finally {
    isPollingAttention = false
  }
}

export const register: Register = on => {
  let lang: Lang = 'en'

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    lang = await systemLang($)
    const usage = await $.session.usage()
    await take($, usage.rateLimits, false)
    // Redraw every minute so a passed reset and the forecast stay current.
    $.clock.every(60_000, () => update($, minute, n => n + 1))
    await poll($)
    $.clock.every(SYSTEM_POLL_MS, () => poll($))
    await pollAttention($)
    $.clock.every(ATTENTION_POLL_MS, () => pollAttention($))
    return result
  })

  on('prompt.submit', async ($, e, next) => {
    await quietly(track($, { kind: 'prompt.submit' }))
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    await quietly(track($, { kind: 'turn.start', agentId: e.agentId }))
    return next(e)
  })

  on('classic.PermissionRequest', async ($, e, next) => {
    await quietly(track($, { kind: 'permission', tool: e.tool_name }))
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    await quietly(track($, { kind: 'tool.start', tool: e.tool, asks: asksOf(e.tool, e as unknown as Record<string, unknown>) }))
    const result = await next(e)
    await quietly(track($, { kind: 'tool.end', tool: e.tool }))
    return result
  })

  on('turn.complete', async ($, e, next) => {
    await quietly(track($, { kind: 'turn.complete', reason: e.reason, agentId: e.agentId }))
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await quietly(track($, { kind: 'session.end' }))
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) await take($, e.rateLimits, true)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'desktop' || e.props.hasSurvey) return next(e)
    const reading = await read($, limits)
    const sys = await read($, system)
    const listed = await read($, attention)
    const ownId = await $.session.id().catch(() => '')
    const waiting = bandSessions(listed, ownId)
    const working = workingBand(listed, ownId)
    await read($, minute)
    if (!reading && !sys && waiting.total === 0 && working.total === 0) return next(e)

    const now = await $.clock.now()
    const { Box, Markdown, Svg, Text } = $.ui.resolve(e)
    const a = ATTENTION_TEXT[lang]

    // Two columns side by side, at work on the left and waiting on the right, each a heading with
    // its count and a row per session: its title as a link that opens it, and how long it has been
    // so. Links, not Buttons, as the desktop draws a Button as a grey native button; and https ones
    // it answers itself, as it draws any other link as plain text. The columns keep their places
    // while one is empty, so the person finds each where it was.
    const rows = []
    const sessionRow = (prefix: string, s: AttentionSession, dot: boolean) => (
      <Box key={`${prefix}-${s.id}`} flexDirection="row" alignItems="center" justifyContent="space-between" columnGap="sm"
        width="100%">
        <Box flexDirection="row" alignItems="center" columnGap="sm" flexShrink={1} minWidth={0}>
          {dot ? <Svg source={dotSvg(stateColor(s.state))} alt={a[s.state]} width={8} height={8} /> : null}
          <Markdown key={`${prefix}-open-${s.id}`}
            text={`[${markdownText(shortTitle(s.title, lang, COLUMN_TITLE_MAX))}](${openHref(s)})`}
            onLinkPress={() => openSession($, s.link)} pressableLinks={[openHref(s)]} />
        </Box>
        <Text size="footnote" dimColor>{a.minutes(minutesWaiting(s.since, now))}</Text>
      </Box>
    )
    const sessionColumn = (key: string, color: string, header: string, list: AttentionSession[], hidden: number,
      prefix: string, dots: boolean) => (
      <Box key={key} flexDirection="column" rowGap="xs" width="50%" flexShrink={1} minWidth={0}>
        <Box flexDirection="row" alignItems="center" columnGap="sm">
          <Svg source={dotSvg(color)} alt={header} width={8} height={8} />
          <Text size="footnote" dimColor>{header}</Text>
        </Box>
        {list.map(s => sessionRow(prefix, s, dots))}
        {hidden > 0 ? <Text key={`${prefix}-more`} size="footnote" dimColor>{a.more(hidden)}</Text> : null}
      </Box>
    )
    if (waiting.total > 0 || working.total > 0) {
      rows.push(
        <Box key="sessions" flexDirection="row" alignItems="flex-start" columnGap="lg" width="100%">
          {working.total > 0
            ? sessionColumn('working', COLORS.work, a.workingHeader(working.total), working.shown, working.hidden,
              'working', false)
            : <Box key="working" width="50%" />}
          {waiting.total > 0
            ? sessionColumn('attention', waiting.isBlocking ? COLORS.warn : COLORS.ok, a.waitingHeader(waiting.total),
              waiting.shown, waiting.hidden, 'attention', true)
            : <Box key="attention" width="50%" />}
        </Box>,
      )
    }

    // The bottom row, against the prompt: a ring per reading with its value inside and a short caption,
    // as in the menu bar. Each ring's details are a row above it that the pointer on the ring reveals;
    // warnings show in their own rows above it only while they hold.
    const warnings: string[] = []
    const details: JSX.Element[] = []
    const stats: JSX.Element[] = []
    const ring = (key: string, svg: string, alt: string, caption: string, detail: string) => {
      const scope = `limit-rings-${key}`
      stats.push(
        <Box key={`ring-${key}`} flexDirection="row" alignItems="center" columnGap="xs" hover={{ scope }}>
          <Svg source={svg} alt={alt} width={18} height={18} />
          <Text size="footnote" dimColor>{caption}</Text>
        </Box>,
      )
      details.push(
        <Box key={`detail-${key}`} display="none" hover={{ scope, display: 'flex' }}>
          <Text size="footnote" dimColor>{detail}</Text>
        </Box>,
      )
    }

    // Only the windows the plan reports: a plan without the 5-hour limit gets no empty slot for it.
    if (reading) {
      const windows: [string, string, string, LimitWindow | undefined, number][] = []
      if (reading.fiveHour) windows.push(['five-hour', TEXT[lang].fiveHours, TEXT[lang].fiveHoursShort, reading.fiveHour, FIVE_HOUR_MS])
      if (reading.sevenDay) windows.push(['seven-day', TEXT[lang].week, TEXT[lang].weekShort, reading.sevenDay, SEVEN_DAY_MS])
      for (const [key, title, short, w, lengthMs] of windows) {
        const text = windowText(w, lengthMs, now, lang)
        const percent = w ? `${Math.round(w.percentUsed)}%` : TEXT[lang].noData
        ring(key, ringSvg(w, now), `${title}: ${percent}`, windowCaption(w, short, now, lang),
          `${title}: ${percent} · ${text.detail}${text.warning ? ` · ${text.warning}` : ''}`)
        if (text.warning) warnings.push(`${title}: ${text.warning}`)
      }
    }
    let notes: string[] = []
    if (sys) {
      const t = SYSTEM_TEXT[lang]
      const texts = systemTexts(sys, lang)
      const stale = now - sys.measuredAt > STALE_MS
      if (reading && stats.length > 0) stats.push(<Text key="divider" size="footnote" dimColor>|</Text>)
      if (sys.cpu && texts.cpu) {
        ring('cpu', usedRingSvg(sys.cpu.percent, 100, sys.cpu.level, stale), texts.cpu, t.cpuShort, texts.cpu)
      }
      if (sys.gpu && texts.gpu) {
        ring('gpu', usedRingSvg(sys.gpu.utilization, 100, sys.gpu.level, stale), texts.gpu, t.gpuShort,
          texts.gpuDetail ?? texts.gpu)
      }
      if (sys.memory && texts.memory) {
        ring('memory', usedRingSvg(memoryUsed(sys.memory), sys.memory.total, sys.memory.level, stale), texts.memory,
          texts.memoryCaption ?? t.memoryShort, texts.memoryDetail ?? texts.memory)
      }
      if (sys.disk && texts.disk) {
        ring('disk', usedRingSvg(sys.disk.total - Math.min(sys.disk.available, sys.disk.total), sys.disk.total,
          sys.disk.level, stale), texts.disk, texts.diskCaption ?? t.diskShort, texts.diskDetail ?? texts.disk)
      }
      if (!stale) notes = [...(texts.queue ? [texts.queue] : [])]
      if (!stale) warnings.push(...texts.hints)
    }

    for (const [i, note] of notes.entries()) rows.push(<Text key={`note-${i}`} size="footnote" dimColor>{note}</Text>)
    for (const [i, warning] of warnings.entries()) {
      rows.push(<Text key={`hint-${i}`} size="footnote" color="warning">{warning}</Text>)
    }
    rows.push(...details)
    if (stats.length > 0) {
      rows.push(
        <Box key="stats" flexDirection="row" alignItems="center" columnGap="md" flexWrap="wrap">
          {stats}
        </Box>,
      )
    }

    return (
      <Box flexDirection="column" rowGap="xs">
        {rows}
      </Box>
    )
  })
}
