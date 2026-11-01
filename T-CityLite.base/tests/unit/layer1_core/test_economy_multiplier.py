"""TS-7 经济倍率 — 一个 convar 只能有一种单位。

背景：`economy_reward_scale` 在仓库里被两套单位读：
  * 整数读者按 /100（core_economy、qb-shops、economy-dashboard）
  * 浮点读者直接当倍率（custom-economy 的 RewardScale）
而 configs/modules/economy.cfg 写的是 `1.0`。至少一边必然错，最多差 100 倍。

本用例直接加载 core_economy/server/main.lua 的真实源码（不复制实现），
用 convar stub 驱动 getGlobalMultiplier，钉住"浮点倍率"这一种语义。
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
MAIN_LUA = BASE / "resources" / "[system]" / "core_economy" / "server" / "main.lua"

HARNESS = r"""
-- ── 最小运行时 stub：只让 main.lua 能在纯 Lua 里被 load 并导出函数 ──
__convars = {}

local function to_num(value)
    if value == nil then return nil end
    local n = tonumber(value)
    return n
end

-- atoi 语义：CfxLua 的 GetConvarInt 对 "1.0" 会取 1，这里如实模拟
function GetConvarInt(key, default)
    local n = to_num(__convars[key])
    if n == nil then return default end
    return math.floor(n)
end

function GetConvarFloat(key, default)
    local n = to_num(__convars[key])
    if n == nil then return default end
    return n
end

function GetConvar(key, default)
    if __convars[key] == nil then return default end
    return tostring(__convars[key])
end

function CreateThread(_) end      -- 不启动 30 分钟衰减循环
function Wait(_) end
function AddEventHandler(_, _) end

__exported = {}
function exports(name, fn) __exported[name] = fn end

__QBCore = {
    Functions = {
        GetPlayer = function(_) return nil end,
        GetPlayerByCitizenId = function(_) return nil end,
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}
"""

PROBE = r"""
local function probe(label, convars)
    __convars = convars or {}
    local value = __exported['GetGlobalMultiplier']()
    print(('%s=%.6f'):format(label, value))
end

probe('unset', {})
probe('ratio_1_0', { economy_reward_scale = '1.0' })
probe('ratio_0_8', { economy_reward_scale = '0.8' })
probe('ratio_1_5', { economy_reward_scale = '1.5' })
probe('zero', { economy_reward_scale = '0' })
probe('negative', { economy_reward_scale = '-2' })
probe('manual_wins', { economy_reward_scale = '0.8', economy_global_multiplier = '1.25' })
probe('manual_zero_falls_through', { economy_reward_scale = '1.5', economy_global_multiplier = '0' })
"""


def run_probe() -> dict[str, float]:
    source = MAIN_LUA.read_text(encoding="utf-8")
    assert "exports['qb-core']:GetCoreObject()" in source, (
        "core_economy/main.lua 的初始化方式变了 —— 先更新这个 harness 再改实现"
    )
    source = source.replace("exports['qb-core']:GetCoreObject()", "__QBCore")

    script = HARNESS + "\n" + source + "\n" + PROBE
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name

    result = subprocess.run(["lua5.4", path], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, f"lua 执行失败：\n{result.stderr}\n{result.stdout}"

    values: dict[str, float] = {}
    for line in result.stdout.splitlines():
        if "=" in line and not line.startswith("["):
            key, _, raw = line.partition("=")
            try:
                values[key.strip()] = float(raw)
            except ValueError:
                continue
    return values


@pytest.fixture(scope="module")
def probed() -> dict[str, float]:
    return run_probe()


def test_ratio_is_taken_literally(probed):
    assert probed["ratio_1_0"] == pytest.approx(1.0), (
        "economy_reward_scale = '1.0' 必须被当成 1 倍。"
        "按 /100 解析会变成 0.01，等于所有奖励打 1 折以下"
    )
    assert probed["ratio_0_8"] == pytest.approx(0.8)
    assert probed["ratio_1_5"] == pytest.approx(1.5)


def test_missing_or_invalid_falls_back_to_one(probed):
    assert probed["unset"] == pytest.approx(1.0)
    assert probed["zero"] == pytest.approx(1.0), "0 不是合法倍率，必须回落到 1.0"
    assert probed["negative"] == pytest.approx(1.0), "负倍率应视为未配置"


def test_manual_override_has_priority(probed):
    assert probed["manual_wins"] == pytest.approx(1.25)
    assert probed["manual_zero_falls_through"] == pytest.approx(1.5), (
        "economy_global_multiplier = 0 表示'未手动设置'，应让位给自适应倍率"
    )


def test_readers_agree_on_the_unit():
    """三个整数读者必须和 core_economy 读同一种单位。"""
    readers = {
        BASE / "resources" / "[qb]" / "qb-shops" / "server" / "main.lua":
            "GetConvarFloat('economy_reward_scale'",
        BASE / "resources" / "[system]" / "economy-dashboard" / "server" / "main.lua":
            "GetConvarFloat('economy_reward_scale'",
    }
    for path, expected in readers.items():
        text = path.read_text(encoding="utf-8")
        assert expected in text, f"{path.name} 仍在用另一套单位读 economy_reward_scale"
        assert "GetConvarInt('economy_reward_scale'" not in text, (
            f"{path.name} 又出现了 /100 语义的整数读取 —— 单位会再次分叉"
        )
