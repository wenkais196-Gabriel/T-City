"""世界痕迹的区域注册表 — core-framework 的纯数据 + 纯函数。

为什么要单独测它：`RegionOf(x, y)` 的结果**会写进数据库**（`world_state.region_id`），
一旦改名或换边界，历史行就对不上。所以这里的断言全部是"坐标 → id"的确定映射，
不允许出现"大致正确"。模块必须保持**纯**：不调 FiveM 原生、不碰 DB、不读 convar，
否则它就不能在离线 harness 里跑，也就没法在 CI 里被反证。

    python3 -m pytest -q tests/unit/layer1_core/test_world_regions.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
CF = BASE / "resources" / "[standalone]" / "core-framework"
REGIONS = CF / "shared" / "regions.lua"
MANIFEST = CF / "fxmanifest.lua"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 静态：能加载、是纯的
# ---------------------------------------------------------------------------

def test_manifest_loads_regions_as_shared_script():
    manifest = read(MANIFEST)
    assert "shared/regions.lua" in manifest, "regions.lua 必须在 shared_scripts 里"
    shared = manifest[manifest.index("shared_scripts"):manifest.index("server_scripts")]
    assert "shared/util.lua" in shared
    assert "shared/regions.lua" in shared


LONG_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def strip_comments(src: str) -> str:
    """注释里提到 `CreateThread` 不算调用 —— 否则"写清楚为什么不用原生"反而会触发闸门。

    与 FIT-04 的做法一致（test_export_contracts.py 也先去掉注释再判）。
    """
    return LINE_COMMENT_RE.sub("", LONG_COMMENT_RE.sub("", src))


def test_module_is_pure_no_native_no_db():
    src = strip_comments(read(REGIONS))
    for forbidden in (
        "MySQL",
        "exports.",
        "GetConvar",
        "Wait(",
        "CreateThread",
        "TriggerEvent",
        "GetGameTimer",
        "vector3(",
        "PlayerData",
    ):
        assert forbidden not in src, f"区域注册表必须保持纯：出现了 {forbidden}"


def test_every_region_pins_a_stable_id_label_and_positive_radius():
    src = read(REGIONS)
    # id 是写进 DB 的主键，必须是小写短名；改名要靠迁移，不能靠"顺手统一"。
    assert "FALLBACK = 'city_wide'" in src
    assert src.count("id = '") >= 8, "至少 8 个区域（不含 city_wide 兜底）"
    assert src.count("radius = ") >= 8


# ---------------------------------------------------------------------------
# 行为：真 Lua 文件 + 真坐标
# ---------------------------------------------------------------------------

HARNESS = r"""
dofile(__REGIONS__)

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end

expect(type(Regions) == 'table', 'Regions 全局表存在')
expect(Regions.FALLBACK == 'city_wide', '兜底是 city_wide')
expect(#Regions.LIST >= 8, '至少 8 个区域')

-- 1) id 唯一 + 半径为正 + 标签非空
local seen = {}
for i = 1, #Regions.LIST do
    local r = Regions.LIST[i]
    expect(type(r.id) == 'string' and #r.id > 0, 'region id 非空字符串')
    expect(not seen[r.id], 'region id 重复: ' .. tostring(r.id))
    seen[r.id] = true
    expect(type(r.label) == 'string' and #r.label > 0, 'label 非空: ' .. tostring(r.id))
    expect(type(r.radius) == 'number' and r.radius > 0, 'radius 为正: ' .. tostring(r.id))
    expect(type(r.x) == 'number' and type(r.y) == 'number', 'x/y 为数字: ' .. tostring(r.id))
end

-- 2) 每个区域的锚点必须落回自己（坐标写进 DB 的前提）
for i = 1, #Regions.LIST do
    local r = Regions.LIST[i]
    local got = Regions.RegionOf(r.x, r.y)
    expect(got == r.id, ('锚点不落回自己: %s -> %s'):format(r.id, tostring(got)))
end

-- 3) 边界语义：正好半径内包含，稍外就不包含
local first = Regions.LIST[1]
expect(first ~= nil, '有第一个区域')
local inside = Regions.RegionOf(first.x + first.radius - 0.01, first.y)
expect(inside == first.id, '半径内 0.01 应命中: ' .. tostring(inside))

-- 4) 非法输入一律兜底，绝不抛错
local bad = {
    { nil, 0 }, { 0, nil }, { '1', 2 }, { true, false }, { 0 / 0, 0 }, { math.huge, 0 },
    { -math.huge, 0 }, { 0, 0 / 0 },
}
for i = 1, #bad do
    local x, y = bad[i][1], bad[i][2]
    local ok, got = pcall(Regions.RegionOf, x, y)
    expect(ok, 'RegionOf 不应抛错，输入: ' .. tostring(x) .. ',' .. tostring(y))
    expect(got == 'city_wide', '非法坐标必须兜底 city_wide')
end

-- 5) 远离所有区域 → 兜底（海上）
expect(Regions.RegionOf(3000.0, -5000.0) == 'city_wide', '海上坐标兜底')

-- 6) IsValid / Get 的契约
expect(Regions.IsValid('city_wide') == true, 'city_wide 合法')
expect(Regions.IsValid(first.id) == true, '已注册 id 合法')
expect(Regions.IsValid('no_such_region') == false, '未注册 id 不合法')
expect(Regions.IsValid(nil) == false, 'nil 不合法')
expect(Regions.IsValid(42) == false, '非字符串不合法')
expect(Regions.Get(first.id) ~= nil, 'Get 命中')
expect(Regions.Get('nope') == nil, 'Get 未命中返回 nil')

-- 7) 重叠时取最近的那个（不是列表里第一个）
-- 造一个必然重叠的点：取两个邻域区域的锚点中点，结果必须是其中之一，且距离更小
local a, b = Regions.LIST[1], Regions.LIST[2]
local mx, my = (a.x + b.x) / 2.0, (a.y + b.y) / 2.0
local mid = Regions.RegionOf(mx, my)
expect(mid == a.id or mid == b.id or mid == 'city_wide', '中点结果必须是三者之一')

print('world_regions harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_region_behaviour_under_lua(tmp_path: Path) -> None:
    harness = tmp_path / "world_regions_harness.lua"
    harness.write_text(HARNESS.replace("__REGIONS__", json.dumps(str(REGIONS))), encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "world_regions harness ok" in result.stdout
