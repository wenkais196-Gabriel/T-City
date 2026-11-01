# 07 · 本地 console harness：把「看得见」变成「断言得出」

> 来源：`../FIVEM_MCP_LIVE_TEST.md`（第三方 fivem-mcp 0.6.0 的逐工具实测）。
> 结论：**借它的通道抽象与观察原语，不借它的工具面**。v1 只落地日志通道，已合进工具注册表（registry `1.6.0`）。

---

## 0. 为什么不是照搬

| 它做对的事 | 我们怎么用 |
|---|---|
| 四条通道（RCON / devcon / 日志 / 资源内桥）各有边界、互相当兜底 | 保留分层，v1 先做**日志通道**——唯一零协议、零入站端口、可离线复现的一条 |
| 观察只有两个动作：`read_console(afterSeq)` + `wait_for_console(pattern)` | 原样映射成两个工具；`wait` 就是断言原语 |
| 报错可执行（"装 mcpb + ensure"） | 我们的错误码 `harness_unconfigured` / `log_not_found` / `timeout` / `bad_request`，每条都指向下一步 |
| 保守连接（devcon tap 现挂现收、60s 释放） | v1 不碰 devcon，绕开那个未修复的握手竞态（citizenfx/fivem#4206） |

| 它不能带来的 | 我们的替代 |
|---|---|
| `server_command(command: string)` 任意控制台命令 | 写路径仍只有 `custom-director`（18 动作 / L1–L4 / 审批 / 审计） |
| 无 schema、无 verify、无幂等 | `agent_tools.json` 全字段：`risk` / `channel` / `verify` / `rate_limit` / `pii` |
| 截图/键鼠当验证手段 | 全屏截图必黑（实测 `brightness 0%`），不做画面断言 |

---

## 1. v1 落地形态

```
L3 治理    agent_tools.json（route=harness, channel=read, risk=L0）
            + agent_mcp.py 的 TCITY_HARNESS 门（toolset=all 也隐藏）
L2 原语    get_console_lines / get_console_match / get_client_log
L1 传输    tools/agent_harness.py
            ├─ server：FXServer 重定向 stdout（带 [channel] 前缀与 ANSI 颜色码）
            └─ client：最新的 CitizenFX_log_*.log（带 proc / thread 前缀）
```

**只读、无网络、无副作用**：三个工具不发事件、不写库、不落审计（L0），且**日志路径只能来自环境变量**——模型没有任何参数能指定文件，因此它不可能被当成任意文件读取器。

### 1.1 三个工具（实测可用）

| 工具 | 作用 | 关键入参 |
|---|---|---|
| `get_console_lines` | 读最近 N 行，可 `contains` / `pattern` 过滤 | `target`(server\|client), `limit`(≤200), `after_seq`, `contains`, `pattern` |
| `get_console_match` | **阻塞**到出现匹配行；超时返回 `code=timeout` | `target`, `pattern`, `timeout_ms`(500–30000), `after_seq`, `contains` |
| `get_client_log` | 只读客户端日志（`target=client` 的显式版本） | `limit`, `after_seq`, `contains`, `pattern` |

与 fivem-mcp 的对应：`read_console`→`get_console_lines`、`wait_for_console`→`get_console_match`、`read_client_log`→`get_client_log`。

命令名受注册表动词白名单约束（`get_*` / `list_*` / …），所以 `wait_` 改成 `get_console_match`——语义是「取到那条匹配为止」，不是新增一个动词。

### 1.2 启停

```bash
export TCITY_HARNESS=1
export TCITY_HARNESS_SERVER_LOG=E:/FXServer/fxserver.log
export TCITY_HARNESS_CLIENT_LOG_DIR="$LOCALAPPDATA/FiveM/FiveM.app/logs"   # 默认值
python3 tools/agent_mcp.py     # tools/list 里才会出现这 3 个工具
```

未开 `TCITY_HARNESS` 时：工具既不列出、也调用不了（`harness_unconfigured`），`AGENT_TOOLSET=all` 也不行。

