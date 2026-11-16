---
id: engineering-templates-plan
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-16
review_by: 2027-04-30
---

# 计划：<主题>

> 阶段 P。产物放 `docs/<area>/plans/<slug>.md`（文件名不带日期：日期只给 audit/research，
> 见 `standards/doc-lifecycle.md` §3 与 `engineering/TREE.md` §4）。L1/L2 改动可以只写进 commit message，
> 但**验收标准与回滚方式**不能省。

## 1. 范围

- 要做：
- **明确不做**（防止膨胀）：

## 2. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | | `<命令>` → 期望输出 |
| 2 | | |

标准必须是命令或可观察状态，不能是"功能正常"。

## 3. 切片（每片独立可运行）

| # | 切片 | 影响文件 | 验证 |
|---|---|---|---|
| S1 | | | |
| S2 | | | |

需要机器可读进度时，在 frontmatter 加 `plan_status: 1`，并在正文任意位置放一段
`plan-status` 块（每行 4 列；ID 必须与上表首列完全一致，依赖/阻塞/拍板留在正文）：

    ```plan-status
    S1 | todo | - | -
    S2 | todo | - | -
    ```

三档语义：**未登记**＝没有 `plan_status: 1` 或没有块；**未取证**＝`done` 但 `ev`
不可复核（`-` 与 PR 区间都不算证据）；**未开始**＝显式 `todo`。`ev` 只接受单个
`#PR` 或仓内存在的相对路径；看板由 `python tools/docs_lifecycle.py --board` 生成。

## 4. 架构对照

- 涉及平面：P0 / P1 / P2 / P3 / P4（`ARCHITECTURE.md`）
- 跨平面契约变化：事件名 / 字段 / 错误码（无则写"无"）
- 宪法条款对照（哪几条相关，如何满足）：

## 5. 回滚方式

- 代码：`git revert <sha>` / 开关 convar / 保留旧分支
- 数据：迁移是否可逆？不可逆的话备份与回滚脚本在哪
- 运行时：需要重启哪些资源

## 6. 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| | | | |

## 7. 测试计划

- 新增/修改的测试文件：
- 反向校验（错误形状 → 必须红）：
- 真机验证（需要玩家/控制台）：
