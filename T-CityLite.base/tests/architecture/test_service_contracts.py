"""ARCH — 方法级导出契约：`exports['<res>']:<Method>(...)` 必须真的存在。

为什么这条规则值得单独存在：资源代理 `exports['some-resource']` **永远是 truthy**，
所以 `if exports['x'] then` / `if exports['x'].Method then` 这种守卫挡不住任何东西；
方法不存在时 FiveM 只在该调用点抛 `No such export`，外面套一层 pcall 就彻底静默
（钱没发、物品没到、界面不注册，服务端日志干干净净）。

闸门把两侧都从代码里推出来：

* 声明侧 = 所有字面量 ``exports('Name', ...)`` + 所有 ``Bus.RegisterService('<svc>', {...})``
  块 + 字面量 ``exports('service_<svc>_<Method>', ...)``；
* 调用侧 = 所有 ``*.lua`` 里的字面量 ``exports['<res>']:<Method>(``（剥注释/字符串）；
* 树内资源的方法必须能在本资源声明里找到；树外/动态注册只按
  ``service_contracts.json`` 的 ``external_exports`` / ``dynamic_exports`` 逐方法放行。

登记表由 ``tools/dev/service_contracts_scan.py --update`` 生成 ``services`` 段，
人工复核 33 个外部调用点对应的方法（``review`` 锚点会钉住数量与服务名）。

    python3 -m pytest -q tests/architecture/test_service_contracts.py
"""
from __future__ import annotations

import importlib.util
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
TOOL = REPO / "tools" / "dev" / "service_contracts_scan.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location("service_contracts_scan", TOOL)
    assert spec and spec.loader, f"找不到扫描器：{TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["service_contracts_scan"] = module
    spec.loader.exec_module(module)
    return module


def test_every_export_call_resolves():
    """前向：真实仓库里每一处字面量导出调用都能解析到声明或已登记的动态/外部契约。"""
    tool = _load_tool()
    result = tool.scan()
    registry = tool.load_registry()
    problems = tool.violations(result, registry)

    assert result.resource_dirs, "扫描不到任何资源目录，范围被改坏了？"
    assert result.calls, "扫描不到任何 `exports['res']:Method(` 调用，范围被改坏了？"
    assert len(result.declared_service_methods()) >= 20, "Bus.RegisterService 一个都没解析到？"

    assert not problems, (
        "导出契约闸门红了。修法：把调用点改成真实 owner 的导出；树内方法不存在就是死调用，"
        "不要用 pcall / truthy 守卫糊过去。树外或动态注册的方法逐方法登记进 "
        "tests/architecture/service_contracts.json 的 external_exports / dynamic_exports。\n  "
        + "\n  ".join(problems))


def test_reverse_unresolved_export_is_rejected():
    """反向：合成的未声明调用必须报；注释/字符串里的同名文本必须不报。"""
    tool = _load_tool()
    registry = tool.load_registry()

    declared = defaultdict(set)
    declared["custom-main"] |= {"LogEconomy"}
    declared["custom-storage"] |= {"service_storage_AddItem"}

    def problems_for(source: str) -> list[str]:
        synthetic = tool.Scan()
        synthetic.resource_dirs = {"custom-main", "custom-storage"}
        synthetic.declarations = declared
        synthetic.calls = tool.extract_calls(source, "probe.lua", caller="probe")
        return tool.call_violations(synthetic, registry)

    # 真调用 → 必须报
    unresolved = problems_for(
        "exports['custom-main']:AddScaledMoney(1, 'cash', 1, 'probe')\n")
    assert any("AddScaledMoney" in problem for problem in unresolved), unresolved

    # 注释 / 字符串里的同名文本 → 必须不报（否则文案里的示例代码会把闸门刷红）
    quiet = problems_for(
        "-- exports['custom-main']:AddScaledMoney(1, 'cash', 1, 'probe')\n"
        "local example = \"exports['custom-main']:AddScaledMoney(1, 'cash', 1, 'probe')\"\n"
        "local block = [[ exports['custom-main']:AddScaledMoney(1, 'cash', 1, 'probe') ]]\n")
    assert not quiet, quiet

    # 未登记的 service 方法 → 必须报
    unresolved_service = problems_for(
        "exports['custom-storage']:service_storage_NoSuchMethod()\n")
    assert any("NoSuchMethod" in problem for problem in unresolved_service), unresolved_service

    # 已声明方法 / 已登记的动态资源 → 必须不报
    assert not problems_for("exports['custom-main']:LogEconomy('t', 'm', 1)\n")
    assert not problems_for("exports['qb-core']:GetPlayer(1)\n")
