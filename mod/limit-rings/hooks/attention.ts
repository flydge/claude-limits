// Pure logic for sessions waiting on the person. Each session writes its own state to
// ~/.claude/attention/<session id>.json (`stateFileText`); the menu bar app gathers them with
// the Claude app's titles and links into ~/.claude/attention.json (AttentionCore.swift), which
// the band draws (`parseAttention`). Which sessions show, and in what order, is decided there.

import type { Attention, AttentionSession, AttentionState } from '../types'
import { COLORS, type Lang } from './limits'

export type SessionState = 'working' | AttentionState | 'ended'

export const QUESTION_TOOLS: readonly string[] = ['AskUserQuestion', 'ExitPlanMode']
export const ATTENTION_POLL_MS = 2_000
export const ATTENTION_STALE_MS = 10_000
export const MAX_CHIPS = 3
const TITLE_MAX = 28

export const ATTENTION_TEXT = {
  en: { permission: 'permission', question: 'question', done: 'done', untitled: 'Untitled session' },
  ru: { permission: 'разрешение', question: 'вопрос', done: 'готово', untitled: 'Сессия без названия' },
} as const

// The session's state as the hooks hear it. `waitingTool` is the tool a permission prompt
// or a question is held on: its call ending is the person's answer.
export type Tracker = { state: SessionState; since: number; waitingTool?: string }

export type AttentionEvent =
  | { kind: 'turn.start'; agentId?: string }
  | { kind: 'prompt.submit' }
  | { kind: 'permission'; tool: string }
  | { kind: 'tool.start'; tool: string }
  | { kind: 'tool.end'; tool: string }
  | { kind: 'turn.complete'; reason: string; agentId?: string }
  | { kind: 'session.end' }

// A permission prompt or a question holds the person whichever loop raised it; a turn's start
// and end count on the main loop only, as a subagent's turns end inside the main one.
export function nextState(t: Tracker, ev: AttentionEvent, now: number): Tracker {
  const to = (state: SessionState, waitingTool?: string): Tracker =>
    state === t.state && waitingTool === t.waitingTool
      ? t
      : { state, since: state === t.state ? t.since : now, ...(waitingTool ? { waitingTool } : {}) }
  const isWaiting = t.state === 'permission' || t.state === 'question'
  switch (ev.kind) {
    case 'turn.start':
      return ev.agentId ? t : to('working')
    case 'prompt.submit':
      return to('working')
    case 'permission':
      return to(QUESTION_TOOLS.includes(ev.tool) ? 'question' : 'permission', ev.tool)
    case 'tool.start':
      return QUESTION_TOOLS.includes(ev.tool) ? to('question', ev.tool) : t
    case 'tool.end':
      return isWaiting && t.waitingTool === ev.tool ? to('working') : t
    case 'turn.complete':
      if (ev.agentId) return t
      return ev.reason === 'aborted' ? to('working') : to('done')
    case 'session.end':
      return to('ended')
  }
}

export function stateFileText(sessionId: string, t: Tracker): string {
  return JSON.stringify({ session_id: sessionId, state: t.state, since: Math.round(t.since / 1000) }) + '\n'
}

const LINK = /^claude:\/\/claude\.ai\/epitaxy\/local_[0-9a-f-]+$/
const STATES: readonly string[] = ['permission', 'question', 'done']

// Only a link into the Claude app is kept: the band hands it to `open`.
export function parseAttention(text: string, now: number): Attention | null {
  let raw: any
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (!raw || typeof raw !== 'object' || !Array.isArray(raw.sessions)) return null
  const sessions: AttentionSession[] = raw.sessions
    .filter(
      (s: any) =>
        typeof s?.id === 'string' && typeof s.cli_id === 'string' && typeof s.title === 'string' &&
        STATES.includes(s.state) && typeof s.since === 'number' && Number.isFinite(s.since) &&
        typeof s.link === 'string' && LINK.test(s.link),
    )
    .map((s: any) => ({ id: s.id, cliId: s.cli_id, title: s.title, state: s.state, since: s.since * 1000, link: s.link }))
  const updated = typeof raw.updated_at === 'number' ? raw.updated_at : undefined
  return { measuredAt: updated ? updated * 1000 : now, sessions }
}

export const sameSessions = (a: Attention | null, b: Attention | null) =>
  JSON.stringify(a?.sessions ?? []) === JSON.stringify(b?.sessions ?? [])

/** The sessions the band shows: all but its own, the first `max` as buttons, the rest counted. */
export function chipsFor(a: Attention | null, ownId: string, max = MAX_CHIPS) {
  const others = (a?.sessions ?? []).filter(s => s.cliId !== ownId)
  return { shown: others.slice(0, max), hidden: Math.max(0, others.length - max) }
}

export function shortTitle(title: string, lang: Lang): string {
  const t = title.trim()
  if (!t) return ATTENTION_TEXT[lang].untitled
  return t.length > TITLE_MAX ? t.slice(0, TITLE_MAX - 1).trimEnd() + '…' : t
}

export function stateColor(state: AttentionState): string {
  return state === 'done' ? COLORS.ok : COLORS.warn
}

export function dotSvg(color: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12">` +
    `<circle cx="6" cy="6" r="4" fill="${color}"/></svg>`
}

export const isOpenableLink = (link: string) => LINK.test(link)
