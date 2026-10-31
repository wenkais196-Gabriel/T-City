# 警察模块蓝图 v1（待开发）

> **状态**：设计定稿，**部分实现**。上线前请先读 [RESEARCH-2026-10.md](RESEARCH-2026-10.md)（调研与裁决依据）。
> **实现进度**见 §0.3；逐条核对与差异（含故意不做的项）在
> [`docs/police/architecture/10-backup-v2.md` §3.13](../../police/architecture/10-backup-v2.md)。
> **用途**：给未来的开发会话当施工图 —— 每次只做一个 Phase，按本文的验收标准收尾。
> **纪律**：本文的「决策日志」（§1）不要在实现时重新讨论；要改先改这里，再改代码。

---

## 0. 开工前必读（5 分钟）

### 0.1 已经核实过的仓库事实（别再挖一遍）

| 事实 | 影响 | 证据 |
|---|---|---|
| `custom-justice` 的案卷与刑期**全在内存**（`activeCases` / `inmates`，零 SQL） | 重启即清空 → 案卷必须落库，且由我们接手 | `T-CityLite.base/resources/[custom]/custom-justice/server/main.lua:7,24,64`；（fxmanifest 声明了 oxmysql 但没有任何查询） |
| `justice:server:registerArrest` **全仓 0 调用方** | 司法链是死代码，Phase 1 就是把它接活 | `T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua:10`；跨资源 grep = 0 |
| `callsign` 存在 QBCore metadata，没有表 | 值班/呼号**不要**新建表 | qb-policejob/server/commands.lua:222-226 |
| 驾照状态走 `custom-certificates` 的导出（`GetLicenseStatus`/`GrantLicense`/`SuspendLicense`/`RevokeLicense`/`GetCertificateSerial`），存在 metadata，不是表 | MDT 查执照**只读导出**，不建表 | custom-certificates/server/*.lua:43-155 |
| `plate_flags` 表已存在（`plate`/`isflagged`/`flag_reason`/`flagged_by`/`flagged_at`） | 车辆通缉/BOLO **复用这张表**，不另建 | `T-CityLite.base/tests/fixtures/tcity_schema.sql` |
| qb-policejob 的 MDT = 3 块 HUD 浮层（CCTV / 直升机 ANPR / 指纹屏），241 行 | 平板必须新开应用，不能往里加 | qb-policejob/html/index.html |
| 自研 `custom-crime` 不发任何警情；银行/商店/珠宝/毒品/入室/越狱会发 `police:server:policeAlert` | Phase 2 要把两类来源统一到一个入口 | `T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua`（grep 空）；7 个发件方见调研 §1 |
| police 的 grade 是 0 Recruit / 1 Officer / 2 Sergeant / 3 Lieutenant / 4 Chief（`type='leo'`） | 权限矩阵直接用它，不另建等级 | `T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua` |
| qb-policejob 有一处 legacy `MySQL.Async.insert`（`phone_invoices`） | 顺手清理项，不是阻塞项 | qb-policejob/server/commands.lua:303 |
| `screenshot-basic` 已装（`[standalone]`） | 照片型 bodycam 可行 | 资源目录 |
| 手机前端是 Svelte 5 + Vite，构建产物落 html/；App 目前是硬编码 import，**没有注册表** | Phase 0 必须先做 `PhoneApps` | `T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte:1-21` |
| 基线测试数字（开工前自己跑一遍确认没漂） | 见 §0.2 | — |

### 0.2 基线（每次开新 Phase 前跑）

```bash
cd E:/T-City-harness        # 日常在 worktree 里干活
git status --short && git log --oneline -3
python -m pytest -q T-CityLite.base/tests/architecture T-CityLite.base/tests/unit tests/tools
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua          # 15 suites / 149 checks / 0 failed
lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua
```

> 2026-10-30 实测：Python 侧 **1226 passed / 150 skipped / 714 subtests**。
> 本机 python 在 `C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe`（系统 PATH 里没有 `python3`）。
> 原稿里的 tests/agent、`tools/agent_tools.py` 是老路径，现分别落在 `T-CityLite.base/tests/agent/`。

### 0.3 实现进度（2026-10-30）

| 蓝图章节 | 状态 | 落在哪 |
|---|---|---|
| §6.3 支援单位出生配方（六条） | ✅ 五条落地，`SetPedAsCop` 故意不做（理由见 §6.3 注） | `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua` |
| §6.3 硬约束 #1/#2/#3/#4 | ✅（#3 由 `police_backup_onscene_ttl` 承担） | custom-police/{client,server} |
| §6.3 硬约束 #5（不结案） | ⏸ 等 §3 的 call 卡（Phase 2 调度总线） | — |
| §6.2 L3 反应层 | ✅ 到场/护送/撤离/指挥 + 包围（surround）+ 扩音器喊话（/pa）；只剩「不结案」等 P2 的 call 卡 | `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua` |
| §6.2 L0 无线层 | ✅ 派出/到场/撤离三句 10-code，在岗限定 + 双限流 + 可一键关 | `T-CityLite.base/resources/[custom]/custom-police/server/radio.lua`、`T-CityLite.base/resources/[custom]/custom-police/shared/radio_text.lua` |
| §6.3 出生点（2026-10-30 追加） | ✅ **只走路网**：四档递进 `strict→relaxed→last→closest`，取不到就 `spawn_failed`，不再有偏移兜底 | `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua` |
| §6.2 L2 后勤 | ✅ **验尸官 + 拖车 + 现场化验全部落地**（在岗 + 名额 + 寿命 + 审计；生成复用路网取点；化验走 append-only 两条证据） | `T-CityLite.base/resources/[custom]/custom-police/server/coroner.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/coroner.lua` |
| §6.2 L1 布景 | ✅ 站点守卫 + 巡逻车（客户端布景，站点 120m 内生成/260m 外收）+ `/lockdown` 封锁线（服务端授权、5 分钟自清） | `T-CityLite.base/resources/[custom]/custom-police/client/scenery.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/lockdown.lua` |

| Phase 1 司法链 | 🟡 **代码早已存在，但从未跑过**：`police_cases`/`police_reports`/`police_arrests`/`justice_sentences` 四张表都在，`CreateCase`/`RegisterArrest`/`RecordVerdict` 三个导出也接好了（MDT App 在调），但四张表全是 **0 行** | `T-CityLite.base/resources/[custom]/custom-police/server/p3_cases.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/records.lua`、`custom-justice/server/trial.lua:43` |
| Phase 2 调度总线 | ✅ **完成**（服务器侧本就存在 + 本轮补齐）：坐标脱敏（D5）、通知预算层、车机警情页、7 个来源对账。剩余只是真机逐个触发与车机视觉确认 | `docs/police/plans/2026-10-31-p2-dispatch-audit.md` |
| Phase 3 盘查与文书 | ✅ **完成**（P3-1…4）：玩家靶心六动作、酒测/药检（含 consumables 数据源）、盘查带入逮捕表单、BOLO 发布即推送。遗留：读数尚未作为 evidence 挂案（依赖 P4 的延迟绑定）、多机验收待第二客户端 | `docs/police/plans/2026-10-31-p3-audit.md` |
| Phase 4 证据 | 🟡 表与链在、MDT 有证据页；缺 bodycam、延迟化验、盘查读数绑定 | `docs/agent/police/STATUS-2026-10-31.md` |
| Phase 6 Agent 动作 | ❌ `query_case` / `draft_report` / `issue_warrant` 全仓 0 命中 | 同上 |

**P5 验收状态**（详见 [`ACCEPTANCE-RUN-2026-10-30.md`](ACCEPTANCE-RUN-2026-10-30.md)）：
PASS = 01/02/05/06/08/12；部分 = 03（#4 判据建议改 20s×3）；未完成 = 04（实验 A 只做了本场景）；
阻塞 = 07（等 Phase 2）、03#5；待第二客户端 = 09/10。

---

## 1. 决策日志（不要重新讨论）

| ID | 决策 | 理由 | 反方案（为什么不选） |
|---|---|---|---|
| **D1** | 四层拆分：`custom-dispatch`（发生了什么）/ `custom-police`（记下了什么）/ `qb-policejob`（手上能做什么）/ `custom-justice`（怎么判） | 每个资源只有一个职责，可以独立上线与回滚 | 把 MDT 塞进 qb-policejob → 变成第二个技术栈（jQuery+Vue2 HUD） |
| **D2** | 平板是**独立 Svelte 5 + Vite 应用**，产物落 custom-police/html/ | 与手机同栈，可复用组件与 token；手机保持轻量 | 放进 `custom-phone` → 手机包体与焦点管理会被拖累；放进 qb-policejob/html → 技术栈冲突 |
| **D3** | 案卷的唯一事实源是 `police_cases`（落库），`custom-justice` 改为读写它（保留 `JusticeService` 外壳） | 现在全内存，重启即丢；两套案卷必然漂 | 只给 justice 加 SQL → 两套案卷并存，报表明细对不上 |
| **D4** | 罪名以 `T-CityLite.base/resources/[custom]/custom-justice/config.lua` 的 key 为唯一事实源，不另建罚则表 | 已经写好了 13 项罪名 + 5 种减刑 | 新建 `police_charges` → 立刻双写不同步 |
| **D5** | 精确坐标**永不下发客户端**，只给 `radius` 内的偏移点 | 防 meta/透视；ps-dispatch 已验证的做法 | 直接下发 coords → 开挂玩家比调度还准 |
| **D6** | 证据链 **append-only**，纠错靠新增条目 | 「可改的保管链等于没有保管链」 | UPDATE 覆盖 → 法庭 RP 的争议无从裁决 |
| **D7** | 手机只做随身任务（接警/快查/罚单草稿/推送/状态），不做证据链与长报告 | 单手、走路、易被打断 | 手机塞全量 MDT → 两块屏功能重叠且都难用 |
| **D8** | 值班状态（10-8/10-6/10-7）**不落库**，用服务器内存 + `GlobalState` | 值班状态本来就不该跨重启 | 建 `police_officers` 表 → 重启后幽灵警员 |
| **D9** | 照片型 bodycam（事件触发生图，`screenshot-basic`），不做视频 | 存储/性能代价差一个数量级，审计需求 80% 能被截图覆盖 | Medal / 视频回放 → 依赖桌面客户端或大容量存储 |
| **D10** | AI 支援分层 L0–L3，**L4（独立执法）永久禁止** | AI 只吃无聊的部分（等待、包围、后勤），不碰裁决权 | 全功能 AI 警察 → 挤走玩家警察，且 ped 无法做系统交互 |
| **D11** | 旧事件 `police:server:policeAlert` 保留为 shim，映射进 dispatch | 7 个第三方资源在发它，一次性改完风险高 | 直接 rename → 抢劫脚本静默失效 |
| **D12** | 所有平板写操作走服务端校验 + `custom-logs` 审计；agent 动作走 `agent_tools.json` 唯一事实源 | 与既有 agent 栈规则一致（L3/L4 人审、拒绝留痕） | 客户端直接写 DB → 等于没有权限 |

---

## 2. 架构

```
发案来源                         接警总线                        记录层                    司法
─────────────────────────────    ──────────────────────    ──────────────────────    ──────────────
qb-bankrobbery / storerobbery ┐                             ┌ 平板 NUI (Svelte 5)
qb-jewelery / houserobbery    │   custom-dispatch           │  ├ 人员/车辆查询
qb-drugs / prison-break       ├─►  · calls 表 + 状态机   ──► custom-police              custom-justice
custom-crime（待接）           │   · 单位附着 + roster       │  ├ cases / charges         · 庭审/律师/减刑
custom-vehicles（抢车）        │   · 通知预算 + 合并          │  ├ evidence + chain        · 结案回写 court_status
qb-policejob /911p、手机 911  ┘   · 3D blip + 半径圈          │  └ reports / warrants         │
                                      │                       └─ 手机 App / 车机 App        ▼
                                      └──► 手机接警卡 / 车机终端（同一条 call）            qb-prison
                                                                                          
qb-policejob = 物理动作层（手铐/押送/入狱/车库/ANPR/钉刺带/物件）
custom-director = agent 动作面（L1 只读 / L2 人审写 / L3 审批）
```

### 2.1 职责边界（谁不能做什么）

| 资源 | 拥有 | 明确不碰 |
|---|---|---|
| `custom-dispatch` | call 生命周期、单位附着、roster/值班状态、blip、通知预算 | 案卷、证据、报告、UI 页面（只有推送事件） |
| `custom-police` | 案卷、罪名绑定、证据链、报告、通缉/BOLO、权限矩阵、平板 NUI | 手铐/押送/车辆的物理动作、法庭裁决 |
| `qb-policejob` | 手铐、押送、入狱入口、车库、ANPR、钉刺带、现场物件、qb-target 动词 | 记录与 UI 页面 |
| `custom-justice` | 罪名表、律师、减刑、庭审、刑期 | 案卷存储（改读 `police_cases`） |
| `custom-phone` | 接警卡、快查、罚单草稿、BOLO 推送、状态切换 | 长报告、证据链、权限 |
| `custom-vehicles` | 车机终端（当前 call）、雷达/ANPR HUD | 全量档案、案件管理 |
| `custom-director` | agent 动作与审计 | 实时战斗循环（延迟不可控） |

---

## 3. 事件契约

### 3.1 入站（发案 → dispatch）

```lua
-- 统一入口：任何资源都用这一个，别再发 police:server:policeAlert
TriggerEvent('dispatch:server:create', {
    ref      = 'storerobbery:2431:1719',  -- 幂等键（同 ref 5 分钟内合并，merge_count+1）
    kind     = 'robbery',                 -- robbery|shooting|traffic|panic|drugs|generic
    priority = 1,                          -- 0 危急 / 1 紧急 / 2 常规 / 3 信息
    coords   = vector3(415.2, -981.4, 29.6), -- 只留在服务端
    radius   = 80,                          -- 下发客户端的搜索半径
    text     = '商店抢劫进行中',
    suspect  = { plate = '4ABC123', desc = '两名男性，黑色上衣' },
    source   = 'qb-storerobbery',
})
```

**幂等规则**：同 `ref` 5 分钟内只建一张卡，`merge_count + 1`，并对已附着单位只发"新增第 N 起"提示。

### 3.2 出站（dispatch → 屏幕）

| 事件 | 载荷 | 去向 |
|---|---|---|
| `dispatch:client:newCall` | 脱敏后的 call 卡（x/y/z 换为 `radius` 内偏移点） | 警员客户端 → 手机 App + 车机 App + blip |
| `dispatch:client:updateCall` | `{id, status, units[], merge_count}` | 同上 |
| `dispatch:client:clearCall` | `{id, reason}` | 同上（清 blip） |
| `dispatch:client:panic` | `{callsign, coords}` | 全警（穿过静音） |

### 3.3 跨层调用（dispatch → police → justice）

```lua
-- 结案时（dispatch 不写案卷，只交出 call_id）
TriggerEvent('police:server:caseFromCall', { call_id = 'CALL-...', officer = src })

-- 逮捕登记（qb-policejob 调，真正把司法链接活）
TriggerEvent('justice:server:registerArrest', suspectSrc, { 'robbery', 'evasion' }, officerSrc)
-- 👆 这个事件已存在且带完整校验（警察身份/罪名合法/通知律师），只需增加 case_id 关联

-- 结案回写
TriggerEvent('police:server:courtResult', { case_id = 'CASE-...', verdict = 'guilty', minutes = 180 })
```

### 3.4 兼容 shim（必须保留）

```lua
-- qb-policejob/server/main.lua 里现有的监听改成转译，不再直发客户端
RegisterNetEvent('police:server:policeAlert', function(text)
    TriggerEvent('dispatch:server:create', {
        ref = nil, kind = 'generic', priority = 1, radius = 100,
        coords = <上报方坐标>, text = text, source = 'legacy:polliceAlert',
    })
end)
```

---

## 4. 数据模型

**迁移文件**：migrations/v2.8_police_module.sql（当前最新是 `T-CityLite.base/migrations/v2.7_phone_messages.sql`）。
**硬要求**：幂等（`CREATE TABLE IF NOT EXISTS` + `information_schema` 判断）、同步更新 `T-CityLite.base/tests/fixtures/tcity_schema.sql`、CI 的 DB schema job 必须绿。

```sql
-- 1) 接警卡
CREATE TABLE IF NOT EXISTS police_calls (
  id            VARCHAR(24)  NOT NULL,              -- CALL-YYMMDD-####
  ref           VARCHAR(96)  DEFAULT NULL,          -- 幂等键
  kind          VARCHAR(32)  NOT NULL,
  priority      TINYINT      NOT NULL DEFAULT 2,
  street        VARCHAR(96)  DEFAULT NULL,
  zone          VARCHAR(32)  DEFAULT NULL,
  x DOUBLE DEFAULT NULL, y DOUBLE DEFAULT NULL, z DOUBLE DEFAULT NULL,   -- 仅服务端
  radius        SMALLINT     NOT NULL DEFAULT 80,
  suspect_plate VARCHAR(20)  DEFAULT NULL,
  suspect_cid   VARCHAR(50)  DEFAULT NULL,
  suspect_desc  VARCHAR(255) DEFAULT NULL,
  status        VARCHAR(16)  NOT NULL DEFAULT 'pending',  -- pending|enroute|onscene|cleared
  merge_count   SMALLINT     NOT NULL DEFAULT 1,
  created_by    VARCHAR(50)  DEFAULT NULL,
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  arrival_at    TIMESTAMP    NULL,
  closed_at     TIMESTAMP    NULL,
  closed_reason VARCHAR(32)  DEFAULT NULL,          -- player|ai_handled|timeout
  case_id       VARCHAR(24)  DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_ref (ref),
  KEY idx_status_created (status, created_at),
  KEY idx_zone (zone)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2) 接警单位
CREATE TABLE IF NOT EXISTS police_call_units (
  call_id     VARCHAR(24) NOT NULL,
  citizenid   VARCHAR(50) NOT NULL,
  callsign    VARCHAR(16) DEFAULT NULL,
  status      VARCHAR(16) NOT NULL DEFAULT 'attached', -- attached|enroute|onscene|cleared
  attached_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  cleared_at  TIMESTAMP   NULL,
  PRIMARY KEY (call_id, citizenid),
  KEY idx_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3) 案卷（司法链唯一事实源，D3）
CREATE TABLE IF NOT EXISTS police_cases (
  case_id     VARCHAR(24) NOT NULL,                 -- CASE-YYMMDD-####
  call_id     VARCHAR(24) DEFAULT NULL,
  title       VARCHAR(128) NOT NULL,
  summary     TEXT DEFAULT NULL,
  lead_cid    VARCHAR(50) DEFAULT NULL,
  status      VARCHAR(16) NOT NULL DEFAULT 'open',  -- open|submitted|adjudicated|closed
  court_status VARCHAR(24) DEFAULT NULL,            -- pending|trial|guilty|acquitted
  sentence_minutes INT DEFAULT NULL,
  opened_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  closed_at   TIMESTAMP NULL,
  PRIMARY KEY (case_id),
  KEY idx_lead (lead_cid),
  KEY idx_status (status, opened_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4) 案卷罪名（charge_id 指向 custom-justice 的罪名 key）
CREATE TABLE IF NOT EXISTS police_case_charges (
  id       BIGINT AUTO_INCREMENT PRIMARY KEY,
  case_id  VARCHAR(24) NOT NULL,
  charge_id VARCHAR(32) NOT NULL,
  fine     INT NOT NULL DEFAULT 0,
  minutes  INT NOT NULL DEFAULT 0,
  KEY idx_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 5) 证据
CREATE TABLE IF NOT EXISTS police_evidence (
  evidence_id VARCHAR(24) NOT NULL,                 -- EVD-YYMMDD-####
  case_id     VARCHAR(24) DEFAULT NULL,
  kind        VARCHAR(24) NOT NULL,                 -- casing|blood|fingerprint|gsr|drug|photo|weapon
  payload     JSON DEFAULT NULL,                    -- 化验结果、serial、样本状态
  x DOUBLE DEFAULT NULL, y DOUBLE DEFAULT NULL, z DOUBLE DEFAULT NULL,
  collected_by VARCHAR(50) DEFAULT NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (evidence_id),
  KEY idx_case (case_id, kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 6) 保管链（append-only，D6：任何 UPDATE 都算 bug）
CREATE TABLE IF NOT EXISTS police_evidence_chain (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  evidence_id VARCHAR(24) NOT NULL,
  action VARCHAR(16) NOT NULL,                      -- collect|transfer|test|present
  actor  VARCHAR(50) NOT NULL,
  at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  note   VARCHAR(255) DEFAULT NULL,
  KEY idx_evidence (evidence_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 7) 报告
CREATE TABLE IF NOT EXISTS police_reports (
  report_id   VARCHAR(24) NOT NULL,
  case_id     VARCHAR(24) NOT NULL,
  author      VARCHAR(50) NOT NULL,
  body        MEDIUMTEXT DEFAULT NULL,
  status      VARCHAR(12) NOT NULL DEFAULT 'draft',  -- draft|submitted
  submitted_at TIMESTAMP NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (report_id),
  KEY idx_case (case_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 8) 通缉 / BOLO（车辆部分复用 plate_flags，对人不另建表）
CREATE TABLE IF NOT EXISTS police_warrants (
  id          VARCHAR(24) NOT NULL,                 -- WAR-YYMMDD-####
  wtype       VARCHAR(12) NOT NULL,                 -- warrant|bolo
  target_cid  VARCHAR(50) DEFAULT NULL,
  target_plate VARCHAR(20) DEFAULT NULL,
  reason      VARCHAR(255) NOT NULL,
  case_id     VARCHAR(24) DEFAULT NULL,
  status      VARCHAR(12) NOT NULL DEFAULT 'active',-- active|served|cancelled|expired
  issued_by   VARCHAR(50) NOT NULL,
  issued_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at  TIMESTAMP NULL,
  PRIMARY KEY (id),
  KEY idx_target_cid (target_cid),
  KEY idx_status (status, wtype)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 9) 照片型 bodycam（D9）
CREATE TABLE IF NOT EXISTS police_bodycam (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  citizenid  VARCHAR(50) NOT NULL,
  call_id    VARCHAR(24) DEFAULT NULL,
  case_id    VARCHAR(24) DEFAULT NULL,
  trigger_event VARCHAR(32) NOT NULL,               -- gunshot|damaged|panic|manual
  shots      JSON NOT NULL,                          -- [{url, ts}]
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_case (case_id),
  KEY idx_officer (citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### 4.1 已验证（2026-10-29 实跑，MariaDB 11.8.9）

用本机 `tcity-mariadb` 容器（3307）建临时库跑过，不是纸上推演：

| 验证项 | 结果 |
|---|---|
| DDL 连跑两遍 | **通过**（`CREATE TABLE IF NOT EXISTS` 幂等），产出 9 张表 / 30 个索引 |
| 多行 `ref = NULL` | 不冲突（唯一索引允许多个 NULL）→ 旧来源不带 ref 也能共存 |
| 同 `ref` 第二次普通 INSERT | **报 duplicate key**（不会静默合并）→ 合并必须走下面的 upsert |
| 合并 upsert | `ON DUPLICATE KEY UPDATE merge_count = merge_count + 1` 实测 1 → 2 → 3，`id` 不变 |
| `payload JSON` | `JSON_OBJECT(...)` 可存，`JSON_EXTRACT(payload,'$.serial')` 可查 |
| 证据链多行 | 同一 `evidence_id` 按 `action` 追加，读取按 `id` 升序即时间线 |

所以 dispatch 的合并写法固定为：

```sql
INSERT INTO police_calls (id, ref, kind, priority, radius, merge_count)
VALUES (?, ?, ?, ?, ?, 1)
ON DUPLICATE KEY UPDATE merge_count = merge_count + 1,  -- 幂等键命中 = 同一案再次报警
                        priority       = LEAST(priority, VALUES(priority));
```

**不建的表**（D4/D8）：`police_charges`（用 justice config）、`police_officers`（用 metadata + 内存）、`police_licenses`（用 custom-certificates）。

**复用而不新建**：驾照/证照 → `custom-certificates` 导出；车辆通缉 → `plate_flags`；呼号/值班 → QBCore metadata + 内存 roster；审计 → `custom-logs`。

---

## 5. 状态机

### 5.1 call（唯一写者是 dispatch 服务端）

```
            create                 attach                arrival              close
   [pending] ──────► [pending] ──────► [enroute] ──────► [onscene] ──────► [cleared]
      │                  │                  │                │                  ▲
      │ 同 ref 合并      │ 无人接管 5 分钟   │ 到场判定失败     │ 分派自己离开      │
      └─► merge_count+1  └──────────────────┴────────────────┴──────────────────┘
                                        timeout ──► cleared(closed_reason='timeout')
```

- 到场判定：进入 `radius` 且车速 < 2 m/s 持续 2 秒，**服务端**按上报坐标算，客户端只上报自己的坐标。
- 一个 call 只有 **lead**（第一个 attach 的人）能 `close`；其他人只能 `clear` 自己。
- `closed_reason` 三档：`player`（人类警员结案）/`ai_handled`（AI 到场无人接管）/`timeout`。

### 5.2 case

```
[open] ──submit──► [submitted] ──verdict──► [adjudicated] ──serve──► [closed]
   ▲                    │                                               
   └────reopen（仅 grade≥3，写审计）──────────────────────────────────────┘
```

### 5.3 evidence chain（只增不改）

```
collect ──► transfer ──► test ──► present
   │            │           │          │
   └────────────┴───────────┴──────────┴──► 每条都是新行；时间线 = 按 id 升序读
```

---

## 6. 屏幕规格

### 6.1 四屏分工（D7）

| 屏幕 | 只放 | 明确不放 | 打开时机 |
|---|---|---|---|
| 手机（`custom-phone` App `police`） | 接警卡 + 应答/到场、人车快查、罚单草稿、BOLO 推送、状态码切换（10-8/10-6/10-7） | 长报告、证据链、权限、图片墙 | 随时，走路/单手 |
| 车机（`custom-vehicles` dashboard app `police_terminal`） | 当前 call 终端、测速/ANPR HUD、车辆追踪、行车记录仪入口 | 全量档案、案件管理 | 上车自动 |
| 平板（custom-police/html） | 查询、案件、证据链、报告、通缉、人事/权限、审计、法庭日历 | 实时驾驶操作 | 静止、双手、要键盘 |
| 3D 世界 | blip、地面半径圈、qb-target 提示、动画、语音 | 任何 >2 行文本 | 一直 |

### 6.2 平板信息架构

```
左导航（6 项，`1`–`6` 快捷键）        顶部：全局搜索（cid / 姓名 / 车牌 / 案号）
├ 1 调度   当前 call 列表 + 单位状态    右侧：详情面板（固定三段式）
├ 2 人员   身份 → 执照/通缉/前科 → 最近记录
├ 3 车辆   车主 → 注册/保险 → 牌照标记(plate_flags) → 关联案件
├ 4 案件   列表 → 详情（罪名/证据/报告/时间线）
├ 5 证据   采集物列表 → 保管链时间线（只读，操作靠世界交互）
└ 6 通缉   warrant/bolo 列表 → 发布（grade≥2 或 ≥3，见 §8）
```

**输入**：搜索框默认聚焦；↑/↓ 选、`Enter` 打开、`Esc` 后退、`Ctrl+Enter` 提交报告。
**不用双击**：任何二次确认用「长按 600ms 或再按一次明文提示键」。

### 6.3 通知预算（防刷屏）

| 规则 | 数值 |
|---|---|
| 同屏最多显示 | 3 条 |
| 单条存活 | 5 秒 |
| 同 `kind + zone` 合并窗口 | 90 秒（显示 `×N`） |
| 音效 | 常规 1 声 / 紧急 2 声 / 危急循环但**只在状态变化时** |
| major incident | grade≥2 可宣布；常规呼叫对已附着单位静音，priority 0 / 增援 / 点名呼叫**穿透** |
| 静音 | 只影响提示，不影响入库（查牌日志、案卷照常写） |

### 6.4 视觉

- 一屏一个决策；一屏最多一个主按钮。
- 时间/日期全模块统一（跟系统区域设置）。
- 危急用**重量**表达（粗边框 + 慢脉冲），不是更多红色；`prefers-reduced-motion` 时只留边框。
- 平板配色沿用 `custom-phone` 的 token（--foreground/--muted-foreground/--accent/--border/--card），暗色底。

---

## 7. 阶段计划

> 工时是「一个人、熟悉本仓库」的净开发时间，不含评审与实机联调。每阶段一个 PR。

| Phase | 目标 | 范围 | 依赖 | 工时 | 交付物 |
|---|---|---|---|---|---|
| **P0 地基** | 让「记录」这件事有地方放 | 迁移 v2.8（9 表）+ fixture 同步；`custom-police` 服务端骨架（exports + 权限矩阵 + 审计出口）；平板 Svelte 骨架（人员/车辆查询两个页面）；`PhoneApps` 注册表 | 无 | 3–4 天 | 1 个 PR |
| **P1 司法链** | 把死代码接活，**并落库** | 逮捕 → `registerArrest` → `police_cases`；`custom-justice` 改读写案卷表（保留 `JusticeService` 外壳）；入狱与 `court_status` 回写 | P0 | 2 天 | 1 个 PR |
| **P2 调度总线** | 让「有事做」 | `custom-dispatch`（calls 状态机 + roster + 通知预算 + shim）；手机接警卡 App；车机终端 App；blip 与半径圈；`custom-crime` 接入 | P0 | 7–9 天 | 1–2 个 PR |
| **P3 盘查与文书** | 让「做事有产出」 | qb-target 盘查动词（证件/搜身/酒测/药检/GSR）+ 服务端复验；逮捕登记 UI；报告模板（罪名勾选 → 自动算刑期罚款）；通缉/BOLO 发布与手机推送 | P1,P2 | 8–10 天 | 2 个 PR |
| **P4 证据与 bodycam** | 让「案卷有分量」 | 世界证据绑定 case + append-only 链 + 延迟化验；照片型 bodycam（gunshot/damaged/panic 触发 3 张图）；平板证据视图 | P1,P3 | 6–8 天 | 1–2 个 PR |
| **P5 AI 支援分层** | 填空场（L0–L3） | L0 无线电背景（复用 TTS）；L1 布景（站点守卫/巡逻车/封锁线）；L2 后勤（验尸官/拖车/法医）；L3 反应（到场包围/喊话/仅对 NPC 掩护射击 + 五条硬约束） | P2 | 10–14 天 | 2–3 个 PR |
| **P6 Agent 动作** | 差异化 | `police.query_case`/`query_person`（L1）、`police.draft_report`（L2）、`police.issue_warrant`（L3）、AI 调度员（文本报案 → call 卡草稿） | P2,P3 | 5–7 天 | 1 个 PR |

**建议顺序**：P0 → **P1**（最短路径见效果）→ P2 → P3 → P4 → P6 → P5。
理由：P1 两天就能把「逮捕→庭审→入狱」跑通，是最便宜的验证；P5 依赖 P2 且工时最长，放最后；P6 依赖 P2/P3 但收益是差异化，可以在 P4 之后插入。

### 7.1 P5 前置研究：支援单位为什么会被路人 NPC 撞

这是 P5 开工前必须知道的引擎规则，**不是脚本风格问题**。来源：gtamods 的 `vehicles.meta` 文档，flag 31 / flag 1。

| 规则 | 原文要点 | 对实现的约束 |
|---|---|---|
| `FLAG_LAW_ENFORCEMENT` (31) | 「**If the vehicle's siren is on, oncoming traffic vehicles will stop.**」 | 支援单位**出发阶段必须开警笛**，否则车流不会让行 |
| 同上 | 「Peds that are driving cars with this flag **will not stop** in the event of an accident blocking the road.」 | 警车不会被堵在车流里；这也是它「看似从不被撞」的原因之一 |
| 同上 | 轮子脱落率 −50%，爆胎率 30% → 15% | 被蹭也不容易报废，不要拿它当「AI 让行」的证明 |
| `FLAG_BIG` (1) | 「Increases the amount of space between traffic vehicles… peds will avoid ramming the vehicle during chases.」 | 可选：支援单位优先选带此 flag 的车型（SUV/大车） |

**脚本侧必须同时满足的 6 条**（缺一条就会被打车）：

1. 出生在离现场 **80–150 m** 的路口（`GetNthClosestVehicleNodeWithHeading`），**绝不生成在玩家车道内或视野锥里**；
2. `SetEntityAsMissionEntity(veh, true, true)` + `SetVehicleOnGroundProperly`，防止引擎回收与「落地砸车」；
3. `SetVehicleSiren(veh, true)`——这是触发让行开关的那一下（只想要灯就 `SetVehicleHasMutedSirens`，**是否仍触发让行需实机验证**）；
4. `CreatePedInsideVehicle`（不要先建在车外再 warp，那一瞬间是空车，且会出现「坐车顶」）；
5. `SetPedAsCop(ped, true)` + `SetDriverAbility(ped, 0.9)` + `SetDriverAggressiveness(ped, 0.1)`；
6. 驾驶风格固定 **786603**（`DrivingModeStopForVehicles`）；禁止 0 / 262144 / 无 `StopForVehicles` 的组合。

**验证实验（P5 开工第一步就做，各 60 秒）**：

| 实验 | 变量 | 结论 |
|---|---|---|
| A | 同模型同点，警笛关 / 开 | 关着被撞 ⇒ 让行规则没触发 |
| B | 原版 `police` / addon 包警车（都开笛） | addon 被撞 ⇒ 该包 `vehicles.meta` 缺 flag 31 |
| C | 车道内 20 m / 120 m 外路口生成 | 近距被撞 ⇒ 缺反应距离 |

**新增硬性检查**：本仓库当前没有任何 `vehicles.meta`、也没有 addon 车辆包（用原版 `police`/`ambulance`，flag 自带）。**一旦引入 addon 车辆包，必须 grep 它的 `vehicles.meta` 是否含 `FLAG_LAW_ENFORCEMENT`**，否则警灯形同虚设，且症状静默。

---

## 8. 权限矩阵（grade 来自 `T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua`，`type='leo'`）

| 动作 | Recruit(0) | Officer(1) | Sergeant(2) | Lieutenant(3) | Chief(4) |
|---|---|---|---|---|---|
| 接警 / 应答 / 到场 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 查人车档案 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 开罚单 / 写报告草稿 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 提交报告 / 立案 | — | ✓ | ✓ | ✓ | ✓ |
| 采集证据 / 查保管链 | — | ✓ | ✓ | ✓ | ✓ |
| 发 BOLO | — | — | ✓ | ✓ | ✓ |
| 发通缉令（warrant） | — | — | — | ✓ | ✓ |
| 重开已结案卷 | — | — | — | ✓ | ✓ |
| 宣布 major incident | — | — | ✓ | ✓ | ✓ |
| 查看他人报告的全部审计 | — | — | — | ✓ | ✓ |
| 部门/辖区分配 | — | — | — | ✓ | ✓ |

实现要求：**每个动作服务端复检 grade**（不看客户端有没有按钮），越权写 `agent_denials` 风格的审计行（可复用 `custom-logs:LogSecurity`）。

---

## 9. Agent 层规格

| 工具 | 风险 | 审批 | 幂等 | verify（回读） |
|---|---|---|---|---|
| `police.query_case` | L1 只读 | 否 | `idempotency = 'read'` | 返回条数与 `police_cases` 一致 |
| `police.query_person` | L1 只读 | 否 | `read` | 回读 cid 存在性 |
| `police.draft_report` | L2 | 人审后提交 | `idempotency = 'case_id+author'` | 提交后回读 `police_reports.status` |
| `police.issue_warrant` | L3 | **必须** | `idempotency = 'target+reason_hash'` | 回读 `police_warrants.status` |
| `police.create_call_from_report`（AI 调度员） | L2 | 人审 | `ref` 幂等 | 回读 `police_calls` |

落地要求（照 AGENTS.md §3.2）：改 `tools/agent_tools.json` → python tools/agent_tools.py --write 生成 `T-CityLite.base/docs/agent/TOOLS.md` 与 Lua 镜像 → `--check` 必须 OK → 同步 policy.lua（L3/L4 人审）→ 补 tests/agent/* 契约测试。

---

## 10. 测试计划

| 层 | 测什么 | 放哪 | 何时跑 |
|---|---|---|---|
| DB | 迁移幂等（跑两遍）、fixture 与迁移一致 | tests/unit/ + CI DB schema job | 每个 Phase |
| 服务端单测 | 状态机非法转移、权限矩阵越权、幂等 ref 合并、坐标脱敏 | `T-CityLite.base/tests/unit/` | 每个 PR |
| Lua golden | 新增纯函数（call 优先级计算、罪名→刑期、脱敏坐标、审计格式化） | tests/agent/lua/cases*（runner.lua 自动收） | 每个 PR |
| 客户端 golden | 手机/车机 App 的状态渲染（无游戏、无库） | `T-CityLite.base/tests/agent/lua/runner_client.lua` | 改前端时 |
| Agent 契约 | 工具 schema/风险级/verify 字段齐全、MCP 路由 | tests/agent/ | 加工具时 |
| 注册表一致性 | 34 → N 个工具，三处镜像一致 | python tools/agent_tools.py --check | 每个 PR |
| NUI | 平板/手机/车机构建 | `cd web && npm run build`（产物落 html/） | 改前端时 |
| 实机 | 接警→到场→逮捕→立案→庭审→入狱 全链路 | `tools/agent_smoke.py` 扩展 + 人工 | Phase 收尾 |

**每个 Phase 的 DoD**：上面五项全绿 + 本文对应章节的验收标准逐条勾掉 + 文档更新（`docs/agent/police/`）+ 迁移与 fixture 同 PR。

---

## 11. 风险与回滚

| 风险 | 触发信号 | 缓解 | 回滚 |
|---|---|---|---|
| 接警总线改动打挂抢劫脚本 | 抢案后无 blip | shim 先行（D11），新旧入口并存一个 Phase | 关闭 dispatch 资源，shim 直通旧路径 |
| 案卷从内存迁到 DB 后 justice 行为变化 | 律师通知不到、庭审打不开 | 保留 `JusticeService` 外壳，内部换实现；先做双读校验 | 迁回内存实现（一个 flag） |
| 平板 NUI 拖累 FPS | 打开平板掉帧 | 只在打开时创建 NUI、关闭销毁；图片懒加载 | 降级为只读查询 |
| 通知刷屏 | 警员抱怨 | 预算规则（§6.3）+ 合并计数 | 全局静音开关 |
| 证据链被误改 | 时间线出现空洞 | 表权限只 INSERT（服务端唯一写者）+ 单测 | 从 `police_evidence` 重建 |
| AI 支援单位卡住/误伤 | 玩家投诉 | 五条硬约束 + 10 秒卡住兜底 + 120 秒自动撤退 | 关闭 L3 层，只留 L0–L2 |
| 手机包体变大 | 打开手机变慢 | 警察 App 按需 import（动态 `import()`），不在首屏加载 | 移出手机，只在平板提供 |

---

## 12. 不做清单（写下来免得以后又被提）

| 不做 | 理由 |
|---|---|
| 重写 qb-policejob | 物理动作层是它的强项；重写等于两个月白干（D1） |
| 把 MDT 塞进 qb-policejob/html | jQuery + Vue2 HUD，会变成第二个技术栈（D2） |
| 新建 `police_charges` 罚则表 | 与 `custom-justice` 双写必然漂（D4） |
| 新建 `police_officers` 值班表 | 重启后幽灵警员（D8） |
| 视频 bodycam | 存储/性能差一个数量级（D9） |
| AI 独立执法（破案/逮捕玩家/击杀） | 夺走玩家裁决权，且 ped 无法做系统交互（D10） |
| 多警员实时协同编辑报告（带光标） | 小服一天写不了几份，过度设计 |
| 16×16 频道无线电皮肤、K9 系统（作为 P0/P1） | 收益/成本比低 |
| LLM 进实时战斗循环 | 延迟 0.3–2s 且不确定 |

---

## 13. 开工清单（复制到第一个 PR 的描述里）

```
- [ ] git switch -c feat/police-phase<N>-<scope>（分支生存期 ≤ 5 天，见 docs/DEVOPS.md）
- [ ] 跑 §0.2 基线，数字与本文一致（不一致先停下来查环境）
- [ ] 只做本 Phase 范围内的表/事件/页面，不顺手改别的模块
- [ ] migrations/v2.8_police_module.sql 幂等 + tests/fixtures/tcity_schema.sql 同步
- [ ] 服务端对每个新动作做 grade 复检 + custom-logs 审计
- [ ] 新前端先 npm run build，产物落 html/
- [ ] 加/改 Lua golden 用例与 Python 契约测试
- [ ] 文档：更新本文件对应章节的「已实现」标记 + docs/agent/police/
- [ ] PR 描述写清：为什么、验收标准勾选、回滚方式
```

---

## 14. 与调研文档的对应

| 调研结论（RESEARCH-2026-10.md） | 落在本蓝图的哪 |
|---|---|
| §1 三条致命发现（MDT 是贴图 / 司法链死代码 / 只有 blip） | D1、D3、Phase 1、Phase 2 |
| §2 LSPDFR 灵感裁决（值得/降级/不建议） | Phase 3（盘查/拦停）、Phase 4（证据/bodycam）、Phase 5（AI 分层） |
| §3 FiveM 功能矩阵 | §8 权限矩阵、Phase 6（agent） |
| §4.5 AI 支援分层 L0–L3 | Phase 5 + D10 |
| §5 屏幕分工 / 通知纪律 / 输入 | §6 屏幕规格 |
| §6 优先级 P0/P1/P2 | §7 阶段计划（映射成 Phase 0–6） |
| §7 不建议做 | §12 不做清单 |
