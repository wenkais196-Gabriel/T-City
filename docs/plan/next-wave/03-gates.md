---
id: plan-next-wave-gates
type: plan
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
---

# 本轮闸门：复用、新增、棘轮

> **原则**：闸门拦下的规则必须有宪法/架构依据；没有依据的检查删掉，不要让人把闸门当噪音。
> 新闸门必须带反向注入（喂一段坏形状必须红），否则只是一条永远绿的断言。
>
> **命令口径**：带 `.exe` 的 Lua 工具在 PowerShell 里必须写全名（`luac5.4.exe`），否则 Windows 会把 `.4`
> 当文档打开并阻塞。pytest 用 Python 3.12 解释器；本机 PATH 上的 `python` 没有 pytest。

## 1. 每次交付必跑（现成闸门）

在 `T-CityLite.base` 下：

```
pytest tests/architecture tests/unit/layer3_business -q
```

这是本轮的全量离线闸门，约 **4–5 分钟**；慢不是卡死，不要杀进程。产业/菜单之外的层不在本命令里，
但本轮的改动面都在 `tests/architecture` 与 `tests/unit/layer3_business`。

| 闸门 | 命令 | 本轮用途 |
|---|---|---|
| 架构 + 产业单测 | `cd T-CityLite.base && pytest tests/architecture tests/unit/layer3_business -q` | 每个 PR 的底线 |
| 文档生命周期 | `python tools/docs_lifecycle.py --check` | 新增 4 份计划文档的 frontmatter/链接/索引 |
| 文档链接 | `cd T-CityLite.base && pytest tests/architecture/test_docs_links.py -q` | 本文件所有反引号路径必须存在 |
| 命令清单 | `python tools/dev/scan_commands.py --check` | D1 之后不再因行号漂移变红 |
| 交付三件套 | `python tools/dev/release_check.py` | 代码 + 文档 + CHANGELOG |
| Lua 语法 | `luac5.4.exe -p <file.lua>` | 改 Lua 后逐个文件；qb-core 的 `+=` 例外 |
| 手机前端类型 | `cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run check` | W1 改 Svelte |
| 手机 NUI | 同上：`npm run build && node tests/nui/run.mjs` | W1/W3 |
| 菜单取证 | `python tools/dev/menu_surface_census.py` | W3 重测基线 |
| 产业真机 | `python tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` | W0/W2 的真机验收 |

## 2. 本轮新增闸门

### 2.1 `test_industry_balance.py`（W0）

**判什么**

- `sum(Phases[*].days) == CycleDays`，且 `IndustryCycle.CycleEndsAt` 算出的周期末端与它一致。
- 设施 + 1 工位回本 3–14 天、单设施日毛利 $15k–$30k、单组织单周期收入 ≤ $5M；
  阈值与计算过程写进测试常量，不写“约”。
- 一个阶段的可产库存 ≥ 该阶段配额；否则“库存上限”是装饰。
- 两家组织同时卖时，第二家超过 50% 份额必须被拒绝（`org_cap_reached`）。

**反向注入**

- 任一阶段天数 +1 → 天数断言红。
- `SeedQuota` 调回 10 → 收入带断言红。
- `OrgCapRatio` 改成 1.0 → 50% 上限断言红。

**收集方式**：放在 `tests/unit/layer3_business/` 下，文件名以 `test_industry_` 开头，现有 pytest 配置会自动收集。

### 2.2 `test_industry_push.py`（W2）

**判什么**

- 两个在线组织成员 + 一个非成员 → 恰好 2 次 `Notify` 调用，0 次给非成员。
- 同一周期第二次 tick → 0 次新增通知；`industry_enable=false` → 0 次。
- `app_id` 是 `industry`，且 `PhoneNotify` 的白名单接受它。
- CityFeed 仍恰好 1 条（推送不导致公告重复）。

**反向注入**

- 删掉 `maybeWarn` / `maybeResultAnnounce` 的每周期水位 → “第二次 tick 不新增”必须红。
- 把 `NOTIFY_APP_IDS.industry` 删掉 → `app_id` 断言必须红。
- 把非成员也加进推送循环 → 调用次数断言必须红。

**收集方式**：放在 `tests/unit/layer3_business/` 下；不要只放在 `tests/tools/`（那不是业务闸门）。

### 2.3 手机 App 用例（W1，扩展现有 `test_phone_apps.py`）

**判什么**

- `industry` 在 `appRegistry` 里映射到专用页面；`dyn:industry` 不再回退 `DynamicApp`（但回退路径仍存在）。
- 非组织成员看不到 App；Boss 的 `sell` 先 estimate 再 sell；非 Boss 伪造 `sell`/`hire` 返回 `not_boss`。
- `hire` 动作只收 `orgId`，金额由服务端 `HireWorkstation` 计算。

**反向注入**

- 删掉 `hire` 动作里的服务端权限调用 → 非 Boss 用例必须红。
- 把 `Industry.svelte` 从 `appRegistry` 移除 → “专用页面”断言必须红。
- 在页面里写死一个金额 → 构建产物静态断言（金额来自服务端）必须红。

**收集方式**：扩展 `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py`；不要新建第二套 App 测试目录。

