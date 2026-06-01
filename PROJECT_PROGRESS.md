# 🌟 T-City Lite 项目总进度看板 (PROJECT_PROGRESS.md)

本文件是 T-City Lite 项目的 **单一数据源 (Single Source of Truth)**，汇总了项目当前的整体状态、路线图、当前阶段任务清单，以及当前代码库中实际处于启用状态的模块与资源。

> [!NOTE]
> **更新协议 (Sync Protocol)**
> 1. **手动部分**：当项目任务（如接口实现、数据库建表等）发生变动时，可以使用 `python manage_progress.py complete "<任务关键字>"` / `start "<任务关键字>"` 快捷命令，或者直接修改本文件中的【当前阶段任务清单】。
> 2. **自动部分**：当资源启用状态或模块 cfg 文件发生变动时，运行根目录下的 `python manage_progress.py sync` 命令，它会自动扫描 `T-CityLite.base\configs\modules\` 目录，并将实际运行的资源同步写入下方的【代码库活动资源清单】中。

---

## 📅 项目最新同步时间
- **最后更新时间**: 2026-05-31 20:47:03
- **当前开发阶段**: `v0.5 犯罪玩法系统` 🚧

---

## 🗺️ 版本路线图与整体进度 (Roadmap)

| 阶段版本 | 阶段名称 | 状态 | 交付日期 / 计划周期 | 说明 | 详细规范文档 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **v0.1** | [精简启动链](./QBCore_Lite_versions/v0.1-lite-startup.md) | ✅ 已完成 | 2026-05-28 | 剔除 `ensure [qb]`，实现最小可运行启动链，建立模块化 cfg。 | [v0.1 Spec](file:///d:/txData/QBCore_Lite_versions/v0.1-lite-startup.md) |
| **v0.2** | [基础 RP 闭环](./QBCore_Lite_versions/v0.2-basic-rp.md) | ✅ 已完成 | 2026-05-29 (修补) | 启用警用、医院、银行、车辆基础功能，完成 wanted wantedlevel 接管与 duty 快捷切换。 | [v0.2 Spec](file:///d:/txData/QBCore_Lite_versions/v0.2-basic-rp.md) |
| **v0.3** | [基础设施层](./QBCore_Lite_versions/v0.3-economy.md) | ✅ 已完成 | 2026-05-31 | 统一经济出口、安全边界、多标签职业 API、服装/帮派/门锁激活、管理员面板及 Discord 审计。 | [v0.3 Spec](file:///d:/txData/QBCore_Lite_versions/v0.3-economy.md) |
| **v0.4** | [自研手机系统](./QBCore_Lite_versions/v0.4-custom-phone.md) | ✅ 已完成 | 2026-05-31 | 独立于 qb-phone，基于 Svelte + Vite 的 Phone-First 自研手机，包含 Job Board 与领袖 App。 | [v0.4 Spec](file:///d:/txData/QBCore_Lite_versions/v0.4-custom-phone.md) |
| **v0.5** | [犯罪玩法系统](./QBCore_Lite_versions/v0.5-crime-gameplay.md) | 🚧 进行中 | 第 4-5 周 | 便利店抢劫、毒品产业链，打通供应链与警方对抗。 | [v0.5 Spec](file:///d:/txData/QBCore_Lite_versions/v0.5-crime-gameplay.md) |
| **v0.6a**| [民间经济职业](./QBCore_Lite_versions/v0.6a-civilian-economy.md) | ⏳ 待开始 | 第 5-7 周 | 矿工、渔民、农民、货运、机修 5 大自研 civilian 职业体系，联动 Job Board 派单。 | [v0.6a Spec](file:///d:/txData/QBCore_Lite_versions/v0.6a-civilian-economy.md) |
| **v0.6b**| [沙盒社会生态](./QBCore_Lite_versions/v0.6-sandbox-sociology.md) | ⏳ 待开始 | 第 7-8 周 | 三线领袖 KPI 系统、催化剂卡牌全局倍率影响、防剧透盲盒百科 (Anti-Meta-Gaming)。 | [v0.6b Spec](file:///d:/txData/QBCore_Lite_versions/v0.6-sandbox-sociology.md) |
| **v1.0** | [Beta 开放公测](./QBCore_Lite_versions/v1.0-beta-launch.md) | ⏳ 待开始 | 第 8 周末 | 全系统联调、压力测试、数据清理及发布清单。 | [v1.0 Spec](file:///d:/txData/QBCore_Lite_versions/v1.0-beta-launch.md) |
| **v1.3** | [硬核原位登录](./QBCore_Lite_versions/v0.7-hardcore-spawn-system.md) | ⏳ 规划中 | 上线后迭代 | 放弃传统出生点选择，实现下线原位登录与出生。 | [v0.7 Spec](file:///d:/txData/QBCore_Lite_versions/v0.7-hardcore-spawn-system.md) |
| **v1.4** | [多语言本土化](./QBCore_Lite_versions/v0.8-localization-adaptation.md) | ⏳ 规划中 | 上线后迭代 | 支持全服国际化多语言自适应切换。 | [v0.8 Spec](file:///d:/txData/QBCore_Lite_versions/v0.8-localization-adaptation.md) |

---

## 🚧 当前阶段任务清单 (v0.5 犯罪玩法系统)

本部分为 `v0.5` 版本的核心任务。随着开发的进行，我们会逐步将 `[ ]` 标记修改为 `[/]` (进行中) 或 `[x]` (已完成)。

### 1. 便利店抢劫 (qb-storerobbery)
- [ ] 确认 `qb-storerobbery` 资源存在于代码库中
- [ ] 配置在线警察数量门槛（建议至少 2 名警察在岗）
- [ ] 抢劫收益结算全部接入 `AddScaledMoney` 统一经济出口
- [ ] 服务端强制进行地点抢劫冷却时间校验（建议 30 分钟）
- [ ] 测试：店面收银抢劫 -> 警报推送至警方 Radio 与 Notification 弹窗 -> 警察 GPS 航点生成与拦截 -> 结算

### 2. 毒品系统 (qb-drugs)
- [ ] 确认 `qb-drugs` 资源存在于代码库中
- [ ] 配置郊区野外隐蔽的原料采集点
- [ ] 配置采集加工配方（v0.6 农民产出的化肥作为核心中间原料，v0.5 暂以替代品联调）
- [ ] 配置中介出售点（Street Dealer）与交易机制
- [ ] 毒品销售结算全部接入 `AddScaledMoney` 统一经济出口
- [ ] 配置脏钱洗钱链路与当铺/洗车行扣率折旧

### 3. 经济与审计联动
- [ ] 犯罪收益受 `economy_wage_multiplier` 全局 Convar 动态倍率缩放
- [ ] 犯罪大额交易/敏感操作直接写入 Discord `#economy-log` 频道

