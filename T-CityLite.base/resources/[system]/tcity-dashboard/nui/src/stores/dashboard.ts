// stores/dashboard.ts — 全局状态 (Pinia)

import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { OpenPayload, DiagData, ThemePayload, VehicleTemplate, SeatInfo, SeatPickerPayload, RadarTarget, ScanLogEntry } from '../types/dashboard'

export const useDashboardStore = defineStore('dashboard', () => {
  // ── 核心状态 ──
  const visible = ref(false)
  const plate = ref('')
  const model = ref('')
  const vehicleClass = ref(0)
  const template = ref<VehicleTemplate>('sports')
  const theme = ref<ThemePayload | null>(null)
  const features = ref<Record<string, boolean>>({})
  const seats = ref(4)
  const isConvertible = ref(false)
  const vehicleTags = ref<string[]>([])
  const job = ref('unemployed')

  // ── 实时数据 ──
  const diag = ref<DiagData | null>(null)
  const cruiseActive = ref(false)
  const cruiseSpeed = ref(0)
  const cruiseMode = ref<'auto' | 'lock' | 'none'>('none')
  const cruiseRoadLimit = ref(0)
  const driveMode = ref('comfort')
  const nightMode = ref(localStorage.getItem('tcity_night') === '1')

  // ── 后排换座浮层 (Plan C) ──
  const seatPickerVisible = ref(false)
  const pickerSeats = ref<SeatInfo[]>([])
  const pickerCurrentSeat = ref(1)

  // ── v2.1 / v2.2 警车数据 ──
  const policeData = ref<RadarTarget[]>([])
  const scanLog = ref<ScanLogEntry[]>([])

  // ── 标签页 ──
  const activeTab = ref('diag')

  // ── Computed ──
  const isEmergency = computed(() => vehicleClass.value === 18)
  const isAircraft = computed(() => vehicleClass.value === 15 || vehicleClass.value === 16)
  const isBoat = computed(() => vehicleClass.value === 14)
  const isCommercial = computed(() => [10, 12, 17, 19, 20].includes(vehicleClass.value))

  const hasFeature = (key: string) => features.value[key] === true

  const templateComponent = computed(() => {
    const map: Record<string, string> = {
      sports: 'SportsTemplate',
      commercial: 'CommercialTemplate',
      emergency: 'EmergencyTemplate',
      plane: 'PlaneTemplate',
      helicopter: 'HelicopterTemplate',
      boat: 'BoatTemplate',
    }
    return map[template.value] || 'SportsTemplate'
  })

  // ── Actions ──
  function handleOpen(data: OpenPayload) {
    plate.value = data.plate
    model.value = data.model
    vehicleClass.value = data.class
    template.value = data.template as VehicleTemplate
    theme.value = data.theme
    features.value = data.features || {}
    seats.value = data.seats
    isConvertible.value = data.isConvertible
    vehicleTags.value = data.vehicleTags || []
    job.value = data.job
    visible.value = true
    if (data.snapshot) {
      diag.value = data.snapshot
    }
    applyTheme(data.theme)
  }

  function handleClose() {
    visible.value = false
    seatPickerVisible.value = false
    // 延迟清除数据，等动画结束
    setTimeout(() => {
      diag.value = null
    }, 300)
  }

  function handleSeatPicker(data: SeatPickerPayload) {
    pickerSeats.value = data.seats
    pickerCurrentSeat.value = data.currentSeat
    seatPickerVisible.value = true
  }

  function closeSeatPicker() {
    seatPickerVisible.value = false
    pickerSeats.value = []
  }

  function handleDiag(data: DiagData) {
    diag.value = data
  }

  function handleCruise(active: boolean, speed: number, mode?: string, roadLimit?: number) {
    cruiseActive.value = active
    cruiseSpeed.value = speed
    cruiseMode.value = (mode as 'auto' | 'lock' | 'none') || 'none'
    cruiseRoadLimit.value = roadLimit || 0
  }

  function handleDriveMode(mode: string) {
    driveMode.value = mode
  }

  function applyTheme(t: ThemePayload | null) {
    if (!t) return
    const root = document.documentElement
    for (const [key, val] of Object.entries(t.cssVars)) {
      root.style.setProperty(key, val)
    }
    // 设置 body class
    document.body.className = `theme-${t.style}`
    if (nightMode.value) {
      document.body.classList.add('theme-night')
    }
  }

  function toggleNightMode() {
    nightMode.value = !nightMode.value
    localStorage.setItem('tcity_night', nightMode.value ? '1' : '0')
    document.body.classList.toggle('theme-night', nightMode.value)
  }

  function handlePoliceRadar(data: RadarTarget[] | null, log?: ScanLogEntry[] | null) {
    policeData.value = data || []
    if (log) scanLog.value = log
  }

  function setActiveTab(tab: string) {
    activeTab.value = tab
  }

  function toggle() {
    if (visible.value) {
      handleClose()
    }
    // 打开由 Lua 端驱动
  }

  return {
    visible, plate, model, vehicleClass, template, theme, features,
    seats, isConvertible, vehicleTags, job, diag, cruiseActive, cruiseSpeed,
    cruiseMode, cruiseRoadLimit,
    driveMode, nightMode, activeTab, policeData, scanLog,
    seatPickerVisible, pickerSeats, pickerCurrentSeat,
    isEmergency, isAircraft, isBoat, isCommercial,
    hasFeature, templateComponent,
    handleOpen, handleClose, handleDiag, handleCruise, handleDriveMode,
    handleSeatPicker, closeSeatPicker,
    applyTheme, toggleNightMode, setActiveTab, toggle,
    handlePoliceRadar,
  }
})
