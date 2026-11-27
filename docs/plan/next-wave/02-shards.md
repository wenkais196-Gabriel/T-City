---
id: plan-next-wave-shards
type: plan
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
---

# 分片建议：issue 草稿（按依赖排序）

> **用法**：每条是一个可直接建 issue 的草稿。正文第一项固定是“前序核验”；前序不成立就不动代码，
> 回到前一个 issue 把它做完（往前溯）。
>
> **并行边界**：第 0 组五片可以同时开工，但有两处文件重叠：
> ① W1 与 W2 都碰 `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py`，建议 W1 先合、W2 rebase；
> ② W0 拥有 `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`，W2 不要改它，
> 推送文案只读现有的 `RemainingText`。

## 执行顺序

```
第 0 组（可立即并行）
  W4 #369 命令清单去行号（先合，减少后续 CI 噪音）
  W0 产业数值卡与真实周期长度
  W1 手机端产业动作入口
  W2 周期公告推送
  W5 #379 Sonar 三项（2027-01-15 到期）

第 1 组（串行，有前置）
  M6 #348（外部在途）
    └→ W3 M7 手机双 Wait(0) + 菜单架构棘轮
```

M6 不在本文件重复起草：它已派给另一个 agent，issue 是 #348。W3 的前序核验会检查它是否合入。

---

## W4 — ✅ 已完成（2026-11-27，PR #382 / `e75de4ad`）—— 保留原文作记录

### 前序核验（第 1 项，必须先做）

- [ ] 确认 #369 的实现分支 `tool/commands-doc-identity`（提交 `648a943b`）仍在，且 `git diff master...origin/tool/commands-doc-identity`
      只含 `tools/dev/scan_commands.py`、`docs/client/ux/admin-commands.md`、`docs/INDEX.md`；
- [ ] 如果 master 已经合入 #369 或其中的等价改动，本 issue 直接关闭，不重复实现；
- [ ] 如果 M6 已经改了 `qb-adminmenu` 的命令注册，先 rebase 并重跑扫描器。

### 为什么

行号是派生数据：改一行注释它就漂，`test_admin_commands_doc.py` 就红。2026-11-26 一天内为此跑了 3 次 CI
（#365 / #368 / M2 各一次）。命令的身份是“名字 + 资源 + 类型”，不是“文件内位置”。

### 范围

- 采用 #369 的方案 A：表头去掉位置列，资源作为分组标题；危险命令表的位置列改成资源列；
  文档里写清“需要定位时用 `rg` 现场查”。
- 不改命令注册方式，不引入 AST 解析。

### 任务清单

- [ ] 前序核验。
- [ ] rebase `tool/commands-doc-identity` 到最新 master；解决 `admin-commands.md` 冲突时以扫描器输出为准。
- [ ] 确认 `python tools/dev/scan_commands.py --check` 与 `pytest T-CityLite.base/tests/architecture/test_admin_commands_doc.py -q` 绿。
- [ ] 更新 `CHANGELOG.md`。
- [ ] 合入后删除远端分支 `tool/commands-doc-identity`（由 Hermes 执行）。

### 验收标准

- [ ] `python tools/dev/scan_commands.py --check` 退出码 0。
- [ ] 往 `T-CityLite.base/resources/[qb]/qb-target/client.lua` 末尾加一行注释 → 重跑扫描器 → 闸门**仍绿**。
- [ ] 真的新增/删除一条命令 → 闸门红。
- [ ] `cd T-CityLite.base && pytest tests/architecture/test_admin_commands_doc.py -q` 绿。

### 涉及文件

`tools/dev/scan_commands.py`、`docs/client/ux/admin-commands.md`、`T-CityLite.base/tests/architecture/test_admin_commands_doc.py`、
`CHANGELOG.md`。

### 不做

- 不改命令本身的注册方式。
- 不保留一张“会慢慢烂掉”的行号附录。

---

## W0 — `feat(industry): 数值卡与真实周期长度（默认配置可开放）` → **#387**

### 前序核验（第 1 项，必须先做）

- [ ] 确认 S8（#375）已合入，且 `python tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` 在真机有通过记录；
- [ ] 用 `git show` 核对 `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua` 当前四阶段是
      10/10/5/3（28 天），设计稿 §5 写的是 10/10/5/3/2（30 天）；
- [ ] 确认 `industry_demand_seed` 的默认值仍是 10、`industry_sale_price` 仍是 50；如果已被运维改过，以代码默认值为准并在 issue 里记录。

### 为什么

