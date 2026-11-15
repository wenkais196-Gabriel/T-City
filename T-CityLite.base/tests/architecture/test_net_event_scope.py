"""net event 口径校准 —— "归属判定"也是一种授权（`job_deny_guard` 收紧后的配套）。

背景（baseline §3.1.1 的技术债）：`job_deny_guard` 原来是"任意 player 变量上出现 `~=` + return"就算
职业守卫，于是 `if Player.PlayerData.citizenid ~= x then return end` 这种**归属/参数校验**也被当成
鉴权 —— 全仓约 36 条因此被算成"已鉴权"。

收紧之后必须回答：这些 handler 到底**有没有**授权？三类答案：

1. **真没有** → 补守卫（本轮没有遇到）；
2. **有，但形状不同** → 让扫描器认得：
   * `self_scope_guard`：`if <记录>.citizenid ~= Player.PlayerData.citizenid then return end`，
     以及 `local racer = Races[id].Racers[Player.PlayerData.citizenid]` + `if not racer then return end`；
   * 登记 helper（`inReviveWindow` / `IsRaceHost` / `IsWhitelisted` 走 already_checked）——
     必须是真实现 + 调用点形状对得上；
3. **供应商自带**（cfx-default / monitor / PolyZone / connectqueue）→ `vendor_example`：
   不是债，是口径。闸门按文件前缀校验，防止给自己代码开后门。

出口判据：**本仓库自己的资源里，未鉴权又未登记的事件数 = 0**。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ARCH = REPO / "T-CityLite.base" / "tests" / "architecture"
sys.path.insert(0, ARCH.as_posix())

import net_event_scan as scan  # noqa: E402

ALLOWLIST = ARCH / "net_events_allowlist.json"
VENDOR_PREFIXES = (
    "[cfx-default]/", "[system]/monitor/",
    "[standalone]/PolyZone/", "[standalone]/connectqueue/",
)


def allowlist_entries() -> dict[str, dict]:
    data = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    return {entry["name"]: entry for entry in data["entries"]}


# ══════════════════════════════════════════════════════════════════
# 守卫形状：接受真的，拒绝假的
# ══════════════════════════════════════════════════════════════════

def test_reverse_self_scope_guard_accepts_own_record_and_rejects_lookalikes():
    # 接受：与自己的 citizenid 比
    assert scan.self_scope_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if owner ~= Player.PlayerData.citizenid then return end\n"
    )
    # 接受：用 citizenid 从表里取"自己那条"，再判空
    assert scan.self_scope_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "local racer = Races[raceId].Racers[Player.PlayerData.citizenid]\n"
        "if not racer or racer.FinishHandled then return end\n"
    )
    # 拒绝：只是判玩家存在 / 参数类型（收紧前就是这么把 36 条算成已鉴权的）
    assert not scan.self_scope_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if not Player then return end\n"
        "if type(plate) ~= 'string' then return end\n"
    )
    # 拒绝：判定分支里没有真的 return
    assert not scan.self_scope_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if owner ~= Player.PlayerData.citizenid then\n"
        "    TriggerClientEvent('notify', src, 'not yours')\n"
        "end\n"
    )
    # 拒绝：注释里写的判定不算
    assert not scan.self_scope_guard(scan.strip_lua_noise(
        "-- if owner ~= Player.PlayerData.citizenid then return end\n"
        "local Player = QBCore.Functions.GetPlayer(src)\n"
    ))


def test_reverse_job_guard_accepts_real_job_and_rejects_citizenid_compare():
    # 接受：职业白名单
    assert scan.job_deny_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if not Player or Player.PlayerData.job.name ~= 'ambulance' then return end\n"
    )
    # 接受：把职业取成局部变量再比较
    assert scan.job_deny_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "local job = Player.PlayerData.job\n"
        "if job.name ~= 'police' then return end\n"
    )
    # 拒绝：citizenid 比较不是职业守卫（本轮收紧的核心）
    assert not scan.job_deny_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if Player.PlayerData.citizenid ~= citizenid then return end\n"
    )
    # 拒绝：死分支
    assert not scan.job_deny_guard(
        "local Player = QBCore.Functions.GetPlayer(src)\n"
        "if Player.PlayerData.job.name ~= 'police' and false then return end\n"
    )


# ══════════════════════════════════════════════════════════════════
# 出口判据：本仓库自己的资源不许留未鉴权事件
# ══════════════════════════════════════════════════════════════════

def test_own_resources_have_no_unguarded_events():
    """[qb] / [custom] / [system]（除 monitor）下的事件：要么有守卫、要么登记。"""
    resources = REPO / "T-CityLite.base" / "resources"
    events, _ = scan.scan_repo(resources)
    allowed = set(allowlist_entries())

    offenders = []
    for event in events:
        relative = event.path.relative_to(resources).as_posix()
        if relative.startswith(VENDOR_PREFIXES):
            continue
        if scan.is_guarded(event) or event.name in allowed:
            continue
        offenders.append(f"{event.name} ({relative}:{event.line})")

    assert not offenders, "本仓库还有未鉴权也没登记的事件：\n  - " + "\n  - ".join(offenders)

    # 同一份 allowlist 的另一半：vendor_example 只能指向供应商文件
    for name, entry in allowlist_entries().items():
        if entry.get("category") == "vendor_example":
            assert entry["file"].startswith(VENDOR_PREFIXES), (
                f"{name}: vendor_example 却指向 {entry['file']} —— 只有供应商资源能用这个类别"
            )
