<script setup lang="ts">
// VehicleTags.vue — 车辆特征标签行
import { useDashboardStore } from '../stores/dashboard'

const store = useDashboardStore()
</script>

<template>
  <div v-if="store.vehicleTags.length" class="vehicle-tags">
    <span class="tags-label">🏷️</span>
    <span v-for="tag in store.vehicleTags" :key="tag" class="tag">{{ tag }}</span>
  </div>
</template>

<style scoped>
.vehicle-tags {
  display: flex; align-items: center; flex-wrap: wrap; gap: 6px;
  margin-top: 10px; padding-top: 8px;
  border-top: 1px solid var(--tcity-border);
}
.tags-label {
  font-size: 12px; color: var(--tcity-text-dim); margin-right: 2px;
}
.tag {
  display: inline-flex; align-items: center;
  padding: 3px 9px; border-radius: 12px;
  background: rgba(255,255,255,0.07);
  border: 1px solid var(--tcity-border);
  color: var(--tcity-accent);
  font-size: 10px; font-weight: 600;
  white-space: nowrap;
}
</style>
