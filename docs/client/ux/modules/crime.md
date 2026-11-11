---
id: ux-crime
type: manual
status: active
system: crime
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 犯罪与组织 · UX 设计

> 状态 **active · 已交付**：C-1…C-6 全部完成。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测，2026-11-11 重扫）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `qb-storerobbery` | 32 | 2 | 2 |
| `custom-cartel` | 37 | 1 | 4 |
| `qb-drugs` | 48 | 3 | 7 |
| `custom-mining` | 17 | 2 | 1 |
| `custom-crime` | 16 | 0 | 0 |
| **合计** | **150** | **8** | **14** |

全仓库 `police:server:policeAlert` 调用点 **7 处**，其中带自定义文本的 2 处是英文/拼写错误（见 §1.4 第 5 行）。

### 1.2 状态语义

见 §1.3。

### 1.3 状态语义（我扫的）

| 概念 | 现在的实现 | 玩家能不能看见 |
|---|---|---|
| 已被抢过 | `qb-storerobbery` 服务端按次记录，客户端只有一句「该保险箱已被打开过了」 | 只有在按到那一瞬间才知道 |
| 冷却 | 抢劫结束后按位置进入冷却（`qb-storerobbery` 无独立 cooldown 表，靠 `isBusy` 内存态） | **完全不可见** —— 玩家会在同一家店反复试 |
| 警察门槛 | `需要至少 N 名执勤警察才能打开保险箱` | ✅ 这条写得好，是全模块最好的文案 |
| 犯罪收益 | `抢劫完成！战利品已放入背包`（success） | 只给一句，不给金额/物品清单 |
| 通缉 | `SetPlayerWantedLevel(src, 2)`（原生 2 星） | 原生星星，与 RP 报警单**两套并行** |
| 报警 | `police:server:policeAlert`，7 个调用点 | 警察端：自由文本工单标题 |

### 1.4 玩家会卡住的场景

| # | 场景 | 现在 | 依据 |
|---|---|---|---|
| 1 | 想抢收银机但站偏了 | 只回「当前位置附近没有可抢劫的收银机！(需在 1.8 米内)」，**不说往哪走** | qb-storerobbery 的 client/main.lua 收银机交互分支 |
| 2 | 保险箱要长按 ALT | `AddCircleZone` 走 qb-target（全服 `setr UseTarget true`），单动作却要 ALT | `qb-storerobbery/client/main.lua:107` |
| 3 | 抢完再回来 | 冷却不可见，玩家以为脚本坏了 | 见 §1.3 冷却行 |
| 4 | 抢到东西 | 只有一句 success，不知道抢了多少、进了背包还是黑钱 | `抢劫完成！战利品已放入背包` |
| 5 | 警察看见的告警 | 标题是**调用方自由文本**：`'Drug sale in progress'` / `'Suspicous activity'`（拼错）/ `Lang:t('email.storerobbery_progress')` | `qb-drugs/client/cornerselling.lua:33`、`deliveries.lua:144` |
| 6 | 被通缉 | 原生 2 星与 RP 报警单两套并行，玩家不知道该怕哪一套 | `qb-storerobbery/server/main.lua:546` |

**关于告警的一个好消息**：坐标是**服务端从报警者 ped 上取的**（custom-police 的 server/main.lua 的 `police:server:policeAlert` 处理），
客户端不发坐标，还有 15 秒/人 限流 —— 安全上没问题，问题**只在文案与分类**。

### 1.5 外部实践（我的调研，2026-11-11）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| **FiveSecured《FiveM robbery script》** | 抢劫系统是"服务端拥有的地点表"：每个地点写死 `loot / seconds / cooldown / minPolice / stages`；客户端只拿渲染所需，服务端按地点 id 重读配置。提示只在范围内出现 | 我们的警察门槛已有（§1.3），缺的是**把 cooldown 变成可见状态**——表里有 `cooldown`，玩家界面里什么都没有 |
| **MX-Robbery（Cfx 论坛 RedM）** | 抢劫**开始就发警察告警**；带进度条；每地点 + 每玩家双冷却；`RestrictedJobTypes` 禁止体制内职业抢劫 | 我们发告警了但**没有进度条**（长按期间只有原生进度圈），冷却也不可见 |
| **Quasar《Drugs Creator 2.0》** | 毒品链是"采集 → 运输 → 实验室加工 → 分销"多阶段，每阶段风险不同；收益走**脏钱 + 洗钱**，不是直接给现金 | 我们的 `qb-drugs` 也是多阶段，但阶段间**没有统一反馈**；收益直接进背包/现金，缺"脏钱"这一层叙事 |

**外部结论三条**：

