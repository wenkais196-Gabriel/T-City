<script setup lang="ts">
// templates/PlaneDiag.vue — ✈️ 固定翼飞机诊断
import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import GaugeCard from '../GaugeCard.vue'
import ProgressBar from '../ProgressBar.vue'
import StatusRow from '../StatusRow.vue'

const store = useDashboardStore()
const d = computed(() => store.diag)
</script>

<template>
  <!-- ADI (姿态指引仪) 风格 -->
  <div class="adi-ring">
    <div class="adi-horizon" :style="{ transform: `rotate(${d?.heading ?? 0}deg)` }" />
    <span style="font-size:18px;font-weight:700;z-index:1">{{ d?.heading ?? 0 }}°</span>
  </div>

  <div class="gauge-row" style="margin-top:12px">
    <GaugeCard :value="d?.altitude?.absolute ?? 0" label="高度 (m)" />
    <GaugeCard :value="d?.altitude?.aboveGround ?? 0" label="离地 (m)" />
    <GaugeCard :value="d?.airspeed ?? 0" label="空速 km/h" />
  </div>

  <div class="gauge-row">
    <GaugeCard :value="d?.speed?.kmh ?? 0" label="地速 km/h" />
    <GaugeCard :value="(d?.vsi ?? 0) + ''" label="VSI m/s" />
    <GaugeCard :value="(d?.fuel ?? 0) + '%'" label="燃油" />
  </div>

  <StatusRow label="发动机健康" :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.engine_health ?? 1000) / 10" />

  <StatusRow label="起落架" :value="d?.landing_gear === 3 ? '⬆️ 收起' : d?.landing_gear === 0 ? '⬇️ 放下' : '🔄 运动中'" />
</template>
