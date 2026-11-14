"""任务模板里的坐标必须过「离线体检」——不启动游戏就能发现显然错的点。

起因（2026-11-14 真机）：`hotdog_vendor` 的 4 个步骤都在 `(-150, -250, 44)`，那个点落在
Las Lagunas Boulevard 东侧一栋**大楼内部**，玩家走过去既进不去、也不会有交互提示。
纯看数字看不出问题，进游戏跑一遍才能发现 —— 一次要校 78 个模板 / 179 个点，这个成本付不起。

`tools/dev/quest_map.py` 把坐标按社区标定换算成像素、抓 GTA 地图瓦片渲染 PNG（人眼看位置），
并提供 `--scan`：硬错误（世界边界外 / z 越界）必须为 0；提示（z 偏高、多步骤同点）留给人判断。

闸门只跑 `--scan`（离线、不联网）；渲染图是给人看的，不进闸门。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
TOOL = REPO / "tools/dev/quest_map.py"
HOTDOG = BASE / "resources/[custom]/custom-quest/config/quests/quest_civilian_misc.lua"


def _scan(quests_dir: Path | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if quests_dir is not None:
        env["QUEST_MAP_QUESTS_DIR"] = str(quests_dir)
    return subprocess.run([sys.executable, str(TOOL), "--scan"],
                          capture_output=True, text=True, timeout=120, cwd=str(REPO), env=env)


def test_no_hard_coordinate_errors():
    proc = _scan()
    assert proc.returncode == 0, (
        "任务坐标里有硬错误（世界边界外 / z 越界）—— 这种点玩家一定到不了：\n"
        + proc.stdout + proc.stderr
    )
    assert "硬错误 0" in proc.stdout, proc.stdout


def test_scanner_detects_a_point_outside_the_world(tmp_path: Path):
    """反向校验：喂一份含界外点的配置，扫描必须报硬错误并以非零码退出。"""
    bad = tmp_path / "quest_bad.lua"
    bad.write_text(
        "return {\n"
        "    {\n"
        "        id = 'test_bad_coords',\n"
        "        title = 'bad',\n"
        "        steps = {\n"
        "            { id = 'step_a', type = 'reach', data = {\n"
        "                coords = { x = 99999.0, y = 99999.0, z = 30.0 },\n"
        "            } },\n"
        "        },\n"
        "    },\n"
        "}\n",
        encoding="utf-8",
    )
    proc = _scan(tmp_path)
    assert proc.returncode != 0, "界外点没有被判成硬错误（扫描等于没有）：\n" + proc.stdout
    assert "硬错误 1" in proc.stdout, proc.stdout


def test_hotdog_stand_is_no_longer_the_placeholder_inside_a_building():
    text = HOTDOG.read_text(encoding="utf-8")
    start = text.index("id = 'hotdog_vendor'")
    end = text.index("-- 新闻记者 (Reporter)")
    block = text[start:end]
    assert "x = -150.0, y = -250.0" not in block, (
        "热狗摊又回到那栋楼里了（-150, -250 在 Las Lagunas Blvd 东侧建筑内部，玩家到不了）"
    )
    assert re.search(r"coords\s*=\s*\{\s*x\s*=\s*215\.8", block), (
        "热狗摊坐标不是 Legion Square 广场点（这是 2026-11-14 离线渲染核对过的位置）"
    )
