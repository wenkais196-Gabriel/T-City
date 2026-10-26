# 10 — 警情全生命周期：三个按钮、一个判定源、一条归档线

> **核心命题**: 一条警情不是一个状态字段，而是一次**处警会话**：谁负责、走到哪一步、怎么结案、事后能不能查到案卷。
> **适用范围**: custom-police 的 P0 派单层、MDT 调度页、police_cases 归档、45 分钟 stale 清扫。
> **状态**: 设计稿（2026-10-26），实现排入 P5；本文只定语义与顺序，不改代码。

---

## 1. 复核：三个按钮现在到底做了什么

现场观察是「前往 / 到场 / 清场三个按钮，按顺序应该只有一个能点，而且只有被派遣的人能点」。
复核结果是：**这三个约束一条都没有在前端落地，其中两条服务端也没落地。**

| 按钮 | 前端 | 服务端入口 | 实际检查 | 真实结果 |
|---|---|---|---|---|
| 前往 | PoliceMDT.svelte 866 行，永远可点 | appAction enroute → SetIncidentStatus(..., enroute) | PolicePolicy.Can(incident.update, grade≥1) + 若 grade<2 必须已在本单单位表里 + SM-02 转移表 | 单子处于 open 时**必然失败**：转移表里 open 只能到 assigned / closed |
| 到场 | 同行 867，永远可点 | appAction on_scene | 同上 | open / assigned 时同样 invalid_transition |
| 清场 | 同行 868，永远可点 | appAction clear → SetIncidentStatus(cleared) | 同上（**没有单独的清场能力位**） | 状态置 closed、写 disposition（前端硬编码 cleared）、释放单位、写审计；**不建档** |

三条相关事实（都能在代码里指到）：

1. GetIncidents 只返回警情行本身（p0.lua 349–380 行），**不返回"当前这个人能对它做什么"**。前端拿不到判定结果，只能把所有按钮画出来。
2. 士兵规则里那条"只有被派遣的能点"写成了 grade<2 才校验（p0.lua 494 行）：
   grade≥2 的警官可以推进**任何**一张单，且审计里不会出现"我覆盖了谁"。
3. 多单位是假的：police_incident_units 有 role 列但**全仓库无人读写**；markIncidentUnits
   （p0.lua 94–96 行）按 incident_id 一把刷，把这张单上所有单位刷成同一状态。
   所以"到场"的真实语义是"**所有单位都到场**"。

---

## 2. 五个结构性问题

### 2.1 顺序规则只活在一个 switch 里，UI 完全不知道

转移表 SM-02 是唯一权威，这是对的；但它是**服务端私有**的。前端想知道"现在能不能点前往"，
要么复制一份转移表（两套规则必然漂移），要么什么都不显示（现状）。中间那条路是：
**服务端把判定结果一起下发**。

### 2.2 "只有被派遣的能点"有例外，却没有痕迹

grade≥2 跨单操作是合理的（主管接管现场），但当前写法是"静默允许"：审计里只有
incident.status，看不出这是本人单还是别人单。真出事时查不到"谁从谁手里接过去"。

### 2.3 清场 ≠ 归档

p0.lua 31 行的注释写着「archived calls live in cases/audit」，但复核结果：
关闭时**只写 police_audit，不写 police_cases**。police_cases 表存在、有 CreateCase 导出
（p3_cases.lua 324 行）、MDT 有案件页，唯独"警情结案"这条路不通向它。
于是每一张处理完的警情，事后在案件库里查不到——只有一条审计行和一个 disposition 字符串。

### 2.4 disposition 由前端写死

clearIncident 把 status 和 disposition 一起硬编码成 cleared（PoliceMDT.svelte 434 行）。
"误报""已逮捕""调度取消"在数据里无法区分，导致统计、考核、NPC callout 的失败标记全部失真。

### 2.5 一次警情有三个写者，语义重叠

- police_incidents.status：事件进度
- police_units.status + police_units.incident_id：这个人在干什么
- police_incident_units：谁参与过（role 没用）
- 加上 markIncidentUnits 的"一把刷"，三者会互相覆盖。

---

## 3. 目标模型

### 3.1 一条警情由四件东西组成

| 名字 | 回答的问题 | 载体 | 谁是权威 |
|---|---|---|---|
| 事件 incident | 发生了什么、在哪、多急 | police_incidents | 状态是**投影** |
| 单位 unit | 谁在去、谁到了 | police_units | 状态是**事实**（只有本人能改） |
| 动作 action | 此刻谁能做什么 | 判定函数（服务端） | 唯一判定源 |
| 档案 case | 事后怎么查 | police_cases | 结案的产物 |

