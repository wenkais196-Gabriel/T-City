<script setup lang="ts">
// templates/SportsDiag.vue — 🏎️ 跑车/赛车诊断
import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import GaugeCard from '../GaugeCard.vue'
import ProgressBar from '../ProgressBar.vue'
import StatusRow from '../StatusRow.vue'

const store = useDashboardStore()
const d = computed(() => store.diag)
const REDLINE_THRESHOLD = 0.85
const inRedline = computed(() => (d.value?.rpm?.ratio || 0) > REDLINE_THRESHOLD)

</script>

<template>
  <!-- 速度/RPM/档位 -->
  <div class="gauge-row">
    <GaugeCard :value="d?.speed?.mph ?? 0" label="mph" />
    <GaugeCard :value="d?.rpm?.display ?? 0" label="RPM x100" :class="{ 'rpm-redline': inRedline }" />
    <GaugeCard :value="d?.gear ?? 0" label="档位" />
  </div>
  <div class="gauge-row">
    <GaugeCard :value="(d?.speed?.kmh ?? 0) + ''" label="km/h" />
    <GaugeCard :value="(d?.fuel ?? 0) + '%'" label="燃油" />
    <GaugeCard :value="(d?.oil_life ?? 100) + '%'" label="机油" />
  </div>

  <StatusRow label="发动机健康" :value="Math.round((d?.engine_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.engine_health ?? 1000) / 10" />

  <StatusRow label="车身损伤" :value="Math.round((d?.body_health ?? 1000) / 10) + '%'" />
  <ProgressBar :pct="(d?.body_health ?? 1000) / 10" />

  <StatusRow label="冷却水温" :value="(d?.coolant ?? 85).toFixed(1) + '°C'" />
  <StatusRow label="电池电压" :value="(d?.battery ?? 12.6).toFixed(1) + 'V'" />
  <StatusRow label="变速箱温" :value="(d?.trans_temp ?? 72).toFixed(1) + '°C'" />

  <!-- 涡轮增压 -->
  <template v-if="store.hasFeature('diag_turbo') && d?.turbo?.installed">
    <StatusRow label="🛡️ 涡轮增压" :value="(d?.turbo?.psi ?? 0).toFixed(1) + ' psi'" />
    <ProgressBar :pct="Math.min(100, (d?.turbo?.psi ?? 0) / 2 * 100)" />
  </template>

  <!-- 车门 -->
  <div style="margin-top:4px">
    <span style="font-size:11px;color:var(--tcity-text-dim)">🚪 车门</span>
    <span style="font-size:11px;margin-left:8px">
      <template v-for="(door, i) in (d?.doors?.doors || [])" :key="i">
        <span :style="{ color: door === 'open' ? 'var(--tcity-warning)' : 'var(--tcity-success)' }">🚪</span>
      </template>
      <span :style="{ color: d?.doors?.hood ? 'var(--tcity-warning)' : 'var(--tcity-success)' }">🔧</span>
      <span :style="{ color: d?.doors?.trunk ? 'var(--tcity-warning)' : 'var(--tcity-success)' }">📦</span>
    </span>
  </div>
</template>
