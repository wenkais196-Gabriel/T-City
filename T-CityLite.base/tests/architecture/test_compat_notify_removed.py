"""P1-4 阶段 D：`core-framework` 的 compat.lua 整体下线，Notify 回到 qb-core 原实现。

为什么删而不是"改 export + GetResourceState 守卫"：

* 改 export 不构成守卫 —— export 到已停止的资源一样失败，只是换了个报错位置；
* 会新增**第二个** `QBCore.Functions.Notify` 入口，同一个语义两条路径，下一个维护者还要再判一次；
* 这一层静默改变语义：`notify_service` 每源 200ms 只放 1 条、超限直接丢、且**没有丢弃计数**；
  qb-core 的原实现（只做 300 字符截断 + 控制字符清洗）不丢消息。

判据：
  G11  compat.lua 已不存在，manifest 不再引用它
  G15  `QBCore.Functions.Notify` 不再被任何资源赋值 —— 由猴补闸门承担，这里不重复（已实测注入红）
  G10  **没有 `_G.Bus` 时 qb-core 的 Notify 仍把消息发出去** —— 这是删掉整个 compat 之后
       "通知不会静默消失"的唯一证据。qb-core 里那段 `if _G.Bus and _G.Bus.notify` 的 Bus
       是本资源状态里的，而 qb-core 从未注册 `Bus.notify`（它连 bus.lua 都没 include），
       所以走的恒为第 5 层回退分支；这条测试把"恒为回退"变成可执行断言。
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
CORE = BASE / "resources" / "[standalone]" / "core-framework"
QBCORE_FUNCTIONS = BASE / "resources" / "[qb]" / "qb-core" / "server" / "functions.lua"


def _notify_source() -> str:
    """从 qb-core 的 functions.lua 里切出 Notify 函数体（顶层 function 到列 0 的 end）。"""
    lines = QBCORE_FUNCTIONS.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("function QBCore.Functions.Notify("))
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "end")  # 列 0 的 end；内层块缩进
    return "\n".join(lines[start:end + 1])


def test_compat_file_is_gone():
    assert not (CORE / "compat.lua").exists(), (
        "core-framework/compat.lua 还在 —— 阶段 D 的目标是整份下线，而不是只删一个包装"
    )


def test_manifest_no_longer_loads_compat():
    manifest = (CORE / "fxmanifest.lua").read_text(encoding="utf-8")
    assert "compat.lua" not in manifest, (
        "fxmanifest 仍然引用 compat.lua —— 文件删了但清单没改，restart 会报找不到文件"
    )


def test_qb_core_notify_still_delivers_without_the_bus():
    """没有 `_G.Bus` 时，qb-core 的 Notify 必须仍然把消息发给客户端。"""
    harness = (
        r"""
        _G.QBCore = { Functions = {} }
        _G.Bus = nil                 -- qb-core 自己的状态：从未注册 Bus.notify
        local sent = {}
        TriggerClientEvent = function(name, src, text, kind, length)
            sent[#sent + 1] = { name = name, src = src, text = text, kind = kind }
        end
        GetPlayerPing = function(src) return 1 end   -- 玩家在线

"""
        + _notify_source()
        + r"""

        QBCore.Functions.Notify(1, 'hello', 'primary')
        print('RESULT ' .. string.format(
            '{"count":%d,"name":"%s","text":"%s"}',
            #sent,
            sent[1] and sent[1].name or '',
            sent[1] and sent[1].text or ''
        ))
"""
    )
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(harness)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    line = next((ln for ln in proc.stdout.splitlines() if ln.startswith("RESULT ")), None)
    assert line, f"没有拿到 RESULT 行：\n{proc.stdout}"
    result = json.loads(line[len("RESULT "):])
    assert result["count"] == 1, (
        "没有 `_G.Bus` 时 qb-core 的 Notify 一条都没发出去 —— 删掉 compat 之后通知会静默消失"
    )
    assert result["name"] == "QBCore:Notify", f"发出去的不是 QBCore:Notify，实际 {result['name']!r}"
