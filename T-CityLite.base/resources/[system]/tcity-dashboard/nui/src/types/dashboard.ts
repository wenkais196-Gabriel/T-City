// types/dashboard.ts — 全载具中控屏类型定义

export interface ThemePayload {
  template: string
  label: string
  accent: string
  accentGlow: string
  style: string
  font: string
  cssVars: Record<string, string>
}

export interface OpenPayload {
  type: 'open'
  plate: string
  model: string
  class: number
  template: string
  theme: ThemePayload
  features: Record<string, boolean>
  seats: number
  isConvertible: boolean
  vehicleTags: string[]
  job: string
  snapshot: DiagData | null
}

export interface DiagData {
  ts: number
  template: string
  speed?: { mph: number; kmh: number }
  rpm?: { ratio: number; display: number }
  gear?: number
  fuel?: number
  engine_health?: number
  body_health?: number
  oil_life?: number
  coolant?: number
  battery?: number
  trans_temp?: number
  doors?: { doors: string[]; numDoors: number; hood: boolean; trunk: boolean }
  seats?: SeatInfo[]
  turbo?: { installed: boolean; psi: number }
  spoiler?: boolean
  trailer?: boolean
  air_brake?: number
  siren?: boolean
  altitude?: { absolute: number; aboveGround: number }
  airspeed?: number
  heading?: number
  landing_gear?: number
  depth?: number
  speedKnots?: number
  gross_weight?: number
  vsi?: number
  [key: string]: unknown
}

export interface CruisePayload {
  type: 'cruise'
  active: boolean
  speed: number
  mode: 'auto' | 'lock' | 'none'
  roadLimit: number
}

export interface DriveModePayload {
  type: 'driveMode'
  mode: string
}

export interface RadarTarget {
  plate: string
  model: string
  speed: number
  distance: number
  isFlagged?: boolean
  isStolen?: boolean
  speedGun?: number
}

// v2.2: 扫描日志条目
export interface ScanLogEntry {
  plate: string
  model: string
  speed: number
  distance: number
  time: string
  isFlagged: boolean
  isStolen: boolean
}

// v2.1: 警车数据
export interface PoliceData {
  radarTargets: RadarTarget[]
  anprHits: RadarTarget[]
  stolenHits: RadarTarget[]
  speedRadarMode: boolean
  flaggedPlates: Record<string, string>  // plate → reason
}

export interface SeatPickerPayload {
  type: 'seatPicker'
  seats: SeatInfo[]
  currentSeat: number
}

export type NuiMessage =
  | { type: 'open' } & OpenPayload
  | { type: 'close' }
  | { type: 'diag'; data: DiagData }
  | { type: 'cruise'; active: boolean; speed: number; mode: string; roadLimit: number }
  | { type: 'driveMode'; mode: string }
  | { type: 'registerApp'; app: unknown }
  | { type: 'policeRadar'; data: RadarTarget[]; scanLog?: ScanLogEntry[] }
  | SeatPickerPayload

export interface SeatInfo {
  index: number      // -1=驾驶, 0=副驾, 1+=后排
  occupied: boolean
  isPlayer: boolean
}

export type VehicleTemplate = 'sports' | 'commercial' | 'emergency' | 'plane' | 'helicopter' | 'boat'