1. **冷却与门槛是可见状态，不是错误文案** —— 应该在交互提示里就写「冷却 3:12」「需 2 名警察（当前 0）」，而不是让玩家按下去吃一个 error；
2. **阶段推进要有进度条**，不是每完成一步弹一条通知（与任务模块同一条结论）；
3. **收益要能回看**：金额/物品清单应该留档（手机凭证），屏幕只给一句「已到账」。

### 1.6 CC 调研补充（2026-11-11）

**外部做法**：

| 问题 | 外部做法 | 来源 |
|---|---|---|
| 进行中/冷却 | 实时倒计时、进度可视化、战利品预览；冷却区域直接标"暂不可用"，不靠连续弹窗 | Market Robbery；Advanced Drug Sales |
| 警察/通缉 | 警情带**街名** + 60s 红 blip，按 start/complete/cancel 更新；`Policenotify()` 给警察通知 + 100s 脉冲 blip，可接 ps/cd/qs dispatch | Market Robbery；EST Scripts |
| 收益 | 官方店抢发 `markedbills`（带 worth metadata），走物品/脏钱管道而非屏幕现金；商业毒品脚本支持 markedbills / dirty money → 洗白 clean cash | QBCore 官方文档；Advanced Drug Sales |
| 坑 | 店抢警情依赖 qb-phone；换手机资源则警情**静默丢失** | QBCore 官方文档 |

**仓库现状（CC 逐行）**：五处资源**全部**走 `QBCore:Notify`/`TriggerClientEvent`，**0 处** `custom-notify`。

| 类型 | 证据 |
|---|---|
| 进行中 | `custom-mining` 的 client/main.lua:113；`custom-cartel` 的 client/main.lua:332；`qb-drugs` 的 client/deliveries.lua:207 |
| 结果 | `qb-storerobbery` 的 server/main.lua:467；`custom-cartel` 的 server/drug_lab.lua:212；`custom-crime` 的 server/crime.lua:310 |
| 失败 | `qb-storerobbery` 的 client/main.lua:145（警察不足）；`custom-cartel` 的 server/drug_lab.lua:171；`qb-drugs` 的 client/deliveries.lua:135（超时） |

**同一事件发多条（关键）**：

| 事件 | 条数 | 位置 |
|---|---|---|
| 收银机完成 | **3** | server/main.lua:467 + client/main.lua:450 + 独白 NUI client/main.lua:399 |
| 接配送 | 2 | toast client/deliveries.lua:207 + 短信 :239 |
| 商店抢劫报警 | **4** | client/main.lua:598 各警察自建 blip + 声音；server/main.lua:728 `robberyCall`；:729 qb-phone 警情；policeAlert 建单投影 |

**进度条已经在用**（不是通知）：`qb-storerobbery` 的 client/main.lua:420、`custom-mining` 的 client/main.lua:127、
`custom-cartel` 的 client/main.lua:345 —— 所以 §2.2 不需要重造进度条，只需把"阶段切换"从通知里拿掉。

## 2. 设计（目标）

> 综合我的 §1.3–1.5。一句总纲：**门槛、冷却、收益都要"看得见"** ——
> 现在的犯罪链路把大量状态藏在错误提示里，玩家只能靠按下去试。

### 2.1 交互提示里写状态，而不是按下去吃 error

| 情形 | 现在 | 改成 |
|---|---|---|
| 警察不够 | 按了才弹「需要至少 N 名执勤警察」 | 提示直接写 `[E] 撬保险箱 · 需 2 名警察（当前 1）`，**按了没反应** |
| 冷却中 | 无提示，按了才知道被抢过 | 提示写 `[E] 撬保险箱 · 冷却 3:12` |
| 已被抢 | 只有「该保险箱已被打开过了」 | 提示写 `[E] 保险箱已空（10 分钟后重置）` |
| 站得太远 | 「当前位置附近没有可抢劫的收银机！」 | 提示不出现（范围内才显示），不弹 error |

**原则**：`error` 只用于"玩家做了动作但没成功"，不用于"他本来就不能做"。

### 2.2 报警分类（结构化，不再传自由文本）

现状：`police:server:policeAlert(text)` 的 `text` 由调用方随便写，
于是警察端看到 `'Drug sale in progress'`、`'Suspicous activity'`（拼错）、`Lang:t('email.…')`。

改成 `police:server:policeAlert(text, kind)`，**kind 可选**（向后兼容）：

| kind | 标准标题 | 优先级 |
|---|---|---|
| `store_robbery` | 商店抢劫 | 2 |
| `house_robbery` | 入室盗窃 | 2 |
| `drug_sale` | 毒品交易 | 2 |
| `drug_delivery` | 可疑运输 | 2 |
| `vehicle_theft` | 车辆抢夺 | 1 |
| `officer_down` | **警员受伤，请求支援** | 3 |
| 未知/缺省 | 用调用方文本（清洗后），优先级 2 | 2 |

