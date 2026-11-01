---
id: engineering-consumables
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
---

# 消耗品与状态层（custom-consumables）

> 为什么有这个东西：本服**没有 qb-smallresources**，而 `qb-core` 只在
> `T-CityLite.base/resources/[qb]/qb-core/client/loops.lua` 里**读**
> `metadata.hunger` / `metadata.thirst` 来判断饿死扣血 —— 全仓没有任何地方写这两个值。
> 结果是：食物吃了不顶饿、HUD 永远 100、警用酒测也没有数据源。

## 1. 职责边界

| 谁 | 做什么 |
|---|---|
| `custom-consumables` | **唯一写者**：饥饿 / 口渴 / 酒精 / 药物读数；衰减线程；物品使用入口 |
| `qb-hud` | 只读 `metadata.hunger` / `metadata.thirst` 画条 |
| `qb-core` | 只读，用来判断饿到 0 扣血 |
| `custom-police`（酒测/药检） | 只读：`exports['custom-consumables']:GetAlcohol(cid)` |

一条规则：**任何地方要改这几个数，都必须经过这个资源**。第二个写者会让 HUD 与酒测互相打架。

## 2. 数据

状态存在 `PlayerData.metadata`：`hunger` / `thirst`（0–100）、`alcohol` / `drug_level`（0–1）。

| 配置 | 值 | 位置 |
|---|---|---|
| 衰减间隔 | 60 s | `config.lua` `DecayIntervalMs` |
| 饥饿衰减 | −1.0 / 次 | `DecayHunger` |
| 口渴衰减 | −1.2 / 次 | `DecayThirst` |
| 酒精代谢 | −0.01 / 秒 | `AlcoholDecayPerSecond` |
| 药物代谢 | −0.008 / 秒 | `DrugDecayPerSecond` |

物品表按类别分：饮料（`water` / `coffee` / `beer` / `vodka`）、食物（`sandwich` / `burger` / `taco` / `apple`）、
药物（`weed_white` / `weed_purple`）。每条带 `hunger` / `thirst` / `alcohol` / `drug` / `stress` / `cooldownMs`。

## 3. 安全

物品使用走 `qb-inventory:server:UseItem`，客户端可以伪造，所以服务端：

1. 只认 `Config.Consumables` 里有的物品；
2. **校验 `GetItemByName`** —— 没有这件物品的玩家发事件什么都不发生；
3. 每物品冷却（默认 2–6 s）。

## 4. 真机证据（2026-10-31）

```
consumables_status 6 → hunger=81.1 thirst=82.9
（70 秒后）           → hunger=80.1 thirst=81.7
```

正好是配置的 −1.0 / −1.2 每分钟。

## 5. 与警用酒测的关系

`custom-police` 的 `police:server:fieldTest` **优先**读本资源：

```lua
if GetResourceState('custom-consumables') == 'started' then
    value = exports['custom-consumables']:GetAlcohol(cid)
end
```

资源不在时才回退到 `custom-police` 自带的 `Sobriety`（P3-2 的临时实现，将来可以删）。
