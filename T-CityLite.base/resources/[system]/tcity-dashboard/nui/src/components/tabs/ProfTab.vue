<script setup lang="ts">
// tabs/ProfTab.vue — 职业页 (v2.1 — 警察/救护/消防严格分离)
//
// 修复: || store.isEmergency → && store.isEmergency
// 确保 job 与车辆 class 必须同时匹配才显示对应控制台

import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import { sendNui } from '../../composables/useNui'
import { useThrottle } from '../../composables/useThrottle'
import PoliceConsole from './PoliceConsole.vue'
import AmbulanceConsole from './AmbulanceConsole.vue'
import FireConsole from './FireConsole.vue'

const store = useDashboardStore()
const { canAct } = useThrottle(1000)

// ── 严格的 职业 AND 车辆类别 双重要求 ──
const showPolice    = computed(() => store.job === 'police'    && store.isEmergency)
const showAmbulance = computed(() => store.job === 'ambulance' && store.isEmergency)
const showFire      = computed(() => store.job === 'fire'      && store.isEmergency)
const showAviation  = computed(() => store.isAircraft || store.job === 'pilot')
const showMarine    = computed(() => store.isBoat)

function doAction(action: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action })
}
</script>

<template>
  <div class="tab-content" style="display:block">
    <!-- 🚔 警车控制台 (v2.1 重设计) -->
    <PoliceConsole v-if="showPolice" />

    <!-- 🚑 救护车控制台 -->
    <AmbulanceConsole v-if="showAmbulance" />

    <!-- 🚒 消防车控制台 -->
    <FireConsole v-if="showFire" />

    <!-- ✈️ 航空控制台 -->
    <div v-if="showAviation">
      <div class="console-header">✈️ 航空控制台</div>
      <button class="prof-btn" @click="doAction('transponder_cycle')" style="margin-bottom:8px">📡 应答机循环</button>
      <button class="prof-btn" @click="doAction('flares')">🛡️ 热诱弹投射</button>
    </div>

    <!-- 🚤 航海控制台 -->
    <div v-if="showMarine">
      <div class="console-header">🚤 航海控制台</div>
      <button class="prof-btn anchor" @click="doAction('anchor')" style="margin-bottom:8px">⚓ 抛锚/收锚</button>
      <button class="prof-btn" @click="doAction('bilge_pump')">💧 舱底排水泵</button>
    </div>

    <div v-if="!showPolice && !showAmbulance && !showFire && !showAviation && !showMarine"
      class="no-prof">
      <div style="font-size:48px;margin-bottom:12px">🚗</div>
      <div>当前载具无专属职业功能</div>
      <div style="margin-top:8px;font-size:11px">驾驶警车/救护车/消防车/飞机/船只可获得专属控制台</div>
    </div>
  </div>
</template>

<style scoped>
.console-header {
  font-size:13px; font-weight:700; color:var(--tcity-accent); margin-bottom:12px;
  padding-bottom:8px; border-bottom:1px solid var(--tcity-border);
}
.prof-btn {
  width: 100%; padding: 14px; border-radius: 12px; border: none;
  font-size: 14px; font-weight: 700; cursor: pointer; transition: 0.2s;
  background: rgba(255,255,255,0.06); color: var(--tcity-text-dim);
}
.prof-btn:hover { background: var(--tcity-accent); color: white; }
.prof-btn.anchor { background: rgba(34,221,136,0.15); color: var(--tcity-success); }
.no-prof {
  text-align:center; padding:40px 20px; color:var(--tcity-text-dim);
}
</style>