关键转变：**incident.status 不再是某个人直接写进去的值，而是"这张单上各单位进度"的派生结果。**
这直接修掉 2.3 之外的多单位问题，也让"到场"恢复它本来的意思。

### 3.2 状态机（收敛后）

开放 open → 受理 assigned → 前往 enroute → 现场 on_scene → 结案 closed

- 允许一步省掉"受理"：在 open 上点「前往」，服务端**自动把点击者设为 primary 并写一条
  incident.assign 审计**，然后推进到 enroute。单人巡逻不必先点"派给我"（现状的死路）。
- 结案必须带 disposition（四选一，见 3.6），可附 200 字理由。
- 45 分钟无活动的 stale 清扫走**同一条结案路径**（disposition=stale），不再自己写 UPDATE。

### 3.3 单位：primary + support，进度取最大

| 角色 | 能做什么 | 不能做什么 |
|---|---|---|
| primary（第一个接手 / 调度指派） | 推进事件状态：enroute → on_scene → closed | 代表别人到场 |
| support（后加入） | 只能改**自己的**单位状态 | 不能推进事件状态 |

rule: incident.status = max(所有未释放单位的进度)；全部释放 → 结案或回到 assigned。
实现上保留 incident.status 列，但只由 recomputeIncidentProgress(incidentId) 写，
markIncidentUnits 这种"按 incident_id 一把刷"的写法删除。

### 3.4 权限矩阵（capability）

新增三档，替代今天"清场也是 incident.update"的含糊：

| capability | minGrade | 额外条件 | 说明 |
|---|---|---|---|
| incident.enroute | 1 | 本单位已在该单，或可自领 | 前往 |
| incident.arrive | 1 | 本单位已在该单 | 到场 |
| incident.clear | 1 | 本单位已在该单；grade≥2 任意单 | 清场 |
| incident.override | 2 | — | 跨单操作，强制写 override 审计 |
| incident.assign | 2 | — | 指派他人 |
| incident.create | 0 | — | 任何在勤警官可建单（平民报警不经此路径） |

### 3.5 allowed_actions：服务端告诉 UI 能点什么

GetIncidents 每一行新增 actions 字段（契约示例）：

    {"id": 40, "status": "open", ...,
     "actions": {
        "enroute": {"allowed": true,  "reason": null},
        "on_scene": {"allowed": false, "reason": "not_yet_enroute"},
        "clear":    {"allowed": true,  "reason": null}
     },
     "primary": null,
     "units": ["IYY39878"]}

规则：

1. **判定与执行共用同一个函数**（IncidentActionState(actor, incident)）：UI 拿到的 allowed
   与真正执行时的结果不可能不一致。
2. reason 是给玩家看的中文（"还没指派给你""要先去现场才能结案"），不是错误码。
3. 前端只做渲染：allowed 才可点，blocked 变灰并把 reason 放进 tooltip；
   前端**不复制**转移表。
4. 服务端执行时**照旧全量复检**：allowed_actions 是展示层，不是授权凭证（防篡改）。

### 3.6 清场 = 清场命令 + 归档

清场按钮的语义从"把状态改成 closed"变成**一条命令产生两个产物**：

| disposition | 是否建档 | 档案里放什么 |
|---|---|---|
| arrest（已逮捕） | 必建档 | 事件 + 处置 + 涉案人（有则带 citizenid） |
| cleared（已处理） | 默认建档 | 事件 + 处置摘要（警员可编辑，5 分钟不填则用模板） |
| false_alarm（误报） | 不建档 | 只写 disposition，进统计 |
| cancelled（调度取消） | 不建档 | 记录取消人 |

归档实现：

- case_no 规则 INC-YYYYMMDD-<incident id>（唯一，可回查）
- title = 警情标题；summary = 模板化（时间、地点、报警内容、处置结果、参与单位）
- lead_citizenid = 本单 primary；created_by = 清场人
- police_incidents 新增 case_id 列指向 police_cases.id
- 顺带解决权限错位：case.create 要求 grade≥2，但 grade 1 的现场警员必须能结案 →
  归档由 incident.clear 内部完成，**不额外提升调用者权限**（能结案 ≠ 能随便建档，
  档案内容由系统按模板生成，人只能改摘要）

时间线不新建表：police_audit 里 target=incident id 的 incident.* 行就是时间线。
UI 的时间线页 = 这张 audit 投影，排序 desc。

### 3.7 数据模型变更（最小集）

| 变更 | 目的 | 迁移 |
|---|---|---|
| police_incidents.case_id BIGINT UNSIGNED NULL + INDEX | 警情 → 案卷 | up/down 各一条 ALTER |
| police_incident_units.role 真正启用（primary 唯一） | 谁能推进主状态 | 数据回填：每单第一个单位为 primary |
| 不新建表 | 时间线复用 audit；单位状态已有表 | — |

