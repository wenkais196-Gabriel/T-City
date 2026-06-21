# Module 5: 职业与权限系统 (jobs.cfg / police.cfg / medical.cfg / career.cfg / admin.cfg)

> **CFG 文件**: 5 个模块配置 | **资源数**: 8 个

---

## 5.1 jobs.cfg — 基础职业管理

| 资源 | 功能 |
|:---|:---|
| progressbar | 进度条依赖库（被所有职业和交互资源使用） |
| qb-management | 雇员管理系统 — Boss 菜单/雇佣/解雇/职业账户 |
| qb-mechanicjob | 修车工职业 — 修理/改装。车辆状态管理已迁至 custom-vehicles |

### qb-management 功能
- `server/sv_boss.lua` — Boss 操作：雇佣/解雇/升降级/职业账户存取
- `server/sv_gang.lua` — 帮派管理
- `server/sv_org.lua` — 组织管理

---

## 5.2 police.cfg — 警察系统

**资源**: qb-policejob

### T-City 安全加固 (vs 原版)

| 加固 | 位置 |
|:---|:---|
| Impound + onduty 检查 + 审计 | `server/vehicle.lua:42-48` |
| TakeOutImpound + onduty + 10m 距离 + DropPlayer | `server/vehicle.lua` |
| BillPlayer 罚款上限 $50K | `server/main.lua` |
| SetHandcuffStatus 解铐限制 (仅 LEO/EMS) | `server/main.lua` |
| License 命令委托 custom-certificates | `server/commands.lua` |
| /checkid 委托 custom-documents (3.5m 距离) | `server/commands.lua` |
| Department/District 委托 custom-career | `server/commands.lua` |

### 交叉依赖
```
qb-policejob
  ├── custom-career      (SetPlayerDepartment/District)
  ├── custom-certificates (GrantLicense/RevokeLicense/SuspendLicense/ReinstateLicense)
  ├── custom-documents   (verifyPlayer — 证件验证)
  └── custom-vehicles    (Dashboard API — 警笛/喊话器/雷达)
```

---

## 5.3 medical.cfg — 医疗系统

**资源**: hospital_map + qb-ambulancejob

- 死亡/濒死 (`laststand`) → 治疗/包扎/复苏
- 病床/担架
- 与 custom-main 协作：死亡自动复活 fallback + 死亡元数据清理

---

## 5.4 career.cfg — 多标签职业系统

**资源**: custom-career

- 高性能内存缓存型多标签职业标签
- 被 qb-policejob、qb-ambulancejob 等用于 Department/District 管理
- 被 custom-justice 用于律师职业标签

---

## 5.5 admin.cfg — 管理指令

**资源**: custom-admin

- 高安全审计管理指令面板
- Webhook 审计
- 领袖任命/降职撤销

---

## 5.6 安全总览

| 职业资源 | 最大风险 | 缓解 |
|:---|:---|:---|
| qb-policejob | BillPlayer / SeizeCash / JailPlayer | 全部验证 job.type + 距离 + 服务端金额上限 |
| qb-ambulancejob | 治疗/复苏 | 职业检查 |
| qb-management | Boss 雇佣/解雇/账户操作 | 等级检查 |
| custom-admin | 领袖任命/降职 | 审计日志 + Webhook |
| qb-mechanicjob | 车辆改装 | 职业检查 |
