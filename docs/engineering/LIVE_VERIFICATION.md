---
id: engineering-live-verification
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-30
review_by: 2027-04-30
---

# 真机验证工作流（Live verification）

> 适用：改动涉及 **NUI / 输入 / 实体 / 事件时序 / 客户端生命周期** 时。
> 这类问题单测和 golden 用例只能证"逻辑对"，证不了"真的跑起来是什么样"。
> 本文是固定动作，不需要每次重新摸索：照 §4 的回路走一遍，证据落 §5 的三种断言。

## 1. 什么时候必须上真机

| 改动类型 | 必须真机 | 理由 |
|---|---|---|
| NUI 布局、样式、焦点、App 渲染 | 是 | CEF 的渲染与焦点语义和金标 harness 不同（`backdrop-filter` 卡顿、遮罩吞点击都只有真机暴露） |
| 键盘/鼠标/手柄输入链路 | 是 | 合成输入与真实输入的到达路径不同，见 §6 |
| 实体生成、NPC 行为、载具 | 是 | OneSync 焦点区、owner 迁移、任务丢失都是运行时行为 |
| 服务端权限/审计/预算 | 否（golden 够） | 但涉及"谁在什么时候发事件"的时序，仍建议真机复核一次 |
| 纯文档/纯重构 | 否 | 跑 `pytest tests/unit tests/architecture` + golden 即可 |

## 2. 起栈三步（顺序不能反）

```bash
docker start tcity-mariadb                      # 1) 数据库先起来
tasklist | grep -ci FXServer.exe                # 2) 确认没有僵尸实例
./start.sh   # 或直接 FXServer.exe +exec server.cfg，日志重定向到 scratch
explorer.exe "fivem://connect/127.0.0.1:30130"  # 3) 客户端必须经 shell 拉起
```

| 故障现象 | 根因 | 处置 |
|---|---|---|
| 客户端被拒：`数据库错误` | Docker Desktop 没启动 → MariaDB 容器停 | 启动 Docker Desktop + docker start |
| 客户端一直连不上、端口无人监听 | 旧 FXServer 进程还占着 30130 | `taskkill /F /IM FXServer.exe` 后重启 |
| 资源只有七十几 | 某次 restart 连坐停掉了依赖资源 | `tools/dev/check_module_resources.py` 查缺口，逐个 ensure |
| 玩家被踢下线 | `exec configs/modules/core.cfg` 之类会重启核心资源 | 重启后重新连客户端，别在验证中途 exec 核心模块 |

## 3. 四个工具（都在 tools/dev）

| 工具 | 干什么 | 例 |
|---|---|---|
| `fivem_console.py` | 发控制台命令 / 按键（经 MCP → RCON） | `fivem_console.py "restart custom-police"`、`fivem_console.py --key Down` |
| `police_live_probe.py` | 一次打印客户端 phone 状态 + 资源数 + 审计尾巴 | `police_live_probe.py --audit 5` |
| `police_backup_metrics.py` | 从 `police_audit` 聚合支援指标（成功率/耗时/存活/异常率） | `police_backup_metrics.py --hours 24` |
| `police_request_backup.py` | 按 M → 直达 MDT → 逐格走到「请求支援」→ Enter（每步读回焦点） | `police_request_backup.py --verbose` |
| `check_module_resources.py` | 模块声明 vs 实跑，缺口退出码 1 | `check_module_resources.py --url ... --token ...` |
| `resync_modules.sh` | 重新 exec 全部模块 cfg | `./tools/dev/resync_modules.sh` |

## 4. 驱动 UI 的确定性回路（不用鼠标、不看像素）

```bash
export FIVEM_RCON_PASSWORD=...        # server.cfg 里的 rcon_password
export TCITY_LIVE_TOKEN=...           # live token，只读

python3 tools/dev/fivem_console.py "setr agent_devcmd_enabled 1"   # 开 devcmd 桥
python3 tools/dev/fivem_console.py "setr phone_ui_nav 1"           # 开 app 直达
python3 tools/dev/fivem_console.py "adc 1 phone"                   # 开手机（1 = server id）
python3 tools/dev/fivem_console.py "adc 1 phoneui police_mdt"      # 直达 App 的某个 tab

python3 tools/dev/fivem_console.py --key Down        # 走一格
python3 tools/dev/police_live_probe.py               # 读 phone.focus 确认落在哪
python3 tools/dev/fivem_console.py --key Enter       # 激活
```

