---
id: security
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-21
review_by: 2027-04-30
---

# Security Policy

## 支持的版本

| 版本 | 支持 |
|:---|:---|
| `master`（最新） | ✅ |
| 已发布 tag（最近 1 个 minor） | ✅ |
| 更早版本 | ❌ 仅建议升级 |

## 报告漏洞

**请不要开公开 Issue。**

请使用 GitHub 的私密渠道：

- [Security Advisories](https://github.com/wenkais196-Gabriel/T-City/security/advisories/new)

报告时尽量包含：

1. 受影响的资源 / 事件 / 文件
2. 复现步骤（客户端能触发的最小路径）
3. 影响：刷钱？越权？删除他人实体？数据泄露？
4. 建议的修复方向（可选）

## 处理流程

| 阶段 | 目标时间 |
|:---|:---|
| 确认收到 | 48 小时内 |
| 定级（P0/P1/P2） | 3 个工作日 |
| 修复 / 缓解 | P0 ≤ 7 天，P1 ≤ 30 天 |
| 公开披露 | 修复发布后，与报告者协商 |

## 安全基线（所有 PR 适用）

- 客户端事件默认不可信：必须校验 `source`、参数类型/范围、距离、冷却。
- 涉及金钱 / 物品 / 职业 / 帮派 / 载具归属的写操作，必须有服务端权威校验。
- 不提交 `server.cfg`、密钥、Webhook、数据库密码。
- 数据库变更使用参数化查询，禁止字符串拼接 SQL。
- 新资源必须声明 `dependencies`，并在 `server.cfg.template` 中按顺序接入。
