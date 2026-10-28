// Pure logic for sessions waiting on the person. Each session writes its own state to
// ~/.claude/attention/<session id>.json (`stateFileText`); the menu bar app gathers them with
// the Claude app's titles and links into ~/.claude/attention.json (AttentionCore.swift), which
// the band draws (`parseAttention`). Which sessions show, and in what order, is decided there.

import type { Attention, AttentionSession, AttentionState } from '../types'
import { COLORS, type Lang } from './limits'

export type SessionState = 'working' | AttentionState | 'ended'

export const QUESTION_TOOLS: readonly string[] = ['AskUserQuestion', 'ExitPlanMode']
// The Claude app's own tools: the next-step box that ends a turn, and a proposed session.
export const WRAP_UP = 'mcp__ccd_turn__wrap_up'
export const START_SESSION = 'mcp__ccd_session__start_session'
export const ATTENTION_POLL_MS = 2_000
export const ATTENTION_STALE_MS = 10_000
export const MAX_ROWS = 3
const TITLE_MAX = 60

// The state words are the dots' alt text: the band shows a state by its color alone.
export const ATTENTION_TEXT = {
  en: {
    permission: 'needs permission', question: 'has a question', decision: 'needs your decision', done: 'done',
    untitled: 'Untitled session',
    header: (n: number) => `${n} waiting for you`,
    more: (n: number) => `${n} more`,
    minutes: (m: number) => `${m} min`,
  },
  ru: {
    permission: 'нужно разрешение', question: 'вопрос', decision: 'ждёт решения', done: 'готово',
    untitled: 'Сессия без названия',
    header: (n: number) => `${n} ${n % 10 === 1 && n % 100 !== 11 ? 'ждёт' : 'ждут'} ответа`,
    more: (n: number) => `ещё ${n}`,
    minutes: (m: number) => `${m} мин`,
  },
} as const

// The session's state as the hooks hear it. `waitingTool` is the tool a permission prompt
// or a question is held on: its call ending is the person's answer. `awaitsDecision` marks a
// turn that put a choice to the person: when it ends, it waits for a decision, not a look.
export type Tracker = { state: SessionState; since: number; waitingTool?: string; awaitsDecision?: true }

/** What a tool call asks of the person: an answer while it runs, or a decision once the turn ends. */
export type Asks = 'answer' | 'decision'

export type AttentionEvent =
  | { kind: 'turn.start'; agentId?: string }
  | { kind: 'prompt.submit' }
  | { kind: 'permission'; tool: string }
  | { kind: 'tool.start'; tool: string; asks?: Asks }
  | { kind: 'tool.end'; tool: string }
  | { kind: 'turn.complete'; reason: string; agentId?: string }
  | { kind: 'session.end' }

// A question tool, and a session offered for the person to start, hold the call for an answer;
// a next-step box with a question, buttons or `blocked`, and a proposed task card, leave the
// choice to the person once the turn ends.
export function asksOf(tool: string, input: Readonly<Record<string, unknown>>): Asks | undefined {
  if (QUESTION_TOOLS.includes(tool)) return 'answer'
  if (tool === START_SESSION) {
    if (input.initiation === 'offer') return 'answer'
    return input.initiation === 'own_initiative' ? 'decision' : undefined
  }
  if (tool === WRAP_UP) {
    const hasAsk = typeof input.ask === 'string' && input.ask.trim() !== ''
    const hasActions = Array.isArray(input.actions) && input.actions.length > 0
    return hasAsk || hasActions || input.blocked === true ? 'decision' : undefined
  }
  return undefined
}

// A permission prompt or a question holds the person whichever loop raised it; a turn's start
// and end count on the main loop only, as a subagent's turns end inside the main one.
export function nextState(t: Tracker, ev: AttentionEvent, now: number): Tracker {
  const to = (state: SessionState, waitingTool: string | undefined, awaitsDecision: boolean): Tracker =>
    state === t.state && waitingTool === t.waitingTool && awaitsDecision === !!t.awaitsDecision
      ? t
      : {
          state,
          since: state === t.state ? t.since : now,
          ...(waitingTool ? { waitingTool } : {}),
          ...(awaitsDecision ? { awaitsDecision: true as const } : {}),
        }
  const marked = !!t.awaitsDecision
  const isWaiting = t.state === 'permission' || t.state === 'question'
  switch (ev.kind) {
    case 'turn.start':
      return ev.agentId ? t : to('working', undefined, false)
    case 'prompt.submit':
      return to('working', undefined, false)
    case 'permission':
      return to(QUESTION_TOOLS.includes(ev.tool) ? 'question' : 'permission', ev.tool, marked)
    case 'tool.start':
      if (ev.asks === 'answer' || QUESTION_TOOLS.includes(ev.tool)) return to('question', ev.tool, marked)
      return ev.asks === 'decision' ? to(t.state, t.waitingTool, true) : t
    case 'tool.end':
      return isWaiting && t.waitingTool === ev.tool ? to('working', undefined, marked) : t
    case 'turn.complete':
      if (ev.agentId) return t
      if (ev.reason === 'aborted') return to('working', undefined, false)
      return to(marked ? 'decision' : 'done', undefined, false)
    case 'session.end':
      return to('ended', undefined, false)
  }
}

export function stateFileText(sessionId: string, t: Tracker): string {
  return JSON.stringify({ session_id: sessionId, state: t.state, since: Math.round(t.since / 1000) }) + '\n'
}

const LINK = /^claude:\/\/claude\.ai\/epitaxy\/local_[0-9a-f-]+$/
const STATES: readonly string[] = ['permission', 'question', 'decision', 'done']

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

/** The sessions the band shows: all but its own, the first `max` as rows, the rest counted. */
export function bandSessions(a: Attention | null, ownId: string, max = MAX_ROWS) {
  const others = (a?.sessions ?? []).filter(s => s.cliId !== ownId)
  return {
    shown: others.slice(0, max),
    hidden: Math.max(0, others.length - max),
    isBlocking: others.some(s => s.state !== 'done'),
  }
}

export const minutesWaiting = (since: number, now: number) => Math.max(0, Math.floor((now - since) / 60_000))

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

// Tabler's bell outline (MIT), stroked in the state's color like the menu bar's bell.
export function bellSvg(color: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" ` +
    `stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">` +
    `<path d="M10 5a2 2 0 1 1 4 0a7 7 0 0 1 4 6v3a4 4 0 0 0 2 3h-16a4 4 0 0 0 2 -3v-3a7 7 0 0 1 4 -6"/>` +
    `<path d="M9 17v1a3 3 0 0 0 6 0v-1"/></svg>`
}

/** The band's link to a session: https, so the desktop draws it, and answered by the mod. */
export const openHref = (s: AttentionSession) => `https://limit-rings.invalid/open/${s.id}`

/** A title as markdown text: its markdown characters escaped, so it stays one link's text. */
export const markdownText = (t: string) => t.replace(/[\\`*_[\]()<>#!|~]/g, c => `\\${c}`)

export const isOpenableLink = (link: string) => LINK.test(link)
