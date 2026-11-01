---
id: agent-police-blueprint-items-cc
type: spec
status: draft
system: justice
owner: hermes
updated: 2026-11-01
review_by: 2027-04-30
---

# 警察道具层蓝图（Claude Code 独立版）

> 本文件是 **Claude Code 独立调研产出**，原样保留，未与主稿合并。用于对照差异。
> 主稿（含仓库实测审计与最终裁决）见 [`BLUEPRINT-ITEMS.md`](BLUEPRINT-ITEMS.md)；两份稿子的分歧与裁决在主稿 §11。
> 抓取：16 轮 / 14 个页面（含 5 个跟进页）。

---
# T-City Lite 警察 ITEM & PROP 层蓝图

本蓝图只覆盖警察随身与部署的实体道具，不重复 dispatch、案件/记录与 MDT。先给出外部样本的共同结论：**没有一家把 ALPR 做成实体道具；雷达要么是车机 UI，要么是武器码或未给 item ID 的雷达枪**。US$30 的 Pickle 包只有 6 个工具，且不含雷达、钉刺、取证 [S2]。因此本服不该买“道具包”，而应把 qb-policejob 已有的 prop 放置、证据袋与 dispatch 总线接起来。

引用标记 S1–S10 对应文末来源清单；未标记的为本服设计或题目给定上下文。

## 1. 外部道具体系对照

口径：✅ 表示页面明确列出，— 表示页面未提，**不等于不存在**。下表每一列的判断以该列对应 URL 页面为准。

列来源：Pickle 现售包 = https://rpscripts.net/shop/pickle-police-tools-package/ ；Advanced Police Job = https://forum.cfx.re/t/advanced-police-job/5330665 ；Pickle 停售包 = https://forum.cfx.re/t/discontinued-pickles-police-tools-shields-snakecam-bodycam-panic-button-and-more/4978950 ；wasabi v2 = https://docs.wasabiscripts.com/advanced-series/wasabi-police-v2/ ；oxide-police = https://oxidestudios.dev/docs/oxide-police

| 能力/道具 | Pickle 现售包 [S2] | Advanced Police Job [S3] | Pickle 停售包 [S4] | wasabi v2 [S7] | oxide-police [S8] |
|---|---|---|---|---|---|
| 手铐/扎带/剪锁 | — | 手铐（菜单/键位，未称 item） | — | 软铐/硬铐/扎带/钥匙/断线钳 | 前铐/后铐/扎带/剪刀/开锁器 |
| 防暴/防弹盾 | ✅ 2 种盾，可扩展；可持盾瞄准射击 | ✅ 金属/玻璃防暴盾 | ✅ 盾 | — | — |
| 蛇眼摄像头 | ✅ 默认最远 10m | — | ✅ | — | — |
| 随身摄像头 | ✅ item | ✅ bodycam item 开关 | ✅ | ✅ 录像 | ✅ |
| 行车记录仪 | — | ✅ item 安装 | — | — | — |
| 报警按钮 | ✅ `/panic` + item | — | ✅ | 有 panic 警报，未称设备 | — |
| NVG/热成像 | ✅ 头盔集成 | ✅ item + `/toggleNVG` | ✅ | — | — |
| 锥/路障/照明 | — | ✅ 用 item 放置 | — | ✅ placeable props | — |
| 钉刺带 | — | ✅ | — | ✅ | ✅ |
| 测速雷达 | — | ✅ 车载内置 | — | ✅ 雷达枪/雷达柱 | ✅ `WEAPON_RADAR`/车载 |
| 酒精测试 | — | ✅ | — | ✅ | ✅ |
| 指纹/GSR/弹道 | — | ✅ 指纹扫描 | — | ✅ 血/弹壳/指纹/GSR | ✅ GSR/弹道/车辆指纹 |
| 监控/CCTV | — | — | — | ✅ 放置/持久/终端 | ✅ |
| GPS/追踪 | — | 仅警员位置 blip | — | ✅ tracker/手环 | ✅ 追踪带 |
| 轮锁 | — | — | — | — | ✅ |
| 扩音器 | — | — | — | — | ✅ |
| 破门/破拆 | — | — | — | ✅ 断线钳 | ✅ 开锁器 |

