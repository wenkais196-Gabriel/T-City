# Convars 全集索引

> 覆盖所有模块 CFG 中定义的服务器变量

---

## 经济 Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `economy_reward_scale` | 1.0 | 全局奖励倍率 | economy.cfg |
| `economy_price_scale` | 1.0 | 全局物价倍率 | economy.cfg |
| `economy_sample_window_minutes` | 60 | 自适应统计窗口 (min) | economy.cfg |
| `economy_high_inflation_net_per_hour` | 150000 | 通胀阈值 ($/h) | economy.cfg |
| `economy_low_activity_net_per_hour` | 30000 | 冷清阈值 ($/h) | economy.cfg |
| `economy_scale_step` | 0.05 | 自适应微调步长 | economy.cfg |
| `economy_min_reward_scale` | 0.8 | 奖励下限 | economy.cfg |
| `economy_max_reward_scale` | 1.4 | 奖励上限 | economy.cfg |
| `economy_discord_webhook` | "" | 经济日志 Webhook | economy.cfg |
| `economy_wage_multiplier` | 100 | 工资倍率 (整数, /100) | core-framework |

---

## 安全 Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `security_rate_limit_ms` | 1000 | 敏感事件速率限制 (ms) | security.cfg |
| `security_max_add_money_limit` | 50000 | 单次最大加钱 | security.cfg |
| `security_max_add_item_limit` | 20 | 单次最大物品数 | security.cfg |
| `security_max_interaction_distance` | 10.0 | 最大交互距离 (m) ⚠️ 未执行 | security.cfg |
| `security_check_vehicle_spawn` | true | 车辆生成校验 | security.cfg |
| `security_check_weapon_give` | true | 武器赐予校验 | security.cfg |
| `security_discord_webhook` | "" | 安全警报 Webhook | security.cfg |

---

## 犯罪 Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `crime_enable` | true | 犯罪总开关 | crime.cfg |
| `crime_enable_storerobbery` | true | 商店抢劫开关 | crime.cfg |
| `crime_enable_houserobbery` | true | 房屋抢劫开关 | crime.cfg |
| `crime_enable_drugs` | true | 毒品开关 | crime.cfg |
| `crime_cooldown_storerobbery` | 1800 | 商店抢劫 CD (s) | crime.cfg |
| `crime_cooldown_houserobbery` | 1800 | 房屋抢劫 CD (s) | crime.cfg |
| `crime_cooldown_drugs` | 300 | 毒品 CD (s) | crime.cfg |
| `crime_min_police_storerobbery` | 2 | 最少警察数 | crime.cfg |
| `crime_min_police_houserobbery` | 2 | 最少警察数 | crime.cfg |
| `crime_min_police_drugs` | 0 | 最少警察数 | crime.cfg |
| `crime_min_police_launder` | 0 | 最少警察数 | crime.cfg |
| `crime_launder_rate` | 0.75 | 洗钱折旧率 | crime.cfg |
| `crime_launder_min` | 1000 | 最低洗钱金额 | crime.cfg |
| `crime_cooldown_launder` | 60 | 洗钱 CD (s) | crime.cfg |

---

## 车辆 Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `vehicle_dashboard_key` | I | 中控屏快捷键 | vehicles.cfg |
| `megaphone_voice_range` | 50.0 | 喊话器范围 (m) | vehicles.cfg |

---

## Core Framework Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `dirty_flush_tick_interval` | 900 | 脏数据刷盘间隔 (s) | core-framework |

---

## 任务 Convars

| Convar | 默认值 | 说明 | 文件 |
|:---|:---|:---|:---|
| `quest_enable` | true | 任务系统开关 | quest.cfg |
| `quest_max_active` | 3 | 最大活跃任务数 | quest.cfg |
| `quest_accept_cooldown` | 5 | 接取冷却 (s) | quest.cfg |
| `quest_nonce_expiry` | 30 | Nonce 过期 (s) | quest.cfg |
| `quest_rate_limit_ms` | 1000 | 速率限制 (ms) | quest.cfg |
| `quest_max_reach_distance` | 25 | 到达距离 (m) | quest.cfg |
| `quest_enforce_nonce` | true | 强制 Nonce | quest.cfg |
| `quest_enforce_step_order` | true | 强制步顺序 | quest.cfg |
| `quest_use_scaled_money` | true | 使用缩放经济 | quest.cfg |
| `quest_default_account` | bank | 默认奖励账户 | quest.cfg |

---

## QBCore 标准 Convars

| Convar | 说明 |
|:---|:---|
| `qb_locale` | 语言 (zh-cn) |
| `UseTarget` | 使用 qb-target (true) |
| `voice_useNativeAudio` | VOIP 原生音频 |
| `voice_useSendingRangeOnly` | 仅发送范围 |
| `voice_defaultCycle` | 默认语音周期 (GRAVE) |
| `voice_defaultVolume` | 默认音量 (0.3) |
| `voice_enableRadioAnim` | 无线电动画 |
| `voice_syncData` | 语音数据同步 |

---

## 服务器 Convars

| Convar | 说明 |
|:---|:---|
| `sv_maxclients` | 最大玩家数 (48) |
| `sv_hostname` | 服务器名称 |
| `sv_enforceGameBuild` | 强制游戏版本 (3258) |
| `sv_licenseKey` | 服务器许可证 |
| `mysql_connection_string` | 数据库连接串 |
| `steam_webApiKey` | Steam API Key |