### 2.4 `test_menu_architecture.py`（W3）

**判什么**

以重测后的 `menu_surface_baseline.json` 为棘轮：

- `menuv_entry` 除 menuv 自身外 = 0；
- 非排除资源 `backdrop_filter` = 0（monitor 的 6 处作为显式排除项保留）；
- `setnui_single_arg` 只允许 allowlist 内的点（qb-input 的两处必须带到期日）；
- 门卫用途的 `isnuifocused_read` 只允许 allowlist 内的点；
- 新增 `SetNuiFocus` 调用点必须显式登记（按“资源 + 文件 + 计数”，不登记行号）；
- `client_wait_zero` 只许下降；手机主循环合并后应比 M6 后基线少 1。

**反向注入**

- 手工加一处未登记的 `SetNuiFocus` → 红。
- 回填一处 `backdrop-filter` → 红。
- 重新引入一处 `MenuV` 引用 → 红。

**收集方式**：放在 `T-CityLite.base/tests/architecture/` 下，`pytest tests/architecture -q` 自动收集。

## 3. 本轮收紧的棘轮（只许下降）

| 文件 | 当前值 | 本轮怎么动 | 不许 |
|---|---|---|---|
| `T-CityLite.base/tests/architecture/menu_surface_baseline.json` | 2026-11-25 取证；与当前代码不一致 | W3 开工前重跑 census，写入新基线；M6 后 `menuv_entry` 除 menuv 自身外归 0 | 拿旧基线直接当棘轮；把新代码的计数写高 |
| `T-CityLite.base/tests/architecture/gate_coverage_budget.json` | `max_unproven = 281` | 新增闸门必须带反向注入；能降低就降低 | 新增闸门但不证明它会红，导致 `max_unproven` 上调 |
| `T-CityLite.base/tests/architecture/io_budget.json` | 含 custom-industry 生产 tick 的 `unknown-interval` 债务，到期 2027-03-31 | W1/W2 不新增线程；W3 合并双 `Wait(0)` 后 `client_wait_zero` 下降 | 用 `Wait(1)` 绕过 `Wait(0)` 计数；新增逐帧循环 |
| `T-CityLite.base/tests/architecture/reuse_budget.json` | 现有同名实现预算 | 只许下降；新增共享 helper 要同 PR 降预算 | 为省事复制第二份实现 |
| `T-CityLite.base/tests/architecture/net_events_allowlist.json` | 现有事件登记 | 本轮零新增（W1/W2 都不新增 net event） | 新增事件不登记、或登记成 `diagnostic` 却带业务 payload |
| `T-CityLite.base/tests/architecture/table_owners.json` | 8 张产业表已登记；治理表无 owner | 本轮不改 schema；I5 触发时先登记 owner + scan | 新表不登记 owner；跨资源直写 |
| `T-CityLite.base/tests/architecture/broadcast_allowlist.json` | 债务清单 | 本轮零新增 `TriggerClientEvent(..., -1, ...)` | 用全服广播代替按组织成员推送 |

**关于 `menu_surface_baseline.json` 的现状**：文件里是 2026-11-25 的取证结果，当前 census 已经变了：
旧 `setnui_focus=205` vs 当前 195；旧 `isnuifocused_read=34` vs 当前 27；旧 `qb_menu_entry=149` vs 当前 159；
旧 `client_wait_zero=222` vs 当前 223。W3 的第一项任务就是重测；在重测之前，这个文件不是闸门，只是历史证据。

## 4. 到期日与债务

| 债务 | 到期 | 本轮处理 |
|---|---|---|
| #379 Sonar 三项（Duplication / Security / Reliability） | **2027-01-15** | W5 关闭或改规则；没有 token 不算关闭 |
| `io_budget.json` 里 custom-industry 的生产 tick（`unknown-interval`） | **2027-03-31** | 本轮不新增线程；W0 改 tick 间隔时保留这条登记 |
| `m4_focus_allowlist.json` 里 qb-adminmenu 原生键盘的两处 | **2027-02-28** | M6 迁移时清理；M7 闸门允许它带到期日存在 |
| `m4_focus_allowlist.json` 里 story-engine 诊断读取 6 处 | **2027-04-30** | 不在本轮范围；M7 闸门保留 |
| `qb-input` 的两处单参 `SetNuiFocus(false)` | 由 M7 决定 | M7 allowlist 必须带到期日；M6 不碰 qb-input |

## 5. 闸门失败时怎么处理

1. **先判断是代码错还是规则错**。代码错就改代码；规则错就在同 PR 写“为什么旧条款不成立”+ 到期日，
   不能直接删断言或把计数调高。
2. **新闸门必须自证会红**。至少一条反向注入；只有“绿”的闸门没有证明力。
3. **不要为了过闸门改闸门**。把 `max_unproven` 上调、把 `client_wait_zero` 基线调高、把 `menuv_entry`
   排除项扩大，都属于“改规则而不是改代码”，必须在 PR 描述里单列并给出理由。
4. **真机项不能拿单测代替**。产业周期、手机开合、平板锁、推送深链都必须在真机有读数；
   离线用例只证明逻辑。
