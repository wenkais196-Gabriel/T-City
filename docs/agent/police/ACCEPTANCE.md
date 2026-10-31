# 警察模块验收标准（ACCEPTANCE）

> **状态**：验收标准 v1，随施工同步更新。日期 2026-10-30。
> **用途**：每个 Phase 收尾时，逐条判定 PASS / FAIL / N/A，把证据贴进 PR。**没有全 PASS 不进下一 Phase。**
> **配套**：功能范围与架构见 [`docs/agent/police/BLUEPRINT.md`](BLUEPRINT.md)；调研依据见 [`docs/agent/police/RESEARCH-2026-10.md`](RESEARCH-2026-10.md)。

---

## 0. 现状：之前有没有验收标准？

**没有可判定的那一类。** 之前只有三样东西，都不够当验收：

| 已有的 | 它缺什么 |
|---|---|
| `docs/agent/police/BLUEPRINT.md` §10 的「每个 Phase 的 DoD：五项全绿」 | 只说了「跑测试」，没给阈值、没给证据形态；而且它引用的「本文对应章节的验收标准」**当时并不存在**（§0 就是来补这个洞） |
| `docs/agent/police/BLUEPRINT.md` §11 风险表的「触发信号」 | 这是**报警条件**，不是**合格条件**（"玩家投诉"说明已经出事了） |
| `docs/agent/police/RESEARCH-2026-10.md` §7 优先级表的「成本」 | 工时估算，与"做完没做完"无关 |

一句话：**之前定义的是"做了什么"，没有定义"做到什么程度算做完"。** 本文补的就是后者。

---

## 1. 方法论：验收标准怎么写

### 1.1 AC ≠ DoD（两者都要满足）

