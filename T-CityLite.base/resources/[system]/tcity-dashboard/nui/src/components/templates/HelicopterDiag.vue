<script setup lang="ts">
// templates/HelicopterDiag.vue — 🚁 直升机诊断
import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import GaugeCard from '../GaugeCard.vue'
import ProgressBar from '../ProgressBar.vue'
import StatusRow from '../StatusRow.vue'

const store = useDashboardStore()
const d = computed(() => store.diag)
</script>

<template>
  <!-- 悬停辅助十字准星 -->
  <div class="hud-crosshair">
    <span style="position:relative;z-index:1;font-size:12px;color:var(--tcity-accent)">{{ d?.heading ?? 0 }}°</span>
  </div>

  <div class="gauge-row" style="margin-top:12px">
    <GaugeCard :value="d?.altitude?.aboveGround ?? 0" label="雷达高度 (m)" />
    <GaugeCard :value="d?.altitude?.absolute ?? 0" label="绝对高度 (m)" />
    <GaugeCard :value="d?.airspeed ?? 0" label="空速 km/h" />
  </div>

  <div class="gauge-row">
    <GaugeCard :value="d?.speed?.kmh ?? 0" label="地速" />
    <GaugeCard :value="d?.heading ?? 0" label="航向 °" />
    <GaugeCard :value="(d?.fuel ?? 0) + '%'" label="燃油" />
  </div>

  <StatusRow label="发动机健康" :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.engine_health ?? 1000) / 10" />

  <StatusRow label="🔄 偏航指示" :value="(d?.heading ?? 0) + '°'" />
  <StatusRow label="💨 相对风速" :value="Math.floor((d?.speed?.kmh ?? 0) * 0.8) + ' km/h'" />
</template>
