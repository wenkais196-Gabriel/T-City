<script setup lang="ts">
// App.vue — 中控屏根组件
// 职责: 监听 NUI 消息 → Pinia Store → 动态渲染模板

import { useNui, closeDashboard, sendNui } from './composables/useNui'
import { onMounted, onUnmounted } from 'vue'
import { useDashboardStore } from './stores/dashboard'
import DashboardShell from './components/DashboardShell.vue'
import TabBar from './components/TabBar.vue'
import DiagTab from './components/tabs/DiagTab.vue'
import CtrlTab from './components/tabs/CtrlTab.vue'
import DriveTab from './components/tabs/DriveTab.vue'
import ProfTab from './components/tabs/ProfTab.vue'
import SeatPicker from './components/SeatPicker.vue'

const store = useDashboardStore()

// ── 键盘：方向键换页签、Enter 交给当前页、Esc/Backspace 关闭（与手机同一条语义） ──
const TAB_ORDER = ['diag', 'ctrl', 'drive', 'prof']

function onKeydown(e: KeyboardEvent) {
  if (!store.visible) return
  const key = e.key
  if (key === 'Escape' || key === 'Backspace') {
    e.preventDefault()
    closeDashboard()
    return
  }
  if (key === 'ArrowLeft' || key === 'ArrowRight') {
    const order = TAB_ORDER.filter((id) => {
      if (id !== 'prof') return true
      return store.isEmergency || store.isAircraft || store.isBoat || ['police', 'ambulance', 'fire', 'pilot'].includes(store.job)
    })
    const at = Math.max(0, order.indexOf(store.activeTab))
    const next = key === 'ArrowRight'
      ? order[(at + 1) % order.length]
      : order[(at - 1 + order.length) % order.length]
    e.preventDefault()
    store.setActiveTab(next)
  }
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  // 页面真正就绪后再让 Lua 施一次焦点（固定延时在慢机器上不够）
  sendNui('dashboardReady', {})
})
onUnmounted(() => window.removeEventListener('keydown', onKeydown))

useNui((msg) => {
  switch (msg.type) {
    case 'open':
      store.handleOpen(msg)
      // 页面每次打开都向 Lua 报一次就绪 —— 焦点要在这之后施才不会被本 build 忽略
      sendNui('dashboardReady', {})
      // 出警时第一眼就该看到警情：打开即预载，不要求先切到职业页
      if ((msg as any).job === 'police') {
        store.dispatchState = 'loading'
        sendNui('dispatchList', {}).then((res: any) => {
          if (res && res.ok) store.setDispatch(res.incidents || [])
          else store.setDispatch([], 'error')
        }).catch(() => store.setDispatch([], 'error'))
      }
      break
    case 'close':
      store.handleClose()
      break
    case 'diag':
      store.handleDiag(msg.data)
      break
    case 'cruise':
      store.handleCruise(msg.active, msg.speed, msg.mode, msg.roadLimit)
      break
    case 'driveMode':
      store.handleDriveMode(msg.mode)
      break
    case 'seatPicker':
      store.handleSeatPicker(msg)
      break
    // v2.1/v2.2: 警车雷达数据推送
    case 'policeRadar':
      store.handlePoliceRadar(msg.data, (msg as any).scanLog)
      break
  }
})

// ESC / I / 右键 → 关闭
function onKeyDown(e: KeyboardEvent) {
  if (e.key === 'Escape' || e.key === 'i' || e.key === 'I') {
    if (store.seatPickerVisible) {
      store.closeSeatPicker()
      closeDashboard()
    } else {
      closeDashboard()
    }
    e.preventDefault()
    e.stopPropagation()
  }
}
function onContextMenu(e: Event) {
  closeDashboard()
  e.preventDefault()
}

document.addEventListener('keydown', onKeyDown)
document.addEventListener('contextmenu', onContextMenu)
</script>

<template>
  <Teleport to="body">
    <!-- 完整中控屏 (驾驶/副驾) -->
    <DashboardShell>
      <TabBar />
      <DiagTab v-if="store.activeTab === 'diag'" />
      <CtrlTab v-if="store.activeTab === 'ctrl'" />
      <DriveTab v-if="store.activeTab === 'drive'" />
      <ProfTab v-if="store.activeTab === 'prof'" />
    </DashboardShell>
    <!-- 后排换座浮层 (Plan C) — 独立渲染, 不与中控屏互斥 -->
    <SeatPicker v-if="store.seatPickerVisible" />
  </Teleport>
</template>
