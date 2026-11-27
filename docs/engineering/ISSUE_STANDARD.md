---
id: eng-issue-standard
type: manual
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
---

# Issue 标准（标签 / 标题 / 正文）

> 为什么要有这份：2026-11-27 一天里新建了 6 个 issue，**一个标签都没打** —— 面板上全是白板，
> 按 `area:menu` 过滤找不到菜单片，按 `priority:P1` 排不出先后。而仓里早就有一套标签法
> （#332/#342/#349 都在用），只是没写成规则，于是新 issue 全靠记性。

## 1. 标签（必填三件套 + 可选两件）

**必填**：`type:*` 一个、`priority:*` 一个、`area:*` 至少一个。缺一个就算不合规。

| 组 | 取值 | 含义 / 何时用 |
|---|---|---|
| `type:` | `feature` / `bug` / `refactor` / `security` / `chore` / `docs` / `test` | 一句话：这是新能力、修缺陷、改结构、补安全、动构建、写文档、加验证 |
| `priority:` | `P0` 阻断启动/可刷钱/可破坏他人 ｜ `P1` 功能失效/数据错误 ｜ `P2` 降级/维护风险 | 拿不准时按高一级；`P2` 不是"不重要"，是"不阻塞" |
| `area:` | `boot` `db` `economy` `menu` `phone` `quest` `story` `justice` `vehicle` `agent` `ci` `docs` | 一个 issue 可以打多个（例如手机上的产业入口 = `phone` + `economy`） |
| `phase:` | `1` 基础功能 ｜ `2` 角色扮演/多系统 ｜ `3` Agent 导演 | 阶段计划里的 issue 建议带上，历史归档时靠它筛 |
| `status:` | `blocked`（被前置卡住）／`needs-test`（等真机）／`needs-info` | 只在**当前**为真时打；前置解决后必须摘掉（否则看板永远骗人） |

**不要用**旧标签 `bug` / `enhancement` / `documentation`（GitHub 默认那套）—— 与 `type:*` 重名会造成双重语义。

## 2. 标题

`<type>(<scope>): <一句话>` —— 与 commit 约定同形。

- `type` 用 §1 的同一套词；`scope` 用资源名或模块名（`industry`、`menu`、`phone`、`tools`…）
- 一句话说**做什么**，不写"优化""完善"这类无法验收的词
- 例子：`feat(industry): 数值卡与 28 天周期（#387）`、`fix(tools): 探针就绪判据改走 DB 事实`

## 3. 正文结构（五段，顺序固定）

| 段 | 要求 |
|---|---|
| **背景 / 为什么** | 用**代码事实**说话：文件 + 行号 + 当前值。例："`SeedQuota` 默认 10（config/sales.lua 第 28 行）" |
| **前序核验（第一项任务）** | 本仓硬约定：动手前先确认前置成立，不成立就往前溯。**每个 issue 的任务清单第一条必须是它** |
| **范围** | 明确写"做"与"不做"。不做的要写理由（防止下一轮又提一遍） |
| **验收** | 必须是**可执行的命令**或**可观察的现象**。禁止"应该没问题""大幅提升""全面覆盖" |
| **涉及文件** | 写真实路径，且**必须能解析**（反引号里的相对路径会被 docs 闸门当路径解析） |

## 4. 与计划文档的挂接

- 每一片都要在 `docs/plan/<主题>/` 里有出处（哪个计划的哪一片），issue 里回链到那份文档
- 计划文档里也要写回 issue 号，双向可查

## 5. 关闭时

- 写**证据**：跑过的命令与真实输出、真机现象、或"未验"的显式声明
- 不留"应该没问题"；未验证要单独开 issue 或写进已知差异清单

## 6. 怎么检查

```bash
gh issue list --state open --limit 200 --json number,title,labels,body > /tmp/issues.json
python3 tools/dev/issue_lint.py /tmp/issues.json
```

判据就是 §1–§3：标签三件套、标题格式、有任务清单就必须含"前序核验"。
**不放进 CI**：查 issue 要 token，而仓里的闸门必须离线可跑 —— 这个工具吃的是 `gh` 导出的 JSON。

## 7. 现存的债（2026-11-27 盘点）

| 类别 | 状态 |
|---|---|
| 标签 | 当天新建的 5 个 issue 已补齐；老 issue（#332/#342/#349 等）本来就合规 |
| 旧标签 | #11 仍带 `enhancement`，待合并归一 |
| 标题 | #4/#11/#12/#16/#17 是 `[Phase N] …` 旧格式，历史归档不追改 |
| 前序核验 | #233–#240（agent 控制平面）与 #4/#12/#16/#17 没有这一条；属历史 issue，新 issue 必须带 |
