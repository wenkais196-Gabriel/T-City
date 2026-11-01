# 客户端双端测试 Harness（MCP）

本文记录在 **Windows 宿主机 + FiveM Legacy 客户端** 上，让 Agent 不依赖人工点击即可
驱动客户端、读取状态、截图，并与 Linux VM 中的 FXServer 联动测试的方案。

> 仅用于开发/测试环境。宿主 bridge 含 MCP token 和 RCON 密码，**不要提交**到仓库。

## 0. 先确认这件事真的需要实机

客户端逻辑的大部分性质**不需要**开游戏：`lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua`
用 `tests/agent/lua/stubs/client.lua`（虚拟时钟 + 协程调度 + NUI 焦点/消息/回调 + 事件 + 原生桩）
直接跑**未修改的**客户端 Lua，断言焦点三元组、控制禁用集合、忙循环预算、握手/ack 契约。

必须先看真机的只有三类（详细矩阵见 [`design/06-client-model.md`](design/06-client-model.md) §3）：

1. CEF 真实键鼠输入（本文 §1 的已知限制）；
2. 原生渲染 / 物理 / 流式加载时序；
3. GPU、编码、字体回退、TTS 语音包。

换句话说：**先用无头桩把逻辑打绿，再来这里验证"看得见"的部分。**

## 1. 能力与边界

| 能力 | 工具 | 说明 |
|:---|:---|:---|
| 启动/连接客户端 | `launch` / `client_command connect` | Launch 走 `fivem://` URI；连接后客户端可能停在主菜单/角色选择 |
| 执行客户端命令 | `client_command` | 走 devcon F8 控制台，可执行 `RegisterCommand` 的客户端命令；**不依赖鼠标** |
| 截图 | `screenshot` | 失败取证；不要用它做断言 |
| 读客户端日志 | `read_client_log` | 比 `read_console` 稳定；`read_console` 的 devcon tap 有竞态 |
| 服务端命令 | `server_command` | 需要 server.cfg 写 **`set rcon_password "…"`**——裸写 `rcon_password` 实测不生效（`GetConvar` 读到空，RCON 回 `The server must set rcon_password`） |
| 服务端信息 | `server_info` | `getinfo`，无需 RCON |

**已知限制（2026-10-22）**：当前宿主环境下，MCP 的合成鼠标/键盘事件能送达游戏窗口，
但**没有送达 CEF/NUI 页面**；`IsNuiFocused()` 为 true、`keepInput=false` 时依然如此。
因此：

- NUI 的真实鼠标点击/键盘不要用 `press_key`/`click` 断言；
- 用 `nuitest`（`SendNUIMessage({type='testChoose'})`）验证 **NUI JS → fetch → client Lua → server**；
- 真实输入只做人工冒烟，或在 CI 外单独验证。

## 1.1 断言优先：用 console harness，而不是截图

`design/07-harness-channel.md` 落地的三个只读工具（`get_console_lines` / `get_console_match` /
`get_client_log`）可以在**不开游戏、不看屏幕**的前提下完成大部分实机回归：只要求资源把结果
`print` 出来。

```bash
export TCITY_HARNESS=1
export TCITY_HARNESS_SERVER_LOG=E:/FXServer/fxserver.log
```

| 想确认的事 | 用什么 |
|:---|:---|
| 资源是否重载成功 | `get_console_match(server, "Started resource <name>")` |
| 客户端脚本是否真的跑了 | `get_console_match(client, "\[<resource>\].*loaded")` |
| 效果是否落地 | `get_console_match(server, "agent_effects.*<action>", timeout_ms=8000)` |
| 刚才报了什么错 | `get_console_lines(server, pattern="error", limit=20)` |

本文件 §1 的表格只用于**剩下三类必须实机的事**（06 §3）。

## 2. 宿主要求

| 项 | 要求 | 检查 |
|:---|:---|:---|
| 客户端 | FiveM **Legacy**（Enhanced 移除 devcon） | `Get-NetTCPConnection -LocalPort 29200 -State Listen` |
| Node | 22+（本机 24.x） | `node -v` |
| GTA V | 已安装且能进游戏 | 客户端窗口存在 |
| 权限 | 不需要管理员 | 走 30120 出站/HTTP 轮询，不装 sshd |
| GPU | 能跑 FiveM 即可 | 本机 RTX 4060 Ti |

## 3. 拓扑