**更稳的一条路**：需要"叫一单支援"这种业务动作时，别去点 UI —— 用资源自己的开发后门：

```bash
python3 tools/dev/fivem_console.py "setr police_backup_dev_enabled 1"
python3 tools/dev/fivem_console.py "police_backup_dev 1 1"    # serverId, tier
```

它走的是同一个 `RequestBackup`（权限/冷却/预算/审计都不跳过），但把"开手机 → 直达 App →
逐格走焦点 → Enter"四步压成一行。按键注入在窗口焦点被抢时会**静默不发键**，UI 路径仍要留着，
但回归迭代优先用后门。

要点：**每按一次键就读一次 `phone.focus`**，焦点标签（"请求支援"、"调度"）是唯一可靠的定位手段；
盲按 N 次然后祈祷必定失败。

## 5. 三种断言（证据要能贴进 PR）

| 层次 | 看什么 | 何时用 |
|---|---|---|
| 状态探针 | `police_live_probe.py` 的 `open / app / focus / frames` | UI 与输入类改动 |
| 审计与数据库 | `police_live_probe.py --audit N` | 权限、生命周期、原因/时长类改动 |
| 金标与单测 | `lua5.4 tests/agent/lua/runner.lua`、`pytest tests/unit tests/architecture` | 所有改动，先红后绿 |

真机证据的写法：把**带时间戳的读数**原样粘进 PR/设计稿，例如
`backup.ended | BU-1-...-1 | reason=timeout;live=301 | 17:58:05`，并说明这个数字是怎么算出来的。

## 6. 别做（都是实测踩过的）

| 别做 | 实测后果 |
|---|---|
| 直连 RCON（自己拼 Source 协议） | 认证包一进去就被关连接，零字节返回 |
| 往 Windows 控制台 PTY 里发命令 | 只回显 `+vstr` 这类碎片，命令没执行 |
| PowerShell `keybd_event` / `SendKeys` / 桌面驱动 foreground SendInput | 到不了游戏进程：`phone.nav_edges` 恒空，手机不响应 |
| 用"按键没反应"下结论 | 先换 `fivem_console.py --key`，能通说明是注入路径问题，不是键位问题 |
| `restart` 一个被大量资源依赖的插件 | 连坐停掉依赖者且不自动拉回（曾一次停 12 个，`/revive` 静默失效） |
| 指望资源自己审计关停 | 客户端 `onResourceStop` 发的终态事件，接收端正在重启，必然丢 |

## 7. 用 Claude Code 参与（该用在哪、怎么用）

| 场景 | 结论 |
|---|---|
| 联网调研（开源实现怎么做的、native 在哪个端） | **好用**。要求每条结论带 URL，跑 `--allowedTools "WebSearch,WebFetch"` |
| 本地代码评审 | **给预算**：最多 3 个文件、只允许 `Grep -n`/`Glob`、`--max-turns` 留够轮次；否则它会并行几十个 Read 把轮次烧光（实测 $2.05、零产出） |
| 写代码/改仓库 | 不用。它看不到本仓的红线，改出来的东西还要逐行复核，收益为负 |
| 并行子代理（delegate_task） | 适合互不依赖的信息收集，不适合同一文件的多处修改 |

CC 的凭据走 Hermes 环境里的 `ANTHROPIC_*`，后端是 DeepSeek；
`ANTHROPIC_BASE_URL` 必须是 `https://api.deepseek.com/anthropic`，模型用 `deepseek-chat`。

## 8. 一个完整回路（S1 的实际时间线）

1. 起栈 → 客户端进游戏（`src=1 / DXI50064`）
2. `adc 1 phone` + `adc 1 phoneui police_mdt` → `police_live_probe.py` 确认 `app.id=police_mdt, tab=dispatch`
3. `--key Down` 逐步走到焦点 `请求支援`（每步读回焦点）→ `--key Enter`
4. 审计出现 `backup.request | DXI50064 | BU-1-...-3`
5. 等客户端寿命到点（5 分钟）→ 审计出现 `backup.ended | reason=timeout;live=301`
6. `restart custom-police` → **不会**出现 `resource_stop` 审计（见 §6 最后一行），这条本身就是要记进文档的结论
