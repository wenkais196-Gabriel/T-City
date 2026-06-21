<script setup lang="ts">
// templates/CommercialDiag.vue — 🚛 商用/重卡诊断
import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import GaugeCard from '../GaugeCard.vue'
import ProgressBar from '../ProgressBar.vue'
import StatusRow from '../StatusRow.vue'

const store = useDashboardStore()
const d = computed(() => store.diag)

</script>

<template>
  <div class="gauge-row">
    <GaugeCard :value="d?.speed?.mph ?? 0" label="mph" />
    <GaugeCard :value="d?.rpm?.display ?? 0" label="RPM x100" />
    <GaugeCard :value="(d?.fuel ?? 0) + '%'" label="燃油" />
  </div>

  <StatusRow label="发动机健康" :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.engine_health ?? 1000) / 10" />

  <StatusRow label="车身损伤" :value="Math.round((d?.body_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.body_health ?? 1000) / 10" />

  <StatusRow label="机油寿命" :value="(d?.oil_life ?? 100) + '%'" />
  <ProgressBar :pct="d?.oil_life ?? 100" />

  <!-- 挂车状态 -->
  <StatusRow label="🔗 挂车连接" :value="d?.trailer ? '✅ 已连接' : '❌ 未连接'" />
  <!-- 气刹压力 -->
  <StatusRow label="🛑 气刹压力" :value="(d?.air_brake ?? 120) + ' psi'" />
  <ProgressBar :pct="(d?.air_brake ?? 120) / 120 * 100" />
  <!-- 总重 -->
  <StatusRow label="⚖️ 车货总重" :value="(d?.gross_weight ?? 3500) + ' kg'" />

  <StatusRow label="冷却水温" :value="(d?.coolant ?? 85).toFixed(1) + '°C'" />
  <StatusRow label="电池电压" :value="(d?.battery ?? 12.6).toFixed(1) + 'V'" />

</template>
