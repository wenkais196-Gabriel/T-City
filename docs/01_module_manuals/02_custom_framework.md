# Module 2: 自研核心框架 (custom.cfg)

> **CFG 文件**: `configs/modules/custom.cfg`
> **资源数**: 20 个
> **依赖**: core.cfg 和 player.cfg 必须在之前加载

---

## 2.1 架构分层

```
┌─────────────────────────────────────────────┐
│  Layer 3: 应用层                             │
│  custom-phone  custom-quest  custom-career   │
│  custom-certificates  custom-documents       │
│  custom-debug  custom-testing                │
├─────────────────────────────────────────────┤
│  Layer 2: 领域层                             │
│  custom-crime  custom-economy  custom-taxes  │
│  custom-cartel  custom-mining  custom-justice│
│  custom-storage  custom-market               │
├─────────────────────────────────────────────┤
│  Layer 1: 安全与日志层                       │
│  custom-security  custom-logs  custom-main   │
├─────────────────────────────────────────────┤
│  Layer 0: 数据访问层                         │
│  core-framework (Bus + DirtyFlush + 5 Services)│
└─────────────────────────────────────────────┘
```

---

## 2.2 核心服务框架 (core-framework)

**路径**: `resources/[standalone]/core-framework/`

### Bus 全局服务总线
四服务注册 (economy / job / metadata / persistence / security) → 28 个方法。Plugin Contract API 用于第三方模组集成。

### DirtyFlush 脏数据管道
- 15 分钟定时 tick → 只刷 `isDirty = true` 的玩家
- `PlayerDropped` → 同步 `.await` 强制刷盘（保证不掉数据）
- 服务器关机检测 → `txAdmin-stop-type` / `server_shutting_down` Convars → 两次全量刷盘

### Compat 向后兼容桥
- `QBCore.Functions.GetPlayer` → 内存缓存 + 活性检查
- `Player.Functions.AddMoney` → `Bus.EconomyService` 路由 + fallback

> 📄 详见: `../02_script_index/core-framework.md`

---

## 2.3 安全三件套

### custom-security — 安全防火墙
- L1 速率限制器 (per source per action)
- L2 回调劫持 (shop/vehicle spawn)
- L3 事件审计 (money/gang/job change)

### custom-crime — 犯罪校验库
- 商店/房屋/毒品抢劫校验器
- 多层洗钱引擎 (LaunderMoney L1-L4)
- 全 exports，无 RegisterNetEvent（风险转移到调用方）

### custom-main — 中央逻辑入口
- 警察通缉分发系统（GPS 三角定位 8s 脉冲 + 雷达 blip）
- **代码重复**: `server/security.lua` 和 `server/crime.lua` 是 custom-security/custom-crime 的副本

> 📄 详见: `../02_script_index/custom-security-crime-main.md`

---

## 2.4 v0.7 组织系统

| 资源 | 功能 | Bus 集成 |
|:---|:---|:---|
| custom-storage | 通用组织仓库 (job/gang 分容量) | `Bus.StorageService` |
| custom-market | 动态商品市场（供需定价引擎） | `Bus.MarketService` |
| custom-cartel | 帮派毒品产业链 (原料→加工→销售) | Storage + Market + Economy + Security + Job |
| custom-mining | 矿业系统 (采矿→冶炼→市场) | Storage + Market |
| custom-justice | 司法系统 (逮捕→律师→审判→监狱) | Job + Security |

> 📄 详见: `../02_script_index/v07-org-systems.md`

---

## 2.5 custom-quest — 数据驱动任务系统

- 12 种步类型（reach/collect/interact/deliver/combat/placement/...）
- 完整状态机 (Not Started → In Progress → Completed/Failed/Abandoned)
- 8 项安全机制（Nonce 验证、步顺序、限流、距离、冷却、每日限制）
- 4 张数据库表（player_quests/quest_cooldowns/quest_event_log/quest_daily_limits）

> 📄 详见: `../02_script_index/custom-quest.md`

---

## 2.6 其他应用资源

| 资源 | 功能 |
|:---|:---|
| custom-phone | Phone-First 手机系统（银行 + JobBoard） |
| custom-career | 多标签职业系统 |
| custom-certificates | 证照系统（驾驶证/武器证/医疗执照） |
| custom-documents | 统一证件展示与验证 |
| custom-taxes | 经济虹吸（房产税/车辆周期/耐久度） |
| custom-logs | 日志引擎（本地文件 + Discord Webhook） |
| custom-debug | 黑屏诊断与强制修复 |
| custom-testing | 自动化游戏内测试框架 (`/test`) |
| bob74_ipl | IPL 地图加载 |
| cartel-gates | 帮派基地大门工具 |
