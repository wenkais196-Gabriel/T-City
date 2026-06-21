<script setup lang="ts">
// TabBar.vue — 标签栏

import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()

const tabs = [
  { id: 'diag', label: '📊 诊断' },
  { id: 'ctrl', label: '🛠️ 控制' },
  { id: 'drive', label: '🚀 驾驶' },
  { id: 'prof', label: '🚨 职业', show: () => store.isEmergency || store.isAircraft || store.isBoat || ['police','ambulance','fire','pilot'].includes(store.job) },
]
</script>

<template>
  <div class="tab-bar">
    <button
      v-for="tab in tabs"
      v-show="tab.show ? tab.show() : true"
      :key="tab.id"
      class="tab-btn"
      :class="{ active: store.activeTab === tab.id }"
      @click="store.setActiveTab(tab.id)"
    >{{ tab.label }}</button>
  </div>
</template>