### 4. 服务端安全防刷测试
- [ ] 测试：不满足在线警察数门槛时强行拦截犯罪请求
- [ ] 测试：客户端通过工具伪造交单事件被服务端校验物理距离（<ctrl95> 25m）强行拦截并报送审计
- [ ] 针对高频触发事件引入 Rate Limit 熔断惩罚机制

### 5. 自动化测试体系建设（参考 `docs/automated-testing-plan.md`）
- [x] 自动化测试方案文档完成（`docs/automated-testing-plan.md`）
- [x] Phase 1: 离线检测脚本（`tests/check_cfgs.py`, `check_lua_syntax.py`, `check_db_schema.py`, `run_all.py`）
- [x] Phase 2: 游戏内测试资源框架（`[custom]/custom-testing` + `test_runner.lua`）
- [x] Phase 3: 银行系统测试套件（`01_banking_test.lua`）
- [x] Phase 4: 犯罪/警察/安全/持久化测试套件（`02~05_*_test.lua`）
- [ ] Phase 6: CI 集成 + 测试报告自动生成（待服务器稳定后推进）

---

## 🖥️ 代码库活动资源清单 (Active Resources)

> [!IMPORTANT]
> **以下内容由 `manage_progress.py` 扫描代码库配置文件后自动生成，请勿手动编辑。**
> 每次执行 `python manage_progress.py sync` 都会重写此标记块内的资源列表。

<!-- ACTIVE_RESOURCES_START -->

Active resources detected in codebase (**56** resources across **14** modules):

