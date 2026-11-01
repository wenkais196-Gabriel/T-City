---
id: police-agent-control-research
type: research
status: final
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-01-30
---

# Agent 全面接管服务器与自动化测试调研

> 问题：为什么现在只能人工点、问题很怪？能否让 agent 接管服务器并自动测？

## 1. 现状：测试是“假”的

- `custom-testing` 已有 `/test` 框架，但 `suites/02_police_test.lua` 之类是**布尔模拟**：
  ```lua
  local onduty = false
  onduty = not onduty  -- 模拟 /duty
  ```
  不调用真实 export、不写 DB、不经过权限/审计。
- 单元测试大量用 Lua/Python stub，只验证代码形状，不验证运行时。
- NUI/MDT 没有浏览器级测试；CEF 里的 `appQuery`/`loading` 竞态只能人工撞。
- 因此：**646 个测试全绿，仍然会出“第一次点击失败/刷新卡死”**。

## 2. 三层自动化（Linux 服务器可行）

### L1 服务端 E2E（最该先做，100% 可自动化）

在 `custom-testing` 里写**真实场景套件**，通过 export + DB 断言：

- `/test run police_e2e`（控制台 source=0）
- 用在线测试角色或测试 citizenid：
  - duty：`SetDutyForSource` → 查 `players.job.onduty` + `police_units`
  - incident：`CreateIncident` → `AssignUnit` → `enroute` → `on_scene` → `cleared` → 查 closed/disposition
  - NPC budget：Acquire→Get→Release→Get
  - outbox：Enqueue→等待→查 `police_outbox.status='done'`
  - sentence：`ApplySentence`→`AdjustSentence`→`ReleaseSentence`→查 `justice_sentences`
  - audit：每一步查 `police_audit`
- 失败时输出 `file/step/expected/actual`，并在结束时清理测试数据。
- 这套能覆盖 B（服务端建单/派单/关闭）、C/D 的预算、E 的幂等、F 的刑期、G 的审计。

### L2 NUI/组件测试（Playwright，可自动化）

- 用 Vitest/Playwright 在浏览器里加载 `html/index.html`，mock `GetParentResourceName` / `fetch`。
- 覆盖：MDT 五页切换、刷新按钮 `loading` 复位、错误码渲染、表单校验、请求失败重试。
- 直接能抓 L1/L4 这类前端问题。

### L3 真实客户端 E2E（受限，建议后置）

- Windows 有 [`fivem-mcp`](https://github.com/VIRUXE/fivem-mcp)：MCP 驱动客户端输入、截图、devcon 控制台、RCON。
- 我们的服务器在 Linux；没有等价的成熟 Linux 客户端驱动。
- 可选：Wine + `xdotool`/截图，但脆弱、不适合 CI。
- 结论：**客户端/CEF 的最终验收仍需人工**，但 L1+L2 能把 90% 的“怪问题”提前抓出来。

## 3. Agent 接管服务器：能做什么、不能做什么

### 已具备

- `custom-director`：4 个警察工具（看板/建警情/派单/送监），L1–L3 审批。
- `custom-agent-client` / live API：agent 可读状态、执行动作。
- RCON/控制台：可 `ensure/restart`、执行命令。

### 缺口

1. **工具面太窄**：没有 duty、罚单、案件、令状、NPC、刑期、DB 查询、测试运行。
2. **没有测试工具**：agent 不能自己跑 E2E、读断言结果。
3. **没有健康/指标**：资源是否启动、DB 延迟、outbox 积压、NPC 预算使用率不可见。
4. **没有安全沙箱**：agent 动作没有“测试模式/只读模式/最大动作数/急停”。

### 建议的“控制平面”

- **动作目录**扩展：`duty_set`、`sentence_apply/release`、`npc_callout`、`incident_close`、`outbox_enqueue`、`test_run`、`db_query`（只读白名单）。
- **测试工具**：`test_run suite` 返回结构化 JSON（pass/fail/steps），agent 可据此修复-重跑。
- **感知**：`health_snapshot`（资源状态、DB 延迟、outbox、预算、在线警察）。
- **安全**：L1 自动 / L2 人审 / L3 双重确认；测试动作仅 source=0 或 test 角色；token 分离；审计不可关；急停命令。
- **沙箱**：`/test` 只允许在 `tcity_fit6_test` 或测试角色上跑；生产库拒绝。

## 4. 落地顺序

1. **P0**：把 `custom-testing` 的 police 套件改成真实 E2E（服务端），加 `/test run police_e2e`。
2. **P1**：Playwright 跑 MDT（mock NUI），覆盖刷新/加载/错误码。
3. **P2**：给 director 加 `test_run` + `health_snapshot` + `db_query`（只读）。
4. **P3**：可选 Wine 客户端驱动，只做本地人工辅助，不进 CI。

## 5. 结论

- **可以自动化**，但要在**正确的层**：服务端 E2E + 浏览器 NUI；不是靠模拟布尔。
- **可以让 agent 接管服务器**，但必须先补工具面、健康感知、测试入口和安全闸门。
- 现在这些“怪问题”本质是：**没有真实 E2E，单元测试覆盖不到运行时/前端状态机**。

## 参考

- [fivem-mcp：驱动 FiveM 客户端（Windows）](https://github.com/VIRUXE/fivem-mcp)
- [fivem-mcp-server（MCP 封装）](https://www.npmjs.com/package/fivem-mcp-server)
- [FiveM web surface / remote control 分析](https://pyth3rex.github.io/blog/2026/03/26/fivem-web-surface/)
