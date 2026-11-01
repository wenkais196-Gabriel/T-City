---
id: engineering-worktree
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-01
review_by: 2027-04-30
---

# 工作树与分支流程

> 2026-11-01 起生效。根 `AGENTS.md` 只放指针，细节在这里。

## 1. 两个 worktree，各司其职

| 目录 | 角色 | 规则 |
|---|---|---|
| `E:/T-City-harness` | **唯一运行树**（FXServer 的 cwd 是它的 `T-CityLite.base`） | 永远从 `origin/master` 切新分支；同时只承载一个进行中的分支 |
| `E:/T-City` | git 元数据 + 归档（detached，tag `archive/main-salvage-20261101`） | **不得在此启服、不得在此改代码** |

历史原因：主树曾长期停在 `chore/windows-workspace-baseline` 上，与 master 差 1611 个文件（全是假 diff），
39 项本地改动既没提交也没人看。2026-11-01 把这些改动保全到 `salvage/main-20261101` 分支后，
主树改为 detached 归档。

## 2. 开工 / 收工

```bash
# 开工（先停服：RCON quit，等 30130 释放）
git -C E:/T-City-harness fetch --prune
git -C E:/T-City-harness switch -c <type>/<scope>-<slug> origin/master

# 收工
git -C E:/T-City-harness push -u origin HEAD
gh pr create --base master

# 合并后
git -C E:/T-City-harness switch master
git -C E:/T-City-harness merge --ff-only origin/master
git -C E:/T-City-harness branch -d <branch>
```

## 3. 规则

- 分支名 `<type>/<scope>-<slug>`（`fix/`、`feat/`、`docs/`、`chore/`），**禁止在 master 上直接改**。
- **切分支/合并前先停服**，避免服务器读到半套文件。
- **绝不在 harness 里 `git clean -fdx`**：`server.cfg`、`alpine/`、`cache/`、`txData/` 都在 ignore 里。
- 实验资源（`zz-*` 之类）先 gitignore 或放 `scratch/`，别让它跟着提交进仓库。
- 合并后立刻删远端与本地分支，别留着等下次"顺手"。

## 4. 主树里那 39 项历史改动（2026-11-01 已结清）

**结论**：39 项已逐条核对完毕，有用的部分已提取进 master，原始快照保留为 tag
`archive/salvage-20261101`（分支 `salvage/main-20261101` 已删除，README 上不再显示"落后 583 个提交"）。

核对方法：那次保全提交改了 48 个文件，按**内容**逐个比对（不是看提交数）：

| 类别 | 数量 | 处置 |
|---|---|---|
| 内容与 master 完全一致 | 4 | 无需处理 |
| master 里更新（agent_tools / AGENTS / ci 等持续演进过） | 30 | 保留 master 版本 |
| master 里根本没有 | 14 | 5 个只是路径迁移（`tests/agent/test_agent_*.py` → 现在的 `tests/tools/`），**已提取 9 个** |

已提取（2026-11-01，PR 一并入库）：

- `docs/standards/doc-lifecycle.md` + `tools/docs_lifecycle.py`（文档生命周期规范与工具，`--check` 实测 0 error）
- `docs/INDEX.md`（用它自己的 `--index` **对 275 份当前文档重新生成**，不是搬旧快照）
- `docs/agent/phone/DESIGN.md`、`docs/agent/police/BLUEPRINT-ITEMS{,-ARCHIVED,-CC}.md`、`docs/analysis/2026-10-31-systems-coverage-survey.md`

**为什么不整体合并那个分支**：`salvage` 相对 master 多出 440 个文件，其中 **401 个是上游残留**
（qb-* 的 `.github/` 模板、旧 `html/assets` 产物）—— 合并会把它们全带回来。

整仓备份：`C:/Users/swkgb/AppData/Local/hermes/cache/backup/T-City-20261101.bundle`（352 MB，`--all`）。

## 5. 分支卫生（2026-11-01 清理）

| 分支 | 处置 | 理由 |
|---|---|---|
| `dev` | **已删除**（远端 + 本地），CI 的 `branches` 列表同步去掉 | 独有提交 0（tip 是 master 的祖先），最后提交 2026-10-26，无任何文档引用 |
| `salvage/main-20261101` | **转 tag 后删除** | 归档快照，见 §4；保留 tag 后历史仍可 `git show archive/salvage-20261101` |

判断"一个分支该不该留"的两条命令：

```bash
git rev-list --count origin/<branch> ^origin/master   # 独有提交数，0 = 纯落后
git log -1 --format='%ci %s' origin/<branch>          # 最后一次真实活动
```
