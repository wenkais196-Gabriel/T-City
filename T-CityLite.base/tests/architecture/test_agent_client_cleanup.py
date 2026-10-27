"""AGC-01：清理代码不能留下指向已删除变量的引用。

限流从"本地令牌桶"改成 core-framework 的 owner 之后，`buckets` 这个表没有了，但
`playerDropped` 里那行 `buckets[src] = nil` 还在——于是**每次玩家掉线**服务端都报一次

    @custom-agent-client/server/main.lua:356: attempt to index a nil value (global 'buckets')

这类死引用不会在启动时报错、也不会被任何单测碰到，只在特定的生命周期事件里炸。

这里的规则故意做得很窄（只钉住"引用了本文件从未声明的标识符"这一个已知形状），
因为做通用 lint 需要 FiveM 原生全局白名单，噪音会掩盖真问题；但这个形状值得钉住，
因为它是"重构删了东西、调用点忘了删"的典型残留。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
AGENT = BASE / "resources" / "[custom]" / "custom-agent-client" / "server" / "main.lua"

#: 文件里出现过的全局名字（Lua 的全局赋值/函数声明都算声明）
_DECL = re.compile(r"^(?:local\s+)?(?:function\s+)?([A-Za-z_]\w*)\s*(?:=|\()", re.M)


def strip_comments(source: str) -> str:
    """去掉注释再扫：注释里提到旧代码（`buckets[src] = nil`）不算引用。"""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", "", source, flags=re.S)
    return re.sub(r"--[^\n]*", "", source)


def names_a_file_declares(source: str) -> set[str]:
    declared: set[str] = set()
    for match in _DECL.finditer(source):
        declared.add(match.group(1))
    # local a, b, c = ... 形式
    for match in re.finditer(r"^\s*local\s+([A-Za-z_][\w, ]*)=", source, re.M):
        for name in match.group(1).split(","):
            declared.add(name.strip())
    return declared


def dangling_references(source: str, candidates: set[str], globals_allowed: set[str]) -> list[str]:
    """candidates 里的名字如果被 `name[` / `name.` 这样用，却没在本文件声明，就是死引用。"""
    declared = names_a_file_declares(source)
    dangling = []
    for name in sorted(candidates):
        if name in declared or name in globals_allowed:
            continue
        if re.search(rf"\b{re.escape(name)}\s*[\[\.]", source):
            dangling.append(name)
    return dangling


def test_cleanup_code_does_not_reference_a_removed_bucket_table(tmp_path):
    source = strip_comments(AGENT.read_text(encoding="utf-8"))

    # 反向校验：构造一个"删了表还留着清理行"的文件，检查器必须看见
    bad = "local pending = {}\nAddEventHandler('playerDropped', function()\n    pending[1] = nil\n    buckets[1] = nil\nend)\n"
    # 注释里的同名片段不该被当成引用
    assert dangling_references(strip_comments("-- buckets[1] = nil\nlocal a = 1\n"), {"buckets"}, set()) == []
    assert dangling_references(bad, {"buckets"}, set()) == ["buckets"], "检查器抓不住死引用"

    globals_allowed = {
        "exports", "Config", "QBCore", "TriggerEvent", "TriggerClientEvent", "GetPlayerName",
        "CreateThread", "Wait", "Citizen", "json", "print", "GetConvarInt", "source", "_G",
    }
    assert dangling_references(source, {"buckets"}, globals_allowed) == [], (
        "custom-agent-client/server/main.lua 又引用了不存在的 buckets（限流已改走 core-framework）"
    )
