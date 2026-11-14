---
id: engineering-quest-coords
type: runbook
status: active
system: infra
owner: hermes
updated: 2026-11-14
review_by: 2027-04-30
---

# 任务坐标怎么离线核对（不进游戏）

> 一次要校 78 个模板 / 179 个坐标点。靠肉身进游戏跑一遍才能发现「点在大楼里 / 半空 / 水里」，
> 成本付不起 —— 而这类错误在数字上完全看不出来：`(-150, -250, 44)` 看起来像一组正常坐标，
> 实际落在 Las Lagunas Boulevard 东侧一栋建筑的**内部**，玩家走过去既进不去也没有交互。

## 工具

`tools/dev/quest_map.py`：把任务配置里的坐标换算成像素、抓 GTA 地图瓦片、画成 PNG。

```bash
# 一条任务的全部步骤点
python tools/dev/quest_map.py --quest hotdog_vendor --style satellite --scale 5

# 直接给坐标（负号开头记得用 `=`，否则 argparse 会当成参数名）
python tools/dev/quest_map.py --coords="-1338,-1278,4.4" --style atlas --scale 4

# 全仓体检：只报可疑点，硬错误时退出码非 0（可以直接进 CI）
python tools/dev/quest_map.py --scan
```

产物：`.cache/quest_map/*.png`（瓦片缓存在 `.cache/quest_map_tiles/`，两者都在 gitignore 里）。

## 坐标系

社区标定（FiveDock 的 Leaflet CRS、`RiceaRaul/gta-v-map-leaflet` 同源）：

```
zoom 0 时整图 256×256 px，游戏坐标 (x, y) 落在
    px = 0.02072 * x + 117.3
    py = -0.0205 * y + 172.8
每级 zoom 像素翻倍；y 系数为负（游戏 y 朝北、像素 y 朝下）
```

瓦片只有 z0–5（z5 = 8192 px，1 px ≈ 48 m），再细只能放大 z5，所以工具默认 `--scale 3~5`
输出 1 px ≈ 10–16 m 的图，够看清落在哪栋楼 / 哪条人行道。

## 校准常量不止一套（别混用）

同样一组游戏坐标，在不同开源项目里的像素换算**不是同一个尺度**：

| 来源 | z0 换算 | 覆盖宽度 | 备注 |
|---|---|---|---|
| FiveDock（本工具） | `px = 0.02072x + 117.3`，`py = -0.0205y + 172.8` | ≈12,355 单位 | 它的瓦片就是按这套切的 |
| `oyuh/w3w-map` | `px = 0.012575x + 121.421`，`py = -0.012575y + 155.225` | ≈20,358 单位 | 尺度差 1.65×，与 FiveDock 混用会整体偏移 |
| `Flamm64/GTA-V-World-Map` | z2 `px = 0.05030x − 486.97`，`py = -0.05030y + 408.9` | — | 与 w3w 同尺度、原点不同 |

结论：**瓦片与常量必须成对使用**。本工具用 FiveDock 的瓦片 + FiveDock 的常量；
换成别的瓦片源要同时换常量，否则点位会整体漂几十到几百米。
实测两个地标（Legion Square、机场）在两套常量下的 z5 像素差分别是 (76, −768) 与 (402, −1257) —— 足以把
「建筑内部」判成「马路上」。

瓦片源（都实测可用，只要带浏览器 UA；Referer 非必需）：

- FiveDock：`assets.fivedock.dev/maps/{styleatlas|stylesatelite|stylegrid}/{z}/{x}/{y}.{jpg|png}`，z0–5
- VIRUXE 备用：`viruxe.github.io/gtav-map-tiles/{atlas|satelite|grid}/{z}/{x}-{y}.webp`，z0–5（文件名是 `x-y`）

## 判读方法（三条，按成本从低到高）

| 判据 | 能自动化吗 | 怎么做 |
|---|---|---|
| 世界边界 / z 越界 | ✅ | `--scan` 的「硬错误」，退出码非 0；边界取 `x −4000…4500 / y −4000…8000`（FiveM 官方示例与 RageMP 高度图一致） |
| 落在建筑内部 vs 人行道 | ❌ 要人眼 | 用 **satellite** 风格看屋顶/墙体，再用 **atlas** 看街区；红点在深色屋顶块中间 = 大概率进不去 |
| 高度是否离谱 | ⚠️ 半自动 | `--scan` 的「提示」：z > 120 且不是飞行类任务；街区地面 z 一般 20–60 |

飞行类任务（`aviation_*` / `pilot_*` / 含 `flight`）本来就在空中，工具对它们不报 z 偏高。

## 已知的坑

- **同一模板多个步骤共用一个点**是合法设计（热狗摊：备料/烤/卖都在同一摊位），扫描只当「提示」。
- 瓦片**放大不等于更高精度**：z6+ 是把 z5 插值放大，别用它判断「这个点在不在台阶上」。
- 反斜杠路径在 MSYS 下会被当转义；`--coords` 以 `-` 开头必须写成 `--coords=…`。
- FiveDock 瓦片不带 UA 会 403；工具已带浏览器 UA + Referer。

## 已修的点

| 模板 | 旧坐标 | 问题 | 新坐标 |
|---|---|---|---|
| `hotdog_vendor` | `(-150, -250, 44)` | 落在 Las Lagunas Blvd 东侧建筑**内部**，4 个步骤全在楼里 | `(215.8, -810.3, 30.7)`，Legion Square 广场空地，半径放宽到 8/5 m |

## 下一步：把「离路多远」也自动化（未做）

目前「落在建筑里」只能靠人眼看渲染图。可自动化的下一条判据是**最近道路节点距离**：

- 数据源：`DurtyFree/gta-v-data-dumps` 的 `nodes.zip`（约 3.98 MB，67,454 个车辆节点，MIT）
- 判据：点到最近节点的水平距离 > 25 m 且不在水里 → 大概率是院内/楼顶/荒地，标成「提示」
- 局限：只判「远离路网」，判不了楼顶 vs 楼内；后者要解析 `.ybn`/ymap 碰撞（`VIRUXE/rage-formats`），成本高

水与高度（可选）：海面 z=0 由本机 `water.xml` 给出；`Andreas1331/ragemp-gtav-heightmap` 有 407 MB 的
1 m 高度图（8400×12126，MIT），能判「这个点在水下还是在地面」—— 但 407 MB 不适合放进 CI。