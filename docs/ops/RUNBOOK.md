# 运维手册（RUNBOOK）— T-City Lite

> 目标：任何人（或任何 agent）在**不读代码**的情况下能启动、判断健康、备份、恢复、排障。
> 所有命令都在仓库根目录执行。P0 基础设施（守护 / 备份 / 自检 / 持久化回归）的实测记录见文末。

---

## 1. 启停与重启

### 1.1 systemd（推荐，装一次之后一直用）

```bash
# 校验单元文件（不需要 root）
python3 tools/ops/install_service.py --check-only

# 安装并启用（需要 root；会先停掉 screen 里的旧进程，见下方注意）
sudo python3 tools/ops/install_service.py

systemctl status tcity      # 是否在跑
systemctl restart tcity     # 重启
systemctl stop tcity        # 停止
journalctl -u tcity -n 50   # 只看单元层面的报错
tail -f /var/log/tcity/console.log   # FXServer 控制台（自检读这个文件）
```

**注意**：安装前先停掉手工/screen 启动的实例，否则 30120 端口会冲突：

```bash
screen -S tcity -X quit; sleep 2; fuser -k 30120/tcp
```

装好之后不要再混用 screen —— 两个入口会各自启动一份服务器。

### 1.2 screen（临时/开发用）

```bash
screen -dmS tcity bash -c 'cd /home/swk/Documents/deepseek-harness/default-workspace/T-City && ./start.sh > /tmp/tcity_console.log 2>&1'
screen -r tcity        # 进控制台（Ctrl-A D 退出但不停止）
```

**给运行中的控制台送命令必须用回车符**：

```bash
screen -S tcity -X stuff $'set tcity_evidence_debug 1\r'
```

用 `\n` 只会把字面量写进输入行，残余字符会拼到下一条命令前面（日志里会出现 `sayset ...` 这种被污染的命令）。

### 1.3 什么情况必须整机重启

改**被依赖的资源**（qb-core、qb-inventory、core-framework、custom-police）必须整机重启。
只 `restart qb-inventory` 会把 12 个依赖它的资源（含 custom-police）一起停掉且不带回来，
表现为手机 MDT 报「服务端处理异常」、`No such export ...`、弹壳不再生成。
叶子资源（custom-phone、custom-ui）可以单独热重启。

---

## 2. 健康自检

```bash
python3 tools/ops/healthcheck.py                          # 默认读 /var/log/tcity/console.log
python3 tools/ops/healthcheck.py --log /tmp/tcity_console.log
python3 tools/ops/healthcheck.py --json /tmp/health.json  # 机器可读
```

退出码 0 = 健康；1 = 有失败项（每项一句人能照着修的话）；2 = 日志/参数不对。

检查项与阈值（都来自实测，改清单要同步改）：

| 项 | 期望 | 失败意味着 |
|---|---|---|
| 启动资源数 | ≥ 84 | 有资源没起来：看日志 `Failed to start` / `Couldn't find resource` |
| SCRIPT ERROR | 0 条 | 先修脚本错误，再谈功能 |
| 启动标记（5 条） | `剧情引擎已启动` / `P0 dispatch layer loaded` / `任务注册器已加载` / `手机任务入口已就绪` / `quests app registered` | 对应系统的服务端代码没跑起来；后两条断了就是「玩家接不到任务」 |
| HTTP | 30120 的 /info.json 返回 JSON | 端口没监听或被防火墙拦 |
| 数据库表 | 74 张 | 迁移没跑全，或连错库 |

`--skip-http` / `--skip-db` 可在离线环境只跑日志解析（CI 与单测就是这么用的）。

---

## 3. 备份与恢复

### 3.1 日常备份（已装 cron，每天 04:00）

```bash
python3 tools/ops/backup_db.py --dry-run    # 看将执行什么，不落盘
python3 tools/ops/backup_db.py              # 立即备份一次
crontab -l | grep backup_db                 # 确认定时任务在
ls -lh ~/backups/tcity/daily                # 产物
```

