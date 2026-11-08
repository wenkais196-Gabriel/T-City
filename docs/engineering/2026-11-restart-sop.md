---
id: restart-sop
type: runbook
status: active
system: infra
owner: hermes
updated: 2026-11-07
review_by: 2027-02-01
---

# 重启 SOP：`restart` 的级联与恢复

> 依据：2026-11-07 真机事故 —— 玩家在线时执行 `restart qb-core`，资源数 85 → **42**，
> 客户端刷一屏 `SCRIPT ERROR: No such export GetCoreObject in resource qb-core`，
> 经济/背包/车库等几十个功能静默失效（命令根本没注册，玩家只看到"没反应"）。

## 1. 为什么会这样

FXServer 的 `restart X` 会**先停掉所有把 X 写进依赖的资源**，然后只重启 X 自己 ——
被停的依赖方**不会**自动 `ensure` 回来。

被依赖最多的资源（`fxmanifest` 反向统计）：

| 资源 | 依赖它的资源数 |
|---|---|
| `qb-core` | 44 |
| `core-framework` | 29 |
| `oxmysql` | 19 |
| `production-freeze` | 10 |
| `qb-inventory` | 10 |

生产环境另一个坑：被停的资源可能已经在客户端加载完成，客户端再调 `exports['qb-core']`
就是上面那句 `No such export`，而且**不会自愈**（除非资源重新启动）。

## 2. 规则

1. **活服禁止** `restart qb-core` / `core-framework` / `oxmysql`。改这三个必须走整服重启。
2. 改了它们的代码、又必须验证时，按第 4 节的"整服重启"流程，在维护窗口做。
3. 叶子资源（`qb-garages`、`custom-police` 这类没人依赖的）可以热重启，但也要按第 3 节核对。
4. 改 `fxmanifest` **新增脚本文件**时必须 `refresh`（不是 `restart`），否则清单不重读。

## 3. 热重启叶子资源的流程

```bash
tcity-cmd -w 8 "restart <res>"      # Linux 布局
# Windows：python tools/dev/fivem_console.py "restart <res>" --wait 8
```

然后**立刻核对**（三条都过才算恢复）：

1. **server.cfg exec 的模块里 `ensure` 的资源全部在跑**（按集合判定，不按固定数字 ——
   地图资源 `fivem-map-*` 与 `dev.cfg` 的 `custom-testing`/`custom-agent-ops` 不该影响结果，
   真机实测资源总数 85/86 都出现过）：
   ```bash
   curl -s http://127.0.0.1:30130/info.json | jq '.resources | length'   # 只看总数
   ```
   少了就跑恢复脚本（它会做集合核对，缺一个就退出 1）：
   ```bash
   pwsh tools/dev/resync_modules.ps1            # Windows（RCON）
   tools/dev/resync_modules.sh                  # Linux（有 tcity-cmd 时自动执行）
   ```
2. **控制台无 `SCRIPT ERROR`**：尤其 `No such export`、`Execution of function reference`、
   `attempt to index a nil value`。
3. **关键命令还在**：被停资源注册的命令会一起消失（`/revive`、`/garages` 等）。
   抽查方法：控制台输入该命令，看是报"未知命令"还是正常执行。

## 3.5 ⚠️ `restart` 会连带停掉依赖它的资源

2026-11-08 实测：`restart qb-weapons` 之后，控制台紧跟着停了 **12 个**资源 ——
`qb-inventory`、`custom-justice`、`custom-police`、`custom-market`、`custom-cartel`、
`custom-storage`、`custom-mining`、`custom-certificates`、`qb-ambulancejob`、`qb-cityhall`、
`qb-management`、`qb-mechanicjob`。这些资源**不会自己回来**，`restart <名字>` 也没用
（控制台只会回一句 `Can't restart a stopped resource.`）。

所以每次 `restart` 一个被广泛依赖的资源后，必须做两步：

```bash
curl -s http://127.0.0.1:30130/info.json | jq '.resources | length'   # 掉了就补
python tools/dev/fivem_console.py "start qb-inventory"                 # 对每个被停的用 start，不是 restart
```

判定依据是**集合**不是数字（见上面第 1 条）；补完再跑一次 `resync_modules.ps1` 也可以，
它会把模块 cfg 里 `ensure` 的资源重新拉起。

## 4. 整服重启（唯一安全的重启 qb-core 方式）

```bash
# 1) 停：让所有玩家落盘（quit 会走 ForceSave）
python tools/dev/fivem_console.py "quit" --wait 3
# 2) 等进程完全退出（别在残留进程上再起一个，会烧 licence 配额）
# 3) 起
cd T-CityLite.base && E:/FXServer/FXServer.exe +exec server.cfg
# 4) 等到"Started resource"刷完，核对资源数 = 85
```

## 5. 静默失效的排查清单

症状是"功能没反应"，日志里未必有错误 —— 按这个顺序查：

1. 资源数是否 85（少一个就可能少一整片功能）；
2. 客户端 F8 是否刷 `No such export ...`；
3. 该功能的命令/事件是否还注册着（资源被停 → 命令不存在）；
4. `custom-logs` 的审计文件最近有没有新行（审计断了说明桥接资源挂了）。

## 6. 已知未自动化

- `resync_modules.ps1` 只做 `exec` + 资源数核对，**不验证命令是否注册**（第 3 条第 3 点的
  抽查仍是人工）。
- 停机窗口内的玩家落盘依赖 `quit` 的 ForceSave；如果进程被强杀，最多丢 15 分钟（脏池刷盘周期 900s）。
