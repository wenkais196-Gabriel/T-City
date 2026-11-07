"""闸门：顶层缓存 QBCore 却没重解析的文件 —— 基线棘轮，只许减不许增。

真机 2026-11-07：`qb-clothing` 报 `Execution of function reference in script host failed`。
文件顶层的 `local QBCore = exports['qb-core']:GetCoreObject()` 是 **qb-core 当次 script host
的快照**，`restart qb-core` 之后表里的函数引用全部失效；而它没有声明 qb-core 依赖，
所以重启级联也不会把它带走 —— 旧表一直用下去。

与 PR #193/#194 修的那类（MySQL 回调里调跨资源引用）不是同一件事：
那次是**调用上下文**不对，这次是**缓存过期**，静态看完全正常。

三种安全形态（不算风险）：
  1. 在 `onResourceStart` / `onClientResourceStart` 里重新 `GetCoreObject()`（自愈）；
  2. 资源 fxmanifest 显式声明 qb-core 依赖（随 `restart qb-core` 一起重启，顶层缓存重跑）；
  3. 文件里压根不用 `Functions/Player/Commands/ServerCallbacks`（只读数据，不碰函数引用）。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stale_core_cache_scan as scan  # noqa: E402


def test_no_new_stale_core_cache_files():
    added, removed = scan.check()
    assert not added, (
        "新增了「顶层缓存 QBCore 且不在重启级联内、又没重解析」的文件 —— `restart qb-core` 后"
        "这些函数引用会失效：\n  " + "\n  ".join(item.replace("\u0000", "  var=") for item in added)
        + "\n修法：加 onResourceStart('qb-core') → QBCore = exports['qb-core']:GetCoreObject()，"
          "或在 fxmanifest 里声明 dependency 'qb-core'（会让它随重启一起重载）。"
    )
    assert not removed, (
        "基线里的文件已经不在风险集里了（修好了或写法变了），请同步删条目，否则基线会腐烂：\n  "
        + "\n  ".join(item.replace("\u0000", "  var=") for item in removed)
        + f"\n重写基线：python {Path(scan.__file__).name} --write"
    )


def test_baseline_metadata_is_valid():
    payload = json.loads(scan.BASELINE.read_text(encoding="utf-8"))
    assert payload.get("owner"), "基线必须写 owner"
    assert payload.get("expires"), "基线必须有到期日"
    assert payload["count"] == len(payload["entries"]), "count 与条目数不一致"


def test_scanner_classifies_the_three_safe_shapes():
    """自证：三种安全形态都不该被算成风险，危险形态必须被抓到。"""
    dangerous = "local QBCore = exports['qb-core']:GetCoreObject()\nQBCore.Functions.GetPlayer(1)\n"
    assert scan.CACHE.search(dangerous), "没识别出顶层缓存"
    assert scan._has_rehook(dangerous) is False, "危险形态被误判为已重挂"

    rehook = (
        "local QBCore = exports['qb-core']:GetCoreObject()\n"
        "AddEventHandler('onResourceStart', function(name)\n"
        "    if name == 'qb-core' then QBCore = exports['qb-core']:GetCoreObject() end\n"
        "end)\n"
    )
    assert scan._has_rehook(rehook), "带重解析的形态没被识别为自愈"

    data_only = "local QBCore = exports['qb-core']:GetCoreObject()\nprint(QBCore.Shared.Items)\n"
    assert not scan.re.search(r"\bQBCore\s*\.\s*(?:Functions|Player|Commands)\b", data_only), (
        "只用 Shared 数据的文件不该判风险"
    )
