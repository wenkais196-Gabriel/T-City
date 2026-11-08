"""P1-3 批 20：qb-weed（5）+ qb-streetraces（3）—— `[qb]` 归零。

**先修一个"这个资源根本跑不起来"的 bug**：`local plantCache = {}` 原本声明在文件**末尾**（第 126 行），
而 `placePlant` / `removeDeathPlant` / `harvestPlant` / `foodPlant` 四个 handler 都在它之前 —— 它们引用的是
全局 `plantCache`（nil）。实测（对 master 版本跑本探针）五个崩溃点：

```
server/main.lua:43: attempt to index a nil value (global 'plantCache')   -- placePlant
server/main.lua:49: attempt to index a nil value (global 'plantCache')   -- removeDeathPlant
server/main.lua:63: attempt to index a nil value (local 'Player')        -- harvestPlant（Player 为 nil 没判）
server/main.lua:68: attempt to index a nil value (global 'plantCache')   -- harvestPlant
server/main.lua:97: attempt to index a nil value (global 'plantCache')   -- foodPlant
```

也就是说「种一株植物」这条路径在 master 上**每次都会抛错**（行写进 DB 了，但缓存行抛错、后续刷新不执行）。
把表挪到所有 handler 之前，并删掉末尾那份会把作用域再遮蔽一次的重复声明。

在此之上补的校验：`placePlant` 原来**连 Player 都没取**（任何客户端都能往 house_plants 塞任意行），
现在要求 Player + house 非空 + sort 在 `QBWeed.Plants` 白名单 + coords 能解出地图内的 x/y/z + 单屋 20 株上限；
`removeDeathPlant` 只能铲**缓存里、且 building 对得上**的植株；`harvestPlant` 的 `amount`（只用来发种子）
夹成 1..6，`plantName` 走白名单；`foodPlant` 的 `plantName` 走白名单（原来 `QBWeed.Plants[plantName]['label']`
遇到坏名字直接 nil 索引崩线程）。

`qb-streetraces` 三条**本来就是**服务端权威的（stake 夹在 Config 区间、奖池按参赛人数重建、
先销毁赛局再发钱、禁重复报名），本轮把 `RaceId` 规范化成数字并登记，不改玩法。

⚠️ 两个资源都不在启动集里（`qb-weed`、`qb-streetraces` 均为 `started: false`），所以只有
`luac5.4 -p` + 探针验证，**没有真机验证** —— 这是本次最需要说明的局限。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix()],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def test_plant_cache_is_in_scope_for_every_handler():
    """master 上四个 handler 引用的是全局 nil 的 `plantCache` —— 种植必抛错。"""
    data = _run("weed_probe.lua", "[qb]/qb-weed")
    assert data["PLACE_OK"] == "true", "正常种植没写库"
    assert data["REMOVE_UNKNOWN_BLOCKED"] == "true", "未登记的 plantId 也能删（旧版还先崩在 plantCache）"


def test_place_plant_validates_source_and_arguments():
    data = _run("weed_probe.lua", "[qb]/qb-weed")
    assert data["PLACE_BAD_ARGS_BLOCKED"] == "true", "无 Player / 坏 sort / 坏坐标 / 坏 house 都能种（旧版连 Player 都没取）"
    assert data["PLACE_HOUSE_CAP"] == "true", "同一屋能无限种（旧版没有上限）"


def test_freshly_planted_can_be_harvested_and_removed():
    """`house_plants.plantid` 是 varchar(50)，客户端回传的是**字符串**。

    缓存键若用 `math.random` 的两位数（数字），本次会话种下的植株在 removeDeathPlant /
    harvestPlant 里按字符串查会 miss —— 死株铲不掉、收获也收获不了（CC 复核发现的 P0）。
    """
    data = _run("weed_probe.lua", "[qb]/qb-weed")
    assert data["HARVEST_FRESH_PLANT_OK"] == "true", "刚种下的植株收获不了（缓存键数字 vs 字符串）"
    assert data["REMOVE_FRESH_PLANT_OK"] == "true", "收获后缓存没清干净，或铲除走错分支"


def test_harvest_and_food_are_bounded():
    data = _run("weed_probe.lua", "[qb]/qb-weed")
    assert data["HARVEST_AMOUNT_CLAMPED"] == "true", "种子数量没夹取 / Player 为 nil 时抛错"
    assert data["HARVEST_BAD_PLANT_SAFE"] == "true", "坏 plantName 会抛错"
    assert data["FOOD_BAD_ARGS_SAFE"] == "true", "施肥收到坏 plantName / nil amount 会抛错（旧版 nil 索引）"