- 产物：`~/backups/tcity/daily/tcity-YYYY-MM-DD_HHMM.sql.gz`
- 保留：每日 7 天（`--keep-days`），当天文件永不删
- 口令不进命令行：从 `server.cfg` 读连接串，经 `MYSQL_PWD` 传给 `mysqldump`（`ps` 看不到）
- 失败会响：`mysqldump` 非 0 或产出 0 字节都会返回非 0，并删掉半截文件
- 日志：`~/backups/tcity/backup.log`

### 3.2 恢复（唯一可信的验证方式）

```bash
# 从 server.cfg 取连接串再拆出口令（不把 DSN 字面写进文档）
DSN=$(awk -F'"' '/connection_string/{print $2; exit}' T-CityLite.base/server.cfg)
PASS=$(printf '%s' "$DSN" | cut -d: -f3 | cut -d@ -f1)
MYSQL_PWD="$PASS" mysql -u swk -e "CREATE DATABASE TCityLite_restore"
zcat ~/backups/tcity/daily/<file>.sql.gz | MYSQL_PWD="$PASS" mysql -u swk TCityLite_restore
MYSQL_PWD="$PASS" mysql -u swk -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='TCityLite_restore'"   # 期望 74
```

恢复后先别把服务器指过去，用 `--compare` 或直接查表确认内容对，再决定是否切换。

---

## 4. 重启不丢数据的回归

```bash
# 1) 重启前
python3 tools/ops/persistence_check.py --take --out /tmp/persist-before.json
# 2) kill -9 模拟崩溃，再启动（systemctl start tcity 或 screen 方式）
# 3) 重启后
python3 tools/ops/persistence_check.py --compare /tmp/persist-before.json
```

比对范围（schema 见脚本头部注释）：

- `players`：现金、银行、职业/等级、在勤状态、metadata
- 玩家背包：`players.inventory`（**不在 inventories 表**）
- 容器：`inventories(identifier, items)` —— 后备箱 / 公寓 / 组织仓库

退出码 0 = 无差异；1 = 逐条列出差异（每行点名 citizenid 或容器 id）；2 = 取数失败。
行序不同不算差异（DB 返回顺序不保证）。

---

## 4b. 让运维脚本（或 AI 助手）自己管守护进程

无人值守的修复要求"能停、能起、能看状态"，但**不应该给密码**。用一条最小权限的 sudoers
drop-in，把权限限定在 `tcity` 这一个单元和仓库里那个安装脚本上：

```bash
sudo tee /etc/sudoers.d/tcity-ops-systemd >/dev/null <<'EOF'
# T-City 运维：只允许管 tcity 这一个单元，外加仓库里的安装脚本
swk ALL=(root) NOPASSWD: /usr/bin/systemctl start tcity, /usr/bin/systemctl stop tcity, /usr/bin/systemctl restart tcity, /usr/bin/systemctl reset-failed tcity, /usr/bin/systemctl enable tcity, /usr/bin/systemctl disable tcity, /usr/bin/systemctl is-active tcity, /usr/bin/systemctl is-enabled tcity, /usr/bin/systemctl daemon-reload
swk ALL=(root) NOPASSWD: /usr/bin/python3 @REPO@/tools/ops/install_service.py
EOF
sudo chmod 0440 /etc/sudoers.d/tcity-ops-systemd
sudo visudo -c
```

注意三点：

1. **不要用 `systemctl *` 通配**——那等于把 root 交出去（`systemctl` 可以拉起任意单元）。
2. sudoers 按命令行**逐字**匹配：命令里写成 `tcity.service` 就不匹配 `tcity`，统一用 `tcity`。
3. `journalctl -u tcity` 不需要 root（`swk` 在 `adm` 组），日志文件 `/var/log/tcity/console.log` 是
   root 所有但 `644`，读取也不需要 sudo。

