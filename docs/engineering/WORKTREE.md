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

## 4. 主树里那 39 项历史改动

已保全在 `salvage/main-20261101`（远端也有一份）。其中 6 个文件 master 里没有 ——
mcp 诊断资源 zz-mcp-diag、docs 下的 INDEX 与 standards、2026-10-31 的系统覆盖调研、
客户端 harness 测试、文档生命周期工具。要用的话单独挑出来走 PR，不要整体合并那个分支。

整仓备份：`C:/Users/swkgb/AppData/Local/hermes/cache/backup/T-City-20261101.bundle`（352 MB，`--all`）。
