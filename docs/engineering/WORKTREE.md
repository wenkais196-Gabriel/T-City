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
| `E:/T-City` | **唯一工作树 + 运行树**（FXServer 的 cwd 是它的 `T-CityLite.base`） | 永远从 `origin/master` 切新分支；同时只承载一个进行中的分支 |
| `E:/archive/T-City-harness-20261101` | 2026-11-01 之前那棵 worktree 的只读归档（含当时未提交的两份草稿与运行日志） | 不得再改、不得再启服 |

**为什么合并成一棵树**：2026-11-01 主仓库的 git 元数据目录（原 `E:/T-City`）在会话中被移除，
`E:/T-City-harness` 立刻变成孤儿 worktree（`.git` 文件指向一个不存在的 `worktrees/T-City-harness`），
所有 git 操作失败、`release_check.py` 只能扫到 0 个文件。当天按 GitHub 远端重新克隆到 `E:/T-City`，
把 harness 里未提交的改动逐文件搬过去并提交成 PR，随后把 harness 整体归档。**双树方案的价值
（一份跑、一份改）不值得它带来的故障模式**：元数据一丢，两棵树就都不可信，而"跑"和"改"本来就能靠停服/切分支解决。

历史原因：主树曾长期停在 `chore/windows-workspace-baseline` 上，与 master 差 1611 个文件（全是假 diff），
39 项本地改动既没提交也没人看。2026-11-01 把这些改动保全到 `salvage/main-20261101` 分支后，
主树改为 detached 归档。

## 2. 开工 / 收工

```bash
# 开工（先停服：RCON quit，等 30130 释放）
git -C E:/T-City fetch --prune
git -C E:/T-City switch -c <type>/<scope>-<slug> origin/master

# 收工
git -C E:/T-City push -u origin HEAD
gh pr create --base master

# 合并后
git -C E:/T-City switch master
git -C E:/T-City merge --ff-only origin/master
git -C E:/T-City branch -d <branch>
```

### 2.1 新克隆到能起服之间

gitignored 的运行时依赖不在仓库里，clone 完直接起服会看到每个资源都报
`@oxmysql/lib/MySQL.lua:94: No such export query in resource oxmysql`：

| 步骤 | 命令 / 说明 |
|---|---|
| 1. 配置 | `cp T-CityLite.base/server.cfg.template T-CityLite.base/server.cfg`，填 license / DB / token |
| 2. 补 oxmysql 依赖 | 从旧树或备份复制 `oxmysql` 的 `node_modules`（13 MB；缺了整库不可用） |
| 3. 起服 | `cd T-CityLite.base && E:/FXServer/FXServer.exe +exec server.cfg`（本机 artifact 在 `E:/FXServer`） |
| 4. 自检 | `curl -s 127.0.0.1:30130/info.json` 应返回 85 个资源；控制台无 `No such export` / `SCRIPT ERROR` |

只改前端才需要 `custom-phone/web` 与 `tcity-dashboard/nui` 的 node_modules（89 MB / 99 MB），起服不需要。

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
