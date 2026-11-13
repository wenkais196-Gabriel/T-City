---
id: jobs-content-05-verification
type: audit
status: active
system: jobs
owner: hermes
updated: 2026-11-13
review_by: 2027-04-30
stage: V1
---

# 验证：R1 就业循环 · garbage 真机跑通（阶段 V1）

> 阶段 V。**只放证据，不放结论**：每条都带可复现的来源（命令输出 / 日志行号 / 文件位置）。
> 覆盖范围 = `garbage_v1_city`（4 站）**一条**完整旅程；其余档位与 bus 见 §5「未覆盖」。

## 1. 自动化测试

```
$ cd T-CityLite.base && <python> -m pytest tests/unit/layer3_business/test_route_stop_validator.py -q
.........                                                                [100%]
9 passed in 0.16s

$ <python> -m pytest tests/unit/layer3_business/test_quest_availability.py -q
....                                                                     [100%]
4 passed in 0.07s

$ <python> -m pytest tests/unit/layer3_business/test_bus_route_config.py \
    tests/unit/layer3_business/test_garbage_route_config.py \
    tests/architecture/test_admin_commands_doc.py \
    tests/architecture/test_net_event_inventory.py -q
23 passed in 5.45s
```


全量回归（本轮所有改动落地后重跑）：

```
$ <python> -m pytest tests/unit tests/architecture -q
1427 passed, 147 skipped, 51 subtests passed in 318.45s (0:05:18)
```
本轮新增的两条断言（都在 route_stop 探针里）：

| 断言 | 要防的回归 |
|---|---|
| `NO_PLAYER_COORDS_SAFE` | 服务端取不到玩家坐标时必须返回 `no_player_coords`，不能 `#(nil - vector3)` 抛错 |
| `RUN_MESSAGE_PASSTHROUGH` | `QuestValidators.Run` 必须把校验器的第二个返回值带出来（`wrong_job` 等），不许压成 `'failed'` |

## 2. 反向校验（证明这条规则真的会红）

| 注入的错误形状 | 期望 | 实际 |
|---|---|---|
| 校验器里写裸 `QBCore`（本资源无该全局） | 站点点不动，日志给出真实原因 | 真机复现：`quest_route_validators.lua:58: attempt to index a nil value (global 'QBCore')` |
| `Run` 用 `local ok, result = pcall(...)` 只接两个值 | `RUN_MESSAGE_PASSTHROUGH` 应为 false | 未单独跑红（改动与新断言同批落地）→ 记为结构性证据，不是运行证据 |
| `GetEntityCoords` 返回 nil | `NO_PLAYER_COORDS_SAFE` 应为 false（旧实现抛错） | 同上 |

> 诚实标注：第 2、3 行的「换回旧实现必红」本轮**没有单独回滚取证**。它们的旧行为有真机日志支撑
> （第 1 行那次的报错文本正是旧实现的产物），但「断言本身能变红」这件事仍未取运行证据。

## 3. 静态检查

- `luac5.4 -p`：custom-quest 的四个服务端文件（route validators / validators / main / availability）全部通过。
- 清单顺序闸：`tests/architecture/test_quest_entrypoint.py` 绿（availability 模块仍在
  quest_manager 之后、main 之前）。
- net event 清单：重生成后 **439 事件 / 0 个资源有债**（`net_events_baseline.json`）。
- 管理员命令清单：`tools/dev/scan_commands.py` 重生成，**336 条命令**。
- 文档闸：`tools/docs_lifecycle.py --check` 与链接闸随全量回归一起跑。

## 4. 真机证据

服务器：FXServer `:30130`，**86 个资源**（85 应有 + `fivem-map-hipster`），整份控制台日志
`SCRIPT ERROR` = **0**。玩家 `ChillyOtter2835`（`DXI50064`），职业 `garbage` grade 0。

控制台日志（`%TEMP%\tcity_console.log`，行号为当次启动内序号）：

