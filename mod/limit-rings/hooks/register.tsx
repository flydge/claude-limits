import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LimitWindow, Limits } from '../types'
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

// Rings with the 5-hour and weekly limits above the prompt in the desktop app.
// The terminal already has the status line, so the band draws on `desktop` only.
// Each reading is also saved to ~/.claude/limits.json for the menu bar app.

const limits = atom({ plugin: 'limit-rings', key: 'limits' } as const, null as Limits | null)
const minute = atom({ plugin: 'limit-rings', key: 'minute' } as const, 0)

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

export const register: Register = on => {
  let lang: Lang = 'en'

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    lang = await systemLang($)
    const usage = await $.session.usage()
    await take($, usage.rateLimits, false)
    // Redraw every minute so a passed reset and the forecast stay current.
    $.clock.every(60_000, () => update($, minute, n => n + 1))
    return result
  })

  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) await take($, e.rateLimits, true)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'desktop' || e.props.hasSurvey) return next(e)
    const reading = await read($, limits)
    await read($, minute)
    if (!reading) return next(e)

    const now = await $.clock.now()
    const { Box, Svg, Text } = $.ui.resolve(e)

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

    return (
      <Box flexDirection="row" alignItems="center" columnGap="lg">
        {item('five-hour', TEXT[lang].fiveHours, reading.fiveHour, FIVE_HOUR_MS)}
        {item('seven-day', TEXT[lang].week, reading.sevenDay, SEVEN_DAY_MS)}
      </Box>
    )
  })
}
