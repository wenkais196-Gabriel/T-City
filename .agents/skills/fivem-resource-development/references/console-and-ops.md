# 控制台、启动链与清单语义（FXServer 运维面）

从 shell 驱动本机服务器、资源清单变更何时生效、以及为什么 RCON 走不通。这些是"验证"
和"部署"共用的底座；正文只留结论，细节在这里。

## 驱动本机服务器

```bash
screen -dmS fivem bash -c 'cd <server-dir> && ./start.sh'      # start.sh may `exec`
scripts/fxserver_console.py "status"                            # send + read back the reply
scripts/fxserver_console.py -w 8 "restart custom-phone"
scripts/fxserver_console.py --page                              # current console page
```

scripts 目录下的 fxserver_console.py (env `FXSERVER_SCREEN`, `FXSERVER_ENV_FILE`) wraps the three raw
calls — `stuff $'cmd\r'`, sleep, `hardcopy`, strip ANSI, return only the lines after the echoed
command:

```bash
screen -S fivem -p 0 -X stuff $'restart custom-phone\r'         # submit needs the \r
screen -S fivem -X hardcopy /tmp/console.txt                   # visible page only
```

- If `start.sh` ends in `exec`, a background process manager kills it on return — start it
  detached under `screen`.
- `stuff "restart x\n"` leaves the command typed but unsubmitted; send `$'restart x\r'`.
- **The echo is not evidence, in either direction — verify by effect.** The console mixes
  concurrent stdout into the input line, so a command that worked can echo as `vector2version`
  (or `randomitemsrestart qb-hud`) while executing correctly, and a command that did nothing can
  look clean. Treat the echo as decoration and confirm the *effect* instead: `restart <res>` must
  print `Stopping resource` **and** `Started resource`; after any restart re-check that the resource
  is actually running, because a bad line can leave it silently stopped (`Can't restart a stopped
  resource`).
- **The input line keeps residue, and nothing you send clears it.** DEL (`\177`, even ×200), Ctrl+U
  and a bare CR all failed; the residue then joins the next command. The only reliable move is to
  send one throwaway CR first — the console swallows whatever was pending as its own (unknown)
  line — and then send the real command. **That is not enough on its own**: residue can arrive
  *after* the CR (async stdout lands on the input line mid-injection) and join your command. Seen
  twice: `restart custom-director` → `randomitemsrestart custom-director`, and
  `restart custom-agent-client` → `rateLimiter_arrayUpdate_burstrestart custom-agent-client`, both
  leaving the resource **silently stopped**. So after any restart/stop confirm via
  `curl -s localhost:30120/info.json` (is it in `resources`?), never via the echo; and if a
  resource is already missing, do not rescue it command by command — restart the whole server
  (`screen -S <s> -X quit` → `fuser -k 30120/tcp` → start again). When a result must be
  trustworthy, skip the console entirely: put a start-time probe in the resource that writes the
  outcome with `SaveResourceFile` (see `verification.md`).
- **`TriggerClientEvent(..., source = 0, ...)` from a console call throws `native ...: Argument at
  index 1 was null`.** qb-core's own command wrapper does this for `missing_args` / permission
  failures, so an error naming qb-core 的 server/commands.lua right after a console command is
  usually the framework notifying a non-existent player — fix your handler's nil guard, but do not
  chase the framework path as part of that fix.
- `hardcopy` captures the current screen, not scrollback — grep it right after the action you
  care about. `-X logfile` / `-X log on` applied to an already-created session can capture
  nothing (and a manual `log off` may not resume); treat the log file as a bonus, not the plan.
- **Probe a command channel before building on it.** A 200 from HTTP 的 info.json on the game TCP port
  proves only that an HTTP listener is there; send one real protocol packet
  (`--probe-rcon HOST PORT PASS`) and see whether it answers or closes. If it closes, drive the
  console through `screen` as above instead of writing an RCON client.
- **Console commands collide with the framework's chat commands.** A resource that calls
  `QBCore.Commands.Add('status', …)` shadows the console `status`, and handlers written for
  players index `GetPlayer(source)` unguarded — running it from the console executes the chat
  handler with `source = 0` and throws. When a console command errors in an unrelated resource,
  that is the cause; pick a different command, and nil-guard `source == 0` in the handler.