雷达与 ALPR 再单列，因为它们是“道具化”判断的关键：

| 产品 | 形态 | 页面明确给出 | 是否库存道具 | 来源 |
|---|---|---|---|---|
| codesign ALPR | 车机 UI | 4 路相机、自动锁定、BOLO 标记、车牌/车型/颜色/速度/相机日志 | 否，无道具/ prop | [S5] |
| RS9000 | 车内面板 | 前后天线、50m 固定量程、超速蜂鸣、1.2.0 加车牌显示 | 否 | [S6] |
| wasabi radar gun | 手持/固定点 | 雷达枪、雷达历史、持久雷达柱 | 雷达枪，但未给 item ID | [S7] |
| oxide | 武器 + 车机 | `WEAPON_RADAR`、车载前后锁定 | 是（武器码） | [S8] |
| APJ | 车机 | 内置车载雷达、锁定/自动锁定限速 | 否 | [S3] |

结论：**道具层最值得抄的是 Pickle 的“每个工具一个 item、可按 job/grade 限制”** [S2]；APJ、wasabi、oxide 值得抄的是“同一套 UI 同时服务手持与车机” [S3][S7][S8]，而不是再买一套实体模型。

## 2. 分类清单

| 类别 | 候选道具 | 解决的 RP 问题 | 外部依据 |
|---|---|---|---|
| 执法控制 | 扎带 | 大规模拘捕/临时约束，手铐不够用 | [S7][S8] |
| 执法控制 | 防暴盾 | 对峙时提供移动掩体，减少直接开枪 | [S2][S3][S4] |
| 执法控制 | 破门锤/断线钳 | 入室、破门、剪锁有动作与声音，不再“穿门” | [S7][S8][S10] |
| 执法控制 | 约束头套/封口 | 押送时阻止喊话/识别；但滥用风险高 | [S8] |
| 交通 | 钉刺带 | 追车终止手段，比撞停更可控 | [S3][S7][S8] |
| 交通 | 锥/路障/照明 | 现场封控、夜间可见、保护现场 | [S3][S7] |
| 交通 | 手持雷达 | 超速取证，TRAFFIC 专属玩法 | [S7][S8] |
| 交通 | 车载雷达 | 巡逻中测速，不占背包 | [S3][S6][S8] |
| 交通 | 轮锁 | 违停/扣押，低强度日常 | [S8] |
| 交通 | 测速相机 | 固定点自动测速/提醒 | [S3][S8] |
| 交通 | ALPR | 热榜车牌命中，追车起点 | [S5] |
| 取证 | 证据袋 | 链式保管（现有） | 现有 |
| 取证 | 证据标记/警戒带 | 现场边界、编号、可点击证据入口 | 本服提案；[S7] 仅泛称 placeable props |
| 取证 | 指纹套件 | 身份确认/前科串联 | [S3][S7][S8] |
| 取证 | GSR 套件 | 射击残留，区分开枪者 | [S7][S8] |
| 取证 | 呼气测试 | 酒驾检查，最高频交通 RP | [S3][S7][S8] |
| 取证 | 毒品快筛 | 毒驾/持毒初筛 | UNVERIFIED 外部未见 |
| 取证 | 证据相机 | 照片/视频入卷 | [S8][S10] |
| 记录监控 | bodycam | 执法记录、投诉复盘 | [S2][S3][S4][S7][S8] |
| 记录监控 | dashcam | 追车/事故记录 | [S3] |
| 记录监控 | CCTV | 定点监控、站内终端 | [S7][S8] |
| 记录监控 | 蛇眼 | 隔门/墙角侦查 | [S2][S4] |
| 记录监控 | NVG/热成像 | 夜间搜索/追踪 | [S2][S3][S4] |
| 通信定位 | 报警按钮 | 一键增援，小服的可靠入口 | [S2][S4] |
| 通信定位 | GPS 追踪器 | 嫌疑人/车辆定位，长线案件 | [S7][S8] |
| 通信定位 | 追踪手环 | 保释/软禁监控 | [S7] |
| 通信定位 | 扩音器 | 喊话/疏散/谈判 | [S8] |

