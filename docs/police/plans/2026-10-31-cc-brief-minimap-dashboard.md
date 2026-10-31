# 任务：小地图回原生 + 车载面板诊断（给 Claude Code）

## 背景（已完成的调研，别重复）

1. **小地图被改坏**：`T-CityLite.base/resources/[custom]/hud-position-tool/client.lua` 用
   `SetMinimapComponentPosition` 改组件，其 `basePositions.square` 的 mask/blur 尺寸（0.262×0.300）
   **远大于 GTA 原生**，导致地图内容溢出边框、原生距离文字跑到框外。
   原生默认值（来自 `common:/data/ui/frontend.xml`，Cfx 论坛两处引用一致）：

   ```
   minimap      L B  -0.0045, 0.002, 0.150, 0.188888
   minimap_mask L B   0.020, 0.032, 0.111, 0.159
   minimap_blur L B  -0.03,  0.022, 0.266, 0.237
   ```

   注意：`SetMinimapComponentPosition` 改的是**客户端会话内**的状态，资源重启不会自动复位，
   所以必须**显式写回原生值**。另有一个已知问题：`minimap` 组件不会立即重绘，
   Cfx 官方给的解法是 `SetRadarBigmapEnabled(true,false)` → Wait → `SetRadarBigmapEnabled(false,false)`
   （或 `SetBigmapActive(true/false)`）。

2. **车载面板 `I` 键没反应**：客户端日志显示每次按键出现 **两条** `[dashboard] enter`
   （`RegisterCommand` 在资源重启后重复注册），且有一条 `enter` 之后**没有任何后续日志**就结束 ——
   说明走了两个**没埋点**的分支之一：
   - `_openSeatPicker(...)`：后排乘客分支
   - `_closeNui()`：`_isDashboardOpen` 为 true 但界面其实已经关掉（状态卡住）

## 要做的改动

### A. 小地图显式回原生（`hud-position-tool/client.lua`）

1. 保留现有 `hud_position_tool` 开关；当开关为 **关闭**（默认）时：
   - 显式把三个组件写回上面的原生值（不要"什么都不做"，因为旧值会残留）；
   - 写完后做一次 bigmap 刷新（`SetRadarBigmapEnabled(true,false)` → `Wait(200)` → `SetRadarBigmapEnabled(false,false)`），必要时重复一次；
   - 在 `onClientResourceStart` 与 convar 变化时都执行一次，保证重启后也对。
2. 开关打开时保持现有行为（位置调试工具可用），但**把预设值改成原生值**再叠加偏移，避免再次溢出。

### B. 车载面板（`[system]/tcity-dashboard/client/main.lua`）

1. 给那两个没埋点的分支加 `dbg`：`blocked:seat_picker`、`toggle:close`、`toggle:open`。
2. `_isDashboardOpen` 卡住的场景要**自愈**：判定为"打开"之前，用
   `pcall(function() return exports['custom-ui']:Top() end)` 检查栈顶是否真的是 dashboard 帧；
   不是就把本地标志清掉当关闭处理。
3. 消除重复注册：`RegisterCommand('dashboard', ...)` 只在**首次**注册（用 `_dashboardCommandRegistered` 之类的本地标志 + `GetResourceState` 判断），
   或在重复注册时先 `RegisterCommand` 覆盖（同名命令后注册者覆盖先注册者，需确认只留一份）。
   用日志（`[dashboard] register`）证明只注册一次。

## 约束（必须遵守）

- 改完跑：`python -m pytest tests/tools T-CityLite.base/tests/architecture T-CityLite.base/tests/unit -q`（用 `C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe`）
  与 `python tools/dev/release_check.py`，必须全绿。
- `luac5.4 -p` 检查每个改过的 Lua 文件。
- 新增闸门（`T-CityLite.base/tests/architecture/test_p6_agent_stack.py` 末尾，§9）：
  1. 原生三行数值必须出现在 hud-position-tool 里（防再次漂移）；
  2. dashboard 必须有 `blocked:seat_picker` / `toggle:open` / `toggle:close` 诊断与 `custom-ui:Top()` 自愈。
- 不要改 `[qb]` 上游；不要动 `server.cfg`；不要提交 `node_modules`。
- 完成后在分支 `fix/minimap-native-and-dashboard` 上提交一次，**不要 push、不要开 PR**，把提交 hash 与测试摘要返回给我。