默认配置下，单组织单周期最多卖 20 件（每阶段 5 件 × 四阶段）、收入约 $962；设施 + 1 工位成本 $100,000，**回本约 104 个周期**。
库存上限 144 永远碰不到，配额先耗尽。这不是“平衡得不好”，是“还没有进入平衡阶段”。
同配置里还有 28 天 vs 30 天的口径冲突，必须在公告“真实周期”之前定死。

### 范围

- 给出正式数值卡（不是验收 convar）：设施/工位成本、单工位产能、售价、每阶段配额、库存上限、prestige 系数。
- 决定周期长度：28 天（代码现状）或 30 天（设计稿含结算阶段）；二者选一，改配置与文档。
- 加可执行的数值断言；不改 schema，不加新表。
- 真机压缩周期验收 + 14 天试玩报告。

### 任务清单

- [ ] 前序核验。
- [ ] 写数值卡：至少包含“单设施日毛利 / 单周期收入 / 回本周期 / 两家组织时 50% 上限是否生效”。
- [ ] 定周期长度；如果选 30 天，明确“结算 2 天”是状态机阶段还是公告窗口，不能只在文档里多一行。
- [ ] 改 `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`、同目录的
      `facility.lua`、`sales.lua`、`production.lua` 的正式值。
- [ ] 新增数值断言（建议文件 `test_industry_balance.py`）：周期天数、设施 + 1 工位回本 3–14 天、
      单设施日毛利 $15k–$30k、单组织单周期收入有可执行断言（默认约 \$962 = 5 件×4 阶段×$50×3.85 阶段倍率）、库存/配额关系、50% 上限。
- [ ] 反向注入：阶段天数 +1、`SeedQuota` 调回 10、`OrgCapRatio` 改 1.0 → 对应断言必须红。
- [ ] 真机跑 `industry_cycle_probe.py --scale 60 --cycles 2`。
- [ ] 14 天试玩：每天记录销售额、库存、参与组织数、在线人数；出结论。
- [ ] 更新 `docs/server-design/12-industry-operations.md` §5/§10/§20 与 `CHANGELOG.md`。

### 验收标准

- [ ] `cd T-CityLite.base && pytest tests/unit/layer3_business/test_industry_cycle.py tests/unit/layer3_business/test_industry_sales.py tests/unit/layer3_business/test_industry_facility.py -q` 全绿。
- [ ] 新增数值断言全绿；三条反向注入各自变红。
- [ ] `python tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` 真机通过。
- [ ] 14 天报告给出“保留 28 / 改 30 / 改其他”的明确结论与数据；没有报告不算完成。
- [ ] `docs/server-design/12-industry-operations.md` 的周期表与代码一致。

### 涉及文件

`T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`、同目录的 `facility.lua`、`sales.lua`、
`production.lua`、`T-CityLite.base/tests/unit/layer3_business/` 下现有产业用例与新增数值用例、
`docs/server-design/12-industry-operations.md`、`docs/plan/industry-ops/06-plan.md`、`CHANGELOG.md`。

### 不做

- 不改 `industry_facility` 的 schema。
- 不为了“让产业赚钱”去抬 `core_economy` 的全局倍率。
- 不把验收 convar 的值写进正式配置。

---

## W1 — `feat(phone): 手机端产业动作入口（卖出 / 雇工位）` → **#388**

### 前序核验（第 1 项，必须先做）

- [ ] 确认 `custom-phone` 的 `industry` App 仍注册在
      `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua`，且 `actions.sell` 已存在；
- [ ] 确认 `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua` 的 `HireWorkstation` 仍是玩家侧写入口，
      且 `IndustryAccess.IsOrgBoss` 仍是唯一权限判定；
- [ ] 确认 `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/appRegistry.ts` 的
      “服务端 App id → 专用 Svelte 页面”路径仍可用（任务 App 是样板）；
- [ ] 如果 `T-CityLite.base/resources/[custom]/custom-phone/web/node_modules` 缺失，按
      `T-CityLite.base/resources/[custom]/custom-phone/web/AGENTS.md` 的构建前置处理；**不要**把 `node_modules` 提交。

### 为什么

S5 明确把手机端定成只读；卖出入口只有 Boss 菜单的世界坐标。服务端 `sell` 动作已经实现并测过，
缺的是 `hire` 导出与一个能承载动作的 Svelte 页面。手机是这个服的第一入口。

### 范围

- 新增 `Industry.svelte`，在 `appRegistry.ts` 注册 `industry`；`dyn:industry` 优先用专用页面，
  构建失败时仍可回退 `DynamicApp` 只读列表。
