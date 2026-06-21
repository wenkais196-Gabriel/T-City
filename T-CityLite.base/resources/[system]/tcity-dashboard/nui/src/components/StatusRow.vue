<script setup lang="ts">
// StatusRow.vue
defineProps<{ label: string; value: string | number }>()
</script>
<template>
  <div class="status-row">
    <span class="label">{{ label }}</span>
    <span class="value">{{ value }}</span>
  </div>
</template>