## 3. 该抄什么、该砍什么

判断标准只有三条：10–30 人能不能凑出使用场景；是否复用现有 prop/证据/dispatch；维护成本是否低于它带来的 RP。

### 值得做

| 道具 | 裁决 | 理由 |
|---|---|---|
| 钉刺带 item 化 | 值得 P0 | 现有 `/spikestrip` 已能用，只差 item gate；最低成本改变追车 RP |
| 锥/路障/照明 item 化 | 值得 P0 | 现有 prop 已同步，item 化后才有“取用—部署—回收”链条 |
| 证据标记/警戒带 | 值得 P0 | 把“现场”变成可点击的证据入口，MDT 有内容可写 |
| 呼气测试 | 值得 P0 | 酒驾是最高频交通 RP；一次 UI + 一条 evidence row |
| 报警按钮 | 值得 P0 | 小服没有 NPC 警察，panic 是可靠增援入口 [S9] |
| 手持雷达 | 值得 P1 | TRAFFIC 专属玩法；只读 UI，不写库 |
| 指纹/GSR | 值得 P1 | 复用现有 blood/casing/fingerprint，CID 有活干 |
| GPS 追踪器 | 值得 P1 | 长线案件/绑架案核心；MDT 显示位置 |
| 防暴盾 | 值得 P2 | SWAT 场景少，但用到时很出彩；先做 1 种 |
| 破门锤 | 值得 P2 | 入室搜查的仪式感；与 qb-target 门状态结合 |
| 轮锁 | 值得 P2 | TRAFFIC 低强度日常；实现简单 |

### 降级做

| 道具 | 裁决 | 理由 |
|---|---|---|
| 车载雷达 | 降级 | 只做车机 UI，复用手持雷达；RS9000 本身就是面板不是道具 [S6] |
| ALPR | 降级 | 只做“车牌查询 + 热榜命中 dispatch”，不铺摄像头网；codesign 也是纯软件 [S5] |
| bodycam | 降级 | item 开关 + 起止日志 + 案件引用，不做实时视频；全量视频存储不现实 |
| dashcam | 降级 | 并入 bodycam/事故记录，不单列 item [S3] |
| NVG/热成像 | 降级 | 做成头盔/装备附属，不单列 item；Pickle/APJ 都是装备 [S2][S3] |
| 测速相机 | 降级 | 固定点提示 + dispatch，不自动罚单；自动罚单绕过 RP [S3][S8] |
| CCTV | 降级 | 站内终端 + 少量固定点，不做随身部署；wasabi/oxide 是系统 [S7][S8] |

### 不建议做

| 道具 | 裁决 | 理由 |
|---|---|---|
| 蛇眼 | 不建议 | 第二摄像头/CEF，使用频率极低 [S2][S4] |
| 抓钩 | 不建议 | 物理同步/滥用，且非本服核心 [S10] |
| 刺棍 | 不建议 | 近战 prop，无玩法闭环 [S10] |
| K9 | 不建议 | UNVERIFIED 无种子依据；AI 寻路/动画/指令，维护成本远超收益 |
| 无人机 | 不建议 | UNVERIFIED 无种子依据；操控/图传/权限，小服无人专门操作 |
| 封口/头套 | 不建议 | 同意与滥用风险 [S8] |
| 自动测速罚单 | 不建议 | 无 NPC 警察兜底 [S9]，罚单应由玩家开 |
| 独立防弹衣 take vest | 不建议 | qb-smallresources 已有 useable armor [S9]，重复 |
| 全量 ALPR 摄像头网 | 不建议 | 热榜维护/误报/隐私争议；小服车流撑不起 |

