# T-City Lite — DevOps 工作流

> **目标**：让每一次改动都能在 GitHub 上被追踪：Issue → 分支 → PR → CI → Review → 合并 → 发布。
> **原则**：小步提交、可回滚、自动化检查、文档与代码同仓。

---

## 1. 分支与环境

```
master（稳定，可部署）
  ├─ feat/<scope>     新功能
  ├─ fix/<scope>      缺陷修复
  ├─ chore/<scope>    CI / 依赖 / 文档
  └─ hotfix/<scope>   线上紧急修复（从 tag 切出）
```

- `master` 受保护：禁止直接 push，必须 PR + CI 绿 + 1 位 Review。
- 功能分支生命周期 ≤ 5 天；过期的分支及时关闭。
- 一个 PR 只做一件事；大改动拆成多个可独立回滚的 PR。

### 建议的 GitHub 分支保护

仓库 **Settings → Branches → Add rule**（`master`）：

- [x] Require a pull request before merging
- [x] Require approvals: 1
- [x] Require status checks to pass: `Config & dependency checks`、`Lua syntax (changed files)`
- [x] Require conversation resolution
- [x] Do not allow bypassing the above settings
- [x] Require linear history（配合 Squash merge）

## 2. Issue 生命周期

```
New → Triaged → Ready → In Progress → In Review → Done
```

- **New**：任何 bug / 想法，先开 Issue（安全漏洞走私密渠道）。
- **Triaged**：维护者补 `priority:*`、`area:*`、`phase:*` 标签与里程碑。
- **Ready**：验收标准清晰、依赖已确认，可以开工。
- **In Progress**：关联分支已创建（在 Issue 里回填分支/PR 链接）。
- **In Review**：PR 打开，CI 运行。
- **Done**：PR 合并，Issue 自动关闭（`Closes #N`）。

### 标签体系

| 前缀 | 取值 | 用途 |
|:---|:---|:---|
| `type:` | `bug` `feature` `security` `refactor` `docs` `chore` | 变更类型 |
| `priority:` | `P0` `P1` `P2` `P3` | P0 = 阻断启动/可刷钱/可破坏他人 |
| `area:` | `boot` `quest` `story` `economy` `vehicle` `justice` `phone` `db` `nui` `ci` `docs` | 影响面 |
| `phase:` | `1` `2` `3` | 对应三阶段路线图 |
| `status:` | `blocked` `needs-info` `needs-test` | 流程状态 |

### 里程碑

| 里程碑 | 范围 | 对应报告 |
|:---|:---|:---|
| **Phase 1 — Foundation** | 启动链、DB、持久化、安全、观测底座 | 审查报告 §5 阶段 1 |
| **Phase 2 — Roleplay & Systems** | 任务/剧情/职业/司法/经济闭环、社交漏斗 | §5 阶段 2 |
| **Phase 3 — Agent Director** | Bridge、动作层、规则导演、LLM 导演、NPC 演员 | §5 阶段 3 |

## 3. Project 看板

建议在 GitHub Projects 建一个 Board，列为：

`Backlog → Ready → In Progress → In Review → Done`

自动化规则：

- Issue 打上 `status:ready` → 移入 Ready
- 关联 PR 打开 → 移入 In Review
- PR 合并 / Issue 关闭 → 移入 Done

## 4. CI 流水线

`.github/workflows/ci.yml` 在 push / PR 时运行：

| Job | 内容 | 失败即阻断 |
|:---|:---|:---|
| **Config & dependency checks** | `check_cfgs.py`（ensure 目标存在）、`check_dependencies.py`（依赖图 + 启动顺序）、`check_bus_wiring.py`（注册方是否 include bus.lua） | ✅ |
| **Lua syntax (changed files)** | 对 PR/本次 push 改动的 Lua 执行 `luac5.4 -p`（含反引号的 FiveM 文件自动跳过） | ✅ |
| **Docs links** | 检查 Markdown 相对链接是否存在（当前非阻断） | ⚠️ |

本地等价命令见 [`CONTRIBUTING.md`](../CONTRIBUTING.md) §4。

安装仓库自带的 pre-commit（可选，提交前自动跑离线检测）：

```bash
bash tools/install-hooks.sh
```

> 为什么不做全仓 Lua 解析：FiveM 的 Lua 方言支持反引号 hash 字面量（`` `prop` ``），标准 `luac` 会误报。CI 只检查**本次改动**，并跳过这类文件。

## 5. 发布流程

1. `CHANGELOG.md` 把 `[Unreleased]` 改成版本号 + 日期。
2. 合并到 `master`，CI 绿。
3. 打 tag 并推送：

   ```bash
   git tag -a v1.0.0 -m "v1.0.0"
   git push origin v1.0.0
   ```

4. `release.yml` 自动创建 GitHub Release（自动生成 release notes）。
5. 生产部署前执行审查报告 §7 的启动冒烟清单。

版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)：

- **MAJOR**：数据库/API/事件契约不兼容
- **MINOR**：新增系统/玩法，向后兼容
- **PATCH**：修复、安全加固

## 6. 一次性初始化 GitHub 标签 / 里程碑 / Issue

仓库已提供脚本（需要 `gh` CLI 且已 `gh auth login`）：

```bash
# 1. 安装 gh（一次）
#    macOS: brew install gh
#    Ubuntu: sudo apt install gh
# 2. 登录
gh auth login
# 3. 在仓库根目录执行
bash tools/bootstrap_github.sh
```

脚本会：

- 创建 `type:*` / `priority:*` / `area:*` / `phase:*` 标签
- 创建 Phase 1/2/3 三个里程碑
- 把审查报告里"仍未修复"的高优先级项建成 Issue（已存在则跳过）

## 7. Definition of Done

一个 Issue 算完成，需要同时满足：

- [ ] 验收标准全部满足（可测量）
- [ ] PR 已合并到 `master`
- [ ] CI 绿（配置/依赖/Lua 语法）
- [ ] 有测试或可复现的验证记录（游戏内步骤 / 命令输出）
- [ ] 数据库变更附迁移脚本
- [ ] `CHANGELOG.md` 已更新
- [ ] 相关文档已更新（模块手册 / 审计报告 / API 参考）
- [ ] 安全影响已评估（客户端可伪造？越权？经济影响？）

## 8. 当前阶段追踪

| 阶段 | 状态 | 入口 |
|:---|:---|:---|
| Phase 1 — 基础功能 | 🚧 进行中 | [审查报告 §5](../T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md) |
| Phase 2 — 角色扮演 / 多系统 | ⏳ 待开始 | 同上 |
| Phase 3 — Agent 中枢导演 | ⏳ 设计完成 | [08 — Agent 导演](server-design/08-agent-director.md) |

> 每次阶段评审后更新本表，并在 GitHub Milestone 里关闭对应 Issue。
