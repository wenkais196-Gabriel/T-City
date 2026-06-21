<script setup lang="ts">
// tabs/DriveTab.vue — 驾驶模式 + 双模巡航信息面板 (v2.0)

import { ref, computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import { sendNui } from '../../composables/useNui'

const store = useDashboardStore()

// ── 驾驶模式 ──
const modes = [
  { id: 'comfort', icon: '🏖️', label: '舒适' },
  { id: 'sport',   icon: '🚗', label: '运动' },
  { id: 'eco',     icon: '🌿', label: '经济' },
]

const specialModes = computed(() => {
  const m = []
  if (store.isCommercial) m.push({ id: 'freight', icon: '📦', label: '货运' })
  m.push({ id: 'offroad', icon: '🏔️', label: '越野' })
  return m
})

function switchMode(mode: string) {
  store.handleDriveMode(mode)
  sendNui('dashboardAction', { action: 'drive_mode', params: { mode } })
}

// ── 道路类型识别 (基于限速) ──
const roadLabel = computed(() => {
  const limit = store.cruiseRoadLimit
  if (!limit || limit === 0) return { icon: '🛣️', label: '未知路段' }
  if (limit <= 20)  return { icon: '🅿️', label: '低速区' }
  if (limit <= 35)  return { icon: '🏔️', label: '山路/越野' }
  if (limit <= 50)  return { icon: '🏙️', label: '城市道路' }
  if (limit <= 90)  return { icon: '🔄', label: '高速匝道' }
  return             { icon: '🛣️', label: '高速公路' }
})

// ── 巡航速度显示 (m/s → km/h) ──
const cruiseKmh = computed(() => {
  if (!store.cruiseActive) return '--'
  return Math.round(store.cruiseSpeed * 3.6)
})

// ── 巡航模式标签 ──
const cruiseStatus = computed(() => {
  if (!store.cruiseActive) return null
  if (store.cruiseMode === 'auto') return { icon: '🛣️', label: '动态道路巡航', sub: '自动跟随道路限速' }
  if (store.cruiseMode === 'lock') return { icon: '📌', label: '定速巡航', sub: '↑↓ 微调速度' }
  return { icon: '⚡', label: '巡航中', sub: '' }
})
</script>

<template>
  <div class="tab-content" style="display:block">
    <!-- 驾驶模式 -->
    <div class="drive-section">
      <div class="drive-section-title">驾驶模式</div>
      <div class="mode-grid">
        <button
          v-for="m in modes" :key="m.id"
          class="mode-btn"
          :class="{ active: store.driveMode === m.id }"
          @click="switchMode(m.id)"
        >{{ m.icon }} {{ m.label }}</button>
      </div>
    </div>

    <div class="drive-section" v-if="specialModes.length">
      <div class="drive-section-title">特殊模式</div>
      <div class="mode-grid">
        <button
          v-for="m in specialModes" :key="m.id"
          class="mode-btn"
          :class="{ active: store.driveMode === m.id }"
          @click="switchMode(m.id)"
        >{{ m.icon }} {{ m.label }}</button>
      </div>
    </div>

    <!-- 巡航信息面板 v2.0 — 仅陆地载具 -->
    <div v-if="!store.isAircraft && !store.isBoat" class="cruise-card" :class="{ on: store.cruiseActive, auto: store.cruiseMode === 'auto', lock: store.cruiseMode === 'lock' }">
      <!-- 未激活: 提示 -->
      <template v-if="!store.cruiseActive">
        <div class="cruise-speed">--</div>
        <div class="cruise-label">km/h · 巡航待机</div>
        <div class="cruise-hints">
          <span class="hint-tag">Y 动态道路巡航</span>
          <span class="hint-tag">U 定速巡航</span>
        </div>
      </template>

      <!-- 已激活: 信息面板 -->
      <template v-else>
        <!-- 道路信息 (仅 Auto 模式) -->
        <div v-if="store.cruiseMode === 'auto'" class="road-info">
          <span class="road-icon">{{ roadLabel.icon }}</span>
          <span class="road-name">{{ roadLabel.label }}</span>
          <span class="road-limit">限速 {{ store.cruiseRoadLimit }} km/h</span>
        </div>

        <!-- 巡航速度 -->
        <div class="cruise-speed">{{ cruiseKmh }}</div>
        <div class="cruise-label">km/h</div>

        <!-- 模式标签 -->
        <div v-if="cruiseStatus" class="cruise-mode-badge">
          {{ cruiseStatus.icon }} {{ cruiseStatus.label }}
        </div>
        <div v-if="cruiseStatus?.sub" class="cruise-sub">
          {{ cruiseStatus.sub }}
        </div>
      </template>

      <!-- 操作提示 -->
      <div class="cruise-footer">
        刹车 / 手刹 / 猛踩油门退出
      </div>
    </div>

    <!-- 非陆地载具提示 -->
    <div v-else class="cruise-na">
      🚫 飞行/航海载具暂不支持巡航
    </div>
  </div>
</template>

<style scoped>
/* ── 巡航卡片基础 ── */
.cruise-card {
  background: rgba(255,255,255,0.04);
  border: 1px solid var(--tcity-border);
  border-radius: 12px;
  padding: 14px;
  text-align: center;
  margin-top: 12px;
  transition: border-color 0.3s, background 0.3s;
}

.cruise-card.on {
  border-color: var(--tcity-accent);
  background: rgba(255,140,0,0.06);
}
.cruise-card.on.auto {
  border-color: #4CAF50;
  background: rgba(76,175,80,0.06);
}
.cruise-card.on.lock {
  border-color: #2196F3;
  background: rgba(33,150,243,0.06);
}

/* ── 速度显示 ── */
.cruise-speed {
  font-size: 32px;
  font-weight: 700;
  color: var(--tcity-accent);
  font-variant-numeric: tabular-nums;
}
.cruise-card.on.auto .cruise-speed { color: #4CAF50; }
.cruise-card.on.lock .cruise-speed { color: #2196F3; }
.cruise-label {
  font-size: 10px;
  color: var(--tcity-text-dim);
  margin: 2px 0 8px;
}

/* ── 待机提示 ── */
.cruise-hints {
  display: flex;
  gap: 8px;
  justify-content: center;
  flex-wrap: wrap;
  margin-top: 8px;
}
.hint-tag {
  background: rgba(255,255,255,0.06);
  border: 1px solid var(--tcity-border);
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 11px;
  color: var(--tcity-text-secondary);
}

/* ── 道路信息 (Auto 模式) ── */
.road-info {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  margin-bottom: 8px;
}
.road-icon { font-size: 16px; }
.road-name {
  font-size: 12px;
  font-weight: 600;
  color: var(--tcity-text-primary);
}
.road-limit {
  font-size: 11px;
  color: var(--tcity-text-dim);
  background: rgba(255,255,255,0.06);
  border-radius: 4px;
  padding: 1px 6px;
}

/* ── 模式标签 ── */
.cruise-mode-badge {
  font-size: 12px;
  font-weight: 600;
  margin-top: 6px;
  color: var(--tcity-text-primary);
}
.cruise-sub {
  font-size: 10px;
  color: var(--tcity-text-dim);
  margin-top: 2px;
}

/* ── 底部提示 ── */
.cruise-footer {
  font-size: 10px;
  color: var(--tcity-text-dim);
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px solid rgba(255,255,255,0.05);
}

/* ── 非陆地载具提示 ── */
.cruise-na {
  background: rgba(255,255,255,0.03);
  border: 1px solid var(--tcity-border);
  border-radius: 12px;
  padding: 14px;
  text-align: center;
  margin-top: 12px;
  font-size: 12px;
  color: var(--tcity-text-dim);
}
</style>