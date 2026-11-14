"""物流「租借绑定」必须有关闭路径 —— 三个真 bug 的回归闸（2026-11-14）。

修之前的形态（全部实测过）：

1. `rentalDeposit = 0` 写死在绑定里 → 配置里 300–2000 的押金在收据上永远是 $0；
2. `ClearLogisticsBinding` 定义了却**全仓库零调用** → 失败/放弃后 plate / netId /
   rentalFeePct 残留，下一趟按上一趟的费率结算；
3. `playerDropped` 只清 `QuestCache` → 掉线重连后旧绑定还在（车没还，费率还在）。

闸门分两种形状：
  • 静态契约：源码里「押金从 stepData 读」「两条终结路径都清」「断线整表清」；
  • 运行时探针：真跑源码里的绑定存储（`fixtures/logistics_binding_probe.lua`），
    验幂等、计数、只清一个不动兄弟。

每条静态规则都带反向校验：喂一段**旧形状**的源码，规则必须判红。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
VALIDATORS = BASE / "resources/[custom]/custom-quest/server/quest_logistics_validators.lua"
MANAGER = BASE / "resources/[custom]/custom-quest/server/quest_manager.lua"
CACHE = BASE / "resources/[custom]/custom-quest/server/quest_cache.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "logistics_binding_probe.lua"

LUA = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# 规则 1：押金从 stepData 读，不许写死 0
# ---------------------------------------------------------------------------

def deposit_read_from_step_data(src: str) -> bool:
    """真实现：局部变量从 stepData.rental_deposit 取；绑定里给 isOwned 分叉；没有写死 0。"""
    reads = re.search(r"local\s+rentalDeposit\s*=\s*tonumber\(\s*stepData\.rental_deposit\s*\)", src)
    branched = re.search(r"rentalDeposit\s*=\s*isOwned\s+and\s+0\s+or\s+rentalDeposit", src)
    hardcoded = re.search(r"rentalDeposit\s*=\s*0\s*,", src)
    return bool(reads and branched) and not hardcoded


def test_binding_records_the_configured_deposit():
    assert deposit_read_from_step_data(read(VALIDATORS)), (
        "绑定里的押金又变成写死的 0 了：配置里 rental_deposit 会再次失效")


def test_deposit_rule_rejects_the_old_hardcoded_shape():
    """反向校验：旧形状（押金写死 0）必须被判红。"""
    old = """
    local isOwned = playerOwnsVehicle(citizenid, vehInfo.plate)
    setBinding(citizenid, questId, {
        plate = vehInfo.plate,
        isRental = not isOwned,
        rentalDeposit = 0,
        rentalFeePct = isOwned and 0 or rentalFeePct,
    })
    """
    assert not deposit_read_from_step_data(old)


# ---------------------------------------------------------------------------
# 规则 2：失败与放弃两条终结路径都要清绑定
# ---------------------------------------------------------------------------

def termination_paths_clear_bindings(src: str) -> bool:
    """FailQuest 与 AbandonQuest 各有一处 clear 调用，且清理走 pcall 保护。"""
    # 只数**调用点**：定义行 `local function clearLogisticsFor(citizenid, questId)` 也长一样，
    # 不排除它的话「只调一处」会被数成两处，闸门就形同虚设。
    calls = sum(
        1 for line in src.splitlines()
        if "clearLogisticsFor(citizenid, questId)" in line and "function clearLogisticsFor" not in line
    )
    helper = re.search(r"local function clearLogisticsFor\(citizenid, questId\)", src)
    guarded = re.search(r"pcall\(\s*ClearLogisticsBinding", src)
    return calls >= 2 and bool(helper) and bool(guarded)


def test_fail_and_abandon_both_clear_the_binding():
    assert termination_paths_clear_bindings(read(MANAGER)), (
        "任务终结路径少了一处清理：放弃/失败后绑定会残留到下一趟")


def test_termination_rule_rejects_a_missing_cleanup_path():
    """反向校验：只有一处（放弃有、失败没有）必须被判红。"""
    partial = """
    local function clearLogisticsFor(citizenid, questId)
        if type(ClearLogisticsBinding) ~= 'function' then return end
        pcall(ClearLogisticsBinding, citizenid, questId)
    end
    function QuestManager.AbandonQuest(source, questId)
        clearLogisticsFor(citizenid, questId)
    end
    """
    assert not termination_paths_clear_bindings(partial)


# ---------------------------------------------------------------------------
# 规则 3：断线清掉该玩家所有绑定
# ---------------------------------------------------------------------------

def drop_handler_clears_all_bindings(src: str) -> bool:
    """playerDropped 里必须调用 ClearAllLogisticsBindings（键是 citizenid → questId，只能整表清）。"""
    handler = re.search(r"AddEventHandler\('playerDropped'.*?\nend\)", src, re.S)
    if not handler:
        return False
    return "ClearAllLogisticsBindings" in handler.group(0)


def test_player_drop_clears_every_logistics_binding():
    assert drop_handler_clears_all_bindings(read(CACHE)), (
        "断线没有清物流绑定：重连后旧 plate/netId 还挂在内存里")


def test_drop_rule_rejects_a_cache_only_cleanup():
    """反向校验：只清 QuestCache 的旧写法必须被判红。"""
    old = """
    AddEventHandler('playerDropped', function()
        local src = source
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData then
            QuestCache.ClearPlayer(Player.PlayerData.citizenid)
        end
    end)
    """
    assert not drop_handler_clears_all_bindings(old)


# ---------------------------------------------------------------------------
# 运行时探针：真跑源码里的绑定存储
# ---------------------------------------------------------------------------

def _run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_binding_store_semantics_pass():
    proc = _run_probe(VALIDATORS)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 5/5" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_probe_goes_red_when_clear_all_is_broken(tmp_path: Path):
    """反向校验（运行时）：把整表清改成空操作，探针必须红。"""
    mutated = (read(VALIDATORS)
               .replace("        PlayerBindings[citizenid] = nil\n", "        -- mutated: 不清\n"))
    target = tmp_path / "validators_mutant.lua"
    target.write_text(mutated, encoding="utf-8")
    proc = _run_probe(target)
    assert proc.returncode != 0, "把整表清改成空操作后探针仍然通过 —— 探针没有在验证任何东西"
    assert "FAIL" in proc.stdout
