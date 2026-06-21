<script setup lang="ts">
// App.vue — 中控屏根组件
// 职责: 监听 NUI 消息 → Pinia Store → 动态渲染模板

import { useNui, closeDashboard } from './composables/useNui'
import { useDashboardStore } from './stores/dashboard'
import DashboardShell from './components/DashboardShell.vue'
import TabBar from './components/TabBar.vue'
import DiagTab from './components/tabs/DiagTab.vue'
import CtrlTab from './components/tabs/CtrlTab.vue'
import DriveTab from './components/tabs/DriveTab.vue'
import ProfTab from './components/tabs/ProfTab.vue'
import SeatPicker from './components/SeatPicker.vue'

const store = useDashboardStore()

useNui((msg) => {
  switch (msg.type) {
    case 'open':
      store.handleOpen(msg)
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