- 服务端新增 `HireIndustryWorkstation` 导出（复用 `IndustryUi.HireWorkstation`），手机 App 增加 `hire` 动作。
- 不新增 net event；所有动作继续走 `requestAppAction` → `PhoneApps.Action` → `custom-industry` 导出。

### 任务清单

- [ ] 前序核验。
- [ ] `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua` 导出 `HireIndustryWorkstation`；不复制 Boss 判定。
- [ ] `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua` 增加 `hire` 动作；
      参数只收 `orgId`，不收金额/工位号。
- [ ] 新增 `Industry.svelte`：快照、卖出（estimate → 确认 → sell）、雇工位（显示 `nextWorkstationCost` 与 `hireBlocked`）。
- [ ] `appRegistry.ts` 注册 `industry`；保留 `DynamicApp` 回退。
- [ ] `npm run check`、`npm run build`；提交 `html/` 产物。
- [ ] 新增用例：非成员不可见、Boss 可卖/可雇、非 Boss 返回 `not_boss`。
- [ ] 真机验收。
- [ ] 更新 `CHANGELOG.md` 与 `docs/client/ux/menu-regression-checklist.md`（如果新增了手机路径）。

### 验收标准

- [ ] `cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run check` 退出码 0。
- [ ] `npm run build` 退出码 0；`node tests/nui/run.mjs` 退出码 0。
- [ ] `cd T-CityLite.base && pytest tests/unit/layer3_business/test_phone_apps.py tests/unit/layer3_business/test_industry_ui.py -q` 全绿。
- [ ] 新增用例覆盖：非成员看不到 App；Boss 卖出走 estimate → sell；非 Boss 伪造 `sell`/`hire` 返回 `not_boss`。
- [ ] 构建产物中 `https://` 与 `backdrop-filter` 为 0。
- [ ] 真机：组织成员手机可见产业 App；Boss 卖 5 件，`org_ledger` / `industry_sales` 各增一行；非 Boss 页面无按钮且伪造动作被拒。

### 涉及文件

`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua`、
`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua`、
`T-CityLite.base/resources/[custom]/custom-phone/web/src/core/appRegistry.ts`、
新增 `Industry.svelte`（放在 `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/`）、
`T-CityLite.base/resources/[custom]/custom-phone/html/`（构建产物）、
`T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py`、`test_industry_ui.py`、`CHANGELOG.md`。

### 不做

- 不在前端算钱（金额只来自 `EstimateIndustrySale`）。
- 不为手机单独写一套权限判定。
- 不新增 NUI net event。

---

## W2 — `feat(phone): 周期公告推送（警告 + 结果）` → **#389**

### 前序核验（第 1 项，必须先做）

- [ ] 确认 `custom-phone` 的 `PhoneNotify` 导出仍存在，且 `Notify` 仍接受 `(citizenid, title, content, appId, meta)`；
- [ ] 确认 `NOTIFY_APP_IDS` 仍只允许 `banking` / `police_mdt`；本片要加 `industry`；
- [ ] 确认 `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua` 的
      `maybeWarn` / `maybeResultAnnounce` 仍是“每周期一次”的水位；
- [ ] 确认 W1 是否已合入；如果未合入，深链会落到只读 `DynamicApp`，这不阻塞本片，但要在 PR 里写明。

### 为什么

#338 的验收写了“CityFeed + 手机推送”，实现只做了 CityFeed；`announce.lua` 的文件头也写明“留给后续片”。
结算会清空设施、库存、配额与金库余额；没有提前通知，玩家会认为资产被偷。

### 范围

- 给在线组织成员推一条通知；离线成员继续靠 CityFeed，不伪造“全服推送”。
- 通知 `app_id = industry`，深链到产业 App；标题/正文只放周期号、组织名、金额/时间，不放 PII。
- 复用现有 `PhoneNotify`，不新增 net event；失败只记日志，不阻断结算。

### 任务清单

- [ ] 前序核验。
- [ ] `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua` 的 `NOTIFY_APP_IDS` 加 `industry`。
- [ ] `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua` 增加“按在线组织成员推送”：
      遍历 `QBCore.Functions.GetQBPlayers()`，对每个玩家遍历 `Config.Industry.OrgWhitelist` 调
      `IndustryAccess.OrgMembership`（或复用 `IndustryUi.PlayerOrgId`）判断是否属于任一组织，
      再调 `exports['custom-phone']:Notify`。`Notify` 的 `meta.source` 用 `Player.PlayerData.source`。
