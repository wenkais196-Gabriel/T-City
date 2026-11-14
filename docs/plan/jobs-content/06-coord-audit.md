---
id: jobs-content-06-coord-audit
type: audit
status: active
system: jobs
owner: hermes
updated: 2026-11-14
review_by: 2027-04-30
---

# 全量排查：78 个任务模板的坐标（阶段 V2）

> 工具：`T-CityLite.base` 之外的 `tools/dev/quest_map.py`（离线，不需要进游戏）。
> 方法见 `docs/engineering/QUEST_COORDS.md`。本文只放**结论与证据**。

## 1. 怎么查的

三步，逐级加成本：

1. **静态硬错误**（`--scan`，退出码非 0）：世界边界外、z 越界、占位 `(0,0,0)`。
2. **路网判据**（同一命令）：离最近路面节点 > 60 m、或与路面高差 > 25 m → 提示。
   数据是 DurtyFree 的 67,454 个车辆节点（水面节点已剔除）。
3. **人眼看联络图**（`--sheet`）：78 个模板全部渲染成 4 页卫星缩略图，逐格判断落在
   道路/人行道/空地，还是**建筑内部/楼顶/水面**。第 2 步抓不到「在楼里但离路 20 m」这种情况
   —— 热狗摊就是这一类，只能靠眼睛。

## 2. 结论

| 结果 | 数量 |
|---|---|
| 硬错误（一定到不了） | **0** |
| 本轮修掉 | **14 个模板** |
| 已解释、无需改动 | 5 个（采石场泥路 / 海滩终点 / 飞行类） |
| 剩余「待查」 | **0** |

## 3. 修掉的 14 个

### 3.1 落在建筑内部 / 楼顶（7 个，靠联络图发现）

| 模板 | 问题 | 处理 |
|---|---|---|
| `hotdog_vendor` | 4 步在 Las Lagunas Blvd 东侧建筑内部 | 移到 Legion Square 广场 `(215.8, -810.3, 30.7)`，半径 8/5 m |
| `cartel_ch4_benevolent_king` | 3 步在庭院建筑室内 | 移到院内车道 `(1431.8, 1153.2, 113.2)` |
| `cartel_ch4_tyrant` | 3 步在同一栋建筑室内 | 同上；`raid_prep` 移到路口 `(1598.8, 1271.2, 88.2)` |
| `civilian_ch4_artisan` | 3 步在纺织厂建筑内部 | 移到 Spucci Blvd 路边 `(155.5, -1017.2, 28.4)` / `(138.2, -1011.8, 28.4)` |
| `civilian_ch4_survivor` | 同上 | 同上 |
| `civilian_ch4_mogul` | 3 步在 Arcadius 楼顶（z=150，比路面高 122 m，玩家上不去） | 移到楼下街面 `(-157.0, -903.5, 28.3)`，并把「站在顶层办公室」的文案改成「站在总部大楼楼下」 |
| `news_report` | 新闻社点在 Little Seoul 大楼里 | 移到路边 `(-591.8, -901.0, 24.7)` / `(246.0, -899.2, 28.1)` |

### 3.2 目的地是占位 `(0,0,0)`（7 个，靠路网判据发现）

`euro_trucking_steel` / `heavy_trailer` / `fuel_tanker` / `container_haul` / `car_transport` /
`oversized_construction` / `timber_haul`。`validate_delivery_arrival` 会拿 `destCoords` 算距离，
而原点在路面下方 70 m —— 卡车开到那儿也判不到，整条任务永远交不掉。已按主题换成真实目的地。

## 4. 已解释、不用改的 5 个

| 模板 | 为什么不算问题 |
|---|---|
| `miner_apprentice` / `miner_mid` / `miner_boss` / `civilian_ch1_first_dollar` | 都在 **Davis 采石场**，泥路不在车辆节点数据里（离路 438–456 m）。联络图上能看到进入矿区的路 |
| `cartel_ch4_fugitive` | 终点在北部**海滩**，车开不过去但可徒步；616 m 是节点数据盲区（那一带海边公路未收录），不是死点 |

## 5. 全量明细（48 个含坐标的模板）

> 只有含 `coords` 的模板会出现在这里（部分执照考试用 `script_trigger`，没有坐标）。
> 「最远离路 / 最大高差」取该模板所有步骤里最差的一个。

