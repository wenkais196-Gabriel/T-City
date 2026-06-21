<script setup lang="ts">
// SeatPicker.vue — 后排换座浮层 (Plan C)
// 后排乘客按 I → 显示此卡片, 点击空座换位

import { computed } from 'vue'
import { useDashboardStore } from '../stores/dashboard'
import { sendNui, closeDashboard } from '../composables/useNui'
import { useThrottle } from '../composables/useThrottle'
import type { SeatInfo } from '../types/dashboard'

const store = useDashboardStore()
const { canAct } = useThrottle(800)

const frontRow = computed<SeatInfo[]>(() =>
  store.pickerSeats.filter(s => s.index === -1 || s.index === 0)
)
const backRow = computed<SeatInfo[]>(() =>
  store.pickerSeats.filter(s => s.index >= 1)
)

const labels: Record<number, string> = {
  [-1]: '驾驶',
  [0]: '副驾',
  [1]: '左后',
  [2]: '右后',
  [3]: '后三',
  [4]: '后四',
  [5]: '后五',
}

function labelFor(idx: number): string {
  return labels[idx] ?? `座${idx + 2}`
}

// 后排乘客只能换到后排 (index >= 1)
function canSwitch(s: SeatInfo): boolean {
  return !s.occupied && !s.isPlayer && s.index >= 1
}

function switchTo(s: SeatInfo) {
  if (!canSwitch(s) || !canAct()) return
  sendNui('dashboardAction', { action: 'seat', params: { index: s.index } })
  // 换座后关闭浮层
  setTimeout(() => closeDashboard(), 300)
}
</script>

<template>
  <div class="seat-picker-overlay" @click.self="closeDashboard()">
    <div class="seat-picker-card">
      <div class="picker-title">🪑 换座</div>

      <!-- 前排 (只读) -->
      <div class="picker-row">
        <div
          v-for="s in frontRow" :key="s.index"
          class="picker-seat readonly"
          :class="{ me: s.isPlayer }"
        >
          <span class="pick-icon">{{ s.isPlayer ? '👤' : s.occupied ? '🧑' : '🪑' }}</span>
          <span class="pick-label">{{ labelFor(s.index) }}</span>
        </div>
      </div>

      <!-- 后排 (可点击换座) -->
      <div v-if="backRow.length" class="picker-row">
        <div
          v-for="s in backRow" :key="s.index"
          class="picker-seat"
          :class="{ me: s.isPlayer, occupied: s.occupied && !s.isPlayer, free: canSwitch(s) }"
          @click="switchTo(s)"
        >
          <span class="pick-icon">{{ s.isPlayer ? '👤' : s.occupied ? '🧑' : '🪑' }}</span>
          <span class="pick-label">{{ labelFor(s.index) }}</span>
        </div>
      </div>

      <div class="picker-hint">ESC 或再次按 I 关闭</div>
    </div>
  </div>
</template>

<style scoped>
.seat-picker-overlay {
  position: fixed; inset: 0;
  display: flex; align-items: center; justify-content: center;
  z-index: 9999;
  /* 无背景遮罩 — 轻量浮层 */
}
.seat-picker-card {
  background: rgba(10, 10, 15, 0.92);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  border: 1px solid var(--tcity-border, rgba(255,255,255,0.12));
  border-radius: 16px;
  padding: 18px 20px;
  min-width: 200px;
  max-width: 260px;
  box-shadow: 0 8px 32px rgba(0,0,0,0.5);
}
.picker-title {
  font-size: 14px; font-weight: 700;
  color: var(--tcity-accent, #ff8c00);
  margin-bottom: 14px;
  text-align: center;
}
.picker-row {
  display: flex; gap: 10px; justify-content: center;
  margin-bottom: 8px;
}
.picker-seat {
  display: flex; flex-direction: column; align-items: center;
  padding: 10px 14px; border-radius: 10px;
  border: 1px solid var(--tcity-border, rgba(255,255,255,0.12));
  background: rgba(255,255,255,0.04);
  transition: 0.15s;
  min-width: 64px;
}
.picker-seat.readonly {
  opacity: 0.45;
}
.picker-seat.me {
  background: rgba(255,140,0,0.15);
  border-color: var(--tcity-accent, #ff8c00);
  opacity: 1;
}
.picker-seat.occupied {
  background: rgba(255,255,255,0.06);
  opacity: 0.6;
}
.picker-seat.free {
  cursor: pointer;
}
.picker-seat.free:hover {
  background: rgba(34,221,136,0.12);
  border-color: var(--tcity-success, #22dd88);
  transform: scale(1.04);
}
.pick-icon {
  font-size: 22px; line-height: 1;
}
.pick-label {
  font-size: 10px; color: var(--tcity-text-dim, #888);
  margin-top: 4px;
}
.picker-seat.me .pick-label {
  color: var(--tcity-accent, #ff8c00);
}
.picker-hint {
  text-align: center;
  font-size: 10px;
  color: var(--tcity-text-dim, #555);
  margin-top: 10px;
}
</style>
