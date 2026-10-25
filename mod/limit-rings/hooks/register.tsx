import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LimitWindow, Limits, System } from '../types'
import {
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

const limits = atom({ plugin: 'limit-rings', key: 'limits' } as const, null as Limits | null)
const minute = atom({ plugin: 'limit-rings', key: 'minute' } as const, 0)
const system = atom({ plugin: 'limit-rings', key: 'system' } as const, null as System | null)
const systemOpen = atom({ plugin: 'limit-rings', key: 'systemOpen' } as const, false)

const APP_BIN = 'Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits'

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
    return result
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
    await read($, minute)
    if (!reading && !sys) return next(e)

    const now = await $.clock.now()
    const { Box, Button, Svg, Text } = $.ui.resolve(e)

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

    const rows = []
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
            <Button key="memory-toggle" onPress={toggle}><Text size="footnote"> {texts.memory}</Text></Button>
          </Box>,
        )
      }
      if (sys.disk && texts.disk) {
        parts.push(
          <Box key="disk" flexDirection="row" alignItems="center">
            <Svg source={usedRingSvg(sys.disk.total - Math.min(sys.disk.available, sys.disk.total), sys.disk.total,
              sys.disk.level, stale)} alt={texts.disk} width={20} height={20} />
            <Button key="disk-toggle" onPress={toggle}><Text size="footnote"> {texts.disk}</Text></Button>
          </Box>,
        )
      }
      parts.push(<Button key="system-details" label={isOpen ? t.less : t.more} onPress={toggle} />)
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