**为什么必须分类**：优先级决定它在警情板里的排序，而现在的工单标题连"这是毒品还是抢劫"都分不出。

### 2.3 收益留档，屏幕只给一句

| 时机 | 通道 | 内容 |
|---|---|---|
| 抢劫完成 | `feed` | 「抢劫完成 · 已放入背包」 |
| 同上（明细） | `phone` | 「战利品：$1,200 + 3× 脏钱」——金额与物品清单 |
| 保险柜被打开 | `feed` | 「保险柜已开 · 你拿到了 X」 |
| 中断 | `feed` | 「已中断 · 按时间比例结算 $X」（现在这条有，但没金额） |

**为什么收益不走 `toast`**：toast 是"需要停一下"的中央提示，会在玩家正要跑路时挡住准星；
收益是结果，属于左下 `feed` + 手机明细。

### 2.4 热区：单动作 → `[E]`

8 个热区里凡"一个位置只有一个动作"的（保险箱、收银机、冶炼炉、实验室），
一律改成 `custom-prompt` 的 `[E]`；只有同一位置有 ≥2 个动作（如保险箱：撬/放包）才留 ALT 列表。

### 2.5 通缉与告警的关系

| 现状 | 决策 |
|---|---|
| 原生 2 星（`SetPlayerWantedLevel`）与 RP 工单两套并行 | **保留原生星**（NPC 警察要追），但只在"被目击"路径置星；工单由 `policeAlert` 负责。两者不互相取消，文档里写清各自职责，玩家侧的感知仍以屏幕左上星与警察到场为准 |

### 2.6 不做的事

| 项 | 理由 |
|---|---|
| 重做制毒/贩毒的游戏循环 | 属于玩法设计，不在 UI/UX 范围 |
| 引入新资源 | 现有 5 个资源够用；新资源会扩散触点 |


## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收 |
|---|---|---|---|---|
| C-1 ✅(`6bf4d92d`) | 报警分类：`policeAlert(text, kind)` + 6 类标准标题与优先级；7 个调用点补 kind | custom-police 的 server 的 main.lua、custom-police 的 client 的 main.lua、custom-vehicles 的 client 的 main.lua、qb-drugs 的 client 的 {cornerselling,deliveries}.lua、qb-houserobbery 的 client 的 main.lua、qb-storerobbery 的 client 的 main.lua | 中（跨资源契约，需契约闸门） | 警察端工单标题是中文且分类正确；`officer_down` 排最前 |
| C-2 ✅(`ae10c785`) | 门槛/冷却写进交互提示（保险箱、收银机） | qb-storerobbery 的 client/main.lua | 中 | 警察不够时提示写"需 N 名（当前 M）"。**按 E 的反馈口径已被 C-8 取代**（PO 2026-11-12 要求给失败提示，不再静默） |
| C-3 ✅(`7c717344`) | 收益留档：完成/中断给 `feed` + 手机明细 | qb-storerobbery 的 client/main.lua、`qb-drugs` 出售处 | 低 | 屏幕一句、手机有金额与物品 |
| C-4 ✅(`5da47b2c`) | 单动作热区 → `[E]`（保险箱、冶炼、实验室） | qb-storerobbery / custom-mining / qb-drugs | 中（要实测距离） | 站到位置直接出现 `[E]`，不用 ALT |
| C-5 ✅(`c8443524`) | 失败原因细分**经核实已达标**（文案早就分开），改做通道迁移：custom-mining 17 处接三层 | custom-mining | 低 | 采矿失败走 error、开始/产出走 feed |
| C-6 ✅(`7c717344`) | 报警单一派发入口：删 qb-phone 并行警情与客户端自建 blip，只留声音 + policeAlert 建单投影 | qb-storerobbery 的 server 与 client | 中 | 一次抢劫警官侧只响一次、地图上只有一颗 blip |

| C-7 ✅ | **采矿交互返工**（PO 2026-11-12）：① 无死亡态判定 → 倒地仍能采矿；② 提示随范围常驻、没法取消 | custom-mining 的 client/main.lua、server/main.lua | 中 | ① 倒地 1 秒内提示消失、服务端 `mineOre` 以 `metadata.isdead/inlaststand` 拒绝；② 走开即消失、进度条中走开取消 |
| C-7b ⛔回滚 | 冶炼厂 blip 曾改为全图可见（`SetBlipAsShortRange(false)` + `SetBlipDisplay(4)`）—— PO 2026-11-12 说已找到，改回近距离可见 | custom-mining 的 client/main.lua:55-64 | 低 | blip 只在靠近时显示（回滚后行为） |

