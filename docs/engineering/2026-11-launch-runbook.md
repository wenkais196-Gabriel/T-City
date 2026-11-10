---
id: launch-runbook-2026-11
type: runbook
status: active
system: meta
owner: hermes
updated: 2026-11-10
review_by: 2027-03-31
---

# 开服 Runbook（T-City Lite）

> 这份文件回答一个问题：**把服务器开门之前、之后、出事时，各要做什么。**
> 检查项由 `tools/dev/launch_check.py` 自动跑，本文只解释"为什么"和"怎么修"。

## 0. 开服前：一条命令

```bash
python3 tools/dev/launch_check.py        # 全跑（repo 半区 + 本机半区）
python3 tools/dev/launch_check.py --ci   # 只跑 repo 半区（CI 里跑这个）
```

`P0 未解决 0 项` 才开门。P1/P2 是"开了也能跑，但要在第一周补"。

## 1. 配置：生产与开发必须分成两份

`server.cfg` 是 gitignored 的（含 license / rcon / DB 口令）。生产那份**不要**从开发那份直接改：

| 项 | 开发 | 生产 | 为什么 |
|---|---|---|---|
| `sv_maxclients` | 8 | 按实际槽位（≥32） | 8 人服开门就是"满员" |
| `set onesync on` | 可省 | **必须显式写** | 32+ 槽位依赖 OneSync；不写会退化成老同步 |
| `sv_hostname` | 含 DEV | 对外名字 | 玩家列表第一眼看到它 |
| `agent_actions_enabled` / `agent_live_enabled` | 1 | **0**（或换新 token + 只给受信网络） | 这是"agent 能替玩家做事"的总开关，开着等于把动作代理暴露给能连上 30130 的人 |
| `agent_*_token` | 明文 dev token | 空 / 新随机值 | 三个 token 都在 `server.cfg` 里，随 cfg 一起泄漏 |
| `mysql_connection_string` | root | 专用账号 | root 一旦被注入就是整库沦陷；专用账号只给 `TCityLite.*` |
| `exec configs/modules/dev.cfg` | 有 | **没有** | 那份会加载 `custom-testing` / `custom-agent-ops` / 调试工具 |

模板：`T-CityLite.base/configs/prod/server.cfg.example`（**无密钥**，只有结构与注释）。

## 2. 数据库账号（一次性）

```sql
CREATE USER 'tcity'@'%' IDENTIFIED BY '<强口令>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES, CREATE TEMPORARY TABLES,
      EXECUTE, TRIGGER ON `TCityLite`.* TO 'tcity'@'%';
FLUSH PRIVILEGES;
```

`CREATE/ALTER/DROP/TRIGGER` 是迁移需要（`migrations/` 里有建表与触发器）；**不要**给 `ALL ON *.*`。

改完 `server.cfg` 后重启，跑一次 `python3 tools/dev/launch_check.py` 确认 `#10` 变绿。

## 3. 备份（开服前必须演练过一次）

```bash
python3 tools/dev/db_backup.py                    # 备份 + 保留 7 份
python3 tools/dev/db_backup.py --restore <file> --to-scratch   # 恢复演练（恢复到 TCityLite_restore_probe）
```

* 备份文件在 `backups/`（gitignored，含真实玩家数据，**永不入库**）；
* 每份备份配一个 `.json` manifest（大小 / sha256 / 表数 / 时间）——"文件在"不等于"能恢复"；
* 恢复演练**只恢复到 `<db>_restore_probe`**，脚本拒绝直接覆盖生产库（要覆盖就手工切库，那是另一个决定）。

排期：每天一次（Windows 任务计划 / cron），保留 7 天；大版本前额外手动存一份并标记文件名。

## 4. 启动与停止

```bash
# 起（cwd 必须是 T-CityLite.base）
cd T-CityLite.base && E:/FXServer/FXServer.exe +exec server.cfg

# 停（走 quit 让玩家落盘）
python3 tools/dev/fivem_console.py "quit" --wait 3
```

起完核对三件事：`info.json` 的资源数、控制台 `SCRIPT ERROR` 计数、`boot_cfg.py --check` 顺序。
`restart <资源>` 会连带停掉依赖它的资源（实测 `restart core-framework` 85 → 54），
用 `tools/dev/restart_sweep.py` 按 `configs/boot.json` 的顺序补回来。

⚠️ **有在线玩家时不要 `restart qb-core`**：实测会让 FiveM 原生层崩（`adhesive.dll+85A8CC`）。
要换 qb-core 只能整服重启。

## 5. 开门后第一小时看什么

| 看什么 | 在哪看 | 正常长什么样 |
|---|---|---|
| 有人能进、能建角色、能出生 | 客户端实测 | 三条都通才算"能玩" |
| `SCRIPT ERROR` | 控制台日志 | 0；有的话先看是不是 `source = 0` 的命令通知路径 |
| 资源数 | `info.json` | 与启动序列一致（现在 82） |
| 玩家钱/物品重启后还在 | 重启一次自己验 | 不同步 = 存档链断了，立刻停服 |
| 日志/审计落盘 | `custom-logs` 目录 | 有当天文件且在增长 |

## 6. 出事时

| 症状 | 先做什么 | 别做什么 |
|---|---|---|
| 全服卡顿 | 看 `server thread hitch warning` 频率；对照 `io_budget.json` 的热循环清单 | 别直接 `restart` 一堆资源 |
| 钱/物品异常 | 停服 → 从最近备份恢复到 `_restore_probe` 比对 → 再决定回滚 | 别在生产库上试 SQL |
| 玩家进不来 | `info.json` 资源数、`sv_maxclients`、txAdmin 是否有踢人规则 | 别反复重启（每次都烧 licence 配额） |
| 崩溃循环 | 保留最后 200 行日志 + `txData/` 不删 | 别 `git clean`、别删 `cache/` |

## 7. 回滚

代码回滚：`git revert` 后重启（配置在 gitignored 的 cfg 里，回滚代码不会回滚配置，两边都要看）。
数据回滚：`db_backup.py --restore <旧备份> --to-scratch` 验证通过后，手工停服 → 切库 → 起重启。

## 8. 现在还没做的（明确写出来，别当成已做）

1. **客户端 19 个 stale-core 点**没验证过（唯一验证手段会崩原生层），开服后第一个小时重点看客户端 F8；
2. **玩法链没有端到端验证**（进服 → 建角色 → 钱/物品/手机/工作/警匪），需要真人客户端跑一遍；
3. `DirtyFlush` 管线未实现（导出已带 `available=false`，调用方据此跳过）；
4. 反作弊：目前只有服务端鉴权与限流，没有独立 AC。
