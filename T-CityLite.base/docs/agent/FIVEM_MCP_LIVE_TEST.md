---
id: base-agent-fivem-mcp-live-test
type: audit
status: final
system: agent
owner: hermes
updated: 2026-10-27
---

# fivem-mcp 实机验证报告（ziyacivan/fivem-mcp 0.6.0）

> 目标：在 Windows 单 checkout（`E:\T-City`）上起 FXServer + FiveM 客户端，逐工具验证 `npx fivem-mcp-server` 的 23 个工具，判断哪些能用在我们自己的 agent 栈（`tools/agent_mcp.py`）里。
> 环境实测时间：2026-10-26。服务器与客户端均在本机。

---

## 1. 环境

| 项 | 值 |
|---|---|
| FXServer | artifact **37872**（`E:\FXServer\FXServer.exe`），数据目录 = `T-CityLite.base`（cwd） |
| 端口 | **30130**（TCP+UDP）——30120 被 `vmnat.exe`（VMware NAT，pid 4140）占用 |
| server.cfg | 最小开发配置（本地 server.cfg，gitignored，不在仓库里）：onesync、`set rcon_password`、8 槽、9 个 Cfx 自带资源 + 一次性诊断资源 `zz-mcp-diag` |
| 客户端 | FiveM build **3258**（`%LOCALAPPDATA%\FiveM`），GTA V `E:\GTAV`，devcon 监听 `127.0.0.1:29200` |
| MCP server | `fivem-mcp-server@0.6.0`，stdio，协议 `2025-06-18` |
| 探测脚本 | `%LOCALAPPDATA%\hermes\cache\scratch\mcp_probe.py`（标准库 JSON-RPC stdio 客户端，未入库） |

---

## 2. 工具验证结果（23/23 有结论）

| 工具 | 结果 | 证据 / 备注 |
|---|---|---|
| `status` | ⚠️ 可用但**字段不可信** | `client.connected` 在 devcon 实际可用时仍为 `false`；`server.rcon.configured` 正常 |
| `server_info` | ✅ | `getinfo`：`hostname=T-City DEV (MCP test)`, `clients=0`, `protocol=4` |
| `server_command` | ✅ | `zdiag hello world` → 服务器控制台回显 `[zz-mcp-diag] zdiag from console args=hello,world`；`restart zz-mcp-diag` 也正常 |
| `client_command` | ✅ | `zdiagc` → `[script:zz-mcp-diag] client console command zdiagc executed`，并回传该行 |
| `read_console`(server) | ✅ | 读 FXServer 日志文件，带 `channel`（`rcon` / `script:zz-mcp-diag`），但 `seq` 恒为 0、`nextSeq=-1`（**server 侧不支持 afterSeq 翻页**） |
| `read_console`(client) | ✅（语义特殊） | 首次调用**必空**（tap 现挂现收）；`wait 6000` 后再读拿到 `seq 2..6` 的心跳行，`channel` 精确到资源 |
| `wait_for_console`(server) | ✅ | 需先发起再等：并行发命令后 8s 内命中 `{"channel":"rcon","message":" zdiag zz-wait-probe-ok"}` |
| `wait_for_console`(client) | ✅ | 命中 `[zz-mcp-diag] heartbeat #3`（tap 已挂时立即返回） |
| `list_commands` | ❌ | 恒返回 `{"count":0}`，两次实测（资源重启前后）都拿不到命令表 |
| `launch` | ✅ | `fivem://connect/127.0.0.1:30130` 成功拉起；两次进服 |
| `quit_game` | ✅ | 优雅：`quit accepted — client console socket closed`；`{"force":true}` 走 taskkill 也 OK |
| `window_status` | ✅ | 返回标题 `FiveM® by Cfx.re - T-City DEV (MCP test)`、pid、2560×1440 矩形 |
| `focus_window` | ✅ | `focused 'FiveM® by Cfx.re …'` |
| `restore_focus` | 未测 | 无独立验证价值 |
| `screenshot` | ❌（本机） | 返回 `captured 2560x1441 via bitblt-screen -> 900x507 png; brightness 0%`，图全黑——**独占全屏抓不到 D3D** |
| `press_key` | ✅ | `tapped W`（scan code 注入，无报错） |
| `hold_key` / `release_key` | 未测 | 与 `press_key` 同实现 |
| `type_text` | 未测 | 同上 |
| `mouse_move` | ✅ | `mouse by (40,0)` |
| `click` / `scroll` | 未测 | 依赖可用画面才有验证意义 |
| `wait` | ✅ | `waited 6000ms` |
| `read_client_log` | ✅ | 命中 `CitizenFX_log_*.log` 里 3 行 heartbeat，支持 `contains`/`pattern` |
| `bridge` | ⚠️ 未安装 | 报错清晰：`mcpb is not installed — copy the bridge/ folder … and add ensure mcpb; then set mcpb_enabled true` |

