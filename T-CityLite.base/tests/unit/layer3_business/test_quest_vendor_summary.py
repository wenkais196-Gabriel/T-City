"""S5 账单数据（B0）：收摊之后的任务完成路径还能拿到售出 / 回收汇总。

已核实的旧行为：摊主按 E 收摊时 `QuestVendorBridge.CloseFor` 返回 summary，但调用方只
发了一条「收摊了」通知就把它丢了；任务完成回调里再调一次 `CloseFor` 时会话已经销毁，
返回 nil，于是 `issueSettleReceipt` 里的 soldTotal / leftover / raw 全成 0。

这一组用真实实现跑「收摊 → 完成」：
  • 运行时探针（fixtures/vendor_summary_probe.lua）证明卖出的钱能进入
    `QuestSettle.Compute` 的 soldTotal，并且缓存取一次就没了；
  • 变异用例删掉「取走即删」那一行，探针必须红（反向证明一次性消费不是摆设）；
  • 静态接线：完成路径的 `closeVendorFor` 真的会去取这份缓存。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
RESOURCE = BASE / "resources/[custom]/custom-quest"
BRIDGE = RESOURCE / "server/quest_vendor_bridge.lua"
MANAGER = RESOURCE / "server/quest_manager.lua"
PROBE = Path(__file__).with_name("fixtures") / "vendor_summary_probe.lua"

# 与既有测试一致：Windows 上 subprocess 只能直接执行 .exe
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

#: 唯一的一次性消费点。改名时这条反向校验会先报 count != 1，而不是悄悄永远绿。
CONSUME_LINE = (
    "    -- 一次性消费：取走即删，重复调用返回 nil。\n"
    "    LastSummary[citizenid] = nil\n"
    "    return entry.summary"
)


def _run_probe(resource: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(resource)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


def _copy_resource(dst: Path) -> Path:
    """把探针需要的三个服务端文件复制到临时资源目录（做变异用）。"""
    target = dst / "custom-quest"
    (target / "server").mkdir(parents=True)
    for name in ("quest_vendor.lua", "quest_settle.lua", "quest_vendor_bridge.lua"):
        shutil.copy(RESOURCE / "server" / name, target / "server" / name)
    return target


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_close_then_complete_computes_nonzero_sold_total():
    """收摊之后的完成路径必须还能算出非 0 的售出总额。"""
    proc = _run_probe(RESOURCE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "FAIL" not in proc.stdout, proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_probe_goes_red_when_cache_is_not_consumed(tmp_path: Path):
    """反向校验：去掉「取走即删」，第二次取仍拿到同一份汇总，探针必须红。

    没有这条，缓存就变成「每次任务完成都能再结算一次」的印钞机。
    """
    src = BRIDGE.read_text(encoding="utf-8")
    assert src.count(CONSUME_LINE) == 1, (
        "一次性消费点不唯一或已被改名：先更新 CONSUME_LINE，否则这条反向校验会失效")
    mutated = src.replace(CONSUME_LINE, "    return entry.summary", 1)

    target = _copy_resource(tmp_path)
    (target / "server/quest_vendor_bridge.lua").write_text(mutated, encoding="utf-8")

    proc = _run_probe(target)
    assert proc.returncode != 0, (
        "缓存不消费后探针仍然全绿 —— 同一份收摊数据会被重复结算")
    failed = [line for line in proc.stdout.splitlines() if "FAIL" in line]
    assert any("TAKE_IS_ONE_SHOT" in line for line in failed), (
        f"期望 TAKE_IS_ONE_SHOT 变红，实际失败行：{failed}")
    assert any("NO_DOUBLE_SETTLE" in line for line in failed), (
        f"期望 NO_DOUBLE_SETTLE 变红，实际失败行：{failed}")


def test_completion_path_uses_the_one_shot_cache():
    """完成路径的 closeVendorFor 必须去取桥里的缓存，否则数据还是丢。"""
    manager = MANAGER.read_text(encoding="utf-8")
    block = manager[manager.index("local function closeVendorFor"):]
    block = block[:block.index("\nend\n")]
    assert "QuestVendorBridge.CloseFor" in block
    assert "QuestVendorBridge.TakeLastSummary" in block, (
        "closeVendorFor 没有取一次性缓存 —— 第二次 CloseFor 返回 nil 时账单仍是 0")
    # 只断言「出现过这个名字」会被 `if false and …` 这种改法骗过去（实测过）。
    # 所以这里钉住整段守卫 + 取用调用：删掉、改名、或者把它短路掉都会红。
    assert ("    if not summary and type(QuestVendorBridge.TakeLastSummary) == 'function' then\n"
            "        local okCached, cached = pcall(QuestVendorBridge.TakeLastSummary, citizenid, questId)\n"
            "        if okCached then summary = cached end\n"
            "    end") in block, (
        "完成路径的缓存回补被改写了 —— 允许改实现，但要同步这里；不接受只留一句注释或短路守卫")

    bridge = BRIDGE.read_text(encoding="utf-8")
    assert "function QuestVendorBridge.TakeLastSummary" in bridge
    assert "SUMMARY_TTL_MS" in bridge, "缓存没有过期上界"
    open_block = bridge[bridge.index("function QuestVendorBridge.OpenFor"):]
    open_block = open_block[:open_block.index("\nend\n")]
    assert "LastSummary[citizenid] = nil" in open_block, (
        "新会话开始必须清掉上一班的汇总，否则旧数据会串到下一班")


def test_cache_does_not_add_a_net_event():
    """B0 只加内存缓存：事件面不变。"""
    bridge = BRIDGE.read_text(encoding="utf-8")
    assert bridge.count("RegisterNetEvent(") == 1