- [ ] 推送挂在 `maybeWarn` / `maybeResultAnnounce` 的既有水位之后；同一周期不重复。
- [ ] 新增用例（建议 `test_industry_push.py`）：2 个成员 + 1 个非成员 → 2 次；重复 tick → 0 次；
      `industry_enable=false` → 0 次；`app_id` 是 `industry`。
- [ ] 真机压缩周期验收。
- [ ] `CHANGELOG.md`。

### 验收标准

- [ ] `cd T-CityLite.base && pytest tests/unit/layer3_business/test_industry_cycle.py tests/unit/layer3_business/test_phone_apps.py -q` 全绿。
- [ ] 新增推送用例全绿；删掉“每周期一次”水位后，重复 tick 用例必须红。
- [ ] 真机 `industry_phase_seconds=60`：警告 1 条通知 + 1 条 CityFeed；结果 1 条通知；点击通知进产业 App。
- [ ] 离线成员上线后能看到 CityFeed 历史公告，但不会收到旧的推送。
- [ ] `net_events_allowlist.json` 零新增（本片不新增 net event）。

### 涉及文件

`T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua`、
`T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua`、
`T-CityLite.base/tests/unit/layer3_business/test_industry_cycle.py`、
`T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py`、`CHANGELOG.md`。

### 不做

- 不做“全服广播推送”；没有 citizenid 的玩家不在推送范围。
- 不在通知里放玩家名、坐标、citizenid。
- 不因为推送失败而阻断结算。

---

## W5 — `chore(ci): 关闭 SonarCloud 三项` → **#379**（已存在，到期 2027-01-15）

### 前序核验（第 1 项，必须先做）

- [ ] 确认 #377（PR #380）已合入，`industry_probe_common.lua` 存在且四个探针不再各自复制 SQL 求值；
- [ ] 用 Sonar API 重新读 `new_duplicated_lines_density`，确认 issue 里的 5.1% 是否已被 #377 消掉；
- [ ] 确认本地有**只读** SonarCloud token（环境变量即可，不能入库）；没有 token 就不要开始盲改；
- [ ] 确认三项的当前值：PR #373 的 Duplication、PR #376 的 Security Rating、PR #371 的 Reliability Rating。

### 为什么

2026-11-26 决定“SonarCloud 质量门先跳过，按正确性闸门推进”，issue #379 记录了三项与到期日。
2027-01-15 到点必须二选一：拿 token 逐个修，或把质量门规则改成“仅 src/、测试与夹具不计入新代码”，
并在 `docs/engineering/CONSTITUTION.md` 写明理由。不许无限期挂着。

### 范围

- 先修重复率（如果仍 >3%），再处理 Security / Reliability 的具体条目。
- 如果选择改规则，只改“新代码范围”，不降低现有正确性闸门；同 PR 写理由与复审日。
- 不为了过 Sonar 改业务行为；任何行为改动都必须有测试。

### 任务清单

- [ ] 前序核验。
- [ ] 用 Sonar API 拉三项当前值，贴进 issue。
- [ ] 重复率：如果 >3%，按文件处理（优先 `industry_probe_common.lua` 与四个探针）；
      不允许把测试/夹具排除当成第一选择，除非重复确实是“测试样板”。
- [ ] Security / Reliability：拿到具体条目后逐条判断“真缺陷 / 误报 / 规则不合适”；误报用行尾 `NOSONAR` + 理由，
      真缺陷先写失败用例再修。
- [ ] 如果改规则：更新 Sonar 质量门 + `docs/engineering/CONSTITUTION.md` + `CHANGELOG.md`，写明复审日。
- [ ] 跑全量闸门与 `python tools/dev/release_check.py`。

### 验收标准

- [ ] 有 token 时，Sonar API 显示 `new_duplicated_lines_density <= 3`、`new_security_rating = 1.0`、
      `new_reliability_rating = 1.0`；或质量门规则改为“仅 src/”后同一 API 显示通过。
- [ ] `cd T-CityLite.base && pytest tests/architecture tests/unit/layer3_business -q` 全绿。
- [ ] 如果改规则：`docs/engineering/CONSTITUTION.md` 有理由、影响范围、复审日；不是只改 Sonar UI。
- [ ] issue #379 关闭时附 Sonar 读数或规则变更链接；没有 token 的“我觉得修好了”不算。

### 涉及文件

SonarCloud 项目设置（外部）、`T-CityLite.base/tests/unit/layer3_business/fixtures/industry_probe_common.lua`、
四个产业探针、`docs/engineering/CONSTITUTION.md`（仅在改规则时）、`CHANGELOG.md`。

### 不做