---

## 3. 踩到的坑（都已在实机确认）

1. **30120 被 VMware NAT 占**：`vmnat.exe` 同时监听 TCP+UDP 30120，FXServer 直接 `EADDRINUSE` 退出。改 30130 解决；不要为此停 VMnetNAT（会断虚拟机网络）。
2. **`rcon_password "x"` 不生效**：写普通形式时资源里 `GetConvar('rcon_password','')` 读到长度 0，RCON 回 `The server must set rcon_password to be able to use this command.`；必须写 **`set rcon_password "x"`**。
3. **FiveM 校验父进程**：`powershell Start-Process FiveM.exe` / `Start-Process 'fivem://…'` 都会触发
   `Error: This application should be launched directly from the shell or a web browser.`
   （日志里由 `[FiveM]` 打印，随后 DumpServer 弹框）。唯一可靠姿势：`explorer.exe "fivem://connect/host:port"`。
4. **`delete` 客户端命令要先等资源挂载**：资源刚 `restart` 时立刻发 `client_command` 会得到 `[cmd] No such command zdiagc.`；等客户端重新挂载（日志出现 `Mounted zz-mcp-diag`）后再发就成功。
5. **devcon tap 是"现挂现收"**：`read_console(client)` 首次必空，且 60s 无调用会断开；不要指望它读历史。VIRUXE 的 README 说明这是为了规避 `devcon.dll` 的握手竞态（未合并的上游修复 citizenfx/fivem#4206）。
6. **全屏截图必黑**：BitBlt/PrintWindow 都抓不到独占全屏；要么把游戏切窗口化，要么只靠日志断言。
7. **`status.client.connected` 不能当健康判据**：它反映的是"MCP 进程当前是否持有一条 devcon 连接"，不是"客户端能不能用"。

---

## 4. 对我们 agent 栈的直接价值

| 能力 | 现状（T-City） | 借它补什么 |
|---|---|---|
| 实机断言 | `agent_smoke.py` 靠人眼看日志 / 轮询 HTTP | `wait_for_console(server/client, regex)` 就是现成的断言原语，可直接映射成 smoke 的 `expect` 步骤 |
| 客户端证据 | 无 | `read_console(client)` 带资源名 channel + `read_client_log` 双通道，比纯服务端日志更接近"玩家看到什么" |
| 交互驱动 | 无（NUI 靠人点） | `press_key`/`mouse_move`/`click` + `send_nui`(bridge) 能覆盖 NUI 焦点、按键这类只在实机暴露的 bug（参考本项目 WASD 冻结那类问题） |
| 安全边界 | L1–L4 + 审批 + 审计 | 这个 MCP **完全没有权限分级**：`server_command` 可以执行任意控制台命令。只能作为**开发期工具**接入，不能进生产工具面 |

结论：**取两块零件（`wait_for_console` + `read_client_log`/`read_console(client)`），不要整体接入**。它们和我们 `tools/agent_tools.json` 的 verify 字段天然对齐，包一层具名工具（带 L1 只读分级）即可。

---

## 5. 复现命令

```bash
# 1. 服（30130）
cd /e/T-City/T-CityLite.base
E:/FXServer/FXServer.exe +exec server.cfg > /e/FXServer/fxserver.log 2>&1

# 2. 客户端（必须经 explorer，父进程校验）
powershell -NoProfile -Command "Start-Process explorer.exe -ArgumentList 'fivem://connect/127.0.0.1:30130'"

# 3. MCP 探测
python mcp_probe.py --cmd "C:/Program Files/nodejs/npx.cmd -y fivem-mcp-server" \
  --env FIVEM_RCON_ADDRESS=127.0.0.1:30130 \
  --env FIVEM_RCON_PASSWORD=<rcon> \
  --env FIVEM_SERVER_LOG=E:/FXServer/fxserver.log \
  --call server_info '{}' \
  --call server_command '{"command":"restart <resource>"}' \
  --call read_console '{"target":"client","limit":5}'
```

---

## 6. 清理

- `resources/[custom]/zz-mcp-diag/`：一次性诊断资源（server/client 心跳 + 两个命令），验证完可删；未入库。
- 本地 server.cfg（`server.cfg` 这一层目录下的文件）：含 license key / rcon 密码，**已在 .gitignore**，永不提交。
- `E:\FXServer\`：运行时目录，在仓库外。