“看起来酷但没人用”的填充物很集中：**蛇眼、抓钩、刺棍、热成像头盔、全量 ALPR、自动测速相机、K9/无人机**。小服一晚可能只有 1–2 场追车、0–1 场 SWAT；一个一周用一次的道具，要占 8–20 小时开发、一张图标、一套同步/回收/QA，机会成本远高于把证据和 dispatch 打通。prop 类尤其如此：每多一种就多一组 netId 同步、清理和权限 bug。

## 4. 道具的生命周期

获取只走军械库与证物室两扇门，部门 + 等级双门控；不做合成/黑市。现有 police stash 是否按等级限权未经确认，实现时必须在服务端取物处校验，不能假设 UI 会拦。使用入口分三类：**usable item**（测试、开关、消耗品）、**qb-target**（对人/车/门/尸体）、**车机**（雷达/ALPR/行车记录）。部署物统一复用 qb-policejob 的 prop 放置与网络同步，不另起一套。

| 道具 | 获取（部门/等级） | 使用入口 | 消耗/复用 | 回收/上限 | 留痕 |
|---|---|---|---|---|---|
| 扎带 | PATROL 0 | usable 对已控制玩家 | 一次性 | 无 | 可选审计 |
| 锥/路障/照明 | PATROL 0 | usable 放置 | 复用 | qb-target 回收；每人 5/类、全局 30 | deployment |
| 钉刺带 | TRAFFIC 1 / PATROL 1 | usable 放置 | 复用 3 次 | 回收；`Config.MaxSpikes` | deployment + audit |
| 证据标记/警戒带 | PATROL 1 / CID 2 | usable 放置 | 标记复用、胶带一次性 | 标记回收；胶带不回收 | evidence |
| 呼气测试 | TRAFFIC 1 / PATROL 1 | usable 对玩家 | 主机复用、吹嘴一次性 | 无 | evidence + audit |
| 指纹/GSR | CID 2 | usable 对物/车/人 | 试剂一次性 | 无 | evidence |
| 手持雷达 | TRAFFIC 1 | usable 开 UI | 复用 | 无 | UI；可选 evidence |
| 车载雷达 | TRAFFIC 1 | 车机菜单 | 复用 | 无 | UI；可选 evidence |
| 报警按钮 | 全体 0+ | usable / `/panic` | 复用 | 无 | dispatch + audit |
| bodycam | PATROL 1 | usable 开关 | 复用 | 无 | audit + evidence ref |
| GPS 追踪器 | CID 2 | qb-target 装车/人 | 复用，电池 30 min | 回收 | MDT + dispatch + evidence |
| 防暴盾 | SWAT 2 | usable 装备 | 复用 | 回军械库 | audit |
| 破门锤 | SWAT 2 | qb-target 门 | 复用 5 次 | 无 | audit |
| 轮锁 | TRAFFIC 1 | qb-target 车轮 | 复用 | 解锁回收 | evidence + audit |
| CCTV | CID 2 | 放置 + 终端 | 复用 | 回收；全局 8 | MDT + evidence ref |
| 蛇眼 | SWAT 2 | usable | 复用 | 无 | 无（不建议） |

消耗设计：一次性（扎带、试纸、封条、证据袋）与可复用（盾、雷达、破门锤、轮锁、CCTV、追踪器）。可复用设备 `unique=true`，`info` 里放 `serial/owner/uses`；部署类 item 不消耗，只置 `info.deployed=true` 并登记，回收时复位；重启时 prop 全清、item 留在背包，避免丢件。上限沿用 `Config.MaxSpikes` 的思路，新增每人/全局 `MaxDeployables`，超限拒绝而不是静默删旧 prop。

留痕：设备序列号、发放/归还、部署/回收、证据产出。审计写现有案件/记录或轻量 `police_tool_audit`；不要每个道具一张表。

## 5. 与已定架构的接线

所有取证道具只调一个服务端函数 `AddPoliceEvidence(src, kind, payload, item, coords, caseId?)`，由它写 `police_evidence`、回填 `filled_evidence_bag.info.evidence_id`、推 MDT；所有报警只调 dispatch 总线的 `CreateCall`，不要各自 `TriggerClientEvent`。这样一张表能查全链路。

