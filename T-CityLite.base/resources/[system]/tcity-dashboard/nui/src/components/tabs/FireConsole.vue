<script setup lang="ts">
// tabs/FireConsole.vue — 🚒 消防车控制台

import { sendNui } from '../../composables/useNui'
import { useThrottle } from '../../composables/useThrottle'

const { canAct } = useThrottle(1000)

function doAction(action: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action })
}
function siren(mode: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action: 'siren', params: { mode } })
}
</script>

<template>
  <div>
    <div class="console-header">🚒 消防车控制台</div>
    <button class="prof-btn" @click="doAction('water_cannon')" style="margin-bottom:8px">💧 水炮开关</button>
    <button class="prof-btn" @click="siren('wail')">🔊 警笛控制</button>
  </div>
</template>

<style scoped>
.console-header {
  font-size:13px; font-weight:700; color:var(--tcity-accent); margin-bottom:12px;
  padding-bottom:8px; border-bottom:1px solid var(--tcity-border);
}
.prof-btn {
  width: 100%; padding: 14px; border-radius: 12px; border: none;
  font-size: 14px; font-weight: 700; cursor: pointer; transition: 0.2s;
  background: rgba(255,255,255,0.06); color: var(--tcity-text-dim);
}
.prof-btn:hover { background: var(--tcity-accent); color: white; }
</style>
