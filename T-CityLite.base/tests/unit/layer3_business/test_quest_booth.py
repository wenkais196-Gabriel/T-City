"""S2 摊位：摆放判定的服务端权威性 + 接线完整性。

为什么这一组测试必须存在：
    摆放判定是「玩家看到绿圈就以为能放」的那条路径。它背后有三层容易断的地方：
      1. 纯判据本身（五种拒绝 + 合法）—— 探针真跑源码
      2. `booth` 步骤类型有没有真的接进校验闸 —— 上一轮 `rental` 就是「客户端能推进、
         服务端校验器根本没跑」，押金一分没扣还零报错
      3. 路网点是**生成物**：路网缓存更新了而 Lua 没重生成，判据就会对着旧地图做判断
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
REPO = BASE.parent
BOOTH = BASE / "resources/[custom]/custom-quest/server/quest_booth.lua"
PROBE = Path(__file__).with_name("fixtures") / "booth_probe.lua"
STEP_GATE = BASE / "resources/[custom]/custom-quest/server/quest_step_gate.lua"
MANIFEST = BASE / "resources/[custom]/custom-quest/fxmanifest.lua"
ROADS = BASE / "resources/[custom]/custom-quest/config/quests/hotdog_roads.json"

LUA = shutil.which("lua5.4")


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只能跑静态断言")
def test_placement_rules_hold():
    proc = run_probe(BOOTH)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 17/17" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_probe_goes_red_when_the_road_check_is_removed(tmp_path: Path):
    """反向校验：把「压路面」那条判据删掉，探针必须红。

    没有这条，探针可能只是"全绿因为它什么都没检查"。
    """
    src = BOOTH.read_text(encoding="utf-8")
    assert "if hints.onRoad == true then" in src
    broken = src.replace(
        "    if hints.onRoad == true then\n        return false, QuestBooth.REASON.ON_ROAD\n    end\n",
        "", 1)
    assert "if hints.onRoad == true then" not in broken
    # 离线点那半也要一起摘掉，否则 onRoad 用例仍然会被离线距离拦住，测不出「删了就红」
    broken = broken.replace(
        "    if type(roadDistance) == 'number' and roadDistance < clearance then\n"
        "        return false, QuestBooth.REASON.ON_ROAD\n    end\n", "", 1)
    target = tmp_path / "quest_booth_broken.lua"
    target.write_text(broken, encoding="utf-8")
    proc = run_probe(target)
    assert proc.returncode != 0, "删掉压路面判据后探针仍然全绿 —— 这条用例没在防什么"
    assert "FAIL RV_ON_ROAD" in proc.stdout


def test_booth_step_is_wired_into_the_validator_gate():
    """`booth` 必须在 VALIDATED_TYPES 里，且配置字段进 META_KEYS。

    上一轮 `rental` 漏了这张表：客户端一路推进、服务端校验器从没执行，
    表现是「任务能过、押金没扣、日志里什么都没有」。
    """
    gate = STEP_GATE.read_text(encoding="utf-8")
    assert re.search(r"^\s*booth\s*=\s*true", gate, re.M), "booth 没进 VALIDATED_TYPES —— 摆放判定永远不会跑"
    for field in ("model", "rental_point", "max_distance", "road_clearance",
                  "min_separation", "forbidden_zones"):
        assert re.search(rf"\b{field}\s*=\s*true", gate), f"META_KEYS 缺 {field}：配置写在 step.data 顶层会被吞掉"


def test_booth_files_are_declared_in_the_manifest():
    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "server/quest_booth.lua" in manifest
    assert "config/quests/hotdog_roads.json" in manifest


def test_road_points_are_in_sync_with_the_cache():
    """路网点是生成物。缓存更新而 Lua 没重跑，判据就会对着旧地图判断。"""
    python = shutil.which("python3") or shutil.which("python")
    if python is None:
        pytest.skip("需要 python 跑生成器")
    proc = subprocess.run(
        [python, str(REPO / "tools/dev/booth_roads.py"), "--check"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
    )
    if proc.returncode == 2:
        # 路网缓存是 gitignored 的，CI 机器上没有 —— 这时「产物是否过期」无法判定，
        # 只能跳过。产物本身已经在仓库里（hotdog_roads.lua），服务端照样能跑。
        pytest.skip(proc.stdout.strip())
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_dev_template_uses_the_booth_step():
    """配置里那条 dev 模板必须真的用上 booth 步骤，否则接线全绿也没人走这条路径。"""
    template = (BASE / "resources/[custom]/custom-quest/config/quests/quest_hotdog.lua").read_text(encoding="utf-8")
    assert "type = 'booth'" in template
    assert "validator_id = 'validate_booth_place'" in template
    assert ROADS.exists()


def test_booth_record_is_cleared_on_all_three_quest_end_paths():
    """完成 / 失败 / 放弃 三条路径都要清摊位记录。

    只清客户端的实体是不够的：服务端的 QuestEntityRegistry 里还留着 netId。
    玩家下次登录（同一 citizenid）如果重建会话，会拿到一个已经死掉的实体句柄。
    """
    manager = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    assert "local function closeBoothFor" in manager
    for reason in ("completed", "failed", "abandoned"):
        assert f"closeBoothFor(citizenid, questId, '{reason}')" in manager, (
            f"{reason} 路径没有清摊位记录")


def test_placed_stand_survives_step_advance():
    """摆好的摊位在「推进到下一步」时不能被删。

    真机可见的失败形态：放置成功的一瞬间摊位从地图上消失，而服务端还以为自己有个摊位。
    这条断言守的是「HaltBooth（停线程、留实体）而不是 ResetBooth（连实体一起删）」。
    """
    client = (BASE / "resources/[custom]/custom-quest/client/quest_hotdog_client.lua").read_text(encoding="utf-8")
    assert "local function HaltBooth" in client
    # stepAdvanced 分支里必须是 HaltBooth，不能是 ResetBooth
    branch = client[client.index("QUEST_STEP_ADVANCED"):]
    branch = branch[:branch.index("end)")]
    assert "HaltBooth('stepAdvanced')" in branch
    assert "ResetBooth('stepAdvanced')" not in branch
    # 结束清理不能因为 active=false 就早退，否则被 Halt 过的摊位永远删不掉
    cleanup = client[client.index("local function CleanupOnQuestEnd"):]
    cleanup = cleanup[:cleanup.index("end")]
    assert "EntityExists(BoothState.cart)" in cleanup, "清理判据必须看实体，而不是 active"