| 产出 | `police_evidence` | UI 读数 | dispatch call | 备注 |
|---|---|---|---|---|
| 证据袋/标记/指纹/GSR/呼气/毒品/弹道/照片 | ✅ | — | — | 统一走 `AddPoliceEvidence`，payload 带 kind/coords/source_item |
| 手持/车载雷达 | 可选 | ✅ | — | 超速读数先 UI；“存为证据”才落库 |
| ALPR | 命中可写 | ✅ | ✅ | 仅热榜命中 call，日志留 MDT |
| 测速相机 | ✅ | — | ✅ | 固定点，不自动罚单 |
| 报警按钮 | — | — | ✅ | 最高优先级，带部门/坐标 |
| GPS 追踪器 | 可选 | ✅ | 激活时 ✅ | 位置更新走 MDT，不刷 dispatch |
| bodycam | 引用 | ✅ | — | 只存起止/坐标/案件 id，不存视频 |
| dashcam | 引用 | — | 事故时可选 | 并入 bodycam |
| CCTV | 引用 | ✅ | — | 站内终端查看 |
| 钉刺带 | — | — | 手动 | 只写 deployment/audit |
| 盾/破门锤 | 破门可写 | — | — | 默认 audit |
| 轮锁 | ✅ | — | — | 车牌 + 照片 |
| 锥/路障 | — | — | — | deployment only |
| 蛇眼 | — | ✅ | — | 不建议 |

qb-smallresources 已移除 GTA 通缉系统与默认紧急 NPC [S9]；按项目给定上下文，默认 dispatch 也被移除。因此 ALPR/测速相机/panic 的自动检测必须转成玩家 dispatch call，没有 NPC 警察兜底。这也是“自动罚单”在本服不成立的根本原因。

## 6. 优先级与工时

按 1 名熟练 dev、含自测、不含图标绘制估算；每个新 item 图标另计 0.5h。

| 优先级 | 内容 | 工时 | 依赖 |
|---|---|---|---|
| P0 | 物品底座：`items.lua` 定义 + 图标 + 军械库服务端校验 | 6h | qb-inventory、police stash |
| P0 | 部署注册表/回收/上限/重启复位 | 5h | 现有 prop 放置、`Config.MaxSpikes` |
| P0 | 钉刺带 item 化 | 3h | 上两项 |
| P0 | 锥/路障/照明 item 化（先 3 类） | 3h | 上两项 |
| P0 | 证据标记 + 警戒带 | 6h | 部署注册表、`police_evidence` |
| P0 | 呼气测试 | 5h | evidence export、UI |
| P0 | 报警按钮 | 4h | dispatch 总线、audit |
| P1 | 手持雷达 | 8h | UI、车辆速度 native |
| P1 | 指纹/GSR 套件 | 8h | evidence export、qb-target |
| P1 | 毒品快筛 | 4h | 同上 |
| P1 | GPS 追踪器 | 10h | MDT、dispatch、DB |
| P1 | bodycam 日志化 | 8h | audit、evidence ref |
| P1 | 证据相机 | 6h | 截图/片段元数据 |
| P1 | 轮锁 | 4h | 车辆状态、evidence |
| P1 | 防暴盾 | 10h | 盾牌动画/武器同步 |
| P2 | 破门锤 | 8h | qb-target、门状态 |
| P2 | CCTV | 16h | 摄像头注册、MDT viewer、权限 |
| P2 | 车载雷达 | 8h | 复用手持雷达 UI |
| P2 | ALPR 精简版 | 14h | 车牌查询/热榜、dispatch |
| P2 | 测速相机 | 10h | 放置、dispatch、不自动罚单 |
| P2 | 蛇眼（可选） | 8h | 第二摄像头；不建议默认做 |
| P2 | NVG/热成像（可选） | 4h | 视觉 toggle |

