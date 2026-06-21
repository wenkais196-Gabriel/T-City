// composables/useThrottle.ts — 操作节流

import { ref } from 'vue'

export function useThrottle(cooldownMs = 1000) {
  const lastAction = ref(0)

  function canAct(): boolean {
    const now = Date.now()
    if (now - lastAction.value < cooldownMs) return false
    lastAction.value = now
    return true
  }

  return { canAct, lastAction }
}