| 模板 | 点 | 最远离路 | 最大高差 | 结论 |
|---|---|---|---|---|
| `euro_oversized_construction` | 4 | 36 m | 8 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_timber_haul` | 4 | 26 m | 8 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_container_haul` | 4 | 18 m | 1 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_trucking_steel` | 4 | 17 m | 1 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_trucking_heavy_trailer` | 3 | 17 m | 1 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_fuel_tanker` | 4 | 15 m | 1 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `euro_car_transport` | 4 | 9 m | 4 m | 已修 · 目的地曾是占位 `(0,0,0)` |
| `hotdog_vendor` | 4 | 7 m | 1 m | 已修 · 4 步在 Las Lagunas Blvd 东侧建筑**内部** |
| `civilian_ch4_artisan` | 3 | 0 m | 0 m | 已修 · 3 步在纺织厂**建筑内部** |
| `civilian_ch4_survivor` | 3 | 0 m | 0 m | 已修 · 3 步在纺织厂**建筑内部** |
| `cartel_ch4_benevolent_king` | 3 | 0 m | 0 m | 已修 · 3 步在庭院建筑**室内** |
| `cartel_ch4_tyrant` | 3 | 0 m | 0 m | 已修 · 3 步在同一栋建筑**室内** |
| `news_report` | 6 | 0 m | 0 m | 已修 · 新闻社点在**大楼里**（Little Seoul 街区内部） |
| `civilian_ch4_mogul` | 3 | 0 m | 0 m | 已修 · 3 步在 Arcadius **楼顶**（比路面高 122 m） |
| `cartel_ch4_fugitive` | 3 | 616 m | 27 m | 已解释 · 终点在北部海滩：车开不过去，但可徒步；这一带路面节点稀疏，616 m 是数据盲区不是死点 |
| `miner_mid` | 2 | 456 m | 33 m | 已解释 · 同上（Davis 采石场） |
| `civilian_ch1_first_dollar` | 3 | 456 m | 13 m | 已解释 · 同一片采石场 |
| `miner_apprentice` | 2 | 455 m | 13 m | 已解释 · Davis 采石场，泥路不在车辆节点数据里 |
| `miner_boss` | 2 | 438 m | 13 m | 已解释 · 同上（Davis 采石场） |
| `aviation_medical_airlift` | 10 | 252 m | 287 m | 飞行类（高度不判） |
| `pilot_license_exam` | 10 | 88 m | 138 m | 飞行类（高度不判） |
| `cartel_ch2_territory_war` | 5 | 51 m | 13 m | OK |
| `bus_route` | 4 | 50 m | 13 m | OK |
| `cartel_weed_run` | 1 | 46 m | 2 m | OK |
| `aviation_smuggling_flight` | 5 | 46 m | 2 m | 飞行类（高度不判） |
| `vehicle_chop_shop` | 5 | 38 m | 18 m | OK |
| `civilian_ch3_cost_of_empire` | 3 | 34 m | 8 m | OK |
| `cartel_ch3_empire_shadow` | 4 | 31 m | 3 m | OK |
| `recycle_run` | 5 | 30 m | 10 m | OK |
| `police_ch3_abyss` | 4 | 29 m | 5 m | OK |
| `police_ch4_martyr` | 3 | 24 m | 2 m | OK |
| `civilian_ch2_startup_struggle` | 3 | 23 m | 5 m | OK |
| `cartel_ch1_first_blood` | 4 | 22 m | 2 m | OK |
| `police_ch4_silent_guardian` | 3 | 22 m | 2 m | OK |
| `tow_service` | 5 | 21 m | 1 m | OK |
| `euro_multi_stop_courier` | 13 | 21 m | 3 m | OK |
| `cartel_initiation` | 3 | 20 m | 2 m | OK |
| `police_ch1_first_shift` | 4 | 20 m | 2 m | OK |
| `police_ch2_corruption_web` | 4 | 20 m | 7 m | OK |
| `police_ch4_hero` | 3 | 20 m | 5 m | OK |
| `garbage_collection` | 5 | 19 m | 6 m | OK |
| `cartel_drug_run` | 3 | 18 m | 1 m | OK |
| `heavy_license_exam` | 4 | 17 m | 4 m | OK |
| `cartel_launder` | 1 | 17 m | 1 m | OK |
| `driver_license_exam` | 6 | 16 m | 4 m | OK |
| `taxi_fare` | 4 | 16 m | 1 m | OK |
| `euro_refrigerated` | 7 | 15 m | 1 m | OK |
| `miner_collector` | 1 | 13 m | 0 m | OK |

## 6. 还没覆盖的

| 项 | 说明 |
|---|---|
| 碰撞体细节 | 渲染只能判「落在什么地物上」，判不了台阶/围栏/门锁 |
| 室内点位 | QBCore 的室内是独立坐标空间，本工具按室外世界坐标算，室内模板需要单独标注 |
| 真机复核 | 14 处修复都是离线核对（离路距离 + 高差 + 渲染图），还没逐一进游戏走过 |
