---
id: ux-admin
type: manual
status: active
system: ops
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 管理与审计 · UX 设计

> 状态 **active**：四节齐全。A-1…A-5 已交付；细分权限层与金钱命令审计列入 §5。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `custom-admin` | 39 | 0 | 13 |
| `custom-logs` | 0 | 0 | 0 |

### 1.2 玩家会卡住的场景

| # | 场景 | 现在 |
|---|---|---|
| 1 | 新管理员找命令 | 全仓 **336 条**命令，没有游戏内清单；`/amenu` 曾对**所有玩家**开放（已补 admin 权限） |
| 2 | 误操作不可回滚 | 改钱/给物品没有二次确认，也没有"谁在什么时候做了什么"的即时回执 |
| 3 | 查日志 | `custom-logs` 只落文件与 Discord，游戏内无法检索 |

### 1.3 CC 逐行审计（2026-11-11）

| 命令 | 注册权限 | 二次确认 | 位置 |
|---|---|---|---|
| `/myid` | `user`（全体） | 无 | custom-admin 的 server/commands.lua:11 |
| `/amenu` | `admin` | 无 | 同文件:42,69 |
| **`/tccops`** | **`user`（全体）** | 无 | 同文件:78,102 |
| `/clearme` | `admin` | 无 | 同文件:136,162 |
| 6 条执照命令 | `admin` | 无 | 同文件:170–368 |
| `/apanel`、`/menu` | **客户端注册，无服务端校验** | 无 | client/admin_panel.lua:9,54 |

**权限判定在注册期**：`QBCore.Commands.Add` 的最后一个参数决定 `restricted`，
非 `user` 会被注册成 ACE 命令；**回调内不复查权限**。

**两个真问题**：

1. **`/tccops` 是 `user`** —— 任何玩家都能把抢劫警察门槛设成 0，等于关掉整条犯罪链的门禁；
2. **`/apanel`、`/menu` 是客户端命令** —— 任何玩家都能读到管理命令清单，且客户端命令不过服务端判权。

**审计现状**：`custom-logs` 分 economy / security / system 三流，写日文件 + Discord，
但字段只有自由文本 `title + message`；经济记录有目标与新余额，**没有操作者、没有旧值**；
custom-admin **全文 0 处审计调用**。结论：有金额流水，**没有"谁改了谁的钱"**。

### 1.4 外部实践（CC 调研）

| 维度 | 做法 | 来源 |
|---|---|---|
| 权限分层 | txAdmin **没有固定 owner/admin/mod 预设**，按动作授权（kick/ban/teleport/heal、manage.admins、all_permissions）；社区实践 Support→Mod→Admin→Owner，**经济权不给 Support/Mod** | txAdmin 文档、Clouduxe |
| 破坏性操作 | ban 与大额给钱做 **two-step confirm**；金额上限 + 理由码 + 限流；每个动作服务端重新验权 | RAX、QBCore 文档 |
| 审计 | 中央 `LogStaffAction` 记 操作者(name/id/license/discord)、动作、目标、old/new、理由、UTC；按类别分频道 + 索引化落库 | 同上 |
| 底层授权 | ACE：`add_ace <principal> command.<name>`；restricted 命令由服务端判定 | FiveM 文档 |

**外部结论三条**：

1. **按动作授权，不按头衔**：`admin` 是一个总闸，但"能不能给人发钱"要单独一条权限；
2. **破坏性操作 = 服务端复核 + 二次确认（写清目标与金额）+ 先落审计再执行**；
3. **审计必须有 old/new 与操作者**，只有"谁收到了钱"等于没审计。

### 1.5 玩家会卡住的场景（更新）

| # | 场景 | 现在 |
|---|---|---|
| 1 | 管理员找命令 | 全仓 **339 条**，游戏内只有 10 条硬编码；现已生成清单（A-1） |
| 2 | 普通玩家能改玩法参数 | `/tccops` 曾是 `user`（A-2 已修） |
| 3 | 谁改了谁的钱 | 查不到（A-3 已补审计） |
| 4 | 误操作 | 执照类命令无二次确认（A-4 待做） |
| 5 | 目标比自己权限高 | 无等级比较（A-5 待做） |

## 2. 设计（目标）

> 一句总纲：**管理能力的每一层都要能回答三个问题** —— 谁能做、做了什么、怎么追。

### 2.1 权限分层（按动作，不按头衔）

