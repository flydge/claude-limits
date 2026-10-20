export type LimitWindow = { percentUsed: number; resetsAt: number }
export type Limits = { fiveHour?: LimitWindow; sevenDay?: LimitWindow; measuredAt: number }

declare module 'claude-code' {
  interface PluginState {
    'limit-rings': { limits: Limits | null; minute: number }
  }
}