> **C-7 的翻车记录（值得记住）**：`IsDowned()` 第一次写在了文件 215 行，而它的第一个使用点是 101 行 ——
> Lua 的 `local` 只对**其后**的代码可见，于是运行时 `IsDowned` 是全局 nil，真机 F8 直接刷
> `attempt to call a nil value (global 'IsDowned')`。`luac5.4 -p` 查不出来（语法合法）。
> 规则：新增的 helper 一律放文件顶部的 "基础函数" 区，或者至少放在第一个使用点之前；
> 闸门只能拦语法，这类错只能靠真机日志或「声明先于使用」的 review 发现。
| C-8 ✅ | **保险箱按 E 的失败反馈**：警力不足 → `error`「警力不足 · 需 N 名，当前 M 名」；冷却中 → `feed`「保险箱已空 · 冷却剩余 mm:ss」 | qb-storerobbery 的 client/main.lua | 低 | 警力 1 / 门槛 2 按 E 出红条；冷却 3:42 按 E 出 feed 且带 3:42 |

**顺序**：C-1（收益最大、跨资源一次做完）→ C-3（低风险）→ C-2 → C-4 → C-5。


## 4. 验收（步骤）

> CC 定标准（2026-11-11），DB 表名与列名、`/tccops` 命令都已核对存在。

### V-1 报警分类（C-1）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `/tccops 0`；平民在未抢过的店按 ALT→「撬收银机（抢劫商店）」 | 警察手机收到 `#<id> 911: 商店抢劫` | 截图 |
| 2 | 警察 `M` → MDT → 接警 | 行标题「商店抢劫」，优先级 P2 | 截图 |
| 3 | `SELECT title, priority FROM police_incidents ORDER BY id DESC LIMIT 1` | `商店抢劫 / 2` | DB |
| 4 | （可选）让警察倒下触发 `officer_down` | 标题「警员受伤，请求支援」，排最前 | 截图 |

**反例**：标题是英文自由文本；`officer_down` 不是最高优先级；任一调用点漏 kind。

### V-2 结算单条（C-3）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `/tccops 0`；撬收银机并等结算 | **只 1 条**「抢劫结算：逗留…实得…袋」，无「抢劫完成」 | 录像计数 |
| 2 | 开手机通知中心 | 只 1 条「抢劫结算」，正文含「合计 $…」 | 截图 |
| 3 | `SELECT COUNT(*) FROM phone_notifications WHERE title='抢劫结算' AND timestamp > NOW() - INTERVAL 2 MINUTE` | 1 | DB |

**反例**：屏幕上再出现「抢劫完成」；手机上两条结算；正文没有金额或袋数。

### V-3 单一派发（C-6）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | 警察值班并在远处待命；平民开抢 | 服务端 `[policeAlert]` 只 1 行；警情音效只响 1 次 | 日志 + 录像 |
| 2 | 警察开地图 | 同坐标**只有 1 颗**同名 blip | 截图 |
| 3 | `SELECT COUNT(*) FROM police_incidents WHERE title='商店抢劫' AND created_at > NOW() - INTERVAL 2 MINUTE` | 1 | DB |

**反例**：手机两条同事件通知；同坐标两颗 blip；又出现 qb-phone 并行警情。

### V-4 门槛/冷却写进提示（C-2）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `/tccops 3` 但只有 1 名警察值班；站到未抢过的保险箱旁 | `[E] 撬保险箱 · 需 3 名警察（当前 1）` | 截图 |
| 2 | 按 E | 无动作，**且不弹 error** | 录像 |
| 3 | `/tccops 0` 抢完一间店再回来 | 提示含「冷却 mm:ss」，5 秒后再看少约 5 秒 | 两张截图 |

**反例**：按 E 才弹「需要至少 3 名执勤警察」；冷却不显示；改 `/tccops` 后提示的门槛没变。

### V-5 单动作热区改 `[E]`（C-4）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | 站到保险箱前（≤2m），**不按 ALT** | 出现 `[E] 撬保险箱`，按 E 进小游戏 | 截图 |
| 2 | 站到冶炼炉前 | `[E] 冶炼矿石`，按 E 开菜单 | 截图 |
| 3 | 站到毒品实验室前 | `[E] 打开实验室`，按 E 开菜单 | 截图 |

**反例**：键位仍写 ALT；必须长按 ALT 才出现；按 E 无反应。

## 5. 已知未决

- 犯罪链路的"被发现/被通缉"反馈没有统一通道（现在混在 chat 与 notify 里）；
- 组织（cartel）内部消息走 chat，与 IC 消息通道不一致。
