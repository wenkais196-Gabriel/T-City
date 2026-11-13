"""阶段 D · C1：validator 步骤的服务端闸。

背景：`validator` 步骤只在 `dashboardStampDelivery` 那条路径上执行过 `validator_id`；
客户端 `nodeComplete` 路径直接 `ValidateNode` → `AdvanceStep`，校验器从未跑过
（调研 01-research.md §2.1-5）。本测试覆盖两层：

1. 行为层：`QuestStepGate` 纯函数的判定（哪些步骤必须过 validator、入参合成、开关默认值）；
2. 契约层：`nodeComplete` 处理器必须在 `AdvanceStep` **之前**咨询这个闸 ——
   顺序反了等于没拦，而顺序是文本检查能判的（带反向校验，见架构测试）。
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
    return data


def test_only_validator_steps_with_an_id_are_gated():
    data = _run("quest_step_gate_probe.lua", "[custom]/custom-quest")
    assert data["RV_VALIDATOR_OK"] == "validate_delivery_arrival", "带 validator_id 的步骤没被识别"
    assert data["RV_NO_ID"] == "true", "没有 validator_id 却被当成需要校验（会让普通步骤卡死）"
    assert data["RV_EMPTY_ID"] == "true", "空字符串 validator_id 也被当成需要校验"
    assert data["RV_WRONG_TYPE"] == "true", "非 validator 类型也被要求过校验（过度收紧）"
    assert data["RV_NIL_STEP"] == "true", "nil 步骤抛错"
    assert data["RV_NO_DATA"] == "true", "没有 data 的 validator 步骤抛错"


def test_validator_payload_merges_only_metadata():
    data = _run("quest_step_gate_probe.lua", "[custom]/custom-quest")
    assert data["PAYLOAD_FROM_VALIDATOR_DATA"] == "true", "validator_data 没被带进校验器入参"
    assert data["PAYLOAD_META_RADIUS"] == "true", "radius 这类 meta 字段没合并（校验器会判错距离）"
    assert data["PAYLOAD_META_DEST"] == "true", "destCoords 没合并（到达校验直接失效）"
    assert data["PAYLOAD_SKIPS_UI"] == "true", "把 UI 字段（coords/label/duration）也塞进校验器入参"
    assert data["PAYLOAD_NIL_SAFE"] == "true", "nil 步骤不是空表"


def test_enforcement_defaults_on_and_can_be_rolled_back():
    data = _run("quest_step_gate_probe.lua", "[custom]/custom-quest")
    assert data["ENFORCE_DEFAULT"] == "true", "默认没有开启拦截（等于没做）"
    assert data["ENFORCE_OFF_ZERO"] == "true", "convar=0 关不掉（回滚失效）"
    assert data["ENFORCE_OFF_FALSE"] == "true", "convar=false 关不掉"
    assert data["ENFORCE_ON_ONE"] == "true", "convar=1 反而关掉了"