| Module Cfg | Description | Active Count | Active Resources |
| :--- | :--- | :--- | :--- |
| **admin.cfg** | T-City Lite v0.3 - 管理指令及高安全审计配置文件 | **1** | `custom-admin` |
| **banking.cfg** | T-City Lite v0.2 - banking module | **1** | `qb-banking` |
| **career.cfg** | T-City Lite v0.3 - 职业多标签管理配置文件 | **1** | `custom-career` |
| **core.cfg** | T-City Lite v0.1 - core startup module | **12** | `mapmanager`, `chat`, `spawnmanager`, `sessionmanager`, `basic-gamemode`, `hardcap`, `baseevents`, `oxmysql`, `qb-core`, `qb-loading`, `menuv`, `qb-adminmenu` |
| **crime.cfg** | T-City Lite v0.5 - 犯罪模块统一配置文件 | **5** | `qb-doorlock`, `qb-storerobbery`, `qb-houserobbery`, `qb-drugs`, `qb-pawnshop` |
| **custom.cfg** | Module configuration | **10** | `custom-logs`, `custom-economy`, `custom-security`, `custom-crime`, `custom-main`, `bob74_ipl`, `cartel-gates`, `custom-phone`, `custom-debug`, `custom-testing` |
| **economy.cfg** | T-City Lite v0.3 - 经济平衡配置文件 | **0** | *No active resources* |
| **jobs.cfg** | T-City Lite v0.2 - basic jobs and shared RP dependencies | **3** | `progressbar`, `qb-management`, `qb-mechanicjob` |
| **medical.cfg** | T-City Lite v0.2 - medical module | **2** | `hospital_map`, `qb-ambulancejob` |
| **player.cfg** | T-City Lite v0.1 - player flow startup module | **14** | `PolyZone`, `qb-menu`, `qb-input`, `qb-target`, `qb-interior`, `qb-clothing`, `qb-weathersync`, `qb-apartments`, `qb-spawn`, `qb-multicharacter`, `qb-weapons`, `qb-inventory`, `qb-hud`, `qb-scoreboard` |
| **police.cfg** | T-City Lite v0.2 - police module | **1** | `qb-policejob` |
| **security.cfg** | T-City Lite v0.3 - 安全边界配置文件 | **0** | *No active resources* |
| **vehicles.cfg** | T-City Lite v0.2 - basic vehicle module | **5** | `qb-fuel`, `qb-vehiclekeys`, `qb-garages`, `qb-vehicleshop`, `dealer_map` |
| **voice.cfg** | T-City Lite v0.1 - voice startup module | **1** | `pma-voice` |

<!-- ACTIVE_RESOURCES_END -->

---

## 📝 历史已完成版本详情 (Changelog Summary)

### v0.2 - 基础 RP 闭环
- **日期**: 2026-05-28
- **启用模块**: `jobs`, `banking`, `vehicles`, `police`, `medical`
- **核心优化**:
  - 成功定位并修复了 `pma-voice` 依赖 OneSync 开启的报错问题 (在 `server.cfg` 补上 `set onesync on`)。
  - 针对 Svelte 银行 UI 进行细节修正，关闭了未实现的 Debit Card 订购按钮。
  - 修复了 NUI shared users 列表的 JSON 解析错误，实现了 shared users 的 Lua table 转换。
  - ** wantedlevel 接管系统**：自研 wantedlevel Dispatch 系统，当 Wanted >= 3 时屏蔽 AI 警车并派单给在线玩家警员，并在 Cop HUD 上生成每 8 秒一次的红圈追踪 blip。伴随 25 米范围内平民 NPC 尖叫逃跑、司机制动加速逃离的恐慌逻辑。
  - **duty 一键切换**：新增 `/duty` 聊天命令，允许警员、医生、机修、出租车司机免去跑回原大楼 marker 的烦恼，实时一键上下岗。
- **详见文档**: [v0.2 维护指南](file:///d:/txData/T-CityLite.base/docs/v0.2-maintenance.md) | [wantedlevel 接管技术备忘录](file:///d:/txData/T-CityLite.base/docs/v0.2-wanted-handover-technical-memo.md)

### v0.1 - 精简启动链
- **日期**: 2026-05-28
- **启用模块**: `core`, `player`, `voice`, `custom`
- **核心优化**:
  - 创建了 `T-CityLite.base`，重构 `server.cfg`，彻底废除 `ensure [qb]`，改由模块化 `.cfg` 白名单加载。
  - 实现了 **Spawn Death Fallback** 应急处理，当医疗模块尚未启用时，若玩家出生判定为死亡状态，由 `custom-main` 自动恢复血量并复活，防止进入无限死亡卡死。
  - 补充了 `PolyZone`, `qb-interior`, `qb-clothing`, `qb-weapons` 等作为核心玩家流动的必要前置依赖加载。
- **详见文档**: [v0.1 维护指南](file:///d:/txData/T-CityLite.base/docs/v0.1-maintenance.md)

---

## 🔗 项目核心参考文档链接
- [QBCore Lite 技术讨论记录](file:///d:/txData/QBCore_Lite_技术讨论.md)
- [LITE_CHANGELOG.md](file:///d:/txData/T-CityLite.base/LITE_CHANGELOG.md)
- [v0.2 主测试指南](file:///d:/txData/T-CityLite.base/docs/v0.2-master-test-manual.md)
- [v0.2 数据库性能维护指南](file:///d:/txData/T-CityLite.base/docs/v0.2-database-performance-maintenance-guide.md)
- [v0.3 银行重构技术方案](file:///d:/txData/T-CityLite.base/docs/v0.3-banking-refactor.md)
- [NUI 前端开发标准规范](file:///d:/txData/T-CityLite.base/docs/v0.4-nui-standard.md)
