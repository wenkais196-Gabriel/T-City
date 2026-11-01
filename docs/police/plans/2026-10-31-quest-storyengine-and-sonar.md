---
id: police-plans-2026-10-31-quest-storyengine-and-sonar
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
---

# 两个遗留问题：调研 → 方案 → 验证（2026-10-31）

## 1. `No such export IsArcEnabled in resource story-engine`

### 调研（实际证据）

| 观察 | 证据 |
|---|---|
| 报错点在 **不是调用点**，而是在守卫函数里 | `quest_availability.lua:67` 就是 `if target == nil or type(target[method]) ~= 'function' then return nil end` |
| 导出确实存在 | `story-engine/server/main.lua:170` 有 `exports('IsArcEnabled', ...)`，启动横幅也列出 9 个导出 |
| **资源当时没跑** | 日志里先出现报错，后来 `ensure story-engine` 才有 `Started resource story-engine`；`configs/modules/story.cfg` 里有 `ensure story-engine`，但这一轮没被 exec 过 |
| 关键机制 | FiveM 的 `exports['res']` 是**代理表**，索引一个未注册的导出会**直接抛错**，而不是返回 nil |

### 结论

两层问题：

1. **代码层（真 bug）**：`callExport` 想用 `type(target[method])` 判断导出是否存在，但这一步本身就会抛错 —— 守卫写在崩溃点的右边。
2. **环境层**：`story-engine` 没被拉起，等于把"剧情线是否开放"的检查全变成异常路径。

### 方案

| 层 | 做法 |
|---|---|
| 代码 | 把**索引本身**包进 `pcall`：`local ok, target = pcall(function() return exports[res] end)`，再 `pcall(function() return target[method] end)`；任何一步失败都返回 `nil`（语义仍是"跳过这项检查"） |
| 环境 | `ensure story-engine`，并确认 `configs/modules/story.cfg` 已 exec |
| 闸门 | 合并后的 P6 闸门保留"promote/export 契约"检查；本项由真机验证（重启 `custom-quest` 后 SCRIPT ERROR 新增 0） |

### 验证

| 项 | 结果 |
|---|---|
| `restart custom-quest`（story-engine 已在跑） | SCRIPT ERROR 新增 **0** |
| 报错消失 | 日志里 `IsArcEnabled` 相关行不再新增 |

---

## 2. SonarCloud `C Maintainability Rating on New Code`

### 调研

| 尝试 | 结果 |
|---|---|
| `api/issues/search?...&inNewCodePeriod=true` | `total: 0`（项目私有，匿名读不到） |
| `api/measures/component` | `Project doesn't exist` → 私有项目，需要 token；本机没有 |
| 本地量化替代 | 8 个 `test_p6*.py`，共 459 行，**14 行在 ≥3 个文件里重复**（`REPO = ...`、`src = X.read_text()`、`assert at != -1` 等样板） |

结论：拿不到 Sonar 的具体 issue，但**新增代码里唯一显著的重复源就是这 8 个测试文件互相复制的样板**，与"New Code 上判 C（重复密度）"完全吻合。上一版另外抽出 `{#snippet}` 消除了 MDT 模板里的重复，Sonar 仍红，说明剩下的重复在 Python 侧。

### 方案

把 8 个 P6 闸门文件合并成 1 个 `test_p6_agent_stack.py`：

- 共用一份 `REPO / ROOT / POLICE / DIRECTOR / PHONE` 路径与 `read()` / `block()` / `registry_tool()` 辅助；
- 按 §1 只读通道 / §2 动作层 / §3 策略接线 / §4 草稿箱分组，保留原有全部断言；
- 删除 8 个旧文件。

### 验证

| 项 | 结果 |
|---|---|
| 新文件用例数 | 23 passed |
| 全量 pytest | **1306 passed** / 150 skipped / 767 subtests |
| 覆盖率棘轮 | 合并后未证明规则从 267 降到 **259**，`max_unproven` 同步下调（棘轮只许往下走） |
| 重复 | 跨文件重复从 14 处降到 0（单文件内不再有样板复制） |

> 说明：Sonar 是否转绿要等 CI 跑完才知道；若仍红，说明还有别的新代码重复源（例如 Svelte 侧），需要拿到 token 才能定位。
