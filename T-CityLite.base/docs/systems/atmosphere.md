# T-City Atmosphere — 游戏内氛围音乐系统

> v1.0 | 2026-06-19

---

## 架构

```
加载画面 (qb-loading)              游戏内 (tcity-atmosphere)
────────────────────              ──────────────────────────
曲1→曲2→曲3 顺序, 5s 交叉淡入       Bus Service + NUI + Howler.js
加载完成自动销毁                    场景驱动 + 沉默间隙
                                   事件驱动, 零 Tick
```

---

## 五部曲

| # | 曲名 | 文件 | 场景 | BPM |
|:---|:---|:---|:---|:---|
| 1 | Dusk Prelude | `dusk_prelude.mp3` | default / respawn | 72 |
| 2 | City Lights Pulse | `city_lights_pulse.mp3` | default | 90 |
| 3 | Last Call Reprise | `last_call_reprise.mp3` | default / complete | 78 |
| 4 | Concrete Shadows | `concrete_shadows.mp3` | chase | 105 |
| 5 | Glass and Bone | `glass_and_bone.mp3` | danger | 52 |

---

## 场景

| 场景 | 曲目 | 音量 | 触发 |
|:---|:---|:---|:---|
| `default` | 曲池随机 (1/2/3) | 0.08 | 进服 / 重生 / chase超时 |
| `silent` | 无 | — | `/atmos silent` |
| `chase` | 曲4 | 0.15 | 抢劫 / 追逃 → 5min 超时回落 |
| `danger` | 曲5 | 0.12 | 制毒 raid → 5min 超时回落 |
| `respawn` | 曲1 | 0.10 | 玩家死亡 |
| `complete` | 曲3 | 0.10 | 服刑完成 |

---

## 沉默间隙（default 场景）

曲终后随机等待 8-15 分钟沉默，然后从曲池随机挑一首播放。

```lua
-- config/scenes.lua
['default'] = {
    trackPool   = { 'dusk_prelude', 'city_lights_pulse', 'last_call_reprise' },
    volume      = 0.08,
    silenceMin  = 480,   -- 秒
    silenceMax  = 900,
    trackDuration = 120,
}
```

---

## 安全链

| 层 | 检查 | 规则 |
|:---|:---|:---|
| Source | `src > 0` + `GetPlayerName` | 拒绝离线/伪造 |
| Sanitize | 场景白名单 + 音量 0.0-1.0 | 拒绝非法输入 |
| Cooldown | 仅同场景重复时检查 | chase 60s / danger 30s |
| Priority | 不打断高优先级 | respawn(20) > chase(10) > complete(5) > default(0) |
| RateLimit | 10s 窗口 ≤ 3 次 | 防刷屏 |

---

## 触发点

| 事件 | 资源 | 场景 |
|:---|:---|:---|
| 进服 | `PlayerLoaded` | default |
| 重生 | `qb-ambulancejob/server/main.lua:40` | default |
| 死亡 | `qb-ambulancejob/server/main.lua:157` | respawn |
| 抢劫开始 | `qb-storerobbery/server/main.lua:469` | chase |
| 追逃触发 | `qb-policejob/server/vehicle.lua:95` | chase |
| 制毒 raid | `custom-cartel/server/drug_lab.lua:226` | danger |
| 服刑完成 | `custom-justice/server/prison.lua:126` | complete |

---

## 命令

```
/atmos chase      曲四 (追逃)
/atmos danger     曲五 (危险)
/atmos respawn    曲一 (死亡)
/atmos complete   曲三 (完成)
/atmos default    沉默间隙模式
/atmos silent     静音
/atmos reset      强制回到 default
/atmos stop       停止
/atmos info       当前状态
/atmos vol 0.15   音量 (0-1)
```

---

## 文件

```
[system]/tcity-atmosphere/
├── fxmanifest.lua
├── config/scenes.lua
├── server/atmosphere_service.lua
├── client/atmosphere_nui.lua
├── html/index.html
├── html/atmosphere.js
└── assets/audio/*.mp3 (5)

[qb]/qb-loading/html/
├── app.js          (Playlist 引擎)
└── index.html

configs/modules/atmosphere.cfg

[custom]/custom-testing/suites/
└── 09_atmosphere_test.lua
```

---

## 扩展

新增场景：`config/scenes.lua` 加一行 + `Bus.SafeCall('atmosphere', 'PlayScene', src, '新场景')`

新增曲目：放入 `assets/audio/`，config 中引用
