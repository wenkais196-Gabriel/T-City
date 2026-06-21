<script setup lang="ts">
// templates/BoatDiag.vue — 🚤 船只诊断
import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import GaugeCard from '../GaugeCard.vue'
import ProgressBar from '../ProgressBar.vue'
import StatusRow from '../StatusRow.vue'

const store = useDashboardStore()
const d = computed(() => store.diag)
</script>

<template>
  <!-- 数字罗盘 -->
  <div class="compass-ring">
    <div class="compass-needle" :style="{ transform: `translate(-50%, -100%) rotate(${d?.heading ?? 0}deg)` }" />
    <span style="position:relative;z-index:1;font-size:14px;font-weight:700;color:var(--tcity-accent)">{{ d?.heading ?? 0 }}°</span>
  </div>

  <div class="gauge-row" style="margin-top:12px">
    <GaugeCard :value="(d?.speedKnots ?? 0) + ''" label="节 (kn)" />
    <GaugeCard :value="d?.speed?.kmh ?? 0" label="km/h" />
    <GaugeCard :value="d?.depth ?? 0" label="水深 (m)" />
  </div>

  <div class="gauge-row">
    <GaugeCard :value="(d?.fuel ?? 0) + '%'" label="燃油" />
    <GaugeCard :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" label="引擎健康" />
    <GaugeCard :value="d?.heading ?? 0" label="航向 °" />
  </div>

  <StatusRow label="发动机健康" :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.engine_health ?? 1000) / 10" />

  <StatusRow label="⚓ 吃水深度" :value="(d?.depth ? (d.depth < 1 ? '浅水区' : (d.depth / 10).toFixed(1) + ' m') : '--')" />
</template>
