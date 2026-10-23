# FiveM 双端 Agent 自动化测试：现状调研与落地方案

> 调研日期：2026-10-22
> 范围：FiveM / Cfx.re 生态是否有「Agent 驱动客户端 + 服务端」的开发与测试自动化；若无，其他游戏有哪些可复用的范式；以及 T-City 怎么落地。
> 结论先行：**有雏形，没有成品框架。** 工具层（MCP + devcon + RCON + 探针资源）已经有人做出来了，但"测试框架"这一层（用例、断言、报告、CI）仍然空白。

---

## 0. 一句话结论

| 问题 | 答案 |
|:---|:---|
| FiveM 有 Agent 双端开发/测试方案吗？ | 有 **Agent 驱动** 的工具（fivem-mcp 系列），但**没有测试框架** |
| 有开箱的 client↔server 联调/断言方案吗？ | 没有。官方无，社区论坛的结论也是"自己造" |
| 能参考其他游戏吗？ | 能，而且范式很成熟（Minecraft / WoW / Unreal / Unity） |
| 该怎么实现？ | **确定性探针做断言，Agent 只做编排与探索**；服务端进 CI，客户端留在真机 |

---

## 1. FiveM 生态现状

### 1.1 已经存在的部件

| 项目 | 层 | 能力 | 关键局限 |
|:---|:---|:---|:---|
| [VIRUXE/fivem-mcp](https://github.com/VIRUXE/fivem-mcp) | 客户端驱动 | 启动客户端、`SendInput` 键鼠、截图、读日志、devcon 控制台、RCON、`mcp_bridge` 资源（natives / exports / NUI 回调） | Windows + .NET 11；必须前台窗口；无断言/无用例 |
| [ziyacivan/fivem-mcp-server](https://github.com/ziyacivan/fivem-mcp) | 双端驱动 | RCON 服务端命令 + devcon 客户端 F8 控制台 + 窗口/键鼠/截图 + `wait_for_console` 断言原语 + `test_resource` 提示词 + `mcpb` 桥接资源 | v0.x；断言只是"等一行日志"；报告靠 Agent 叙述 |
| [@mriqbox/fivem-test-harness](https://www.npmjs.com/package/@mriqbox/fivem-test-harness) | 服务端单测 | 用 wasmoon 在 Node 里跑**真实 Lua 文件**，stub 掉 exports / ox_lib / QBCore / ACE / 假 DB | 不启动 FXServer；`CreateThread` 同步执行、`Wait()` 空转；测不了 native |
| [@aeterna_game/fivem-devkit](https://www.npmjs.com/package/@aeterna_game/fivem-devkit) | 静态 + 单测 | 静态检查、安全扫描、busted harness | 同上，不覆盖运行时 |
| [routmoute/fxserver](https://github.com/routmoute/fxserver) | 服务端运行 | FXServer 官方 Linux artifact 的 Docker 镜像 | 需要 `sv_licenseKey`；只解决"跑起来" |
| screenshot-basic | 客户端取证 | 游戏内截图 | 只能取证，不能断言 |

### 1.2 仍然缺的三块

1. **统一的用例 / 断言 / 报告层。** 现在每个项目都在自己拼 pytest/vitest，没有"FiveM 版 Playwright"。
2. **协议级 bot。** Minecraft 有 mineflayer（实现协议、无需渲染即可当玩家），FiveM 的客户端协议是私有的、加密的，社区没有等价物。这决定了 FiveM **无法**像 Minecraft 那样用 headless bot 做多人 E2E。
3. **客户端可 CI 化。** 官方没有 headless 客户端；跑客户端 = Windows + GTA V + GPU + 真窗口。GitHub 托管 runner 做不到。

### 1.3 社区共识

Cfx 论坛 2025 年的一个直接提问（[LUA unit testing with fxserver](https://forum.cfx.re/t/lua-unit-testing-with-fxserver/5321988)）说得很清楚：

> "with the flow of code from client to server and back I don't see an out of the box way of mocking the connection between client and server … do we have to roll our own system?"

即：**官方没有，社区也没有，要自己造。**

### 1.4 一个必须注意的版本坑

fivem-mcp-server 的作者称：**Enhanced 客户端移除了 devcon 端口**，因此客户端工具目前只支持 **Legacy** 客户端（见其 README "Requirements"）。T-City 若计划迁移 Enhanced，客户端自动化链路需要重新验证。服务端侧的 RCON 不受影响。

---

## 2. 其他游戏怎么做（四种范式）

| 范式 | 代表 | 做法 | 对 FiveM 的可迁移性 |
|:---|:---|:---|:---|
| **A. 协议级 headless bot** | [Plugwright](https://github.com/Drownek/plugwright)（Minecraft Paper）、[mod-playerbots](https://github.com/mod-playerbots/mod-playerbots)（AzerothCore） | 起真服务器，用实现了协议的 bot 当玩家；断言写在 bot 侧 | ⭐ 思路可借，**实现不可借**（FiveM 无公开协议） |
| **B. 引擎内 MCP + 官方自动化** | [Unreal MCP](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)（UE 5.8 官方实验特性）、Unity MCP、[AltTester](https://alttester.com)、[GameDriver](https://gdriver.io) | 引擎内嵌 MCP server，Agent 调"生成 actor / 跑 automation test / 查 Slate 控件" | ⭐⭐ 架构可借：**把测试能力做成 MCP 工具** |
| **C. 像素级视觉 Agent** | [SIMA 2](https://deepmind.google/blog/sima-2-an-agent-that-plays-reasons-and-learns-with-you-in-virtual-3d-worlds/)、[Airtest/Poco](https://airtest.doc.io.netease.com/) | 截屏 → 模型决策 → 键鼠动作 | ⭐⭐⭐ 唯一能在 FiveM 客户端上通用的路径，但慢且不稳，只适合探索 |
| **D. 商业 AI QA** | [modl.ai](https://modl.ai) | AI bot 长时间跑，找崩溃/平衡问题 | ⭐ 思路可借，闭源 |

### 2.1 最值得抄的一个：Plugwright

它几乎是"FiveM 想要但做不到"的那个东西：

- 起**真** Paper 服务器（不是 mock）
- Mineflayer bot **真的加入**、走路、聊天、点 GUI
- API 像 Playwright：`await expect(player).toContainItem('emerald', { count: 5 })`
- 有 Gradle 插件和 GitHub Action，`./gradlew paperwrightInit` 即可

它成立的前提是 **Minecraft 协议开放**。FiveM 缺的正是这个前提——所以 FiveM 只能走"真客户端 + 输入注入 + 探针"的路，成本高一个数量级。

### 2.2 最值得抄的架构：Unreal MCP

Epic 在 UE 5.8 里把 MCP server 做进了编辑器进程，暴露的工具里**直接包含 "running automation tests"**。它给 FiveM 的启示不是代码，而是分层：

```
Agent  ←MCP→  引擎内的工具层  ←→  引擎自己的测试框架
```

对应到 FiveM 就是：

```
Agent  ←MCP→  tc_test_probe（资源内的工具层）  ←→  FXServer / 客户端运行时
```

**不要**让 Agent 直接对着屏幕和日志"感觉"对不对；要给它一组**确定性的工具**，让它调用、拿结构化结果。

---

## 3. 方案：确定性探针 + Agent 编排

### 3.1 核心原则

> **LLM 不做断言，只做编排、生成用例、定位失败。**
> 断言必须是 `wait_for(pattern)` / `probe() == expected` / JSON diff 这种确定性操作。

理由：截图判读和日志"意会"在 CI 里必然 flaky，且无法回归。Agent 的价值在于**写用例**和**读失败**，不在于当断言器。

### 3.2 分层（接在 T-City 现有金字塔上）

T-City 现在有 `layer0_db / layer0_js / layer1_core / layer2_services / layer3_business`，全部离线。缺的正好是上面两层：

| 层 | 内容 | 依赖 | 跑在哪 |
|:---|:---|:---|:---|
| L0 静态 | `check_cfgs` / `check_dependencies` / `luac -p` | 无 | GitHub Linux ✅ 已有 |
| L1 纯逻辑 | wasmoon harness（真 Lua + stub） | Node | GitHub Linux ✅ 可加 |
| L2 服务端集成 | 真 FXServer（Docker）+ RCON + 探针断言 | license key | GitHub Linux ✅ 可加 |
| **L3 双端 E2E** | 真客户端 + devcon + 探针 + 截图 | Windows + GPU + GTA V | **self-hosted Windows** |
| L4 探索 | Agent 看截图找问题 | 同上 | 手动 / nightly |

**关键判断：先把 L2 做扎实，L3 只做少量冒烟。** L2 能覆盖 80% 的回归（事件、权限、钱、物品、DB），成本却只有 L3 的十分之一。

### 3.3 组件图

```
┌─────────────────────────────────────────────────────────────┐
│  Agent (Claude Code / T-City agent_gateway)                 │
│    ├─ MCP: tc-test    → run_scenario / get_evidence / diff  │
│    └─ MCP: fivem      → client_command / screenshot / keys  │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
      ┌─────────▼─────────┐         ┌─────────▼──────────┐
      │  FXServer (Linux) │         │ FiveM 客户端 (Win) │
      │  Docker + RCON    │◄───────►│ devcon :29200      │
      │  tc_test_probe    │  事件   │  tc_test_probe     │
      └─────────┬─────────┘         └─────────┬──────────┘
                │                             │
                └──────────┬──────────────────┘
                           ▼
                  [TC-TEST] JSON 行 → 日志
                           ▼
                   runner (pytest) 断言
```

### 3.4 探针资源（核心，约 150 行）

一个只给 dev 环境用的资源，服务端 + 客户端两半，职责是**把状态变成 JSON**。

`resources/[dev]/tc_test_probe/server/main.lua`：

```lua
local RUNS = {}

-- 客户端上报：统一入口，一行一条，方便日志 grep
RegisterNetEvent('tc:test:report', function(runId, payload)
    payload.runId = runId
    payload.src = source
    payload.at = GetGameTimer()
    print(('[TC-TEST] %s'):format(json.encode(payload)))
end)

-- 服务端主动断言：给 runner 一个"要什么测什么"的入口
RegisterCommand('tc_assert', function(_, args)
    local runId, check = args[1], args[2]
    local ok, detail = true, {}

    if check == 'resource_started' then
        local name = args[3]
        ok = GetResourceState(name) == 'started'
        detail.resource, detail.state = name, GetResourceState(name)
    elseif check == 'player_money' then
        local src, account, expected = tonumber(args[3]), args[4], tonumber(args[5])
        local actual = exports['qb-core']:GetCoreObject().Functions.GetPlayer(src)
            ?.PlayerData.money[account]
        ok, detail = actual == expected, { expected = expected, actual = actual }
    elseif check == 'event_fired' then
        local name = args[3]
        ok = (RUNS[name] or 0) > 0
        detail.event, detail.count = name, RUNS[name] or 0
    end

    print(('[TC-ASSERT] %s'):format(json.encode({
        runId = runId, check = check, ok = ok, detail = detail,
    })))
end, true)   -- true = 仅控制台/RCON 可调用

-- 记录所有关键事件，供 event_fired 断言
AddEventHandler('tc:test:track', function(name) RUNS[name] = (RUNS[name] or 0) + 1 end)
```

> 上面 `?.` 是伪代码示意，实际按 qb-core 的取法写。生产环境请把 `tc_assert` 限制在 `sv_devMode` 或独立 convar 下。

`client/main.lua`：

```lua
local function snapshot()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    return {
        kind = 'client_state',
        coords = { x = coords.x, y = coords.y, z = coords.z },
        heading = GetEntityHeading(ped),
        inVehicle = IsPedInAnyVehicle(ped, false),
        health = GetEntityHealth(ped),
        armour = GetPedArmour(ped),
        visibleNui = IsNuiFocused(),          -- NUI 是否抓住焦点
        frontend = IsFrontendReadyForControl(),
    }
end

-- 探针：只读状态
RegisterCommand('tc_probe', function(_, args)
    TriggerServerEvent('tc:test:report', args[1], snapshot())
end, false)

-- 动作：让服务端/runner 能驱动客户端做确定性操作
RegisterNetEvent('tc:test:do', function(runId, action, params)
    if action == 'teleport' then
        SetEntityCoords(PlayerPedId(), params.x, params.y, params.z, false, false, false, true)
    elseif action == 'give_weapon' then
        GiveWeaponToPed(PlayerPedId(), params.hash, 1, false, true)
    elseif action == 'press' then
        -- 走 NUI 或直接调服务端已经封装好的函数，避免键鼠注入
        TriggerEvent(params.event, params.payload)
    end
    -- 动作完成后立刻回一次快照，作为"动作生效"的证据
    TriggerServerEvent('tc:test:report', runId, snapshot())
end, false)
```

**设计要点：**
- 上报统一 `print('[TC-TEST] ' .. json)`，runner 只 grep 这个前缀 → 不依赖任何私有协议。
- 客户端动作**优先走事件**，键鼠注入只作为兜底（`SendInput` 慢且依赖前台窗口）。
- 每个断言带 `runId`，多人/并发不串味。

### 3.5 Runner（pytest，约 60 行）

```python
# tests/e2e/conftest.py
import json, re, subprocess, time, uuid, pytest

TC_TEST = re.compile(r"\[TC-TEST\] (\{.*\})")
TC_ASSERT = re.compile(r"\[TC-ASSERT\] (\{.*\})")

@pytest.fixture(scope="session")
def fxserver():
    subprocess.run(["docker", "compose", "up", "-d", "--build"], check=True)
    log = open(".e2e/server.log", "w")
    proc = subprocess.Popen(["docker", "compose", "logs", "-f", "--no-color"],
                            stdout=log, stderr=subprocess.STDOUT)
    # 等服务器就绪
    wait_for_line(".e2e/server.log", r"Started resource tc_test_probe", timeout=120)
    yield
    proc.terminate()
    subprocess.run(["docker", "compose", "down", "-v"])

def rcon(cmd: str) -> str:
    return subprocess.run(["docker", "compose", "exec", "-T", "fxserver",
                           "./rcon", cmd], capture_output=True, text=True).stdout

def test_quest_reward(fxserver):
    run_id = str(uuid.uuid4())
    rcon("ensure tc_test_probe")
    rcon(f"tc_assert {run_id} resource_started tc_test_probe")
    rcon(f"tc_assert {run_id} player_money 1 cash 500")

    events = read_json_lines(".e2e/server.log", TC_ASSERT)
    assert all(e["ok"] for e in events if e["runId"] == run_id), events
```

L3 只是在上面的基础上多一步：用 fivem-mcp 的 `client_command` 让客户端连服，再 `tc_probe`。

### 3.6 Agent 的正确用法

| 场景 | 谁做 | 怎么做 |
|:---|:---|:---|
| 生成用例 | Agent | 读资源代码 → 输出 `tests/e2e/test_*.py` + 探针调用 |
| 执行 | CI / runner | 确定性跑，Agent 不参与 |
| 失败定位 | Agent | 读 `[TC-TEST]` 日志 + 截图 + 资源源码，给假设 |
| 探索 | Agent | 截图 → 决策 → 键鼠，找"没人写过用例"的问题 |
| 断言 | **不要给 Agent** | 必须 `ok == true` |

这条边界如果破了，整套东西会退化成"每次都要人看一眼的演示"。

### 3.7 CI 编排

```yaml
jobs:
  e2e-server:            # Linux，每次 PR
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f tests/e2e/docker-compose.yml up -d
      - run: python3 -m pytest -q tests/e2e --ignore=tests/e2e/client

  e2e-client:            # Windows + GPU，nightly / 手动
    runs-on: [self-hosted, windows, gpu]
    if: github.event_name == 'schedule'
    steps:
      - run: python3 -m pytest -q tests/e2e/client
```

`tests/e2e/docker-compose.yml` 直接基于 `routmoute/fxserver:recommended`，挂载 `T-CityLite.base` 的 `resources/` 和一份**测试专用** `server.cfg`（独立 license key、`sv_devMode`、关掉 voice/asset escrow）。

### 3.8 两周 MVP

| 天 | 交付 | 验收 |
|:---|:---|:---|
| 1–2 | Docker FXServer 跑起来，测试 cfg + license | `Started resource qb-core` |
| 3–4 | `tc_test_probe` 服务端半 + `tc_assert` | 3 个断言能过/能红 |
| 5–6 | pytest runner + 日志解析 | CI 上 1 个 job 绿 |
| 7–8 | 5 个真实用例（钱、物品、权限、事件、资源启动） | 故意改坏代码能红 |
| 9–10 | 客户端探针 + `client_command connect` | 客户端能连、能 `tc_probe` |
| 11–12 | 截图证据 + 失败归档 | 失败时附 PNG + 日志 |
| 13–14 | Agent 提示词（生成/定位）+ 文档 | 一个新资源能自动补 3 条用例 |

---

## 4. 坑（按踩到的概率排序）

1. **license key**：FXServer 无 key 不启动。CI 用独立 key 放 secrets，别用生产 key。
2. **客户端不可 headless**：L3 必须真机。别指望 GitHub 托管 runner。
3. **Enhanced 客户端**：devcon 链路可能失效，迁移前先验证。
4. **devcon 无鉴权**：`127.0.0.1` 兜底，永远不要 `-devcon` 暴露到公网。
5. **截图成本**：一张 PNG 进上下文很贵，能 `probe` 就别截图；截图只做失败证据。
6. **flaky**：加载时间、流式资源、`CreateThread` 时序。所有等待都要 `wait_for(pattern, timeout)`，禁止 `sleep`。
7. **资源重启崩溃**：客户端在附近时重启 stream 资源（navmesh）会崩客户端——测试用例要避开或先传送。
8. **测试污染**：E2E 必须用独立数据库 + 每用例 `runId` 隔离，别打生产库。

---

## 5. 参考

- Cfx 论坛：[LUA unit testing with fxserver](https://forum.cfx.re/t/lua-unit-testing-with-fxserver/5321988)
- 客户端驱动：[VIRUXE/fivem-mcp](https://github.com/VIRUXE/fivem-mcp)、[ziyacivan/fivem-mcp](https://github.com/ziyacivan/fivem-mcp)
- 服务端单测：[fivem-test-harness](https://www.npmjs.com/package/@mriqbox/fivem-test-harness)、[fivem-devkit](https://www.npmjs.com/package/@aeterna_game/fivem-devkit)
- FXServer 容器：[routmoute/fxserver](https://github.com/routmoute/fxserver)
- 借鉴范式：[Plugwright](https://github.com/Drownek/plugwright)、[mod-playerbots](https://github.com/mod-playerbots/mod-playerbots)
- 引擎侧：[Unreal MCP](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)、[AltTester](https://alttester.com)、[GameDriver](https://gamedriver.io)
- 视觉 Agent：[SIMA 2](https://deepmind.google/blog/sima-2-an-agent-that-plays-reasons-and-learns-with-you-in-virtual-3d-worlds/)、[Airtest](https://airtest.doc.io.netease.com/)
- 版本差异：[What's Changed in FiveM for GTAV Enhanced](https://docs.fivem.net/docs/developers/legacy-vs-enhanced/)

---

## 6. 落地状态（2026-10-22）

本文的 L3 客户端层已经用 **MCP + FiveM Legacy devcon** 做了第一版：

- 宿主机 Node 24 + `fivem-mcp-server`，通过 FXServer 30120 的 HTTP 轮询桥接到 VM；
- 可用工具：`client_command`、`screenshot`、`read_client_log`、`server_info`、
  `server_command`（RCON）、`launch`、`focus_window`；
- 客户端命令 `questrestore` / `decision` / `nuitest` 让测试不依赖鼠标；
- 服务端用 `player_quests` / `player_choices` / `[client-telemetry]` 做确定性断言。

仍然存在的限制：

1. 当前环境下 MCP 合成鼠标/键盘没有送达 CEF/NUI；真实 NUI 点击需人工冒烟，
   自动化用 `nuitest` 钩子验证 fetch 链路。
2. devcon/`read_console` 有竞态，优先 `read_client_log`；不要高频 attach。
3. Enhanced 客户端没有 devcon，迁移前必须重测客户端链路。

详细操作见 `T-CityLite.base/docs/agent/CLIENT_HARNESS.md`。
