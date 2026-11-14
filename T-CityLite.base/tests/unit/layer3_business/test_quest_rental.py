"""租借原语（S1）：押金、计租、关闭路径、重启补退。

为什么单独立闸：热狗线把「租 → 卖 → 还」做成一个**会话**，钱在会话两端进出。
这类代码最容易出的错不是算错，而是**没有关闭路径**——
我们自己的物流就踩过：`ClearLogisticsBinding` 定义了却零调用，放弃/失败/断线后绑定残留。

本闸守 9 条不变量（由 `fixtures/rental_probe.lua` 真跑 `quest_rental.lua` 验证）：
押金不足不建会话 / 重复 open 被拒 / 正常关租退款 = 押金 − 租金 / 重复关租幂等 /
超时按 max_minutes 封顶 / 断线只排队不转账 / 启动扫描只排队 / 登录补退只发生一次 /
免租期内不产生租金。

并带反向校验：把「封顶」改成不封顶，探针必须红。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
RENTAL = BASE / "resources/[custom]/custom-quest/server/quest_rental.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "rental_probe.lua"
LUA = shutil.which("lua5.4")


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只能跑静态断言")
def test_rental_invariants_hold():
    proc = run_probe(RENTAL)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 9/9" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_probe_goes_red_when_the_cap_is_removed(tmp_path: Path):
    """反向校验：去掉 max_minutes 封顶，超时那一条必须红。"""
    src = RENTAL.read_text(encoding="utf-8")
    assert "if maxMinutes > 0 and minutes > maxMinutes then" in src
    mutated = src.replace("if maxMinutes > 0 and minutes > maxMinutes then", "if false then")
    target = tmp_path / "quest_rental_mutant.lua"
    target.write_text(mutated, encoding="utf-8")
    proc = run_probe(target)
    assert proc.returncode != 0, "去掉封顶后探针仍然通过 —— 这条闸没有在验证任何东西"
    assert "timeout_is_capped_at_max_minutes" in proc.stdout
    assert "FAIL" in proc.stdout


def test_close_paths_are_wired_into_every_termination_route():
    """成功、失败、放弃、断线四条路径都必须关租；少一条就是「押金要不回来」。

    成功这条最容易被漏（本会话就漏过一次）：失败/放弃/断线都关了，
    但完成任务时没人关，押金就卡在会话里直到玩家下次断线或超时。
    """
    manager = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    cache = (BASE / "resources/[custom]/custom-quest/server/quest_cache.lua").read_text(encoding="utf-8")
    assert "closeRentalFor(src, 'returned')" in manager, "完成任务时没有关租 —— happy path 押金退不回来"
    assert "closeRentalFor(source, 'failed')" in manager
    assert "closeRentalFor(source, 'abandoned')" in manager
    assert "QuestRental.CloseOnDrop" in cache


def test_drop_path_defers_money_instead_of_paying_offline():
    """断线不能直接 AddMoney —— 那时玩家对象已经不可用。必须走待退队列。"""
    src = RENTAL.read_text(encoding="utf-8")
    drop_body = src[src.index("function QuestRental.CloseOnDrop"):src.index("function QuestRental.QueueUnclosedSessions")]
    assert "AddMoney" not in drop_body, "断线路径里出现了 AddMoney —— 离线玩家没有合法的写入路径"
    assert "PendingRefunds[citizenid]" in drop_body


def test_restart_scan_only_queues():
    """启动扫描只读日志 + 写内存，不许转账。"""
    src = RENTAL.read_text(encoding="utf-8")
    scan_body = src[src.index("function QuestRental.QueueUnclosedSessions"):src.index("function QuestRental.ClaimPendingRefund")]
    assert "AddMoney" not in scan_body, "启动扫描里出现了 AddMoney"
    assert "PendingRefunds[cid]" in scan_body
