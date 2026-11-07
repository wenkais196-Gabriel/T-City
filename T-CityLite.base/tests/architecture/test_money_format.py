"""闸门 G-B1：金额格式化的 `$%d` 债 —— 基线棘轮，只许减不许增。

背景（真机 2026-11-01）：`givemoney 1 cash 0.5` 连抛 10 次
`bad argument #4 to 'format' (number has no integer representation)`，
而 `EconomyService.AddMoney` 是「写内存 → 更新客户端 → 事件 → 写审计」，
所以**钱已进账、审计没写、调用方还收到错误**。税/佣金/乘算奖励必然产生小数。

为什么用基线而不是一次性全改：全仓 129 处，其中 42 处是 locale 文案（税率、保险、房产税），
批量改文案风险高于收益。所以策略是「冻结现状 + 逐处偿还」：新增必须登记，修好必须同步删条目
（双向相等，删多了也会红 —— 否则基线会悄悄腐烂）。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import money_format_scan as scan  # noqa: E402


def _baseline() -> dict:
    return json.loads(scan.BASELINE.read_text(encoding="utf-8"))


def test_money_format_debt_does_not_grow():
    baseline = _baseline()
    current = scan.as_multiset(scan.scan_repo())
    expected = baseline["entries"]

    added = {k: v - expected.get(k, 0) for k, v in current.items() if v > expected.get(k, 0)}
    removed = {k: expected[k] - current.get(k, 0) for k in expected if current.get(k, 0) < expected[k]}

    def render(table: dict[str, int]) -> str:
        return "\n  ".join(
            f"{key.split(chr(0))[0]}  {key.split(chr(0))[1][:70]}  ×{n}" for key, n in sorted(table.items())
        )

    assert not added, (
        "新增了 `$` 与 `%d` 同串的金额格式化（小数金额会抛 format 错）：\n  " + render(added)
        + "\n改成 `$%s` + 一个能渲染小数的格式化函数（整数不带小数点、小数两位）。"
    )
    assert not removed, (
        "有债已经不在代码里，但基线还留着（基线会腐烂，双向相等是刻意的）：\n  " + render(removed)
        + f"\n修好后跑一次：python {scan.__name__}.py（会重写 {scan.BASELINE.name}）"
    )


def test_baseline_metadata_is_valid():
    baseline = _baseline()
    assert baseline.get("owner"), "基线必须写 owner（债有主）"
    assert baseline.get("expires"), "基线必须有到期日，否则等于永久豁免"
    assert baseline["total"] == sum(baseline["entries"].values()), (
        f"total={baseline['total']} 与条目之和 {sum(baseline['entries'].values())} 不一致"
    )


def test_scanner_catches_money_shape_and_ignores_safe_shapes():
    assert len(scan.scan_text("('$%d'):format(0.5)")) == 1, "没抓到真实的金额 %d 形态"
    assert len(scan.scan_text("('价格 $%d'):format(price)")) == 1, "没抓到中文文案里的金额 %d"

    # 安全的写法 / 非金额的 %d，都不该报
    assert scan.scan_text("('$%s'):format(fmtMoney(0.5))") == []
    assert scan.scan_text("('处理了 %d 条'):format(#rows)") == []
    assert scan.scan_text("('罚单 #%d'):format(id)") == []
    # 注释里的示例代码不算
    assert scan.scan_text("-- ('$%d'):format(x)\nlocal a = 1") == []
