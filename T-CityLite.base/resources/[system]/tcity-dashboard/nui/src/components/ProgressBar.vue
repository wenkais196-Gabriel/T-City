<script setup lang="ts">
// ProgressBar.vue
const props = defineProps<{ pct: number }>()
import { computed } from 'vue'
const cls = computed(() => ({
  'progress-fill': true,
  'warning': props.pct < 50,
  'danger': props.pct < 25,
}))
</script>
<template>
  <div class="progress-bar">
    <div :class="cls" :style="{ transform: `scaleX(${Math.max(0, Math.min(100, pct)) / 100})` }" />
  </div>
</template>
