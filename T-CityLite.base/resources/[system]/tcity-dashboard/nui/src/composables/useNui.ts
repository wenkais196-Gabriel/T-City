// composables/useNui.ts — NUI 双向通信桥

import { onMounted, onUnmounted } from 'vue'
import type { NuiMessage } from '../types/dashboard'

type MessageHandler = (data: NuiMessage) => void

const handlers = new Set<MessageHandler>()

export function useNui(onMessage: MessageHandler) {
  const listener = (e: MessageEvent) => {
    const data = e.data as NuiMessage
    if (data && data.type) {
      onMessage(data)
    }
  }

  onMounted(() => {
    handlers.add(onMessage)
    window.addEventListener('message', listener)
  })

  onUnmounted(() => {
    handlers.delete(onMessage)
    window.removeEventListener('message', listener)
  })
}

/**
 * 发送 NUI 回调到 Lua 客户端
 * 所有 POST 走 fetch，Lua 端 RegisterNUICallback 接收
 */
export async function sendNui<T = unknown>(endpoint: string, body: unknown = {}): Promise<T> {
  try {
    const res = await fetch(`https://tcity-dashboard/${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    return (await res.json()) as T
  } catch {
    // NUI 不可用时静默失败
    return null as T
  }
}

/**
 * 关闭中控屏
 */
export function closeDashboard() {
  sendNui('closeDashboard', {})
}
