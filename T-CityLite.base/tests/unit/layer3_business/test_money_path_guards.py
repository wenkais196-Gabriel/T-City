"""P1-5 二期：金额写路径 —— 同一组非法输入在三个入口得到同一个答复。

`SecurityService.ValidateAmount` 是**唯一**实现（非数字 / NaN / inf / 负数 / 0 / 超阈值都拒绝，
不 clamp）。探针真加载 `security_service.lua` + `economy_service.lua`，把 7 组输入喂给
`AddMoney` / `RemoveMoney` / `SetMoney`，同时验证「合法值必须能过」（否则全拒的实现也能拿满分）。

对 master 版本跑，同一份探针的输出是：

```
ECONOMY_AddMoney_NAN|accept        <- 钱写成 NaN
ECONOMY_AddMoney_INF|accept        <- 钱写成 inf
ECONOMY_AddMoney_OVER|accept       <- 5,000,001 直接进账
ECONOMY_RemoveMoney_NAN|accept
```

`player.lua` 的 offline / fallback 分支（Bus 缺失时）现在也走同一条校验；这层不单独写探针，
由静态闸门 `test_money_write_path.py` 断言「三个写入口都引用 ValidateAmount」覆盖。
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


def test_shared_validator_rejects_everything_that_is_not_a_plain_amount():
    data = _run("money_path_probe.lua", "[qb]/qb-core")
    assert data["VALIDATOR_EXISTS"] == "true", "SecurityService.ValidateAmount 不存在"
    assert data["THRESHOLD_IS_FIVE_MILLION"] == "true", "单笔阈值不是 5,000,000"
    assert data["VALIDATOR_REJECTS_NAN"] == "true", "NaN 被当成合法金额"
    assert data["VALIDATOR_REJECTS_INF"] == "true", "inf 被当成合法金额"
    assert data["VALIDATOR_REJECTS_NEG_INF"] == "true", "-inf 被当成合法金额"
    assert data["VALIDATOR_REJECTS_STRING"] == "true", "非数字字符串被当成合法金额"
    assert data["VALIDATOR_REJECTS_NEGATIVE"] == "true", "负数没被拒"
    assert data["VALIDATOR_REJECTS_ZERO_BY_DEFAULT"] == "true", "默认允许 0（Add/Remove 不该允许）"
    assert data["VALIDATOR_ALLOWS_ZERO_WHEN_ASKED"] == "true", "SetMoney 的 0 被误拒"
    assert data["VALIDATOR_ALLOWS_999999"] == "true", "999,999 低于阈值却被拒（过度收紧）"
    assert data["VALIDATOR_REJECTS_OVER_LIMIT"] == "true", "超阈值没被拒"
    assert data["VALIDATOR_ALLOWS_LIMIT"] == "true", "刚好等于阈值却被拒（过度收紧）"


def test_add_money_rejects_nan_inf_and_over_limit():
    data = _run("money_path_probe.lua", "[qb]/qb-core")
    assert data["ECONOMY_AddMoney_NAN"] == "reject", "AddMoney 接受 NaN（旧版就是 accept）"
    assert data["ECONOMY_AddMoney_INF"] == "reject", "AddMoney 接受 inf"
    assert data["ECONOMY_AddMoney_STRING"] == "reject", "AddMoney 接受字符串"
    assert data["ECONOMY_AddMoney_NEGATIVE"] == "reject", "AddMoney 接受负数"
    assert data["ECONOMY_AddMoney_ZERO"] == "reject", "AddMoney 接受 0"
    assert data["ECONOMY_AddMoney_OVER"] == "reject", "AddMoney 接受超阈值金额（旧版就是 accept）"
    assert data["ECONOMY_AddMoney_999999"] == "accept", "999,999 被拒（过度收紧）"


def test_remove_money_rejects_nan_and_over_limit():
    data = _run("money_path_probe.lua", "[qb]/qb-core")
    assert data["ECONOMY_RemoveMoney_NAN"] == "reject", "RemoveMoney 接受 NaN（旧版就是 accept）"
    assert data["ECONOMY_RemoveMoney_INF"] == "reject", "RemoveMoney 接受 inf"
    assert data["ECONOMY_RemoveMoney_OVER"] == "reject", "RemoveMoney 接受超阈值金额"
    assert data["ECONOMY_RemoveMoney_NEGATIVE"] == "reject", "RemoveMoney 接受负数（会反向加钱）"


def test_set_money_keeps_zero_but_rejects_over_limit():
    data = _run("money_path_probe.lua", "[qb]/qb-core")
    assert data["ECONOMY_SetMoney_NAN"] == "reject", "SetMoney 接受 NaN"
    assert data["ECONOMY_SetMoney_OVER"] == "reject", "SetMoney 接受超阈值金额"
    assert data["ECONOMY_SetMoney_ZERO"] == "accept", "SetMoney 清空到 0 被拒（过度收紧）"


def test_合法输入仍然生效():
    data = _run("money_path_probe.lua", "[qb]/qb-core")
    assert data["ECONOMY_ADD_NORMAL"] == "true", "正常加钱被拒（全拒的实现也能过负向用例）"
    assert data["ECONOMY_REMOVE_NORMAL"] == "true", "正常扣钱被拒"
    assert data["ECONOMY_SET_NORMAL"] == "true", "正常设钱被拒"
    assert data["ECONOMY_SET_ZERO_ALLOWED"] == "true", "SetMoney(0) 被拒"
    assert data["ECONOMY_BAD_MONEYTYPE_SAFE"] == "true", "moneytype 为 nil 时抛错"
