"""P2-1：Patron 服务读路径不再 Await DB（延迟 fake DB 断言不阻塞）。

`PatronService.GetTier` 原来在缓存未命中时 `promise.new()` + `Citizen.Await` 同步查库：
第一次读就把处理该事件的协程挂住，而 `GetTier` 又被 `IsActive` / `GetTierBySource` 这类高频入口调用。
现在改成「只读缓存，未命中返回 0 + 后台预热」，需要准确值的调用方用 `GetTierAsync`。

探针里的 `Citizen.Await` 桩**直接报错**（'would block the game thread'），fake oxmysql 支持
正常 / 同步抛错 / 永不回调三种模式。对 master 版本跑：5 true / **17 false**。
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
        key, _, value = line.partition("|")
        if key.startswith("PATRON_"):
            data.setdefault(key, value)
    return data


def test_get_tier_never_blocks_on_a_slow_database():
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_COLD_NO_BLOCK"] == "true", "冷缓存时 GetTier 走了 Await（旧版就是这样）"
    assert data["PATRON_COLD_ISSUED_QUERY"] == "true", "冷缓存时没触发后台预热（永远不会热）"
    assert data["PATRON_WARMED_TIER"] == "true", "DB 回来后缓存没落地"
    assert data["PATRON_WARM_NO_EXTRA_QUERY"] == "true", "缓存已热还继续撞库"


def test_expired_and_failed_records_degrade_to_zero():
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_EXPIRED_IS_ZERO"] == "true", "过期记录没降级成 0"
    # 过期记录不能把 expires_at 留在缓存里：留着会让 cacheValid 每次都判否 → 每读一次查一次库
    assert data["PATRON_EXPIRED_SINGLE_QUERY"] == "true", "过期记录每读一次都撞库"
    assert data["PATRON_FAIL_TIER_ZERO"] == "true", "DB 失败时不是 0"


def test_failed_reads_back_off_for_seconds_not_the_full_cache_ttl():
    """CC 复核抓到的失真：失败条目曾经沿用 5 分钟 TTL，`failed_at` 的 30 秒退避是死代码。"""
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_FAIL_BACKOFF_IN_WINDOW"] == "true", "失败后立刻又去撞库"
    assert data["PATRON_FAIL_STILL_COOLING_AT_20S"] == "true", "20 秒内不该重试"
    assert data["PATRON_FAIL_RETRIES_AFTER_30S"] == "true", "过了 30 秒还不重试（说明退避被拉长到 TTL）"
    assert data["PATRON_RECOVERS_AFTER_BACKOFF"] == "true", "退避结束后没恢复真实等级"


def test_warm_rejects_stuck_loading_and_sync_errors():
    """`loading` 守卫不能把人锁死：导出同步抛错 / 回调永不回来都要能重试。"""
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_SYNC_ERROR_NO_CRASH"] == "true", "导出同步抛错时 GetTier 崩了"
    assert data["PATRON_SYNC_ERROR_RECOVERS"] == "true", "同步抛错后 loading 没清，永久不重试"
    assert data["PATRON_SYNC_ERROR_TIER"] == "true", "同步抛错恢复后等级不对"
    assert data["PATRON_WATCHDOG_WAITS"] == "true", "看门狗窗口内就重试了（会放大并发）"
    assert data["PATRON_WATCHDOG_RETRIES"] == "true", "回调永不回来时没有看门狗，永久锁死"
    # SetTier 之后，之前发出去的查询回调必须作废（否则刚设的等级被旧结果覆盖）
    assert data["PATRON_SET_SURVIVES_STALE_FAILURE"] == "true", "SetTier 被在途回调的失败结果覆盖"
    assert data["PATRON_SET_SURVIVES_STALE_ROW"] == "true", "SetTier 被在途回调带回的旧行覆盖"
    # 看门狗重发会并存两条同代际查询：慢的那条晚到不许覆盖快的那条
    assert data["PATRON_WATCHDOG_TWO_QUERIES"] == "true", "看门狗没有重发"
    assert data["PATRON_WATCHDOG_Q2_APPLIED"] == "true", "新查询的结果没落地"
    assert data["PATRON_WATCHDOG_STALE_Q1_IGNORED"] == "true", "晚到的旧查询覆盖了新结果"
    assert data["PATRON_STALE_CB_ANSWERS"] == "true", "结果过期时回调永远不会被调用"


def test_get_tier_async_resolves_after_load():
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_ASYNC_CACHE_HIT"] == "true", "缓存命中时没有同步回调"
    assert data["PATRON_ASYNC_PENDING"] == "true", "未命中时不该同步回调（应等加载）"
    assert data["PATRON_ASYNC_RESOLVED"] == "true", "加载完成后没有回调真实等级"


def test_set_tier_still_validates_and_updates_cache():
    data = _run("patron_probe.lua", "[standalone]/core-framework")
    assert data["PATRON_SET_REJECTS_9"] == "true", "SetTier 接受越界等级"
    assert data["PATRON_SET_ACCEPTS_2"] == "true", "SetTier 拒绝合法等级"
    assert data["PATRON_SET_CACHE_DIRECT"] == "true", "SetTier 没立刻更新缓存"
