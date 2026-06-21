<script setup lang="ts">
// tabs/CtrlTab.vue — 控制页 (统一按钮顺序, v3.0)
//
// 固定顺序: 引擎 → 车锁 → 车窗 → 报警 → 引擎盖 → 后备箱
//           → 门(动态) → 尾翼模式 → 霓虹灯
// 航空/船只保留专用控制

import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import { sendNui } from '../../composables/useNui'
import { useThrottle } from '../../composables/useThrottle'

const store = useDashboardStore()
const { canAct } = useThrottle(1000)

function doAction(action: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action })
}

type Btn = { action: string; icon: string; label: string; danger?: boolean }

const doorActions = ['door_d', 'door_p', 'door_rl', 'door_rr', 'door_e1', 'door_e2']
const doorLabels = ['驾驶门', '副驾门', '左后门', '右后门', '额外门1', '额外门2']

const buttons = computed<Btn[]>(() => {
  const btns: Btn[] = []
  const vc = store.vehicleClass
  const nd = store.diag?.doors?.numDoors ?? 2
  const isBike = vc === 8 || vc === 13
  const isPlane = vc === 16
  const isHeli = vc === 15
  const isBoat = vc === 14
  const isGround = !isPlane && !isHeli && !isBoat && !isBike

  // ═══ 通用 ═══
  btns.push({ action: 'engine', icon: '⚡', label: '引擎开关' })

  // ═══ 地面车辆 ═══
  if (isGround || isBoat) {
    btns.push({ action: 'lock', icon: '🔒', label: '全车锁' })
  }

  if (isGround) {
    btns.push({ action: 'windows', icon: '🪟', label: '车窗' })
    btns.push({ action: 'alarm', icon: '🔊', label: '紧急警报', danger: true })
  }

  if (isGround && !isBike) {
    btns.push({ action: 'hood', icon: '🔧', label: '引擎盖' })
    btns.push({ action: 'trunk', icon: '📦', label: '后备箱' })
    // 门按钮 — 按实际车门数 (最多 6)
    for (let i = 0; i < Math.min(nd, 6); i++) {
      btns.push({ action: doorActions[i], icon: '🚗', label: doorLabels[i] })
    }
  }

  if (isGround && store.hasFeature('ctrl_spoiler')) {
    btns.push({ action: 'spoiler', icon: '🏁', label: '尾翼模式' })
  }
  if (isGround && store.hasFeature('ctrl_neon')) {
    btns.push({ action: 'neon', icon: '💡', label: '霓虹灯' })
  }

  // ═══ 航空 ═══
  if (isPlane) {
    btns.push({ action: 'landing_gear', icon: '🛬', label: '起落架' })
  }

  return btns
})
</script>

<template>
  <div class="tab-content" style="display:block">
    <div class="ctrl-grid">
      <button
        v-for="btn in buttons"
        :key="btn.action"
        class="ctrl-btn"
        :class="{ danger: btn.danger }"
        @click="doAction(btn.action)"
      >
        <span class="btn-icon">{{ btn.icon }}</span>{{ btn.label }}
      </button>
    </div>
  </div>
</template>