P0 约 32h（4 个工作日），P1 约 58h（7 天），P2 约 68h（8–9 天）。P0 约 9 张图标，另计 4.5h；P0 不依赖任何外部付费资源。

## 7. 明确不建议做

- **蛇眼**：第二摄像头/CEF，默认 10m 视角，使用频率极低；用 `/me` 或现场照片替代 [S2][S4]。
- **抓钩/刺棍**：物理同步与滥用风险，非核心；不做 [S10]。
- **K9/无人机**：UNVERIFIED 无种子依据；AI 寻路/图传/权限，10–30 人服养不起专职操作员。
- **全量 ALPR 摄像头网**：热榜维护、误报、隐私争议；只保留“车牌查询 + 命中提示” [S5]。
- **自动测速罚单**：本服无 NPC 警察兜底 [S9]，罚单必须由玩家开；自动罚单绕过 RP。
- **封口/头套**：同意与滥用风险；不做 [S8]。
- **独立防弹衣 take vest**：qb-smallresources 已有 useable armor [S9]；重复。
- **独立行车记录仪**：并入 bodycam；不做第二套存储 [S3]。
- **武器挂绳/纯装饰**：没有 RP 闭环；不做。
- **第二套手铐/扎带系统**：现有 `handcuffs` 已可用；扎带只作为“大规模拘捕”补充，不重做手铐。

如果只能做三件：**钉刺带 item 化、证据标记/警戒带、报警按钮**。第四件是呼气测试。这四件把“追车—现场—取证—增援”串成一条链，比任何酷炫玩具都更能在 10–30 人服里被反复用到。

---

### 来源清单

- [S1] https://fivemx.com/shop/pickle-police-tools-package —— 只剩迁移公告，实际商品页迁至 rpscripts。
- [S2] https://rpscripts.net/shop/pickle-police-tools-package/ —— Pickle Police Tools 现售包；6 个工具；`police_panic`/`police_shield`/`police_bodycam`/`police_snakecam`；可按 job/grade 限制；US$30。
- [S3] https://forum.cfx.re/t/advanced-police-job/5330665 —— cones/barriers/worklights 用 item 放置；bodycam/dashcam/NVG item；spike strips、speed camera、shields、take vest、breathalyzer、fingerprint scanner、vehicle radar、trackers、evidence lockers。
- [S4] https://forum.cfx.re/t/discontinued-pickles-police-tools-shields-snakecam-bodycam-panic-button-and-more/4978950 —— 已停售；shields、snakecam、bodycam、panic button、helmets、night vision、flashlight。
- [S5] https://forum.cfx.re/t/fivem-radar-alpr-script-by-codesign/4891890 —— ALPR 纯 UI，无道具/ prop；4 路相机、自动锁定、BOLO、日志；€14.99。
- [S6] https://forum.cfx.re/t/release-rs9000-police-radar/672343 —— 车内面板；前后天线；50m 固定量程；1.2.0 车牌显示。
- [S7] https://docs.wasabiscripts.com/advanced-series/wasabi-police-v2/ —— 扎带/断线钳、血/弹壳/指纹/GSR、呼气、CCTV、bodycam、tracker/手环、雷达枪/雷达柱、钉刺带、placeable props、grade-aware armory。
- [S8] https://oxidestudios.dev/docs/oxide-police —— `WEAPON_RADAR`、megaphone、breathalyzer、bodycam、CCTV、evidence camera、tracking bands、wheel clamps、mouth tape/headbags、zip ties、front/rear cuffs、spike strips、placeable speed cameras、vehicle radar。
- [S9] https://github.com/qbcore-fivem/qb-smallresources —— useable binoculars/parachute/armor；tackle/hostage/weapon draw/crouch/prone/fireworks；移除 GTA 通缉系统与默认紧急 NPC。
- [S10] https://forum.cfx.re/t/pickles-police-job-in-game-creator-evidence-system-modern-police-tools/5350894 —— grappler、stab sticks、object placer、NVG/thermal、snakecams、shields、evidence camera、BAC/GSR/fingerprint/blood testing；ox_lib；ESX/QBox/QB。