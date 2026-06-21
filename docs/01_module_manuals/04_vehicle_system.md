# Module 4: 车辆系统 (vehicles.cfg)

> **CFG 文件**: `configs/modules/vehicles.cfg`
> **资源数**: 7 个
> **关键替代**: custom-vehicles 替代了 qb-vehiclekeys（已删除）和 qb-mechanicjob 的车辆状态管理部分

---

## 4.1 架构

```
qb-fuel (燃油)
  ↓
interact-sound (音效库)
  ↓
custom-vehicles (统一车辆系统)
  ├── key_manager.lua    — O(1) 内存钥匙缓存
  ├── vehicle_state.lua  — 部件退化/里程/氮气
  ├── dashboard_api.lua  — 中控屏 API
  └── compat.lua         — qb-vehiclekeys 兼容桥
  ↓
tcity-dashboard (多模态中控屏 — Vue 3 NUI + 6 类模板)
  ↓
qb-garages (车库系统)
  ↓
qb-vehicleshop + dealer_map (车辆商店)
```

---

## 4.2 custom-vehicles — 统一车辆系统核心

### 钥匙管理器
- 纯内存 `_keys[plate] = { _owner = cid, [cid] = type }` — O(1)
- 4 种钥匙类型：owner / shared / temp / hotwired
- 9 个 exports + Bus 注册
- 登录时批量加载：`SELECT plate FROM player_vehicles WHERE citizenid = ?`

### 车辆状态
⚠️ **同步直写 DB** — 每次变异立即 `MySQL.update`，未使用 DirtyFlush。高频驾驶场景可能造成 DB 压力。

### 中控屏 (Dashboard API)
- 喊话器 (Megaphone) — 职业检查 + 速率限制 + 审计
- 警笛控制 — 职业检查
- 物流签章 — 3-way e-stamp 联动 custom-quest
- 第三方 App 注册 — `RegisterDashboardApp(app)`

> 📄 详见: `../02_script_index/custom-vehicles.md`

---

## 4.3 tcity-dashboard — 多模态中控屏

**路径**: `resources/[system]/tcity-dashboard/`

- Vue 3 NUI 前端
- 6 类车辆模板：跑车/商用/紧急/飞机/直升机/船只
- 警察控制台 — ANPR/雷达/追踪器/CCTV/车牌系统 (v2.1)
- Convar 配置：`vehicle_dashboard_key` (I), `megaphone_voice_range` (50.0)

---

## 4.4 传统 qb-* 资源

| 资源 | 功能 | 注意 |
|:---|:---|:---|
| qb-fuel | 简易燃油系统 | 导出 LegacyFuel，被 qb-garages/qb-policejob/qb-ambulancejob 使用 |
| qb-garages | 车辆存储 + 职业车辆取出 | 依赖 qb-fuel 的 LegacyFuel |
| qb-vehicleshop | 车辆购买 (PDM/Luxury/Boats/Air) | + dealer_map |
| interact-sound | 通用音效库 | 安全带/警报等音效 |

---

## 4.5 安全

| 事件 | 验证 | 风险 |
|:---|:---|:---|
| hotwireAttempt | 3s 冷却 + 5m 距离 + 已有钥匙守卫 | MEDIUM |
| lockpickAttempt | 冷却 + 距离 + 背包锁具检查 + 失败消耗 | MEDIUM |
| AcquireVehicleKeys | 现有车主检查 + 盗窃审计 | HIGH |
| giveKeys | 车主检查 + 目标在线 | LOW |

---

## 4.6 维护要点

1. **interact-sound** 必须在 custom-vehicles 之前加载（安全带音效）
2. **custom-vehicles 的 compat.lua** 替代了 `qb-vehiclekeys` — 旧脚本无需修改即可使用新钥匙系统
3. **vehicle_state 同步写 DB** — 高并发时考虑迁移到 DirtyFlush 批处理
4. **tcity-dashboard 依赖 qb-policejob** — 警察控制台功能需要警察职业已加载
