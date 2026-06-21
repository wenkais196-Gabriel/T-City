# custom-phone — 高性能 Phone-First 手机系统

> **路径**: `resources/[custom]/custom-phone/` | **状态**: ✅ ENABLED | **CFG 模块**: custom.cfg
> **依赖**: qb-core, oxmysql | **被依赖**: — (独立)

---

## 文件清单

| 文件 | 角色 |
|:---|:---|
| `fxmanifest.lua` | 资源清单 |
| `server/main.lua` | 服务端入口 |
| `server/banking.lua` | 手机银行功能 |
| `server/jobboard.lua` | 职业公告板 |
| (客户端 NUI) | Vue/React 手机界面 |

---

## 核心功能

- **Phone-First 设计**: 手机作为主要交互入口
- **银行集成**: 通过手机管理账户余额与转账
- **职业公告板**: JobBoard 任务检索与接取
- **通知系统**: 推送/短信通知

---

## 依赖关系

- `qb-core` — 玩家数据
- `oxmysql` — 直接数据库读取（独立于 core-framework）
- ⚠️ **不走 Bus**: custom-phone 直接调用 `oxmysql` 和 `qb-core` exports，未通过 core-framework 的 Bus 或 EconomyService — 存在两条数据路径
