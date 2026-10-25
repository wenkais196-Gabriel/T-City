# AGENTS.md — 手机前端（custom-phone/web）

> 目录：`T-CityLite.base/resources/[custom]/custom-phone/web/`。
> Svelte 5 + Vite；构建产物落在同级 `../../html/`，**产物必须提交**。

## 唯一入口

| 需求 | 唯一做法 |
|---|---|
| 调后端 | `src/utils/nui.ts` 的 `fetchNui` / `requestAppQuery` / `requestAppAction`（带超时与失败上报） |
| 资源名 | `GetParentResourceName()`（`nui.ts` 内部已处理），业务代码不要自己拼 |
| 全局状态 | `src/stores/*`；不要跨组件直接改别人的 store 字段 |
| 样式/组件 | 复用 `src/components/*` 与现有 token；新组件先找有没有可复用的 |

## 禁止

- 业务代码里直接 `fetch(...)`、`$.post`、硬编码 `cfx-nui-<resource>`（闸门会红）。
- 在页面里做权限判断当安全边界（NUI 隐藏 ≠ 权限，一切以服务端为准）。
- 把 PII / token 写进 `localStorage`：玩家可以开 devtools，前端内存等于公开。
- 改完源码只提交 `html/` 不重建，或只重建不提交（两者都会让实机跑旧包）。

## 改动前必读

- **构建产物带内容哈希**（`assets/[name]-[hash].js`）：`index.html` 引用的 hash 必须存在，
  否则 CEF 拿到 404 → 白屏且**没有任何日志**（`test_nui_baseline.py` 会拦）。
- **超时阶梯**：NUI `fetch` 超时 `NUI_TIMEOUT_MS = 6000`、app 请求 `9000`，
  而客户端 Lua 的服务端兜底必须**早于** NUI abort（当前 `SetTimeout(4000)`），
  否则前端只能看到 `AbortError` 而不是结构化错误码。
- **自证握手**：页面挂载前发 `nuiReady {build, host, href, parent}`，然后跑一条真实
  `appQuery('police_mdt','units')` 并把 `code/dur` 回报（`nuiProbe`）。只在 CEF 内跑
  （`inCef` 门禁），浏览器预览不要污染服务端日志。
- **失败可见**：所有传输层失败走 `reportNuiFailure`（10s 去重），服务端打
  `[custom-phone][nui-error]`。abort 也要上报——9s abort 本身就是"请求消失"。

## 已知坑

- `SendNUIMessage` 是投递后不管：frame 未加载时消息静默丢失，所以打开要 ack 重发。
- CEF 不缓存资源文件，但**页面内的 localStorage 会跨重启保留**，脏 key 会让新代码读到旧状态。
- 改 `vite.config.ts` 的产物命名后，必须重建并**同时提交** `index.html` 与 `assets/*`。
- `svelte-check` 报的重复键（如 i18n 里两个同名 key）是真 bug：后者静默覆盖前者。

## 验收命令

```bash
cd T-CityLite.base/resources/[custom]/custom-phone/web
npx svelte-check --tsconfig ./tsconfig.app.json     # 0 errors
node tests/nui/run.mjs                              # NUI harness 全绿
npm run build                                       # 产物进 ../../html
cd ../../.. && /usr/bin/python3 -m pytest tests/architecture/test_nui_baseline.py -q
tcity-cmd -w 8 "restart custom-phone"               # 之后看三条自检日志
```

实机自检三条：`[nui-ready] … parent=custom-phone`、`[probe] code=ok`、`[diag] … break=none`。
