"""qb-weapons：送修取回与弹药回写必须受服务端约束。

背景（2026-11-08，P1-3 批 4）—— 两个真洞，都用 Lua 沙箱探针在**旧实现**上实测过：

| 攻击 | 旧行为（实测） |
|---|---|
| `TakeBackWeapon(1)` 取别人送修的枪 | `AddItem` 成功 → 取回者拿到枪，送修者修好后还能再取一把（复制） |
| 送修未完成就 `TakeBackWeapon` | 同样成功（`Ready` 根本没判） |
| `TakeBackWeapon(999)` | `Config.WeaponRepairPoints[999].RepairingData` → `attempt to index a nil value` 崩服务端 |
| `UpdateWeaponAmmo({slot=1}, 999999)` | `info.ammo = 999999`（无限子弹） |
| `UpdateWeaponAmmo(..., -5)` | `info.ammo = -5`（负数弹药） |
| `{slot=1, name='weapon_carbinerifle'}` 写步枪弹药到手枪 | 名字完全不比对，直接写 |

做法：`fixtures/weapons_probe.lua` 真加载 `config.lua` + `server/main.lua`（反引号哈希字面量
先降级成 `GetHashKey(...)`），mock 掉 FiveM 运行时，逐场景触发 net event 并断言结果。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
RESOURCE = BASE / "resources" / "[qb]" / "qb-weapons"
PROBE = Path(__file__).resolve().parent / "fixtures" / "weapons_probe.lua"


def _run_probe() -> dict[str, list[str]]:
    proc = subprocess.run(
        ["lua5.4", PROBE.as_posix(), RESOURCE.as_posix()],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"probe 失败：\n{proc.stderr}\n{proc.stdout}"

    parsed: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        parsed.setdefault(key, []).append(value)
    assert "HANDLER_ERROR" not in parsed, f"handler 抛错：{parsed.get('HANDLER_ERROR')}"
    return parsed


def test_takeback_only_returns_your_own_finished_repair():
    data = _run_probe()
    # 前三次：别人的 / 没修好 / 坏索引 → 一件都不该发
    assert data["ADDED"][:3] == ["0", "0", "0"], (
        "取回了别人的枪、未修好的枪，或坏索引没被挡住（可复制武器）"
    )
    # 第四次：自己的、已修好 → 发一把
    assert data["ADDED"][3] == "1", "自己的枪修好了却取不回来"
    # 第五次：记录已消费 → 不能再发
    assert data["ADDED"][4] == "1", "同一把枪可以反复取回（复制）"


def test_ammo_is_clamped_and_bound_to_the_named_weapon():
    data = _run_probe()
    assert data["AMMO"][0] == "9999", "弹药上限没夹住（原来能直接写 999999 = 无限子弹）"
    assert data["AMMO"][1] == "9999", "负数弹药也被写进去了"
    assert data["AMMO"][2] == "9999", "坏 slot 改了别人的弹药"
    assert data["AMMO"][3] == "9999", "name 与 slot 不匹配时仍写入（可把步枪弹药写到手枪上）"