Mike Cohn 的定义：*DoD 是所有工作都适用的完成定义，AC 是单个故事独有的合格条件*；一个故事要算完，**两个条件必须同时满足**——所有 AC 满足 + DoD 各项完成。[Mountain Goat / Cohn](https://www.mountaingoatsoftware.com/agile/user-stories/acceptance-criteria)

落到本项目：

| | 管什么 | 写在哪 | 例子 |
|---|---|---|---|
| **DoD（质量门）** | 每个 PR 都一样 | §2 | 五条测试全绿、迁移幂等、fixture 同步 |
| **AC（合格条件）** | 这个功能独有 | §3 | 「重启服务器后按 case_id 仍能查到同一案卷」 |

Cohn 还强调 AC **不是完整测试计划**，而是让双方对"什么算过"达成一致；细节应当随故事接近实现而逐步补充。所以本文只写"判定点"，具体用例留给 `tests/`。

### 1.2 三种写法，按验收对象选

| 对象 | 写法 | 模板 |
|---|---|---|
| **玩家能感知的行为** | Given / When / Then（[Russo 的实践指南](https://www.vincenzorusso.net/user-stories-acceptance-criteria-and-definition-of-done-practical-guidelines/)） | Given <前置>，When <动作>，Then <可观察结果> |
| **工程产物与数据** | 检查项 + 可执行命令 | `<命令>` 输出 `<期望>` |
| **非功能（性能/安全/可靠性）** | 阈值 + 测量方式 | `<指标>` 在 `<条件>` 下 `<关系> <阈值>`，用 `<工具>` 测 |

**硬规则**：每条 AC 必须能说出**判定方式**与**证据形态**。写不出这两样，就不是 AC，是愿望。

### 1.3 用语规范（照 RFC 2119 的词表收紧）

`MUST` / `MUST NOT` 用于必须满足否则 FAIL；`SHOULD` 用于默认应满足、偏离须在 PR 里写理由；`MAY` 可选。禁用"尽量""基本""大概""体验流畅"。

例：~~「报告的提交体验要顺畅」~~ → 「提交动作 MUST 在 500 ms 内返回；失败 MUST 带可读错误，且 MUST NOT 丢草稿」。

### 1.4 非功能维度只取用得上的四个

ISO/IEC 25010 给了九个产品质量特性（2023 版：功能适合性、性能效率、兼容性、交互能力、可靠性、安全性、可维护性、灵活性、安全性 safety）。[概览](https://monterail.com/blog/software-qa-standards-iso-25010) 本项目只挑四个真会出事的：

| 特性 | 本模块的具体体现 | 阈值示例 |
|---|---|---|
| **功能适合性**（correctness / completeness） | 状态机非法转移被拒；罪名→刑期与 config 一致 | 13 项罪名全对，0 例外 |
| **性能效率**（time behaviour / capacity） | 接警、平板打开、50 起并存的写入 | create P95 < 50 ms；平板首屏 < 1 s |
| **可靠性**（fault tolerance / recoverability） | 重启后案卷仍在；无警在线不报错 | 重启丢 0 条；日志 0 个 ERROR |
| **安全性**（accountability / integrity） | 越权被拒且留审计；证据链不可改 | 越权 100% 拒绝；0 条 UPDATE |

安全类 AC 在本项目还多一条硬要求：**拒绝必须留痕**（写 `agent_denials` 或 `custom-logs:LogSecurity`，且不含参数值）。

### 1.5 反模式清单（写之前先自查）

| 反模式 | 例子 | 改法 |
|---|---|---|
| 不可判定 | "平板用起来很顺手" | 换成"无鼠标完成 X 流程 < 3 分钟" |
| 把实现方案当验收 | "用 Svelte 5 写平板" | 验收对象是结果，方案属蓝图 |
| 一条里塞多个事实 | "查得到、能提交、不丢" | 拆成三条独立 AC |
| 只有正向，没有反向 | "允许 lead 结案" | 补"非 lead 结案 MUST 被拒" |
| 重复 DoD | "测试要过" | 删掉，DoD 已管 |
| 没有证据产物 | "已验证" | 附命令输出 / SQL 结果 / 截图路径 |

**AC 的 AC（元验收四问）**：谁能不看代码判定？ · 证据是什么形态？ · 失败长什么样（举得出反例）？ · 有没有对应的回归防止以后退化？

---

## 2. 通用 DoD（每个 PR 都要过）

来自仓库既有基线，**数字以实测为准**（下表为 2026-10-30 在本机 `E:\T-City` 跑出的结果）；**任一项下降即 FAIL，除非 PR 里写明理由并获准**。

> 环境注：本机默认 `python`（3.14.7）**没有 pytest**；用 `C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe`（下文简称 PY）。Lua 与工具注册表不需要。

| # | 条件 | 判定 |
|---|---|---|
| D-1 | agent 测试 | PY -m pytest -q T-CityLite.base/tests/agent：**2026-10-30 实测 6 passed**（只会增长，不会减少） |
| D-2 | 全量 Python | PY -m pytest -q T-CityLite.base/tests/architecture T-CityLite.base/tests/unit tests/tools = **1224 passed / 150 skipped / 714 subtests** |
| D-3 | Lua golden | lua5.4 T-CityLite.base/tests/agent/lua/runner.lua = **15 suites / 149 checks / 0 failed** |
| D-4 | 客户端 golden | lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua = **3 suites / ok=true** |
| D-5 | 工具注册表 | PY tools/agent_tools.py --check = **OK（41 tools）**（工具数变化须同步三处镜像） |
| D-6 | 迁移幂等 | T-CityLite.base/migrations/*.sql 连跑两遍成功，第二遍 0 error（**当前最新是 v3.9**，不是 PLAN 里的 v2.7/v2.8） |
| D-7 | fixture 同步 | 新表/改表同 PR 更新 `T-CityLite.base/tests/fixtures/tcity_schema.sql`；CI db-schema 绿 |
| D-8 | 文档链接 | PY -m pytest -q T-CityLite.base/tests/architecture/test_docs_links.py = 7 passed |
| D-9 | NUI 构建 | 改前端时 cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run build 成功，产物落在 html/ |
| D-10 | 无残留 | 不新增调试 `print`/`TODO`；不提交 `server.cfg`、token、cache/、`node_modules` |
| D-11 | 服务端权威 | 每个新增写动作都有服务端 grade 复检，客户端按钮不作为权限依据 |
| D-12 | 回滚可用 | PR 描述里写明回滚方式，且方式是可执行的（不是"revert"三个字） |

---

## 3. Phase 验收标准

> 编号 `AC-<Phase>-<n>`。**PASS 必须有证据**：命令输出、SQL 结果、日志行、截图路径、或实机观察记录（含服务器 id 与时间）。
> 标 **[实机]** 的需要在线玩家；其余可在本机离线判定。

### 3.1 P0 地基（记录有地方放）

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P0-01 | migrations/v2.8_police_module.sql 连跑两遍均无错误 | 临时库执行两次，`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=? AND table_name LIKE 'police\_%'` | 9 |
| AC-P0-02 | fixture 含全部新表与索引 | `grep -c "CREATE TABLE \`police_" tests/fixtures/tcity_schema.sql` | 9；索引 30 |
| AC-P0-03 | 证据链 MUST NOT 被更新 | grep -rn "UPDATE police_evidence_chain" resources/ \| wc -l | 0 |
| AC-P0-04 | 无罪名表：`charge_id` MUST 指向 justice config 而非新表 | grep -rn "police_charges" resources/ \| wc -l | 0 |
| AC-P0-05 | exports 可用且容错 | 从另一资源 `exports['custom-police']:GetCase('不存在')` | 返回 nil，不抛错 |
| AC-P0-06 | 权限矩阵 100% 覆盖 | 单测遍历 11 动作 × 5 grade | 用例数 = 55，越权全部 false 且各写 1 条审计 |
| AC-P0-07 | 平板能查真实人车 | cd custom-police/web && npm run build 成功 → 打开平板查 1 个 cid | 构建产物存在 + 姓名/职业与 DB 一致 |
| AC-P0-08 | 手机 App 注册表生效 | 注册 demo app，grade 0 / grade 1 分别登录 | grade 0 看不见，grade 1 可见；`app:query` 越权返回 `ok=false` |

### 3.2 P1 司法链（把死代码接活并落库）

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P1-01 | Given 玩家被手铐并勾选 2 项罪名，When 提交逮捕登记，Then `police_cases` +1 行、`police_case_charges` +2 行 | 实机 [实机] + SQL | 行数与勾选一致 |
| AC-P1-02 | 在线的 lawyer MUST 收到 1 条通知（重复触发不叠加） | 测试桩断言事件次数 | **PASS**：golden `justice_chain` 3 个 case |
| AC-P1-03 | Given 庭审 verdict=guilty，Then `court_status='guilty'` 且 `sentence_minutes` = config 计算值 | 单测 + SQL | 差值为 0 |
| AC-P1-04 | **重启 FXServer 后按 case_id 仍查得到同一案卷** | 重启前后各查一次 | 记录完全相同 |
| AC-P1-05 | 刑期 MUST 被 `Config.Justice.MaxSentence` 截断 | 传入 10 倍上限 | **PASS**：99999 → 上限，DB 无 99999 |
| AC-P1-06 | 非 police/judge 调 `justice:server:imprison` MUST 被拒并留审计 | 伪造 source 调用 | **PASS**：平民/离岗警员都拒绝（golden `justice_chain`） |
| AC-P1-07 | 同一次逮捕重复触发 MUST NOT 产生第二份案卷 | 连续触发 2 次同幂等键 | `police_cases` 仍 1 行 |
| AC-P1-08 | 回退开关可用：`UseDb=false` 时行为与今日一致 | 关闭开关跑一遍流程 | 内存实现正常，庭审可开 |

### 3.3 P2 调度总线（让"有事做"）

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P2-01 | 一次抢案 MUST 让手机与车机收到**同一** `call.id`，字段一致 | 双端日志对比 | id 相同，priority/zone 相同 |
| AC-P2-02 | 下发给客户端的 payload MUST NOT 含原始 x/y/z | 打印 payload 并计算与真实点距离 | 距真实点 ∈ [0.5r, r]，或字段缺失 |
| AC-P2-03 | 状态机非法转移 MUST 被拒（如 pending→onscene） | 单测覆盖全部 16 种转移 | 合法 4 条通过，其余被拒 |
| AC-P2-04 | 到场判定：进入半径且 <2 m/s 持续 2 s → onscene；只进不停不得翻转 | 实机 [实机] | 停稳后 2 s 翻转，未停稳不翻转 |
| AC-P2-05 | 同 `ref` 5 分钟内 3 次 MUST 合并为 1 张卡且 `merge_count=3` | 真实 MariaDB upsert | 1 卡 / merge_count 3 |
| AC-P2-06 | 7 个既有来源（银行/商店/珠宝/毒品/入室/越狱/抢车）MUST 逐个产卡 | 逐个触发 [实机] | 7/7 产卡 |
| AC-P2-07 | `custom-crime` 抢案 MUST 产卡（当前 0 覆盖） | 触发商店与房屋抢劫 | 各产 1 卡 |
| AC-P2-08 | 通知纪律：≥5 起同区事件，屏幕同屏 MUST ≤3 条 | 压测触发 | ≤3 条，显示合并计数 |
| AC-P2-09 | 只有 lead 能 close；非 lead 调 close MUST 被拒 | 伪造调用 | 拒绝 + 审计；call 状态不变 |
| AC-P2-10 | 50 起 call 并存时，`dispatch:server:create` MUST P95 < 50 ms，且 tick 增幅 < 5% | 服务器计时 + `GetTimecycle`/tick 采样 | P95 < 50 ms；tick 稳定 |
| AC-P2-11 | 无警在线时 3 起案子 MUST NOT 产生 ERROR 日志 | 日志 grep | 0 个 ERROR |

### 3.4 P3 盘查与文书

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P3-01 | 每个盘查动词 MUST 有服务端复验；伪造事件（远距离/非警）MUST 被拒 | 伪造 `TriggerServerEvent` | 全部拒绝 + 审计行 |
| AC-P3-02 | 距离 >3 m 时盘查 MUST 被拒 | 实机 [实机] + 单测 | 拒绝 |
| AC-P3-03 | 酒测/药检结果 MUST 落 `police_evidence.payload` 且可读 | 执行后 SQL | JSON 含结果与时间 |
| AC-P3-04 | 罪名→刑期/罚款 MUST 与 justice config 完全一致（13 项全覆盖） | 单测遍历 config | 13/13 相等 |
| AC-P3-05 | 报告提交后 MUST NOT 可改（提交态无编辑路径） | 尝试再提交/编辑 | 被拒；`status` 仍 submitted |
| AC-P3-06 | grade 0 提交报告 MUST 被拒 | 权限矩阵用例 | 拒绝 + 审计 |
| AC-P3-07 | BOLO 推手机：离线警员上线后 MUST 收到未读 1 条，且不重复 | 离线→上线 | 未读数 1，重复登录仍 1 |
| AC-P3-08 | 平板无鼠标完成「查人→立案→写报告→发通缉」 | 人工计时 [实机] | 全流程 PASS，用时 < 3 分钟 |

### 3.5 P4 证据与 bodycam

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P4-01 | 世界证据采集后 MUST 绑定 case 且 payload 含 serial | 采集后 SQL | `case_id` 非空，serial 存在 |
| AC-P4-02 | 保管链 MUST append-only（代码无 UPDATE 路径） | grep + 单测 | 0 命中；纠错产生新行 |
| AC-P4-03 | 化验结果 MUST 在配置延迟后出现，且挂同一 evidence_id | 单测（假时钟） | 延迟 = 配置值；id 相同 |
| AC-P4-04 | 开枪 MUST 触发 3 张截图入库并可在平板打开 | 实机 [实机] | `police_bodycam.shots` 长度 3，图片可加载 |
| AC-P4-05 | 单次 ≤ 300 KB × 3，且有 30 天清理任务（干跑通过） | 文件字节 + 清理 dry-run | 达标；dry-run 列出到期条目 |
| AC-P4-06 | 证据时间线 MUST 按 id 升序完整呈现，缺步可见且不补写 | 人工核对 + 单测 | 播放顺序正确，无伪造步 |

### 3.6 P5 AI 支援分层

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P5-01 | 支援车 MUST 在距 call ≥80 m 的路口出生，且不在玩家视野锥内（夹角 >60°） | 出生日志断言 | 每次 100% 满足 |
| AC-P5-02 | 出发阶段警笛 MUST 为开（`IsVehicleSirenOn`） | 单测/日志 | true |
| AC-P5-03 | 五条硬约束各有 1 个用例：不逮捕 / 不对玩家开火 / 120 s 撤退 / 10 s 卡住重派 / 不结案 | 单测 ×5 | 5/5 PASS |
| AC-P5-04 | 三个对照实验（警笛 A / 原版 vs addon B / 出生距离 C）结果 MUST 记录在案 | 实验记录表 | 三行结果 + 结论 |
| AC-P5-05 | 同场景 60 s 内被环境车撞次数 = 0（重复 3 次允许 1 次） | 实机 [实机] 计数 | ≤1 |
| AC-P5-06 | 撤退后 MUST 0 遗留 ped/veh（车辆数与基线相同） | 撤退前后 `GetAllVehicles` 计数 | 差值 0 |
| AC-P5-07 | AI 到场时奖励 MUST 砍到 40% 或改为人类接管才结算 | 单测金额 | 40% ± 0 |
| AC-P5-08 | 代码中 MUST NOT 存在 AI 逮捕/击杀玩家路径 | grep + 评审记录 | 0 命中 |

### 3.6.1 L2 后勤层（验尸官 / 拖车 / 现场化验）

> 这一层是 2026-10-30 新做的，原表里没有对应条款 —— 补在这里，编号 `AC-L2-xx`。

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-L2-01 | 三项服务都 MUST 只接受在岗警察 | 用平民号 / 离岗状态各触发 1 次 | 拒绝且无实体生成；`coroner.rejected` / `tow.rejected` 有行 |
| AC-L2-02 | 生成 MUST 只在路网节点；取不到就干净失败 | 在水边/山地各叫 1 次 | 日志 `spawn node … tier=` 或 `no_road` / `no road node`，**不得**出现在沙滩/海面 |
| AC-L2-03 | 三项共用同一套生命周期：`NPCBudget` 名额 + 冷却 + 服务端寿命 + 掉线回收 | 读 `SLOT_COST` 与三个 server 文件 | `backup/coroner/tow` 都在预算表；三者都有 `*_TTL_SECONDS` 与 `playerDropped` |
| AC-L2-04 | 拖车 MUST 拒绝玩家自己的车（服务端查归属，不信客户端） | 对一块属于 `player_vehicles` 的车牌调 `/tow` | `tow.rejected`（`player_owned`）+ 客户端提示「走扣押流程」 |
| AC-L2-05 | 拖车只挂「没人 + 报废」的 NPC 车，拖走后残骸 MUST 被删除 | `/tow` 一次 | `tow.ended reason=done`；客户端 `cleaned (left)`；残骸句柄消失 |
| AC-L2-06 | 验尸官 MUST 真的删除尸体 | 叫一次验尸官 | 客户端 `coroner.ended reason=done`；尸体句柄消失 |
| AC-L2-07 | 化验 MUST append-only：结果不得 UPDATE 已有证据行 | grep + 一次采样 | 0 处 `UPDATE police_evidence`；`EX-000001`/`EX-000002` 两行 |
| AC-L2-08 | 三项都 MUST 有审计三态；调试后门默认关且**只造场景** | grep + 控制台 | `*.request/.ended/.rejected`；`police_coroner_dev`/`police_tow_dev` 的 convar 默认 0，且入口不代按命令 |

### 3.7 P6 Agent 动作

| ID | 判据 | 判定方式 | 证据 |
|---|---|---|---|
| AC-P6-01 | 新增工具后注册表一致 | python tools/agent_tools.py --check | OK（34 → 39） |
| AC-P6-02 | 每个新工具 MUST 含 schema / risk / requires_approval / verify / idempotency / since | 契约测试 | 5/5 工具字段齐全 |
| AC-P6-03 | L3 `police.issue_warrant` 无审批 MUST 被拒且写 `agent_denials`（不含参数值） | 调用 + SQL | 拒绝；denials +1，payload 无敏感值 |
| AC-P6-04 | `draft_report` MUST 经人审才提交 | 两层事件断言 | 未审时 `status=draft` |
| AC-P6-05 | AI 调度员：10 条自然语言报案 → 类型准确率 ≥80%，优先级偏差 ≤1 级 ≥90% | `agent_eval.py` | 达标数字打印 |
| AC-P6-06 | verify 回读 MUST 与 DB 一致 | `query_case` 条数 vs SQL | 差值 0 |
| AC-P6-07 | 三处镜像一致（json / Lua / TOOLS.md） | `--check` + diff | 无差异 |

---

## 4. 回归清单（每个 Phase 都要跑，防"改好一处、坏掉三处"）

| ID | 不变量 | 判定 | 触及的既有功能 |
|---|---|---|---|
| R-01 | 逮捕 / 押送 / 入狱 / 车库 / 扣押 5 条主命令仍可用 | 各执行 1 次 | qb-policejob 动作层 |
| R-02 | /911p 仍产卡（经 shim） | 执行 1 次 | 旧报案入口 |
| R-03 | 手机开/关不冻结 WASD（焦点语义） | 开→关→再开 | custom-phone 焦点 |
| R-04 | 通知不回环（服务端单播 + `origin='server'`） | 收 1 条通知后不应再触发 | 手机通知 |
| R-05 | 迁移可重跑（含本次新增） | 连跑两遍 | DB |
| R-06 | agent 工具契约与 policy 不破 | D-1/D-5 | custom-director |
| R-07 | 测试数字不下降 | D-1…D-4 | 全仓 |

---

## 5. 验收仪式（谁、何时、怎么记）

1. **时机**：每个 Phase 收尾（PR 提交后、合并前）。
2. **谁**：功能 owner（宋文凯）拍板；Hermes 负责产出证据包（命令输出 + SQL + 截图 + 实机记录）。
3. **怎么记**：PR 描述贴下表，每条 AC 三态之一；**PASS 必须带证据，N/A 必须写原因**，"已验证"三个字不接受。

```markdown
## 验收记录 — Phase <N>
环境：FXServer <版本/构建号> · MariaDB <版本> · 构建 <commit>
| AC ID | 结果 | 证据 | 备注 |
|---|---|---|---|
| AC-P0-01 | PASS | `SELECT COUNT(*) …` = 9（见附件 p0-01.txt） | — |
| AC-P0-04 | N/A | grep = 0，本 Phase 未引入 charge 表 | 由 AC-P0-03 覆盖 |
```

4. **失败处理**：
   - FAIL → **不进下一 Phase**；修完重跑该条，不重跑整表（但 §4 回归要重跑）。
   - 延迟项 → 记 `debt`，写进 `docs/agent/police/BLUEPRINT.md` §11 风险表，并在下一 Phase 的回归里追。
   - N/A 理由是"暂时没做" → 视为 FAIL（没做就是没做完）。
5. **证据留档**：命令输出存 docs/agent/police/evidence/phase<N>/（**不入库时放本地**，只把关键数字贴进 PR）。

---

## 6. 编号映射（两套标签很容易搞混）

`docs/agent/police/RESEARCH-2026-10.md` §7 用的是「优先级 P0-1…P2-4」，`docs/agent/police/BLUEPRINT.md` §7 用的是「Phase P0…P6」，**本文一律用 Phase 编号**：

| 优先级（调研） | Phase（蓝图） | 本文 AC |
|---|---|---|
| P0-1 司法链 | **P1** | AC-P1-01…08 |
| P0-2 调度总线 | **P2** | AC-P2-01…11 |
| P0-3 盘查动作 | **P3** | AC-P3-01…03 |
| P0-4 平板 MDT | **P0 + P3**（骨架在 P0，文书在 P3） | AC-P0-07、AC-P3-04…08 |
| P1-1 证据链 / P1-4 bodycam | **P4** | AC-P4-01…06 |
| P1-2 BOLO 推手机 / P1-3 权限矩阵 | P0（矩阵）+ P3（推送） | AC-P0-06、AC-P3-07 |
| P2-1 无线电 / P2-2 测速 / P2-3 站点化 / P2-4 K9 | 未排期 | — |
| （新增）AI 支援 | **P5** | AC-P5-01…08 |
| （新增）Agent 动作 | **P6** | AC-P6-01…07 |

---

## 7. 来源

- Mike Cohn / Mountain Goat Software，*Acceptance Criteria* 与 *Definition of Done vs Conditions of Satisfaction*：AC 是让双方确认"做对了"的细节，**不是完整测试计划**，且应随实现逐步补充；DoD 与 AC 须同时满足。<https://www.mountaingoatsoftware.com/agile/user-stories/acceptance-criteria>
- Vincenzo Russo，*User stories, acceptance criteria, and Definition of Done: practical guidelines*：Given/When/Then 模板、INVEST 与"可测性"。<https://www.vincenzorusso.net/user-stories-acceptance-criteria-and-definition-of-done-practical-guidelines/>
- ISO/IEC 25010:2023 质量模型（九特性；本节只取功能适合性 / 性能效率 / 可靠性 / 安全性）：<https://monterail.com/blog/software-qa-standards-iso-25010>
- 质量门（quality gate）的定义与用法：<https://tricentis.com/learn/software-quality>
- 仓库基线数字：`docs/agent/police/BLUEPRINT.md` §0.2；CI 作业：`.github/workflows/ci.yml`（Config/Python/Lua/Docs/DB schema/NUI）。

---

## 8. 补充与修订建议（2026-10-30，待 owner 确认）

来源：对 P5（NPC 支援）与 L0（无线电）的第一次实际验收，证据见
[`ACCEPTANCE-RUN-2026-10-30.md`](ACCEPTANCE-RUN-2026-10-30.md)。

| # | 涉及 | 建议 | 理由 |
|---|---|---|---|
| 1 | AC-P5-01 | 判定方式改成「读 `spawn check` 日志行的 `angle=`」，阈值不变 | 夹角现在靠目视，没有证据形态；实现已打这一行 |
| 2 | AC-P5-03 #4 | 「卡住 10 s」→ **20 s × 3 次** | 真机合法掉头 12–16 s，10 s 会把正常交接判成失败（有日志） |
| 3 | AC-P5-05 | 判定方式写明「`collision #n` 计数，同一车 2 s 去重」 | 否则无法判定 |
| 4 | AC-P5-06 | 判据改为「本单位 `leftover=0`」 | 车池总数被路人车流干扰，不可复现 |
| 5 | 新增 | AC-P5-09…12 覆盖 L0 无线电（在岗限定 / 限流 / 文案无身份 / 一键关） | 本轮做的 L0 目前**没有对应 AC**，等于不验收 |
| 6 | AC-P5-07 | 标 `debt`，等 Phase 2 的 `custom-dispatch` 与发案方改造 | 现在没有"奖励结算"这条链路，无法判定 |
| 7 | AC-P0-01 | `v2.8_police_module.sql` → **v3.10** 起 | 迁移目录最新已是 v3.9 |

原则不变：**改判据必须在 PR 里写明理由与到期日**（见 `AGENTS.md` §6「不要为了过闸门而改闸门」）。
