<script setup lang="ts">
// SeatMap.vue — 双排乘员座位图 (点击空座换位)
import { computed } from 'vue'
import { useDashboardStore } from '../stores/dashboard'
import { sendNui } from '../composables/useNui'
import { useThrottle } from '../composables/useThrottle'
import type { SeatInfo } from '../types/dashboard'

const store = useDashboardStore()
const { canAct } = useThrottle(800)

const seats = computed<SeatInfo[]>(() => store.diag?.seats || [])

// 前排: 驾驶(-1) + 副驾(0)
const frontRow = computed(() => {
  return seats.value.filter(s => s.index === -1 || s.index === 0)
})
// 后排: 左后(1) 右后(2) ...
const backRow = computed(() => {
  return seats.value.filter(s => s.index >= 1)
})

const seatLabels: Record<number, string> = {
  [-1]: '驾驶',
  [0]: '副驾',
  [1]: '左后',
  [2]: '右后',
  [3]: '后三',
  [4]: '后四',
  [5]: '后五',
}

function getLabel(idx: number): string {
  return seatLabels[idx] ?? `座${idx + 2}`
}

function switchTo(seat: SeatInfo) {
  if (seat.occupied || seat.isPlayer) return
  if (!canAct()) return
  sendNui('dashboardAction', { action: 'seat', params: { index: seat.index } })
}
</script>

<template>
  <div v-if="seats.length" class="seat-map">
    <div class="seat-title">🪑 乘员 · 点击空座换位</div>
    <!-- 前排 -->
    <div class="seat-row">
      <div
        v-for="s in frontRow" :key="s.index"
        class="seat-card"
        :class="{ me: s.isPlayer, occupied: s.occupied && !s.isPlayer, empty: !s.occupied }"
        @click="switchTo(s)"
      >
        <div class="seat-icon">{{ s.isPlayer ? '👤' : s.occupied ? '🧑' : '🪑' }}</div>
        <div class="seat-label">{{ getLabel(s.index) }}</div>
      </div>
    </div>
    <!-- 后排 -->
    <div v-if="backRow.length" class="seat-row">
      <div
        v-for="s in backRow" :key="s.index"
        class="seat-card"
        :class="{ me: s.isPlayer, occupied: s.occupied && !s.isPlayer, empty: !s.occupied }"
        @click="switchTo(s)"
      >
        <div class="seat-icon">{{ s.isPlayer ? '👤' : s.occupied ? '🧑' : '🪑' }}</div>
        <div class="seat-label">{{ getLabel(s.index) }}</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.seat-map {
  margin-top: 10px; padding-top: 8px;
  border-top: 1px solid var(--tcity-border);
}
.seat-title {
  font-size: 11px; color: var(--tcity-text-dim); margin-bottom: 8px;
}
.seat-row {
  display: flex; gap: 8px; margin-bottom: 6px;
  justify-content: center;
}
.seat-card {
  flex: 1; max-width: 100px;
  display: flex; flex-direction: column; align-items: center;
  padding: 8px 4px; border-radius: 10px;
  border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.03);
  transition: 0.15s;
  cursor: default;
}
.seat-card.occupied {
  background: rgba(255,255,255,0.06);
  border-color: rgba(255,255,255,0.12);
}
.seat-card.me {
  background: rgba(255,140,0,0.12);
  border-color: var(--tcity-accent);
}
.seat-card.empty {
  cursor: pointer;
}
.seat-card.empty:hover {
  background: rgba(255,255,255,0.08);
  border-color: var(--tcity-success);
}
.seat-icon {
  font-size: 20px; line-height: 1;
}
.seat-label {
  font-size: 10px; color: var(--tcity-text-dim);
  margin-top: 3px;
}
.seat-card.me .seat-label {
  color: var(--tcity-accent);
}
</style>
