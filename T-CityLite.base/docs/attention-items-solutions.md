# 注意项解决方案（2026-10-21）

> 对应 v0.7a 验收后遗留的 5 类注意项。原则：能在 CI 自动化的自动化，必须真人客户端的给固定清单与证据要求。

## 1. 客户端 UI 验收

分三层，不要混在一起：

| 层级 | 手段 | 覆盖 | 状态 |
|------|------|------|------|
| L1 浏览器 NUI 冒烟 | `tests/nui/run_ui_tests.py`（Playwright + Chromium） | DOM 渲染、NUI 消息协议、`fetch` 回调、控制台报错、截图 | ✅ 已接入 CI |
| L2 服务端游戏内套件 | 控制台 `test run all` | 资源加载、Convar、DB、callback 注册、业务校验 | ✅ 225 PASS |
| L3 真人客户端 | 固定验收清单 + 截图/录像 | 游戏内按键、NUI 焦点、3D 交互、真实数据、性能 | ⏳ 需要 Windows FiveM 客户端 |

L1 能自动发现“页面白屏、消息字段改名、关闭回调丢失、前端异常”，但不能替代 L3。
L3 建议固定 6 条脚本：车店购车/分期/试驾、车库取车、中控屏按键、物流接单运输、手机收发消息、双人并发。

## 2. DB pytest（132 个）

- 已提供 `tests/fixtures/tcity_schema.sql`（仅结构，无数据），可导入一次性库。
- CI 新增 MariaDB 10.11 service，导入 fixture 后跑全量 **418 passed**。
- 本地不要把测试指向开发库；用 `TCITY_DB_NAME=<临时库>` 隔离。
- 新增 `migrations/v2.2_schema_reconcile.sql`，幂等补齐 story-engine 唯一约束；执行前先查重复数据。

## 3. 构建产物

- `oxmysql/dist`、`oxmysql/web/build`、`menuv/dist`、`tcity-dashboard/nui/dist` 已用 `git add -f` 跟踪（约 370KB）。
- CI 的 `Verify runtime build artifacts` 校验关键文件存在。
- 更新构建产物后必须再次 `git add -f`，否则不会被普通 `git add` 收集。
- 备选方案：改用 release 附件 + 启动前校验脚本；当前选择入库，减少部署步骤。

## 4. 公网心跳报错

`Server list query returned an error` 只影响公网服务器列表展示，不影响本地联调。
上线前再配置端口转发 / `sv_listingIpOverride` / `sv_listingHostOverride`；开发阶段忽略。

## 5. 8 个手机 SKIP

这些用例需要真实 `source > 0` 的玩家上下文：

- 短期：L3 验收时由真人玩家执行，结果记入验收报告。
- 中期：在 `custom-testing` 里增加“单机模拟玩家”注入（创建临时 QBCore 玩家对象），但会触碰玩家数据，建议独立测试库 + 开关。
- 不建议为了绿而把 SKIP 改成 PASS；SKIP 是准确的环境信号。
