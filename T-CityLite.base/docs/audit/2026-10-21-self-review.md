# 自审记录 — Phase 1 审查与修复分支合并

> **日期**: 2026-10-21
> **分支**: `fix/foundation-audit-2026-10-21` → `master`
> **范围**: 16 个提交 / 72 个文件（+3162 / −321）
> **审查人**: 本轮执行 agent（维护者授权自审自合并）

---

## 1. 审查范围

| 提交组 | 内容 |
|:---|:---|
| `fix(boot)` | core-framework 清单、启动顺序、MySQL lib、缺失依赖 |
| `fix(persistence)` | qb-core 刷盘 tick、停机刷盘、断线位置回退 |
| `fix(quest)` | 任务四表迁移、冷却、步骤校验、组队锁、缓存、奖励幂等 |
| `fix(story)` | 决策 pending/超时/上下文绑定、登录事件名 |
| `fix(security)` | 自动 admin、热狗/赛车印钞、载具鉴权、司法、经济出口、死亡/通缉/车牌事件 |
| `fix(bus)` | 9 个注册方 include `bus.lua`；19 处 `Bus.PascalCase` → 显式 export |
| `fix(core)` | `GetPlayer` 缓存活性校验 |
| `chore(dev)` | `custom-testing` 移出生产、hook 路径修复 |
| `test(ci)` | Bus 接线检查接入 CI / `run_all.py` |
| `docs` | 审查报告、Agent 导演设计、CHANGELOG、DEVOPS、自审记录 |

## 2. 自动化验证

| 检查 | 结果 |
|:---|:---|
| `python3 tests/check_cfgs.py` | ✅ exit 0（80 个 ensure 目标全部存在，无重复） |
| `python3 tests/check_dependencies.py` | ✅ exit 0（无缺失依赖 / 无启动顺序冲突 / 无循环依赖） |
| `python3 tests/check_bus_wiring.py` | ✅ exit 0（0 error；1 条 warning：custom-phone 有 fallback） |
| `luac5.4 -p`（42 个改动 Lua） | ✅ 全部通过 |
| `git diff --check` | ✅ 无空白错误 |
| 密钥/私钥/Webhook 扫描 | ✅ 未发现新增敏感值 |
| 冲突标记扫描 | ✅ 无（仅注释分隔线误报） |
| `run_all.py` | ⚠️ 4/5；`light_lint.py` 对全仓（含第三方资源）报 252 errors / 96411 warnings，基线既有，非本轮引入 |

## 3. 人工审查结论

**Blocking：0。**

逐项确认：

- **任务奖励幂等**：`GrantRewards` 仅在 `affectedRows > 0` 回调内执行；`_completing` 使用唯一 token，10s 超时只清除自己持有的锁；迟到回调在 `affected=0` 时跳过副作用；`FailQuest` / `AbandonQuest` 清理步骤与锁。
- **步骤顺序**：`_currentSteps` 在接取/推进/完成/失败/放弃维护；`ValidateStepOrder` 缓存空窗期不再直接放行，改为内存步骤比对。
- **Bus**：`service_<name>_<method>` 与注册处逐一对照；所有调用带 `GetResourceState` + `pcall`，失败保留原 fallback；`@core-framework/bus.lua` 均位于 `server_scripts` 首行，无重复。
- **安全事件**：`ResetDeathStatus` 仅在医疗未启用且服务端判定死亡/倒地时允许；`policeHandoverAlert` 在写 `wanted/criminalrecord` 前完成校验；`plateFlagged` 要求值班 LEO/admin，内部同步已改为本地调用。
- **兼容性**：`GetPlayer` 缓存活性校验改用 `GetPlayerName`；`custom-testing` 迁移到 `dev.cfg`，生产模板保持注释。
- **无运行时可验证性**：本机没有 FXServer `alpine/` 运行时，启动冒烟与 24h 压测仍是发布前必须项。

## 4. 已知限制（不阻塞合并）

1. `nodeComplete` 仍跳过 nonce —— 客户端从不请求/回传 nonce，恢复需同时改客户端与 ExecuteNode，另开 Issue。
2. `custom-phone` 仍有一处 `_G.Bus.EconomyService` 引用，已有人工 fallback。
3. `world_state` 的 `Citizen.Await` 同步读与 `prepare` 返回结构问题未在本轮修复。
4. 真实 FXServer 启动、数据库迁移执行、48 人压测未执行。
5. 两个独立复核 agent 因时间盒未返回报告，本轮以本地静态检查 + 逐文件 diff 复核替代。

## 5. 合并决定

- 方式：`git merge --no-ff` 到 `master`，保留 16 个可追溯提交。
- 理由：所有 P0/P1 静态缺陷已修复并通过检查；剩余项已记录在审查报告与已知限制中，不构成合并阻塞。
- 合并后动作：推送 `master`；建议在 GitHub 上为该 merge commit 建 tag（如 `v0.7.1-phase1`）并执行真实启动冒烟。

---

## 6. 复现命令

```bash
cd T-CityLite.base
python3 tests/check_cfgs.py
python3 tests/check_dependencies.py
python3 tests/check_bus_wiring.py

cd ..
git diff --check master...HEAD
while IFS= read -r f; do
  case "$f" in *.lua) luac5.4 -p "$f" || exit 1;; esac
done < <(git diff --name-only master...HEAD)
```