- Keep server command channels' credentials out of chat: have the user put the value in a
  `chmod 600` env file (read it with `getpass` so special characters survive) or grant a scoped
  `/etc/sudoers.d` NOPASSWD rule instead of storing a password at all. Adding the `source` line to
  `~/.bashrc` does **not** make those variables visible to agent tool calls (they run under
  non-interactive bash, and Ubuntu's `.profile` returns early when not interactive) — have each
  wrapper script read its own env file, and `source` it explicitly in ad-hoc commands. Verify with
  `bash -ic 'echo $VAR'` (works) vs a plain tool call (empty) before blaming the file.
- **"Configure passwordless sudo" is a hand-off, not a task you can do.** `sudo -n true` tells you
  in one call whether it is already in place; if it is not, never ask for the password in chat and
  never write it to a file. Emit one scoped line for the user to paste, then verify with
  `sudo -n <cmd>`:
  ```bash
  sudo bash -c 'printf "# agent ops: ufw only\n%s ALL=(root) NOPASSWD: /usr/sbin/ufw\n" "$USER" \
      > /etc/sudoers.d/<project>-ops && chmod 0440 /etc/sudoers.d/<project>-ops \
      && visudo -c -f /etc/sudoers.d/<project>-ops'
  ```
  Scope it to the binaries the work actually needs (`/usr/sbin/ufw`, a specific `systemctl` unit) —
  an `ALL=(ALL) NOPASSWD: ALL` line is the whole machine for the sake of one firewall rule. While
  waiting for the user, keep working on the parts that need no privilege instead of idling.

## 重启“被依赖的资源”会连带停掉依赖者，而且不会把它们带回来

`restart qb-inventory` 看着只是一条命令，实际发生的是：FiveM 先停下**依赖它的每一个资源**，
再只重启它自己。实测一次 `restart qb-inventory` 停掉了 12 个资源（custom-cartel、
custom-justice、tcity-dashboard、custom-police、qb-ambulancejob、qb-cityhall、
custom-certificates、custom-mining、custom-market、custom-storage、qb-management、
qb-mechanicjob），它们**再也没自己起来**——于是：

- `custom-police` 的导出全部消失 → 手机 MDT 切上下班报
  `No such export SetUnitStatusForSource in resource custom-police`，界面显示“服务端处理异常”；
- `custom-police` 的服务端事件也没了 → 开枪不再产生弹壳数据（客户端一切正常，只是服务端不接）。

两条规矩：

1. 改的是被依赖的资源（qb-core / qb-inventory / core-framework / custom-police）→ **整机重启**，
   不要热重启；热重启只适用于叶子资源（custom-phone、custom-ui 这类没人依赖的）。
2. 如果已经热重启了，先 `grep -c "Stopping resource"` 看那次操作停了多少，再逐个 `ensure`/整机重启，
   不要假设“只动了一个资源”。

## 运维工具化之后的三条硬经验（P0 落地时踩到的）

1. **systemd 单元文件必须是模板，不能写死本机绝对路径**。第一次把 `tcity.service` 推上去 CI 就红了：
   校验器在 runner 上找不到开发机路径下的 `start.sh`。做法是文件里用 `@REPO@` 占位，安装时
   由安装脚本渲染；校验时先渲染再判断，这样同一份文件在任何检出路径下结论一致。
2. **`systemd-analyze verify` 不检查 ExecStart 的可执行文件是否存在**。实测指向
   `/nope/not-a-real-binary` 仍然返回 0（它只做语法/依赖检查）。所以"脚本路径存在吗"必须自己校验，
   否则会得到一个"验证通过但根本起不来"的单元。
3. **玩家背包不在 `inventories` 表**。qb-inventory 把玩家背包存进 `players.inventory`（JSON）：
   `inventories(identifier, items)` 装的是后备箱/公寓/组织仓库，键是 `glovebox-XXX`、`apartment…`、
   `<job>_stash` 之类，**不是 citizenid**。做数据一致性检查时按直觉写 `SELECT ... FROM inventories
   WHERE identifier = <citizenid>` 会得到"什么都没丢"的假绿。

配套工具与手册：`tools/ops/healthcheck.py`（启动自检）、`tools/ops/backup_db.py`（每日备份+恢复验证）、
`tools/ops/persistence_check.py`（重启前后快照对比）、`tools/ops/install_service.py`（单元校验与安装），
说明写在 `docs/ops/RUNBOOK.md`。

## 重启次数本身就是一种资源：Cfx.re 会对 license 校验限流

同一天内反复重启（尤其是每次都在起资源阶段失败再重试）会撞上
`An error occurred while checking server license key: HTTP 429`，此时服务器**根本不会启动**，
日志里只有 license 一行，看起来像"卡住了"。两条经验：

- 一次重启要等服务**真正起来**（`Started resource` 数到基线）再做下一步；不要 10 秒内连开两次，
  第二次往往会撞 `EADDRINUSE`（前一个实例还在关）或者直接把 429 的窗口拉长。
- 撞上 429 只能等（几十分钟量级）。这段时间去写测试/文档，不要反复试——每试一次都在续命限流。

## `-> Quitting: SIGHUP received` 不是崩溃

日志末尾出现 `-> Quitting: SIGHUP received`，随后是 `node::ResetStdio` 的 assert，说明进程是被
**终端/screen 会话回收**的（控制终端消失 → SIGHUP），不是代码崩的。两种正确做法：

1. 用 systemd 部署（仓库已有 `tools/ops/tcity.service` + `install_service.py`），会话关闭不影响服务；
2. 非要用 screen，至少不要把 screen 挂在会被关掉/回收的终端会话里，并且定期确认 `screen -ls` 还在。


### 429 的真实代价：一次 `systemctl start` 可能花掉两次配额

licence 校验发生在**绑定端口之前**，所以一次"起来就失败"的尝试同样消耗配额。更糟的是
`Restart=always` 会在失败后立刻再试一次——`systemctl start` 一次，日志里经常出现两次
`Started`。实测：08:26 正常启动一次，08:36–08:40 的 5 次失败尝试（都卡在 EADDRINUSE），
到 09:09 再试仍然是 429。

所以规则是：

- **一小时一次**，不要 20 分钟一次（实测 25 分钟不够）。
- 起之前先确认端口没人占（`ss -tln | grep 30120`）和 MySQL 在跑，别把配额花在能提前发现的问题上。
- `start.sh` 的 `flock` 已经挡住了"两个实例同时起"，但挡不住"通过 systemd 反复起"——那要靠人（或等 StartLimit 触发）。
- 判断是否真是限流：`tools/ops/healthcheck.py` 会直接点名 429 并给出等待建议，不用去翻日志里那一长串 HTML。
