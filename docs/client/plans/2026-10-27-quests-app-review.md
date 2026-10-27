# 调研 + 计划：任务 App 的「可发现性」与平板详情栏

> L2（一个 app 页面 + 它的 pane 契约）。计划落在本文，验收命令与回滚写在 §4 / §5。
> 触发：实机看到平板上「任务」App 行为怪（右栏按钮不对、切 tab 后两栏对不上）。

## 1. 结论先行（含对我先前判断的纠正）

**「不可接的任务不显示」不是 bug，是 4615b03 的产品决定**，理由写在提交里：
*A menu you cannot order from is not content.* 服务端仍然返回全部行，`/listquests`
和诊断保留完整画面。

真正的缺陷是这个决定**留下的残渣**，以及平板详情栏没跟上这个决定：

| # | 缺陷 | 影响 |
|---|---|---|
| 1 | `Quests.svelte` 头注释仍写「不可接的也照样显示，把 reason_text 摆出来」 | 与代码/测试相反，读代码的人（包括我）会被带偏 |
| 2 | 右栏对「进行中」的任务渲染「接取」 | 点必失败（`TriggerQuest` 拒绝），玩家看到「接取失败：…」 |
| 3 | 切 tab 不清 `selectedId` | 左边「进行中」、右边挂着上一个「可接」任务 |
| 4 | 三处死代码：`reasonText()`、`class:blocked`、`remaining_minutes` 分支 | 看起来「不可接」路径存在，实际永远不可达 |
| 5 | `stackBelow: 660`，但两栏 `min` 之和是 640 | 640–659px 明明装得下却降级成单栏 |
| 6 | 列表过滤后没有任何「还有多少内容」的提示 | 新玩家只看到「现在没有能接的任务」，以为 app 坏了（用户最初观感就是这个） |

## 2. 调研证据

| 证据 | 位置 | 说明 |
|---|---|---|
| 决策链 | `f2fc86b`（30 模板有门，blocked 带原因）→ `75696e0`（展示需求明细）→ **`4615b03`（只摆能接的）** | 三次连续迭代，最后一次推翻了前两次的展示方式 |
| 决策理由 | `4615b03` commit body | 需求 chips 是噪音（`min_police = 0` 这类零值门槛）；「点不了的菜单不是内容」；顺带修了「剧情已通关仍显示可接」 |
| 代码 | `web/src/apps/Quests.svelte:47` `rows.filter(canAccept)` | 过滤发生在客户端；服务端行里仍有 `available/reason_text/requirements` |
| 服务端契约 | `custom-quest/server/quest_availability.lua:283-295` | 返回 5 种 `reason`、`reason_text`、逐条 `requirements`、`remaining_minutes` |
| 测试 | `T-CityLite.base/resources/[custom]/custom-phone/web/tests/nui/quests.spec.mjs` 场景一 | 已断言「不可接的不出现」「拒绝原因不该出现」——**与 4615b03 一致**，是我先前的分析读漏了 |
| 设计文档 | `docs/server-design/11-work-tablet.md:75` | 只写了「Quests 的 detail query 服务端早就有，不新建数据模型」，没写展示策略 |

## 3. 计划（切三片，每片独立可跑）

| # | 切片 | 文件 | 验证 |
|---|---|---|---|
| S1 | 详情栏按 tab 渲染正确动作；切 tab 清选中；`canAccept` 收紧到 `=== true` | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Quests.svelte` | 新 NUI 场景：平板 + 进行中 → 右栏「放弃」且发 `appAction(abandon)`；切回可接不残留 |
| S2 | 头部计数「N 条可接 · M 条条件未满足 · K 条进行中」；删死代码；头注释改成现在的规则 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Quests.svelte` | 新 NUI 场景：计数文案 + blocked 行仍不出现 |
| S3 | `stackBelow: 660 → 640` | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/contracts/quests.panes.ts` | `node tests/nui/run.mjs --surface=both` 全绿；`surface.spec` 仍断言平板两栏 |

## 4. 验收标准（可执行）

| # | 命令 | 期望 |
|---|---|---|
| 1 | `cd web && npx svelte-check --tsconfig ./tsconfig.app.json` | 0 errors |
| 2 | `cd web && npm run build` | 产物进 `../../html`，`index.html` 引用的 hash 存在 |
| 3 | `cd web && node tests/nui/run.mjs --surface=both` | 全绿（含新增两个场景） |
| 4 | `cd T-CityLite.base && pytest -q tests/architecture` | 全绿（`test_surface_contracts` / `test_nui_baseline` / docs 闸门） |
| 5 | `pytest -q tests/unit` | 全绿（quest_availability 等不受影响） |
| 6 | 实机：`/tablet` → 任务 → 切「进行中」 | 右栏出现「放弃」，点击后列表刷新 |

## 5. 回滚

- 代码：`git revert <merge sha>`；本次无迁移、无 convar、无服务端契约变化。
- 运行时：`restart custom-phone`（客户端会重新拉 `html/`），不需要重启整服。

## 6. 风险

| 风险 | 处理 |
|---|---|
| 头部多一行计数被当成"噪音" | 只在 `blockedCount > 0` 时追加后半句，可接为 0 时最容易读懂 |
| 平板右栏改成「放弃」后误触 | 保持原来的两击确认？——不做，和手机 tab 里的「放弃」一致 |
| pane `stackBelow` 改变窗口区间行为 | 只影响 640–659 这一段，且是"本就能并排"的区间 |

## 7. 明确不做

- 不把不可接的任务重新塞回列表（推翻 4615b03 需要产品拍板，不在本次范围）。
- 不改服务端 `quest_availability.lua` / `T-CityLite.base/resources/[custom]/custom-phone/server/apps/quests.lua`（契约不变，零新增字段）。
- 不给平板加任何新查询或动作（`TABLET_GRANTS` 保持为空）。
