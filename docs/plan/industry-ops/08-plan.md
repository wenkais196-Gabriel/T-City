---
id: industry-ops-w1-phone-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：W1 — 手机端产业动作入口（#388）

S5 把手机端定成**只读**（成员看得见余额/工位/库存/配额，但什么都不能做）。
W1 补上两个动作，让管理者不必跑到 Boss 菜单的世界坐标：

| 动作 | 谁 | 走哪条路 |
|---|---|---|
| 卖出库存 | Boss | 手机 → 估价（服务端算）→ 确认 → `sell` |
| 雇工位 | Boss | 手机 → `hire`（只发 orgId，金额/工位号由服务端回） |

```plan-status
ALL | done | #388 | 2026-11-27
```

---

## 1. 契约（这次唯一新增的对外面）

| 面 | 内容 |
|---|---|
| 导出 | custom-industry 的 `HireIndustryWorkstation(orgId)` —— **直接**转发 `IndustryUi.HireWorkstation`，不复制 Boss 判定 |
| 手机动作 | `requestAppAction` 的 `app='industry'`，`action ∈ {sell, hire}`；**参数只带 orgId**（+ 卖出的 qty） |
| 前端 | `Industry.svelte` + `appRegistry` 注册；**`DynamicApp` 回退保留**（注册缺失时仍是只读列表） |
| 新 net event | **0**（全部走既有 `PhoneApps.Action` → `requestAppAction`） |

## 2. 为什么没复制权限判定

`IndustryAccess.IsOrgBoss` 已经是 S1 起的唯一权威。手机动作在服务端**再判一次**，
只会多一处能漂移的副本；这次走"导出转发"，判定仍只有一处。

## 3. 离线验证（我跑的，不是自报）

| 检查 | 结果 |
|---|---|
| `layer3_business` 全量 | 864 passed + 1 skipped + 51 subtests |
| `test_industry_ui` + `test_phone_apps` | 95 passed |
| 反向注入：去掉 `hire` 的 Boss 复验 | **1 failed**（还原后绿） |
| `svelte-check` | 0 errors（16 warnings 为既有） |
| NUI 场景（`node tests/nui/run.mjs --surface=both`） | **49 passed / 0 failed** |

## 4. 真机验收（2026-11-27）

服务器：`E:/T-City-w1` 的 `feat/phone-industry-actions`，端口 30130，`industry_enable=true`，
`phone_ui_nav=1`（`/phoneui industry` 可直达）。

### 4.1 观察到的

| 项 | 证据 |
|---|---|
| 产业 App 能打开（不是只读列表） | 客户端诊断 `kind=query app=industry code=ok why=ok path=CR|CF|SR|SD|CP|CA` |
| 卖出走"估价 → 确认 → 入账" | `org_ledger` 当日三条 `reason=sale`：`ref=sale:7` +250、`ref=sale:8` +8,900、`ref=sale:9` +50 |
| 余额链自洽 | `balance_after` 48,425 → 57,325 → 57,375（每条 = 上一条 + delta） |
| 库存真的扣了 | `industry_facility.stock` 由 204 降到 2；`produced_units` 204 |
| 配额真的记了 | `industry_demand`（`cycle_no=1 expansion`）`quota_used` 184 / `quota_total` 11000 |
| 用户结论 | 「W1 验了，都没问题」 |

### 4.2 没观察到的（不许写成已验）

| 项 | 为什么 |
|---|---|
| **雇工位的真机成功路径** | 当日 `org_ledger` 没有新的 `reason=workstation-hire` 行。**原因已确认：金库余额 57,375，第 4 个工位按 `floor(base×1.35^(n-1))` 约 16 万 —— 资金不足被前端 `hireBlocked` 挡住，属预期行为**（用户 2026-11-27 确认）。因此「资金不足」这条分支实际被真机覆盖了，「成功雇到工位」没有 |
| **非 Boss 只读** | 没有换 Grade1 角色实测；离线 NUI 场景覆盖了（"非 Boss 只读、不渲染动作按钮"） |
| 平板面 | CI 与本地跑的是同一套场景，真机只验了手机 |

上面三条都记在 #397，不在这份文档里假装已验。

## 5. 踩到的两个闸门问题（顺手修了）

| 现象 | 根因 | 修法 |
|---|---|---|
| CI 上 4 条产业 NUI 场景红（本地全绿） | 容器先画"加载中…"，快照是下一轮 NUI 往返才填进来的；慢 runner 上断言读到的是 loading 态 | `openIndustry` 显式等加载态结束（10s 轮询），不再拿 loading 去比文案 |
| 计划里写"构建产物 `https://` 为 0" | 产物里有 `https://svelte.dev/e/...`（Svelte 运行时错误信息的**文档链接**，不发请求），且旧产物里一模一样 | 判据改成"没有外部 `<script src>` / `<link href>`" |

## 6. 文件清单

| 文件 | 变化 |
|---|---|
| `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua` | 导出 `HireIndustryWorkstation` |
| `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua` | `hire` 动作（只收 orgId） |
| `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte` | 新增（377 行） |
| `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/appRegistry.ts` | 注册 industry |
| 重新构建的 `T-CityLite.base/resources/[custom]/custom-phone/html/` 产物 | 重新构建的产物 |
| `T-CityLite.base/resources/[custom]/custom-phone/web/tests/nui/harness.mjs` 与同目录 `industry.spec.mjs` | 场景 + 等快照落地 |

## 7. 回滚

单个资源重启即可：`restart custom-phone` + `restart custom-industry`。
数据面无迁移 —— 两个动作都只写既有的 `industry_sales` / `org_ledger` / `industry_facility`。