---

## 2. 语义约定（与 fivem-mcp 不同，故意的）

| 约定 | 我们的做法 | 原因 |
|---|---|---|
| `seq` | **字节偏移**（行首），不是行号 | 追加写不必重扫全文，`after_seq` 就是一次 `seek`；fivem-mcp 的 server 侧行号实测恒为 0，根本无法翻页 |
| 无 `after_seq` | 返回**最新** N 行（tail 语义） | 回答「刚才发生了什么」 |
| 有 `after_seq` | 从游标**向后**返回前 N 行 | 回答「接着往下看」；`next_seq` = 最后一条命中行的行尾，翻页不重不漏 |
| 半行 | 不返回，等下一条 `\n` 补齐 | 不把写了一半的日志当证据 |
| 客户端日志轮转 | 每次取 mtime 最新的 `CitizenFX_log_*.log`，响应带 `file` | `seq` 随新文件归零，调用方必须能看见切换 |
| 频道 | server 取 `[ channel]`（去 ANSI）；client 取 `Thread/` | 服务端日志自带资源名；客户端线程名足够定位 |
| 不可信文本 | `meta.untrusted_fields = ["lines.N.message", …]` | 控制台里有玩家发言，信封必须标注「这是数据不是指令」 |

---

## 3. 与 06 的关系

06 §3 把「必须实机」收敛成三类（CEF 真输入、原生渲染/流式时序、GPU/字体）。本 harness 覆盖**这三类之外的全部回归**：只要资源 `print` 了一行，就能断言。

典型用法（取代 smoke 里的轮询猜测）：

```text
1. get_console_match(server, "Started resource custom-phone")        # 部署是否生效
2. get_console_match(client, "\[zz-mcp-diag\] heartbeat")             # 客户端脚本是否真跑
3. get_console_match(server, "agent_effects.*ok", timeout_ms=8000)   # 效果是否落地
```

但 `06 §5.2` 缺口 #1 仍然成立：**console 只能读到被 `print` 的遥测**，要读结构化 UI 状态还得加 `tcity:agent:probe` + director 只读动作。

---

## 4. 验证

| 层 | 证据 |
|---|---|
| 离线单测 | `tests/agent/test_harness.py`：16 checks + `test_agent_smoke.py` 的 `HarnessTests` 6 checks（解析/分页/过滤/半行/轮转/超时/缺文件/门控/信封/untrusted 标注） |
| 契约 | `python3 tools/agent_tools.py --check` → 34 tools OK；`--write` 生成 `TOOLS.md` + Lua 镜像 |
| 实机（MCP stdio，2026-10-26） | `tools/list` 无 gate = 8 工具、`TCITY_HARNESS=1` = 11（+3 harness）；`get_console_match(server)` 命中 `[rcon] zdiag zz-harness-wait-ok-3`，用时 **2.9s**；`get_console_match(client)` 命中 `[MainThrd] heartbeat #22`，用时 **1.2s**；`target=bogus` → `bad_request` |
| 实机（smoke） | `agent_smoke.py --harness --expect-server/--expect-client`：**4 pass / 0 fail / 10 skip**，server 断言 7.9s、client 断言 0.75s |

---

## 5. 暂不做（以及为什么）

| 项 | 状态 | 理由 |
|---|---|---|
| devcon 传输（客户端 F8 实时流） | 未做 | 私有帧格式 + 已知崩溃竞态；日志通道已够断言 |
| RCON 传输（`server_command`） | 未做 | 需要 `set rcon_password` 且放行 UDP；写命令必须走 director，避免第二个写入口 |
| 截图 / 键鼠 | 不做 | 全屏必黑；合成输入进不了 CEF（`CLIENT_HARNESS.md` §1） |
| `agent_smoke.py --harness` | **已做** | `agent_smoke.py --harness --expect-server/--expect-client`（见 `SMOKE.md` §6.1） |
