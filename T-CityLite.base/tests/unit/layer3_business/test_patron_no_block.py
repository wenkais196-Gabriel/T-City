"""P2-1：Patron 服务读路径不再 Await DB（延迟 fake DB 断言不阻塞）。

`PatronService.GetTier` 原来在缓存未命中时 `promise.new()` + `Citizen.Await` 同步查库：
第一次读就把处理该事件的协程挂住，而 `GetTier` 又被 `IsActive` / `GetTierBySource` 这类高频入口调用。
现在改成「只读缓存，未命中返回 0 + 后台预热」，需要准确值的调用方用 `GetTierAsync`。

探针里的 `Citizen.Await` 桩**直接报错**（'would block the game thread'），fake oxmysql 故意不立刻回调。
对 master 版本跑，10 条断言翻红（`PATRON_COLD_NO_BLOCK=false` 等）。
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
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
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
    assert data["PATRON_FAIL_TIER_ZERO"] == "true", "DB 失败时不是 0"
    assert data["PATRON_FAIL_BACKOFF"] == "true", "DB 失败后没有退避，每次读都去撞库"


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
