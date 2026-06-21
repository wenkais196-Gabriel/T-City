<script setup lang="ts">
// tabs/DiagTab.vue — 诊断页 (按模板动态渲染)

import { computed } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import SportsDiag from '../templates/SportsDiag.vue'
import CommercialDiag from '../templates/CommercialDiag.vue'
import EmergencyDiag from '../templates/EmergencyDiag.vue'
import PlaneDiag from '../templates/PlaneDiag.vue'
import HelicopterDiag from '../templates/HelicopterDiag.vue'
import BoatDiag from '../templates/BoatDiag.vue'
import VehicleTags from '../VehicleTags.vue'
import SeatMap from '../SeatMap.vue'

const store = useDashboardStore()

const diagComponent = computed(() => {
  const map: Record<string, unknown> = {
    sports: SportsDiag,
    commercial: CommercialDiag,
    emergency: EmergencyDiag,
    plane: PlaneDiag,
    helicopter: HelicopterDiag,
    boat: BoatDiag,
  }
  return map[store.template] || SportsDiag
})
</script>

<template>
  <div class="tab-content" style="display:block">
    <component :is="diagComponent" />
    <VehicleTags />
    <SeatMap />
  </div>
</template>
