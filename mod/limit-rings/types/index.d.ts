export type LimitWindow = { percentUsed: number; resetsAt: number }
export type Limits = { fiveHour?: LimitWindow; sevenDay?: LimitWindow; measuredAt: number }

export type SystemLevel = 'ok' | 'warn' | 'danger'
export type SystemMemory = {
  total: number
  used: number
  compressed: number
  swapUsed: number
  pressure: 'normal' | 'warn' | 'critical'
  level: SystemLevel
}
export type SystemDisk = { total: number; available: number; level: SystemLevel }
export type SystemApp = { name: string; count: number; footprint: number }
export type System = { measuredAt: number; memory?: SystemMemory; disk?: SystemDisk; top: SystemApp[] }

export type AttentionState = 'permission' | 'question' | 'done'
export type AttentionSession = {
  id: string
  cliId: string
  title: string
  state: AttentionState
  since: number
  link: string
}
export type Attention = { measuredAt: number; sessions: AttentionSession[] }

declare module 'claude-code' {
  interface PluginState {
    'limit-rings': {
      limits: Limits | null
      minute: number
      system: System | null
      systemOpen: boolean
      attention: Attention | null
    }
  }
}