### 3.8 可观测性

每个成功动作一行（走现有限流诊断通道，不通篇 print）：

    [police] inc=#40 action=enroute by=<cid> open->enroute units=1 primary=<cid>
    [police] inc=#40 action=clear  by=<cid> on_scene->closed disp=arrest case=12

每个拒绝一行（同通道、按 source 限流）：

    [police] inc=#40 action=clear denied=not_assigned by=<cid>

这样"点了没反应"永远能落成一条可读的拒绝原因，而不是靠玩家描述。

### 3.9 安全边界

- 前端可被篡改：每条动作在服务端独立复检（现状已如此，保留，并在 P5-1 加测试守住）。
- disposition / status 一律白名单。
- override 必须留痕，否则等于没有。
- 归档内容由系统生成，人只能改摘要 → 防止"清场"变成"随便造案卷"。

---

## 4. 判定表（按钮 × 状态 × 身份）

图例：可=可点并成功；灰=置灰并给原因；—=按钮不出现

| 警情状态 | 点击者 | 前往 | 到场 | 清场 | 备注 |
|---|---|---|---|---|---|
| open | 无关 grade1 | 可（自领单） | 灰（还没去） | 灰（不是你的单） | 自领单写 assign 审计 |
| open | 本单 primary | — | 灰（还没去） | 可（撤销/误报） | |
| open | grade≥2 | 可（接管） | 灰 | 可（cancelled） | 接管写 override |
| assigned | primary | 可 | 灰（还没去） | 可 | |
| assigned | support | 可（只改自己） | 灰 | 灰 | |
| enroute | primary | 灰（已前往） | 可 | 可 | |
| enroute | support | 灰 | 可（只改自己） | 灰 | |
| on_scene | primary | 灰 | 灰（已到场） | 可 | 清场是唯一合法下一步 |
| on_scene | support | 灰 | 灰 | 灰 | |
| closed | 任何人 | — | — | — | 板上不出现 |

---

## 5. 分阶段计划

| 阶段 | 内容 | 时间盒 | 验收标准 |
|---|---|---|---|
| P5-1 | IncidentActionState + allowed_actions 下发 + 三按钮门控 + open 自领单 | 0.5–1 天 | 单人巡逻点「前往」一次到位进 enroute；未指派者看到置灰和中文原因；allowed 与执行结果由同一函数产出（harness 断言一致） |
| P5-2 | 单位模型：primary/support 启用、进度派生、删掉 markIncidentUnits | 1 天 | 两个单位分别 enroute/on_scene 时事件状态取最大进度；本人只能改自己的单位状态 |
| P5-3 | 清场归档：disposition 四选一 UI、case_id、case_no、模板摘要、stale 同路径 | 1 天 | 逮捕清场后案件页能查到 INC- 号案卷；误报不建档但进统计；stale 清扫产出同结构档案 |
| P5-4 | override / transfer / 增援单位 | 0.5 天 | 接管留痕（谁覆盖谁）；移交后原 primary 变 support |

每阶段的测试要求（与仓库既有约定一致）：

- Lua harness 驱动真实 p0（MySQL/QBCore 桩）：判定表逐格断言 + 反向校验（把自领单删掉、
  把 assigned 检查放宽成"所有人可点"，测试必须红）。
- NUI 场景：按钮 disabled 状态、tooltip 文案、点不了的时候不发出 appAction。
- 架构闸门：allowed_actions 与执行必须同源（禁止 UI 里出现第二份状态机字符串表）。

---

## 6. 仍需拍板

1. **support 单位点「到场」要不要推进事件状态**：建议推进（派生取最大进度），否则多单位到场
   在板上看不出来。
2. **清场是否一律建档**：建议按 3.6 的表（arrest 必建、cleared 默认建、false_alarm/cancelled 不建）。
3. **主管跨单要不要显式「接管」按钮**：建议要，否则"谁抢了谁的现场"永远查不到。
4. **单人点「前往」自动自领单**：建议是（现状的 open→enroute 是死路）。
5. **清场后单位状态**：建议 available 并解除 incident_id；手动 busy 的保持 busy（沿用今天
   releaseIncidentUnits 的语义）。

---

## 7. 不做什么

- 不碰 qb-policejob 上游动作层（fine / jail / 驾照等），只在自己的 custom-police 里收敛。
- 不新建并行事件模型：police_incidents 仍是唯一事实源，时间线是 audit 的投影。
- 不在前端复制状态机：任何"按钮为什么点不了"的判断都必须来自服务端。
- 不为归档新建表：police_cases 已经存在，只是没人往里写。
