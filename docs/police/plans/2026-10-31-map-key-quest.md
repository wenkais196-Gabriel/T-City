---
id: police-plans-2026-10-31-map-key-quest
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
---

# 三个体感问题：小地图 / I 键 / 序章 node（研究 → 计划）

> 用户观察到的三件事，逐个溯源。全部先给证据，再给改法。

## 1. 左下角小地图「大小、边界、位置都变了」

### 调研

| 观察 | 证据 |
|---|---|
| 有个资源在**改小地图组件位置** | `T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:80` 调 `SetMinimapComponentPosition` |
| 它在启动时无条件应用 | 同文件 `CreateThread(... applyMap() ...)`（第 339–347 行） |
| 默认值不是原生 | `mapScale = 87.5`（即 87.5% 尺寸）、`mapShape = 'circle'`、`minimapOffset` 会叠加偏移 |

**结论**：小地图被 HUD 位置调试工具按"圆形 + 87.5% + 自定义偏移"重排了，跟原生（方形、100%、原生位置）当然不一样。

### 目标（用户原话）

- **步行：没有小地图**
- **在载具上：与原生显示完全一致**（功能与风格都一致）

### 改法

| 改动 | 说明 |
|---|---|
| `hud-position-tool` 加开关 `hud_position_tool`（默认 `0`） | 关闭时 `applyMap()` 直接返回，不再改任何组件 → 小地图回原生 |
| 新增雷达可见性跟随载具 | 每 1s：`DisplayRadar(IsPedInAnyVehicle(ped, false))`；在载具上开、步行关 |
| 警察摄像机（bodycam 视图）已有 `DisplayRadar` 调用 | 保持不变：录制时它自己管 |

## 2. `I` 键唤不出车载面板

### 调研

| 观察 | 结论 |
|---|---|
| 只有一处绑定 `I` | `tcity-dashboard/client/main.lua:353`，无其它资源抢键 |
| 资源确实加载了 | 日志 `[client-ready] tcity-dashboard v2.1.0` |
| 命令里有三个早退分支 | ①别的界面占着输入（`custom-ui:Top()`）②不在载具 ③去抖 250 ms 内重复 |
| 三个分支都**只弹 notify、不打日志** | 所以从现有日志**无法判断**是哪一条挡住的 |

**结论**：不是"没绑定"，而是"被某个早退分支挡住且没有证据"。需要先埋点，再定位。

### 改法

在命令入口加 `dashboard_debug` 诊断（默认关）：打印 `enter / blocked:taken:<id> / blocked:no_vehicle / blocked:debounce / open`，
这样按一次 `I` 就能在客户端日志里看到确切原因。**先诊断，不瞎改。**

## 3. 警察序章仍然触发不了下一步 node

### 调研（这次挖到底了）

| 观察 | 证据 |
|---|---|
| `quest:client:nodeGoto` → `SetupReachZone(data, …)` | 上一轮补的 `REACH → nodeGoto` 映射是对的 |
| `SetupReachZone` **只在 `if PolyZone then` 里面建区** | `custom-quest/client/main.lua:75` |
| `PolyZone` 是**资源内全局**：`PolyZone = {}` 定义在 PolyZone 自己的 client.lua | `[standalone]/PolyZone/client.lua:2` |
| FiveM 每个资源的脚本环境互相隔离 | 所以 custom-quest 里的 `PolyZone` 恒为 **nil** |
| 结果 | `if PolyZone then` 永远不成立 → **检测区从来没被创建** → 玩家走到警署也不会推进 |

**结论**：上一轮修好的是"节点没下发"，这一轮暴露的是"下发之后建不出检测区"。两个 bug 串在一起，
所以症状一直是"接得到任务、走到点没反应"。

### 改法

在 `SetupReachZone` 里加**纯距离轮询兜底**（不依赖任何外部资源）：

```
每 500ms：距离 ≤ radius 且 activeQuest.current_step == stepId 且未触发过
      → 请求 nonce → TriggerServerEvent(quest:server:reach, questId, stepId, nonce)
离开 → 重置触发标记
```

PolyZone 分支保留（将来若在 manifest 里 `client_script '@PolyZone/client.lua'` 就能用），
但目前**以轮询为准**。

## 4. 验收

| 项 | 判据 |
|---|---|
| 小地图 | 步行时无雷达；上车后雷达尺寸/位置/风格与原生一致（`hud_position_tool=0`） |
| `I` 键 | 按一次后客户端日志出现 `[dashboard] enter` → 后续行说明是开还是被哪条挡住 |
| 序章 | 重新接任务 → 走到 Davis 警署 → 客户端日志 `[quest-reach] triggered` + 服务端收到 `quest:server:reach` |
