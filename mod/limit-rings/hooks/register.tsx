import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Attention, LimitWindow, Limits, System } from '../types'
import {
  ATTENTION_POLL_MS,
  ATTENTION_STALE_MS,
  ATTENTION_TEXT,
  asksOf,
  bandSessions,
  bellSvg,
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
  windowText,
  type Lang,
  type RateLimitLike,
} from './limits'
import { STALE_MS, SYSTEM_POLL_MS, SYSTEM_TEXT, parseSystem, systemTexts, usedRingSvg } from './system'

// Rings with the 5-hour and weekly limits above the prompt in the desktop app.
// The terminal already has the status line, so the band draws on `desktop` only.
// Each reading is also saved to ~/.claude/limits.json for the menu bar app.
// Below them a row with memory and disk, read every 5 s from ~/.claude/system.json
// that the menu bar app writes; pressing it shows the details and the top apps.
// Above them, buttons for the other sessions waiting on the person, read every 2 s from
// ~/.claude/attention.json; each session's own state goes to ~/.claude/attention/<id>.json.

const limits = atom({ plugin: 'limit-rings', key: 'limits' } as const, null as Limits | null)
const minute = atom({ plugin: 'limit-rings', key: 'minute' } as const, 0)
const system = atom({ plugin: 'limit-rings', key: 'system' } as const, null as System | null)
const systemOpen = atom({ plugin: 'limit-rings', key: 'systemOpen' } as const, false)
const attention = atom({ plugin: 'limit-rings', key: 'attention' } as const, null as Attention | null)

const APP_BIN = 'Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits'
// The memory details link: answered by the mod, never opened.
const DETAILS_HREF = 'https://limit-rings.invalid/details'

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
    const isOpen = await read($, systemOpen)
    const waiting = bandSessions(await read($, attention), await $.session.id().catch(() => ''))
    await read($, minute)
    if (!reading && !sys && waiting.shown.length === 0) return next(e)

    const now = await $.clock.now()
    const { Box, Markdown, Svg, Text } = $.ui.resolve(e)

    // A heading with the count, then one row per session: a dot whose color is its state,
    // the title as a link that opens it, and how long it has waited. Links, not Buttons, as the
    // desktop draws a Button as a grey native button; and https ones it answers itself, as it
    // draws any other link as plain text.
    const rows = []
    if (waiting.shown.length > 0) {
      const a = ATTENTION_TEXT[lang]
      const total = waiting.shown.length + waiting.hidden
      const list = waiting.shown.map(s => (
        <Box key={`attention-${s.id}`} flexDirection="row" alignItems="center" justifyContent="space-between" width="100%">
          <Box flexDirection="row" alignItems="center" columnGap="sm">
            <Svg source={dotSvg(stateColor(s.state))} alt={a[s.state]} width={10} height={10} />
            <Markdown key={`attention-open-${s.id}`} text={`[${markdownText(shortTitle(s.title, lang))}](${openHref(s)})`}
              onLinkPress={() => openSession($, s.link)} pressableLinks={[openHref(s)]} />
          </Box>
          <Text size="footnote" dimColor>{a.minutes(minutesWaiting(s.since, now))}</Text>
        </Box>
      ))
      if (waiting.hidden > 0) list.push(<Text key="attention-more" size="footnote" dimColor>{a.more(waiting.hidden)}</Text>)
      rows.push(
        <Box key="attention" flexDirection="column" rowGap="xs">
          <Box flexDirection="row" alignItems="center" columnGap="sm">
            <Svg source={bellSvg(waiting.isBlocking ? COLORS.warn : COLORS.ok)} alt={a.header(total)} width={14} height={14} />
            <Text size="footnote" weight="medium">{a.header(total)}</Text>
          </Box>
          <Box flexDirection="column" rowGap="xs" paddingLeft="lg">
            {list}
          </Box>
        </Box>,
      )
    }

    const item = (key: string, title: string, w: LimitWindow | undefined, lengthMs: number) => {
      const text = windowText(w, lengthMs, now, lang)
      const percent = w ? `${Math.round(w.percentUsed)}%` : TEXT[lang].noData
      const parts = [
        <Svg source={ringSvg(w, now)} alt={`${title}: ${percent}`} width={20} height={20} />,
        <Text size="footnote"> {title}</Text>,
        <Text size="footnote" dimColor> · {text.detail}</Text>,
      ]
      if (text.warning) parts.push(<Text size="footnote" color="warning"> · {text.warning}</Text>)
      return (
        <Box key={key} flexDirection="row" alignItems="center">
          {parts}
        </Box>
      )
    }

    if (reading) {
      rows.push(
        <Box key="limits" flexDirection="row" alignItems="center" columnGap="lg">
          {item('five-hour', TEXT[lang].fiveHours, reading.fiveHour, FIVE_HOUR_MS)}
          {item('seven-day', TEXT[lang].week, reading.sevenDay, SEVEN_DAY_MS)}
        </Box>,
      )
    }
    if (sys) {
      const t = SYSTEM_TEXT[lang]
      const texts = systemTexts(sys, lang)
      const stale = now - sys.measuredAt > STALE_MS
      const toggle = () => update($, systemOpen, open => !open)
      const parts = []
      if (sys.memory && texts.memory) {
        parts.push(
          <Box key="memory" flexDirection="row" alignItems="center">
            <Svg source={usedRingSvg(sys.memory.used, sys.memory.total, sys.memory.level, stale)}
              alt={texts.memory} width={20} height={20} />
            <Text size="footnote"> {texts.memory}</Text>
          </Box>,
        )
      }
      if (sys.disk && texts.disk) {
        parts.push(
          <Box key="disk" flexDirection="row" alignItems="center">
            <Svg source={usedRingSvg(sys.disk.total - Math.min(sys.disk.available, sys.disk.total), sys.disk.total,
              sys.disk.level, stale)} alt={texts.disk} width={20} height={20} />
            <Text size="footnote"> {texts.disk}</Text>
          </Box>,
        )
      }
      // A link rather than a Button: the desktop draws a Button as a grey native button.
      parts.push(
        <Markdown key="system-details" text={`[${isOpen ? t.less : t.more}](${DETAILS_HREF})`}
          onLinkPress={toggle} pressableLinks={[DETAILS_HREF]} />,
      )
      rows.push(
        <Box key="system" flexDirection="row" alignItems="center" columnGap="lg">
          {parts}
        </Box>,
      )
      if (!isOpen && !stale) {
        for (const [i, hint] of texts.hints.entries()) {
          rows.push(<Text size="footnote" color="warning">{hint}</Text>)
        }
      }
      if (isOpen) {
        const details = []
        if (texts.memoryDetail) details.push(<Text size="footnote" dimColor>{texts.memoryDetail}</Text>)
        if (texts.diskDetail) details.push(<Text size="footnote" dimColor>{texts.diskDetail}</Text>)
        for (const [i, hint] of texts.hints.entries()) {
          details.push(<Text size="footnote" color="warning">{hint}</Text>)
        }
        if (texts.top.length > 0) {
          details.push(<Text size="footnote">{t.top}</Text>)
          for (const [i, line] of texts.top.entries()) {
            details.push(<Text size="footnote" dimColor>  {line}</Text>)
          }
        }
        rows.push(
          <Box key="system-details-box" flexDirection="column">
            {details}
          </Box>,
        )
      }
    }

    return (
      <Box flexDirection="column" rowGap="xs">
        {rows}
      </Box>
    )
  })
}