| 层 | 能做什么 | 判定 |
|---|---|---|
| `user` | 只读自己的信息（`/myid`、`/coords`） | 默认 |
| `mod` | 状态类干预（复活、冻结、传送、观察） | `mod` |
| `admin` | 改人（踢、执照、职级）、改玩法参数（`/tccops`） | `admin` |
| `god` | 经济与权限（给钱、给物品、改权限、批 L4 审批） | `god` |

**规则**：改玩法参数与改人 = `admin`；**动钱与动权限 = `god`**。这条与 txAdmin
"经济权不给低层"一致，也与我们已有的 `custom-director` L4 审批对齐。

### 2.2 破坏性操作：服务端复核 + 二次确认

| 动作 | 确认方式 |
|---|---|
| 吊销/暂停执照 | 第一次执行输出摘要「将暂停 <玩家> 的 <类型> 执照，10 秒内再执行一次确认」，10 秒内重复同一命令才生效 |
| 大额给钱（≥ 阈值） | 同上，摘要必须含**金额与目标当前余额** |
| 踢人 / 封禁 | 必须有理由参数，理由进审计 |

**为什么不能只发通知**：通知是事后单向，既不能阻止误操作，也不构成"同意"；
且会被静音、漏看。确认必须是**要人再做一次动作**。

### 2.3 审计：先落审计，再执行

| 字段 | 内容 |
|---|---|
| 操作者 | 名字 + server id + license 前 8 位 |
| 动作 | 动词 + 对象类型（如「暂停执照」「调整门槛」） |
| 目标 | 玩家名 + id（离线则 citizenid） |
| 明细 | **前 → 后**（金额/门槛/执照状态），不许只写"已修改" |
| 时间 | UTC |

落 `custom-logs`（本地文件 + Discord）。**审计写失败只告警，不阻断业务** ——
但连续失败要能看见（后续接监控）。

### 2.4 面板：从硬编码 10 条 → 生成式清单

| 项 | 决策 |
|---|---|
| 数据源 | `tools/dev/scan_commands.py` 扫全仓（339 条），生成 `admin-commands.md` |
| 游戏内 | `/apanel`、`/amenu` 保留简版（`admin` 权限），末尾指向完整清单 |
| 防腐 | 闸门要求文档与"现扫一遍"逐字一致 |

### 2.5 回执给谁

| 谁 | 通道 | 内容 |
|---|---|---|
| 执行者 | `feed` | 动作 + 目标 + 明细（可截图留证） |
| 目标（在线） | `toast` / `phone` | 只告诉他发生了什么（"管理员恢复了你的事故执照"），不含内部细节 |
| 审计员 | `feed` | 与执行者同一条（后续做"仅审计员可见"频道时再分） |
| 全服 | 仅 `/announce` | 公告是唯一允许广播的管理动作 |


## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收 |
|---|---|---|---|---|
| A-1 ✅(`4b54a3e6`) | 生成式命令清单 + 防腐闸门 | `tools/dev/scan_commands.py`、`docs/client/ux/admin-commands.md` | 低 | 339 条、危险且无判权 0 条 |
| A-2 ✅(`98e5e852`) | `/tccops` 改 `admin`；`/apanel`、`/menu` 上服务端 | custom-admin 的 server 与 client | 低 | 普通玩家用 `/tccops` 被拒 |
| A-3 ✅(`5d091841`) | 特权动作审计（操作者/目标/前→后）+ 执行者回执 | custom-admin 的 server/commands.lua | 低 | `custom-logs` 出现"管理员操作"行 |
| A-4 ✅(`edce23cb`) | 破坏性操作二次确认（执照 4 条 + 大额给钱） | custom-admin 的 server/commands.lua、qb-core 的 commands.lua | 中（要改交互节奏） | 第一次输出摘要，10 秒内重复才生效 |
| A-5 ✅(`edce23cb`) | 目标权限比较：不能对同级/更高级动手 | custom-admin 的 server/commands.lua | 中 | admin 吊销 god 的执照被拒 |

**顺序**：A-4 → A-5（都依赖 A-3 的审计骨架）。**A-1…A-5 全部完成**，§4 验收由 CC 定后入库。


## 4. 验收（步骤）

> CC 定标准（2026-11-11）。身份约定：**P** = 无授权玩家；**A/B** = `qbcore.admin`；**G** = `qbcore.god`。
> 授权方式（二选一）：控制台 `add_principal player.<id> qbcore.admin`，或已有 god 用 `/addpermission <id> admin`。
> **前置**：`admin_autogrant` 必须是 `false`（否则全服自动 admin）。

