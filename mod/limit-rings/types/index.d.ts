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
  /** macOS's own estimate of free memory (kern.memorystatus_level × RAM), what gpu-run admits jobs by. */
  available?: number
}
export type SystemCpu = { percent: number; level: SystemLevel }
/** inUse: unified memory the GPU holds now; allocated: what its driver has allocated. */
export type SystemGpu = { utilization: number; inUse: number; allocated: number; level: SystemLevel }
export type SystemQueue = { running: number; waiting: number; runningGB: number; budgetGB: number }
export type SystemDisk = { total: number; available: number; level: SystemLevel }
export type SystemApp = { name: string; count: number; footprint: number }
export type System = {
  measuredAt: number
  memory?: SystemMemory
  disk?: SystemDisk
  cpu?: SystemCpu
  gpu?: SystemGpu
  queue?: SystemQueue
  top: SystemApp[]
}

export type AttentionState = 'working' | 'permission' | 'question' | 'decision' | 'done'
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
      attention: Attention | null
    }
  }
}
