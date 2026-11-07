"""闸门：顶层缓存 QBCore 却没重解析的文件 —— 基线棘轮，只许减不许增。

真机 2026-11-07：`qb-clothing` 报 `Execution of function reference in script host failed`。
文件顶层的 `local QBCore = exports['qb-core']:GetCoreObject()` 是 **qb-core 当次 script host
的快照**，`restart qb-core` 之后表里的函数引用全部失效；而它没有声明 qb-core 依赖，
所以重启级联也不会把它带走 —— 旧表一直用下去。

与 PR #193/#194 修的那类（MySQL 回调里调跨资源引用）不是同一件事：
那次是**调用上下文**不对，这次是**缓存过期**，静态看完全正常。

三种安全形态（不算风险）：
  1. 在 `onResourceStart` / `onClientResourceStart` 里给**同一变量**重新 `GetCoreObject()`（自愈）；
  2. 资源 fxmanifest 显式声明 qb-core 依赖（随 `restart qb-core` 一起重启，顶层缓存重跑）；
  3. 文件里压根不用 `Functions/Player/Commands/ServerCallbacks`（只读数据，不碰函数引用）。

client 侧（`client/` 目录）单独记在 `client_unverified`：跨客户端语义还没在真机验证过，
所以不进棘轮，但**也不许悄悄变多**（新增同样判红）。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stale_core_cache_scan as scan  # noqa: E402

DANGEROUS = "local QBCore = exports['qb-core']:GetCoreObject()\nQBCore.Functions.GetPlayer(1)\n"


def _keys(items: list[str]) -> str:
    return "\n  ".join(item.replace("\u0000", "  var=") for item in items)


def test_no_new_stale_core_cache_files():
    added, removed, client_added, client_removed = scan.check()
    assert not added, (
        "新增了「顶层缓存 QBCore 且不在重启级联内、又没重解析」的文件 —— `restart qb-core` 后"
        "这些函数引用会失效：\n  " + _keys(added)
        + "\n修法：加 AddEventHandler('onResourceStart', ...) → QBCore = exports['qb-core']:GetCoreObject()，"
          "或在 fxmanifest 里声明 dependency 'qb-core'（会让它随重启一起重载）。"
    )
    assert not client_added, (
        "client 侧新增了未登记的风险文件（跨客户端语义未验证，先记账再谈修）：\n  " + _keys(client_added)
        + f"\n确认后重写基线：python {Path(scan.__file__).name} --write（会同时刷新两侧清单）"
    )
    assert not removed, (
        "基线里的文件已经不在风险集里了（修好了或写法变了），请同步删条目，否则基线会腐烂：\n  "
        + _keys(removed)
        + f"\n重写基线：python {Path(scan.__file__).name} --write"
    )
    assert not client_removed, "client_unverified 里的文件已消失，请同步刷新清单：\n  " + _keys(client_removed)


def test_baseline_metadata_is_valid():
    payload = json.loads(scan.BASELINE.read_text(encoding="utf-8"))
    assert payload.get("owner"), "基线必须写 owner"
    assert payload.get("expires"), "基线必须有到期日"
    assert payload["count"] == len(payload["entries"]), "count 与 entries 条目数不一致"
    assert payload.get("client_count") == len(payload.get("client_unverified", [])), (
        "client_count 与 client_unverified 条目数不一致"
    )
    assert payload["count"] + payload["client_count"] > 0, (
        "两侧都为 0 说明扫描器坏了（真机已证实至少有条 client 侧风险），不要用空基线骗绿"
    )


def test_scanner_classifies_the_three_safe_shapes():
    """自证：三种安全形态都不该被判风险，四种危险/伪装形态必须被抓到。"""
    assert scan.CACHE.search(DANGEROUS), "没识别出顶层缓存"
    assert scan._has_rehook(DANGEROUS, "QBCore") is False, "危险形态被误判为已重挂"

    rehook = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "AddEventHandler('onResourceStart', function(name)\n"
        "    if name == 'qb-core' then QBCore = exports['qb-core']:GetCoreObject() end\n"
        "end)\n"
    )
    assert scan._has_rehook(rehook, "QBCore"), "带重解析的形态没被识别为自愈"

    # 伪装 1：只 RegisterNetEvent、没有 AddEventHandler（CC 提的 qb-clothing/client 形态）
    net_event = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "RegisterNetEvent('onResourceStart', function(name)\n"
        "    QBCore = exports['qb-core']:GetCoreObject()\n"
        "end)\n"
    )
    assert not scan._has_rehook(net_event, "QBCore"), "RegisterNetEvent 冒充重挂被当成自愈"

    # 伪装 2：注释里写着事件名 + GetCoreObject
    commented = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "-- AddEventHandler('onResourceStart', function() QBCore = exports['qb-core']:GetCoreObject() end)\n"
    )
    assert not scan._has_rehook(commented, "QBCore"), "注释里的重挂被当成自愈"

    # 安全形态 B：线程里 pcall 重试后给同一变量赋值（真机实证过的写法）
    retry_shape = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "AddEventHandler('onResourceStart', function(resourceName)\n"
        "    if resourceName ~= 'qb-core' then return end\n"
        "    CreateThread(function()\n"
        "        for _ = 1, 30 do\n"
        "            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)\n"
        "            if ok and core then QBCore = core return end\n"
        "            Wait(500)\n"
        "        end\n"
        "    end)\n"
        "end)\n"
    )
    assert scan._has_rehook(retry_shape, "QBCore"), "线程重试形态（QBCore = core）没被识别为自愈"



    # 伪装 2b：`--[=[ ]=]` 长注释（普通 --[[ ]] 正则匹配不到的那种）
    long_comment = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "--[=[ AddEventHandler('onResourceStart', function() QBCore = exports['qb-core']:GetCoreObject() end) ]=]\n"
    )
    assert not scan._has_rehook(long_comment, "QBCore"), "长注释里的重挂被当成自愈"

    # 伪装 3：窗口里出现 GetCoreObject 但不是给同一变量赋值
    other_var = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "AddEventHandler('onResourceStart', function(name)\n"
        "    if name == 'qb-core' then local fresh = exports['qb-core']:GetCoreObject() end\n"
        "end)\n"
    )
    assert not scan._has_rehook(other_var, "QBCore"), "给别的变量赋值被当成同一变量已自愈"

    # 根目录 client.lua 也要归 client 台账（qb-banking / safecracker 就是这种）
    assert scan._scope(Path("a/[qb]/qb-banking/client.lua")) == "client"
    assert scan._scope(Path("a/[qb]/qb-banking/server.lua")) == "server"

    data_only = "local QBCore = exports['qb-core']:GetCoreObject()\nprint(QBCore.Shared.Items)\n"
    assert not re.search(r"\bQBCore" + scan.USE_PATTERN, data_only), "只用 Shared 数据的文件不该判风险"


def test_scanner_rejects_the_bypass_shapes(tmp_path, monkeypatch):
    """反向 fixture：五种"看起来像重挂、其实没重挂"的形态必须判红（CC 复核提出的绕过）。"""
    base = "local QBCore = exports['qb-core']:GetCoreObject()\nQBCore.Functions.GetPlayer(1)\n"
    bypass = {
        "自赋值": base
        + "AddEventHandler('onResourceStart', function(n)\n"
          "    QBCore = QBCore\n    print('GetCoreObject')\nend)\n",
        "右值是死值": base
        + "AddEventHandler('onResourceStart', function(n)\n"
          "    local core = nil\n    if ok and core then QBCore = core end\nend)\n",
        "赋值在失败分支": base
        + "AddEventHandler('onResourceStart', function(n)\n"
          "    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)\n"
          "    if not ok then QBCore = core end\nend)\n",
        "赋值在 handler 之外": base
        + "AddEventHandler('onResourceStart', function(n)\n    print('hi')\nend)\n"
          "QBCore = QBCore\nlocal c = exports['qb-core']:GetCoreObject()\n",
        "只有字符串没有真调用": base
        + "AddEventHandler('onResourceStart', function(n)\n"
          "    print(\"exports['qb-core']:GetCoreObject(\")\n    QBCore = QBCore\nend)\n",
    }
    for name, source in bypass.items():
        assert not scan._has_rehook(source, "QBCore"), f"绕过形态被判成自愈：{name}"
        # 端到端：整份文件也不能因此从风险集里消失
        root = tmp_path / "res"
        (root / "res_x" / "server").mkdir(parents=True, exist_ok=True)
        (root / "res_x" / "fxmanifest.lua").write_text("fx_version 'cerulean'\n", encoding="utf-8")
        target = root / "res_x" / "server" / "main.lua"
        target.write_text(source, encoding="utf-8")
        monkeypatch.setattr(scan, "RESOURCES", root)
        assert scan.scan_file(target), f"端到端漏判：{name}"

    # 真形态（线程重试）必须仍被判自愈，端到端返回空
    good = base + (
        "AddEventHandler('onResourceStart', function(n)\n"
        "    if n ~= 'qb-core' then return end\n"
        "    CreateThread(function()\n"
        "        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)\n"
        "        if ok and core then QBCore = core end\n"
        "    end)\n"
        "end)\n"
    )
    root = tmp_path / "res2"
    (root / "res_y" / "server").mkdir(parents=True, exist_ok=True)
    (root / "res_y" / "fxmanifest.lua").write_text("fx_version 'cerulean'\n", encoding="utf-8")
    target = root / "res_y" / "server" / "main.lua"
    target.write_text(good, encoding="utf-8")
    monkeypatch.setattr(scan, "RESOURCES", root)
    assert scan.scan_file(target) == [], "线程重试形态被判成风险（假阳性）"