### V-1 命令清单（A-1）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | 仓库根执行 `python3 tools/dev/scan_commands.py --check` | 「命令清单是最新的」，退出码 0 | 退出码 |
| 2 | 看 `admin-commands.md` | 「共 **339** 条」「危险命令但没有判权：0 条」；`tccops`/`givelicense`/`apanel` 都是 `QBCore: admin` | Grep |
| 3 | `pytest tests/architecture/test_admin_commands_doc.py tests/architecture/test_admin_permissions.py -q` | 全通过 | pytest |

**反例**：手改清单后 `--check` 仍通过；危险命令权限为 `—` 仍通过；`/tccops` 回退 `user` 后仍通过。

### V-2 权限（A-2）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | P 输入 `/tccops 0`、`/apanel`、`/menu` | 全部被拒（控制台 `Access denied`），门槛不变 | 控制台 + 审计无 P 记录 |
| 2 | P 看聊天框 | 不出现「🛠️ 管理员面板 v2」「⚡ 快速菜单」 | 截图 |
| 3 | A 输入 `/tccops`、`/tccops 0`、`/apanel`、`/menu` | 「当前抢劫警察门槛：2」→「门槛已设为 0」；两个面板正文出现 | 截图 |

**反例**：P 执行后门槛变 0；P 看到管理面板；客户端仍有 `RegisterCommand('apanel')`。

### V-3 审计（A-3）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | A 执行 `/givelicense <P> boat` 两次（10 秒内） | 左下 feed「管理员操作 · 授予执照 · <P>」 | 截图 |
| 2 | 等 6 秒，看 `custom-logs` 资源目录下 `logs/system_audit-<日期>.log` | 含 `[管理员操作] 授予执照 | 操作者 <A>(#id) | 目标 <P> | +boat` | Grep |
| 3 | 依次 `/revokelicense <P> driver`、`/suspendlicense <P> driver`、`/reinstatelicense <P> driver`，再 `/tccops 2`、`/tccops 0` | 追加 `-driver` / `!driver` / `~driver`；门槛行出现 `2 → 0` | Grep |

**反例**：审计行缺操作者或前→后；执行者收不到 feed；审计失败导致命令无法执行。

### V-4 二次确认（A-4）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | A 执行 `/givelicense <P> pilot` 一次，等 11 秒 | toast「确认操作 · … · 10 秒内再执行一次」；pilot 仍 unclaimed；无审计 | `/checklicense <P>` |
| 2 | 10 秒内再执行同一条 | pilot 变 held；审计 `+pilot`；P 收到通知 | 同上 |
| 3 | 执行一次 `/givelicense <P> heavy`，等 11 秒后再执行 | 第二次仍只出摘要；heavy 仍 unclaimed | 同上 |

**反例**：首次就生效；10 秒内换类型/换执行者也被当成确认；超时的第二次直接生效。

### V-5 目标权限比较（A-5）

| 步骤 | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | A 执行 `/revokelicense <G> driver` | 拒绝「对方权限不低于你（你 2 / 对方 3）」；无确认、无审计；G 执照不变 | 截图 + `/checklicense <G>` |
| 2 | A 执行 `/revokelicense <B> driver`（B 也是 admin） | 拒绝「你 2 / 对方 2」 | 截图 |
| 3 | G 执行 `/revokelicense <A> driver` 两次 | 成功；审计 `-driver` | 日志 |

**反例**：A 对 G 的任一条执照命令成功；A 对同级 B 成功；被拒时仍弹确认或写审计。

## 5. 已知未决

| # | 未决 | 影响 | 下一步 |
|---|---|---|---|
| 1 | 权限分层只落到 `admin` / `god` 两级 | 「mod 能复活但不能踢人」这类细分还没做 | 需要一张动作→权限的对照表，再逐条改注册 |
| 2 | 审计只覆盖 custom-admin 的 7 个动作 | 改钱（qb-core 的 `/givemoney`）仍无审计 | 下一批：qb-core 的金钱命令接同一个 auditAdmin |
| 3 | 审计只写本地文件 + Discord | 游戏内无法检索历史 | 后续接 MDT 或专门的审计页 |
| 4 | `/menu` 与 `/apanel` 内容有重叠 | 玩家看到两套 | 合并成一套或按权限裁剪 |

## 5. 已知未决

- 命令清单载体（`/help` 从 JSON 生成 vs 手写 md）待定；
- 权限分层（ACE vs QBCore permission vs job）需要统一到一套；
- 高危命令的二次确认机制未设计。