验证（应列出上述规则，而不是要求密码）：

```bash
sudo -n -l | grep -A2 tcity
sudo -n systemctl is-active tcity
```

## 5. 排障速查

| 症状 | 先查什么 |
|---|---|
| `Couldn't find resource` / 资源数不到 84 | `grep -c "Started resource" /var/log/tcity/console.log`；看 `configs/modules/*.cfg` 的 ensure 是否指向真实目录 |
| `No such export ... in resource X` | X 被别的资源重启连带停掉了；整机重启 |
| 手机 App 空白 / MDT 报「服务端处理异常」 | `custom-police` / `custom-phone` 是否在跑；`phone_apps.lua` 的 audience 是否放行 |
| 端口占用起不来 | `ss -tlnp \| grep 30120` → `fuser -k 30120/tcp` |
| 控制台出现 `sayset ...` / `gametypegiveitem ...` | screen 输入用 `\r` 而不是 `\n`（见 1.2） |
| 备份文件 0 字节 | 磁盘满或权限；看 `~/backups/tcity/backup.log` |
| 重启后钱/物品没了 | 跑第 4 节回归；先看 `persistence_manager` 的 tick 与 `qb-inventory` 的 SaveInventory 触发点 |
| 服务器突然没了，日志末尾 `-> Quitting: SIGHUP received` | 它是被**终端/screen 会话回收**的，不是自己崩的（随后的 `node::ResetStdio` assert 只是关停噪音）。用 systemd 部署就不会再被会话带走；systemd 之外不要把服务器挂在会被关掉的终端里 |
| 启动即退出，日志 `checking server license key: HTTP 429` | Cfx.re 对同一 license 的启动做了限流。**先把守护停掉**（`sudo systemctl stop tcity`）：`Restart=always` 会在 10 秒内再来一次，把限流续成死锁（实测半小时 323 次）。停掉后等 20–30 分钟再手动起 |
| `systemctl status` 显示 `failed`，原因是 `start-limit-hit` | 单元自带的启动限流触发了（5 次 / 5 分钟）。处理完根因后 `sudo systemctl reset-failed tcity && sudo systemctl start tcity` |

日志位置：

- systemd：`/var/log/tcity/console.log` + `journalctl -u tcity`
- screen：`/tmp/tcity_console.log`（清理 ANSI：`sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//' -i`）

---

## 6. 工具一览

| 工具 | 用途 | 单测 |
|---|---|---|
| `tools/ops/healthcheck.py` | 启动自检（退出码 0/1/2） | `tests/architecture/test_ops_healthcheck.py` |
| `tools/ops/backup_db.py` | 每日备份 + 保留策略 | `tests/architecture/test_ops_backup.py` |
| `tools/ops/persistence_check.py` | 重启前后数据对比 | `tests/architecture/test_ops_persistence.py` |
| `tools/ops/install_service.py` | systemd 单元校验与安装 | `tests/architecture/test_ops_service_unit.py` |

---

## 7. P0 实测记录（2026-10-25）

| 项 | 结果 |
|---|---|
| 自检（运行中） | `OK 资源 84 个 / SCRIPT ERROR 0 条 / 标记 3 项齐全 / 表 74` |
| 崩溃恢复 | `kill -9` 后手工重启，85 秒回到 84 资源 / 0 报错，HTTP 正常 |
| 持久化 | 崩溃重启前后 `persistence_check` 无差异（2 名玩家 / 13 种背包物品 / 2 个容器） |
| 备份 | 0.3 MB gz；导入临时库验证：74 张表、players 2 行、inventories 23 行 |
| 定时任务 | `0 4 * * *` 每日备份，日志 `~/backups/tcity/backup.log` |
| systemd | 单元通过 `systemd-analyze verify` 与 `--check-only`；实际安装需 root 执行一次 |
