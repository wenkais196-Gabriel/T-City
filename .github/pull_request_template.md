## 级别与阶段（见 `AGENTS.md §3`）

- [ ] **L1 微改**（注释/文案/单行修复）—— 只跑相关测试
- [ ] **L2 常规**（一个函数/回调/页面）—— 计划在本描述里，测试必带
- [ ] **L3 结构**（跨文件/跨平面/新资源·事件·表）—— 已产出 `research.md` / `plan.md` / `verification.md`
- [ ] **L4 架构**（鉴权/表结构/协议/依赖方向）—— 上面全部 + 宪法对照 + 人审

阶段产物路径（L3/L4 填）：

- 调研：
- 计划：
- 验证（贴测试输出原文）：

## 变更说明

<!-- 这个 PR 做了什么？为什么需要？关联的 Issue：Closes #123 -->

- Closes #

## 变更类型

- [ ] 🐛 修复（bug fix）
- [ ] ✨ 新功能（feature）
- [ ] 🔒 安全修复（security）
- [ ] ♻️ 重构（refactor）
- [ ] 📝 文档（docs）
- [ ] 🔧 构建 / CI（chore / ci）

## 阶段

- [ ] Phase 1 — 基础功能（启动链 / 数据 / 安全 / 持久化）
- [ ] Phase 2 — 角色扮演 / 多系统
- [ ] Phase 3 — Agent 中枢导演

## 影响范围

<!-- 涉及哪些资源 / 模块 / 表 / 事件？ -->

- 资源：
- 数据库：
- 客户端事件 / NUI：
- 配置项 / Convar：

## 测试与验证

<!-- 贴命令输出或截图；没有跑的部分请明确说明 -->

- [ ] `cd T-CityLite.base && python3 tests/check_cfgs.py`
- [ ] `cd T-CityLite.base && python3 tests/check_dependencies.py`
- [ ] 修改的 Lua 文件通过 `luac5.4 -p`
- [ ] 已在 FXServer 实机启动（版本 / artifact：）
- [ ] 已在游戏内复现 / 回归

验证步骤：

1.
2.

## 安全与兼容

- [ ] 没有提交 `server.cfg`、密钥、Webhook、数据库密码
- [ ] 没有新增客户端可越权触发的写操作
- [ ] 数据库变更已提供 `migrations/*.sql`，且可重复执行
- [ ] 向后兼容：旧资源 / 旧事件签名是否仍可用？

## Checklist

- [ ] 已跑 `python3 tools/dev/release_check.py`（凭据 + 到期债务 + CHANGELOG）
- [ ] 已更新 `CHANGELOG.md`（Unreleased）
- [ ] 已更新相关文档（模块手册 / 审计报告 / README）
- [ ] 没有无关的格式化 / 重排噪音
- [ ] 如果改动了启动顺序，已运行 `check_dependencies.py`
