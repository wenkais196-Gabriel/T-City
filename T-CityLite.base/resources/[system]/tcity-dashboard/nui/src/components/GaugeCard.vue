<script setup lang="ts">
// GaugeCard.vue — 仪表卡片
defineProps<{ value: string | number; label: string }>()
</script>
<template>
  <div class="gauge-card">
    <div class="gauge-value">{{ value }}</div>
    <div class="gauge-label">{{ label }}</div>
  </div>
</template>
