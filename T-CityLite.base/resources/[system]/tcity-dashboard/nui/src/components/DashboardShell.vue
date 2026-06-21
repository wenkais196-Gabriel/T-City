<script setup lang="ts">
// DashboardShell.vue — 毛玻璃容器 + Header

import { useDashboardStore } from '../stores/dashboard'
import { closeDashboard } from '../composables/useNui'

const store = useDashboardStore()

const vehicleIcons: Record<number, string> = {
  8: '🏍️', 13: '🚲', 14: '🚤', 15: '🚁', 16: '✈️', 18: '🚔', 19: '🚛', 20: '🚌',
}
</script>

<template>
  <div class="dash-shell" :class="{ active: store.visible }">
    <!-- Header -->
    <div class="dash-header">
      <span style="font-size:26px">{{ vehicleIcons[store.vehicleClass] || '🚗' }}</span>
      <div style="flex:1">
        <div class="vehicle-plate">{{ store.plate || '---' }}</div>
        <div class="vehicle-model">{{ store.model || 'N/A' }} · Class {{ store.vehicleClass }}</div>
      </div>
      <div style="display:flex;gap:6px">
        <button
          class="night-btn"
          :class="{ on: store.nightMode }"
          @click="store.toggleNightMode()"
          title="夜间模式"
        >{{ store.nightMode ? '☀️' : '🌙' }}</button>
        <button class="night-btn" @click="closeDashboard()" title="关闭">✕</button>
      </div>
    </div>
    <!-- 内容由父组件通过 slot 注入 -->
    <slot />
  </div>
</template>

<style scoped>
.night-btn {
  width: 30px; height: 30px;
  border-radius: 50%;
  border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.05);
  color: var(--tcity-text-dim);
  font-size: 14px;
  cursor: pointer;
  display: flex; align-items: center; justify-content: center;
  transition: 0.2s;
}
.night-btn:hover { background: rgba(255,255,255,0.12); color: white; }
.night-btn.on { background: var(--tcity-accent); color: white; }
</style>
