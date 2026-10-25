import { mount } from 'svelte'
import './app.css'
import App from './App.svelte'
import { fetchNui, isBrowser } from './utils/nui'
import { requestAppQuery } from './core/request'

// NUI 侧自证握手（一次，页面加载时）。
//
// 双端联调最大的干扰项是"页面到底跑的是哪个 bundle"：CEF 会缓存 iframe 里的
// 页面，改完 JS 后可能仍在跑旧包，而旧包照样会 ack phone:open，于是看上去
// "手机是好的"。这个握手让页面把自己的 build id、location.host 和
// GetParentResourceName() 的返回值报给服务端：有日志=页面是新的且 NUI→Lua
// 路由通；完全没有=页面是旧的或路由不通。判定见
// docs/client/research/nui-debug-playbook.md §2。
//
// 握手之后立刻跑一次四段探针（设计 §7 probe）：用真实的 appQuery 走一遍
// NUI → client Lua → server → 回包 → NUI，把结果报给服务端。这样每次
// `restart custom-phone` 都有一次端到端自检，不需要人点。
if (!isBrowser()) {
  // CEF 里的宿主名必须和 GetParentResourceName() 对得上（harness / 浏览器预览
  // 都不会满足，探针因此不会污染测试里的请求记录）。
  const parentName =
    typeof (window as any).GetParentResourceName === 'function'
      ? (window as any).GetParentResourceName()
      : null
  const inCef =
    typeof parentName === 'string' &&
    parentName !== '' &&
    location.protocol === 'https:' &&
    location.host === `cfx-nui-${parentName}`

  void (async () => {
    try {
      await fetchNui(
        'nuiReady',
        {
          build: __NUI_BUILD__,
          host: location.host,
          href: location.href,
          parent: parentName,
        },
        { timeoutMs: 4000 },
      )
    } catch {
      /* 握手失败由 fetchNui 内部的 clientError 上报，这里不重复报 */
    }

    if (!inCef) return

    // 探针：一次真实查询，成功/失败码都算"链路通"（业务码由服务端决定）。
    const started = performance.now()
    const result = await requestAppQuery('police_mdt', 'units')
    const dur = Math.round(performance.now() - started)
    void fetchNui(
      'nuiProbe',
      {
        code: result.success ? 'ok' : String(result.error ?? 'unknown'),
        dur,
        build: __NUI_BUILD__,
      },
      { timeoutMs: 3000 },
    ).catch(() => {
      /* 探针自身失败已在上面的日志里体现 */
    })
  })()
}

const app = mount(App, {
  target: document.getElementById('app')!,
})

export default app
