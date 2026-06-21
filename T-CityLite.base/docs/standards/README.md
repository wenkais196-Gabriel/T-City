# 🏛️ T-City Lite 统一开发标准与规范索引 (README.md)

> **文档版本**: v1.1  
> **修订日期**: 2026-06-04  
> **适用版本**: v0.5 - v0.7+  
> **适用角色**: 单人开发者 & 协同 AI Agent  
> **制定宗旨**: 誓死捍卫 **模块化、高性能、安全、可拓展** 四大铁律，规范架构设计与日常运维。

---

## 📁 规范文档结构

为避免单体文档臃肿并减少读取和改写时的上下文压力，本规范划分为以下 6 个独立的指导手册，您可以根据需要分散读取：

| 文档名称 | 核心主题 | 说明 |
| :--- | :--- | :--- |
| **[📜 统一日志规范 (logging_spec.md)](file:///e:/T-City/T-CityLite.base/docs/standards/logging_spec.md)** | 控制台分级与美化日志 | 定义 DEBUG -> FATAL 级别，规避内存与性能开销，严格限制 F8 泄露。 |
| **[📘 技术手册规范 (technical_manual_spec.md)](file:///e:/T-City/T-CityLite.base/docs/standards/technical_manual_spec.md)** | 技术设计与接口映射标准 | 定义组件设计时的 Mermaid 表达、服务导出映射及 Shim 兼容适配写法。 |
| **[🧪 测试手册规范 (testing_manual_spec.md)](file:///e:/T-City/T-CityLite.base/docs/standards/testing_manual_spec.md)** | 两层自检与 NUI Mock | 规范 Python 静态扫描、Lua 断言套件，以及 Svelte 开发中的浏览器仿真。 |
| **[🔧 维护手册规范 (maintenance_manual_spec.md)](file:///e:/T-City/T-CityLite.base/docs/standards/maintenance_manual_spec.md)** | 日常维护与灾难备份 | 规范版本发布变更、Convar 清单、诊断指令、以及断线崩溃数据自愈。 |
| **[📦 脚本模板模板 (script_templates.md)](file:///e:/T-City/T-CityLite.base/docs/standards/script_templates.md)** | 双端最小化基础骨架代码 | 提供内置安全测距、流控和统一 Logger 依赖的 sv/cl Lua 标准模板。 |
| **[🚀 开发与维护工作流 (dev_workflow.md)](file:///e:/T-City/T-CityLite.base/docs/standards/dev_workflow.md)** | 人机协同闭环生命周期 | 针对单人开发者的“规划-开发-联调-测试-文档-发布”完整闭环流程。 |

---

## 🧭 系统物理边界划分

T-City Lite 采用**微服务解耦 + 服务总线**的设计模式，所有资源开发必须遵守以下五层物理边界：

```
┌────────────────────────────────────────────────────────┐
│                      1. 客户端表现层                   │
│      - 五M 客户端 Lua 脚本负责接收用户按键、绘制 3D Blip  │
│      - Svelte NUI 负责前端交互，严禁在 UI 线程中写高频 Loop   │
└──────────────────────────┬─────────────────────────────┘
                           │ (仅允许 TriggerServerEvent / fetchNui)
                           ▼
┌────────────────────────────────────────────────────────┐
│                 2. 安全与接口过滤层                    │
│      - 拦截非法请求。利用 `CheckRateLimit` 进行限流熔断  │
│      - 调用 `ValidateSource` / 物理坐标比对，拒绝跨地图发包   │
└──────────────────────────┬─────────────────────────────┘
                           │ (Service Bus 内部方法路由)
                           ▼
┌────────────────────────────────────────────────────────┐
│                   3. 核心微服务总线层                  │
│      - `core-framework` 动态挂载各 Service exports       │
│      - 业务脚本不允许跨资源直调 exports，必须通过 Bus 转发    │
└──────────────────────────┬─────────────────────────────┘
                           │ (Hot/Warm 缓存操作，标记 DirtyBit)
                           ▼
┌────────────────────────────────────────────────────────┐
│                 4. 缓存与数据隔离层                    │
│      - 状态数据常驻 Hot 缓存，5秒 TTL 自动过期            │
│      - 脏数据通过 `DirtyFlush` 定时聚合异步存盘          │
│      - 支持 money / metadata / job / gang 四种数据类型标记  │
└──────────────────────────┬─────────────────────────────┘
                           │ (MySQL.query.await / I/O 级联降级)
                           ▼
┌────────────────────────────────────────────────────────┐
│                 5. 外部数据持久化层                    │
│      - MariaDB 数据库（全部走参数化查询，建好索引）        │
│      - Webhook 审计系统（非阻塞 PerformHttpRequest 发送）  │
└────────────────────────────────────────────────────────┘
```

---

## 🛡️ 四大原则执行准则

### 1. 模块化 (Modularity)
> [!IMPORTANT]
> - 坚决摒弃 `ensure [qb]` 等粗暴做法。新增资源必须在 `configs/modules/` 下的对应 `.cfg` 中进行白名单注册。
> - 任何涉及跨资源操作的功能，必须通过 `core-framework` 的 `bus.lua` 暴露。

### 2. 高性能 (High Performance)
> [!TIP]
> - 严禁在 Tick 循环中编写任何未进行等待（`Wait(0)`）的复杂空间计算，能用平方距离比较（`dx*dx + dy*dy + dz*dz`）的决不用 `GetDistanceBetweenCoords` (开方开销大)。
> - 严禁在非必要时实时写盘，必须将数据移交 `DirtyFlush` 异步缓冲管道。
> - **数据库查询必须走异步接口**：所有 `MySQL.query.await` 在事件回调中必须替换为 `MySQL.Async.fetchAll` 回调模式。多查询场景使用并行计数器模式（见 `script_templates.md` 1.2 节）。

### 3. 安全 (Security)
> [!WARNING]
> - 牢记：**客户端发送的任何数据（包括 amount, price, item, citizenid）都是可篡改的恶意数据**。
> - 敏感事件（加钱、加物、职业变更）第一行必须校验 `source` 有效性，第二行必须校验交互物理距离。
> - **所有敏感事件必须走五层校验链**：Source 权威 → 类型/数值校验 → 权限/职业校验 → 物理距离校验 → 限流冷却（详见 `script_templates.md` §1.1）。
> - **数据脱敏强制标准**：citizenid 统一用 `sub(1,4).."..."..sub(-4)` 掩码；禁止 `print()` 完整 Steam/License 标识符（详见 `logging_spec.md` §3.4-3.6）。

### 4. 可拓展 (Extensibility)
> [!NOTE]
> - 引入新资源时，需在 `compat.lua` 或相关 `shim` 中为老代码提供 Legacy Wrapper。确保历史脚本可以零修改运行，同时享受新架构的安全与性能红利。