- 不把 token 写进仓库、脚本默认值或命令输出。
- 不为了 Rating 改业务逻辑而不写测试。
- 不把正确性闸门一起放宽。

---

## W3 — `refactor(menu): M7 手机双 Wait(0) 收口 + 菜单架构棘轮` → **#349**（已存在，等 M6）

### 前序核验（第 1 项，必须先做）

- [ ] 确认 M6 #348 已合入 master，且 `menuv_entry` 除 menuv 自身外为 0；如果 M6 未合入，**停在这里**，不要先建闸门；
- [ ] 重跑 `python tools/dev/menu_surface_census.py`，把当前计数作为新基线；
      已知旧基线（`menu_surface_baseline.json`）与当前代码不一致：旧 `qb_menu_entry=149`，当前实测 159；
      旧 `isnuifocused_read=34`，当前实测 27；旧 `setnui_focus=205`，当前实测 195；
- [ ] 确认 `custom-phone` 的 `DeviceLock` 仍由 `OpenPhone` 调用，`ClosePhone` 仍调 `DeviceLock.End()`；
- [ ] 确认 `custom-prompt` 的 `Show` 已有 `lastShown` 去重，`SetContext` 仍没有。

### 为什么

M7 是菜单线的收口片：手机主循环一条 `Wait(0)`，平板再叠 `DeviceLock` 的第二条 `Wait(0)`；
`SetContext` 每次调用都发 NUI。没有棘轮，M1–M6 的清理会在半年内被新代码回填。

### 范围

- 手机主循环与平板移动锁合并为一条逐帧循环（同一个 tick 里先键泵后导航/锁）。
- `SetContext` 补同内容去重（对齐 `Show`）。
- 新增 `test_menu_architecture.py`，以重测后的 `menu_surface_baseline.json` 为棘轮。
- 更新 `configs/boot.json`（M6 下线 menuv 后）与 `docs/DEVOPS.md` 的标签表。

### 任务清单

- [ ] 前序核验。
- [ ] 合并双 `Wait(0)`：`device_lock.lua` 不再自建线程，由主循环每帧调用一个 `DeviceLock.Tick()`/`Apply()`；
      保留 `DeviceLock.End()` 的所有关闭路径与死亡/实体不存在自动解锁。
- [ ] `SetContext` 去重：同内容不重发；内容变化才发。
- [ ] 新增 `test_menu_architecture.py`：`menuv_entry` 归 0（排除 menuv 自身）、非排除 `backdrop_filter` 归 0、
      `setnui_single_arg` allowlist、门卫 `isnuifocused_read` allowlist、新增 `SetNuiFocus` 必须登记、
      `client_wait_zero` 只许下降。
- [ ] 三条反向注入：新增 `SetNuiFocus`、回填 `backdrop-filter`、重新引入 `MenuV` 引用 → 全部变红。
- [ ] 更新 `menu_surface_baseline.json` 与 `gate_coverage_budget.json`（只许下降）。
- [ ] `docs/DEVOPS.md` 标签表。
- [ ] 真机：平板态只有 1 条屏蔽循环；手机/平板开合、死亡、资源重启后人物不被冻住。

### 验收标准

- [ ] `cd T-CityLite.base && pytest tests/architecture -q` 全绿。
- [ ] `cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run build && node tests/nui/run.mjs` 通过。
- [ ] `python tools/dev/menu_surface_census.py` 的新计数写入基线；`client_wait_zero` 比 M6 后基线少 1。
- [ ] 反向注入三条全部变红；还原后全绿。
- [ ] 真机：平板态全客户端只有 1 条屏蔽循环；开合不冻人；M6 后 `/admin` 与手机不能互相叠开。
- [ ] `docs/DEVOPS.md` 有 `area:menu` 标签。

### 涉及文件

`T-CityLite.base/resources/[custom]/custom-phone/client/main.lua`、
`T-CityLite.base/resources/[custom]/custom-phone/client/core/device_lock.lua`、
`T-CityLite.base/resources/[custom]/custom-prompt/client/main.lua`、
新增 `test_menu_architecture.py`（放在 `T-CityLite.base/tests/architecture/`）、
`T-CityLite.base/tests/architecture/menu_surface_baseline.json`、`gate_coverage_budget.json`、
`T-CityLite.base/configs/boot.json`、`docs/DEVOPS.md`、`CHANGELOG.md`。

### 不做

- 不把 `menuv` 源码删掉；M6 的约定是保留只读，闸门排除 menuv 自身。
- 不为通过闸门而放宽 allowlist；新增条目必须带 owner 与到期日。
- 不在本片重做 M1–M6 的焦点栈。
