"""任务模板里的坐标必须过「离线体检」——不启动游戏就能发现显然错的点。

起因（2026-11-14 真机）：`hotdog_vendor` 的 4 个步骤都在 `(-150, -250, 44)`，那个点落在
Las Lagunas Boulevard 东侧一栋**大楼内部**，玩家走过去既进不去、也不会出现交互提示。
纯看数字看不出问题，进游戏跑一遍才能发现 —— 一次要校 78 个模板 / 179 个点，这个成本付不起。

`tools/dev/quest_map.py` 把坐标换算成像素、抓 GTA 地图瓦片渲染 PNG（人眼看位置），
`--scan` 给硬错误（世界边界外 / z 越界，退出码非 0）与提示（z 偏高、多步骤同点）。

两条闸门都自带坏形状（合成输入必须被拒 + 真实仓库必须干净），所以规则本身是被证明过的。
闸门只用 `--scan`：纯文本、不联网、不需要 Pillow。
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

#: 热狗摊落在大楼里的那组坐标（2026-11-14 修掉）
OLD_PLACEHOLDER = "x = -150.0, y = -250.0"
CURRENT = re.compile(r"coords\s*=\s*\{\s*x\s*=\s*215\.8")


def _scan(quests_dir: Path | None = None) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if quests_dir is not None:
        env["QUEST_MAP_QUESTS_DIR"] = str(quests_dir)
    return subprocess.run([sys.executable, str(TOOL), "--scan"],
                          capture_output=True, text=True, timeout=120, cwd=str(REPO), env=env)


def _hotdog_block(text: str) -> str:
    return text[text.index("id = 'hotdog_vendor'"):text.index("-- 新闻记者 (Reporter)")]


def test_coordinate_scan_rejects_out_of_world_points_and_the_tree_is_clean(tmp_path: Path):
    # 反向：喂一份含世界边界外坐标的配置，扫描必须报硬错误并以非零码退出
    (tmp_path / "quest_bad.lua").write_text(
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
    bad = _scan(tmp_path)
    assert bad.returncode != 0, "界外点没有被判成硬错误（闸门等于没有）：\n" + bad.stdout + bad.stderr
    assert "硬错误 1" in bad.stdout, bad.stdout

    # 真实仓库：不允许有任何硬错误
    good = _scan()
    assert good.returncode == 0, (
        "任务坐标里有硬错误（世界边界外 / z 越界）—— 这种点玩家一定到不了：\n"
        + good.stdout + good.stderr
    )
    assert "硬错误 0" in good.stdout, good.stdout


def test_hotdog_coords_detects_a_return_to_the_inside_of_that_building():
    # 反向：旧坐标（落在 Las Lagunas Blvd 东侧建筑内部）必须被判违规
    old_block = "id = 'hotdog_vendor'\n coords = { x = -150.0, y = -250.0, z = 44.0 },"
    assert OLD_PLACEHOLDER in old_block and not CURRENT.search(old_block), (
        "反向用例本身写错了：它应当既不匹配新坐标、又包含旧占位坐标"
    )

    # 真实仓库：不许出现旧坐标，必须是核对过的广场点
    block = _hotdog_block(HOTDOG.read_text(encoding="utf-8"))
    assert OLD_PLACEHOLDER not in block, (
        "热狗摊又回到那栋楼里了（-150, -250 在 Las Lagunas Blvd 东侧建筑内部，玩家到不了）"
    )
    assert CURRENT.search(block), (
        "热狗摊坐标不是 Legion Square 广场点（这是 2026-11-14 离线渲染核对过的位置）"
    )