```text
Windows 宿主机
  └─ node fivem-mcp-bridge.js
       ├─ npx -y fivem-mcp-server（stdio MCP）
       │    ├─ devcon 127.0.0.1:29200 → FiveM Legacy F8 / 输入 / 截图
       │    └─ RCON 172.20.101.94:30120 → FXServer
       └─ HTTP 轮询 172.20.101.94:30120/host-setup/fivem-mcp/*
                                      │
Linux VM                                ▼
  └─ FXServer + host-setup（临时，只用于测试）
       └─ tools/fivem_mcp_client.py（MCP stdio over HTTP 轮询）
```

选 HTTP 轮询而不是反向 TCP，是因为宿主机到 VM 的 8080/9010 会被拦，而 30120 已验证可达；
宿主不需要开放任何入站端口。

## 4. 启动步骤

1. 宿主机下载 `fivem-mcp-bridge.js`（由临时 `host-setup` 资源在 30120 提供）。
2. 确认 `FIVEM_EXECUTABLE`、`FIVEM_CLIENT_DEVCON_PORT=29200`、
   `FIVEM_RCON_ADDRESS=172.20.101.94:30120`、`FIVEM_RCON_PASSWORD` 正确。
3. 运行：

   ```powershell
   node "$env:TEMP\fivem-mcp-bridge.js"
   ```

4. 看到 `fivem-mcp-server ready` 后，在 VM 执行：

   ```bash
   python3 tools/fivem_mcp_client.py --list
   python3 tools/fivem_mcp_client.py --tool status
   ```

5. 客户端进游戏：**必须经 shell 启动**，否则 FiveM 会拒绝并弹
   `This application should be launched directly from the shell or a web browser`：

   ```powershell
   Start-Process explorer.exe -ArgumentList 'fivem://connect/172.20.101.94:30120'
   ```

   ```text
   client_command connect 172.20.101.94:30120
   # 若停在角色选择，再按 ENTER（或人工点 ENTER GAME）
   ```

   devcon（`127.0.0.1:29200`）只在**进服之后**才监听；启动器阶段没有。

## 5. 测试命令

```text
# 服务端/任务状态
client_command questrestore          # 重发当前任务状态；step_decision 会重开 NUI
client_command decision honest_cop  # 绕过 NUI，直接走 story:server:makeDecision
client_command nuitest honest_cop   # NUI 测试钩子：JS chooseOption → fetch → client callback

# 取证
screenshot
read_client_log {"lines": 100}
server_info
```

断言以 **DB / 服务端日志** 为准：

```sql
SELECT status, current_step FROM player_quests
 WHERE citizenid = ? AND quest_id = 'police_ch1_first_shift';

SELECT decision_id, chosen_option FROM player_choices
 WHERE citizenid = ? ORDER BY id DESC LIMIT 1;
```

服务端日志前缀：

- `[client-telemetry]`：NUI 打开/焦点/回调/心跳/看门狗
- `[story-engine] 📩 makeDecision ...`：服务端实际收到选择
- `[custom-quest] cache preload ...`：重连后 QuestCache 已从 DB 预加载

## 6. 已修复的重连问题

`QuestManager.GetActiveQuests` 的 `QuestCache` fallback 是异步 DB 查询，服务端重启后
第一次调用会先返回空表，导致：

- `step_decision` 重连不重新弹窗；
- `/questrestore` 看不到任务；
- `/decision` 报 `no pending decision`。

修复：`QBCore:Server:PlayerLoaded` 时先 `QuestDB.GetActiveQuests` 再
`QuestCache.SetActiveQuests`。测试时若仍为空，先确认 `cache preload` 日志出现，
再执行 `questrestore`。

## 7. NUI 焦点保护

- `SetNuiFocusKeepInput(false)` + `SetNuiFocus(true, true)`；
- `nui.focus` telemetry 记录 `focused` / `keepInput`；
- 45s watchdog 已改为 **300s**，避免人工点击前焦点被释放；
- `nui.watchdog` 只在真正软锁时释放焦点；
- `nuitest` 不依赖鼠标，适合自动化回归。

## 8. 安全

- bridge 只允许测试 token；token/RCON 存在宿主机本地脚本和 `.env`，不提交；
- RCON 只开给测试服，`rcon_password` 强随机；
- devcon 只绑 `127.0.0.1`，不要用 `-devcon` 暴露到局域网；
- `host-setup` 资源是临时测试资源，测试完删除，不进入生产 cfg。
