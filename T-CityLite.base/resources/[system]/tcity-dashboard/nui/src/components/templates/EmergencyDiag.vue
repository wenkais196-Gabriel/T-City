<script setup lang="ts">
// templates/EmergencyDiag.vue — 🚔 紧急服务诊断
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

  <!-- 警报器状态 -->
  <StatusRow label="🔊 警笛状态" :value="d?.siren ? '🟢 已激活' : '⚫ 关闭'" />
  <StatusRow label="🚨 警灯状态" :value="d?.siren ? '🟢 闪烁中' : '⚫ 关闭'" />

</template>