| 行号 | 内容 | 说明 |
|---|---|---|
| 2195 | `nodeComplete: src=3, quest=garbage_v1_city, step=step_report_in, nodeType=INTERACT` | 报到点按 E |
| 2198 | `ExecuteNode: step_stop_01, type=VALIDATOR, auto=nil` | 推进到第 1 站 |
| 2207 | `nodeComplete: step_stop_01` + 无 `validator failed` | **第 1 站校验通过**（修复前同一行会抛 QBCore nil） |
| 2210 | `ExecuteNode: step_stop_02` | 单调推进 |
| 2238 / 2241 | `step_stop_02` → `step_stop_03` | |
| 2256 / 2259 | `step_stop_03` → `step_stop_04` | |
| 2263 / 2266 | `step_stop_04` → `step_report_out, type=INTERACT, auto=true` | 最后一站后自动进入交回 |
| 2279 | `🏁 COMPLETING quest: garbage_v1_city, citizenid=DXI50064, src=3` | 任务结算 |
| 2280 | `💰 ChillyOtter2835 (DXI50064) quest=garbage_v1_city → $370 (bank), garbage rep +8` | 奖励金额与配置一致 |

对照 `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_garbage.lua` 的 `garbage_v1_city`：4 站 / $370 / 10 袋 → 日志金额与站数都对得上。

修复前同一玩家的失败证据（同一份日志）：

```
1735  ⚠️ validator failed: validate_route_stop | quest=garbage_v1_city |
      Validator error: @custom-quest/server/quest_route_validators.lua:58: attempt to index a nil value (global 'QBCore')
1745  （同上，第二次按 E）
```

## 5. 未覆盖的部分

| 项 | 为什么没测 | 谁来兜 |
|---|---|---|
| `garbage_v1_district`（6 站）/ `garbage_v1_full`（8 站） | 只跑通最短档，长档的站距与载具续航未验 | 下一轮真机 |
| `bus_v1_*` 三档 | 共享同一校验器与同一套配置形状，但 bus 的站点是主路近似坐标 | 下一轮真机（重点是站距与停车点是否合理） |
| 断线重连 / 服务器重启后中途接着跑 | 会话是内存态，只验过冷启动采纳站号的离线探针 | 下一轮真机：跑两站后重连 |
| 手机端任务列表（`GetAvailableQuests`）在本次修复后的真实排序与文案 | 修复了三个 fail-open 门控，玩家可见行为会变 | 下一轮真机打开手机任务 App 对照 |
| 结算落库（`player_quests` 状态、rep 持久化） | 未查 DB | 下一轮 `SELECT` 核对 |
| 薪资抑制（`PaycheckInterval` 覆盖钩子）与存量 7 条任务壳降价 | 本轮未动 | R2 第一项 |

## 6. 遗留（写进 CHANGELOG 或开 Issue）

1. `quest_logistics_validators.lua` 里 `KeyManager` 是 custom-vehicles 资源**内部**全局，跨资源恒
   nil → 车辆归属判断每次都回落到 DB 查询。功能正确、只是慢，记债不修。
2. `T-CityLite.base/resources/[custom]/custom-quest/config/quests/lego/bank_escort.lua` 只有 id/title/rewards、**没有 steps**，每次启动都会打
   `⚠️ Template bank_escort has no steps`。该模板永远无法完成。
3. `restart custom-quest` 会级联停掉 `custom-director` / `custom-vehicles` / `qb-mechanicjob` /
   `story-engine` 且不会自动拉回 —— 每次改 custom-quest 后必须手工 `start` 回来，否则玩家侧表现为
   「载具钥匙没了」这类静默失效。
4. `$370` 这一档对应约 1,388 $/h（见 `04-numbers.md`），而存量 7 条任务壳仍是 2k–8k $/h 的水位，
   玩家会优先刷旧壳 —— 数值收敛未做。
