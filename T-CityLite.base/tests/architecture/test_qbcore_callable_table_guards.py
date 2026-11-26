"""闸门：不许用 `type(x.Functions.y) == 'function'` 判 QBCore 的函数。

背景（真机实测，2026-11-26）：本 build 里 `exports['qb-core']:GetCoreObject()` 交出来的
函数是**可调用表**（`type(fn) == 'table'`，靠 `__call` 调用）。所以

    if type(qb.Functions.TriggerCallback) == 'function' then ... end

这条守卫**恒假**，整段代码被静默跳过。同一形状在仓库里已经造成三次真实事故：

* `custom-industry`（S5）：服务端 5 个 callback 全没注册、客户端 `uiEnabled` 永远 false
  —— 玩家侧只表现为「菜单里没有这一项」；
* `custom-director`：广播通知的 `delivered` 永远是 0，通知从未送达；
* `custom-quest` 的 vendor：`payCash` 永远返回 false，**卖东西从不付款**（库存却照扣）。

同一个坑在 AGENTS.md 的 NUI `cb` 条目里也记过一次（NUI 回调的 `cb` 也是可调用表）。

正确写法：只判 nil，把调用包进 `pcall`。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CUSTOM_ROOT = BASE / "resources" / "[custom]"
QUEST_VENDOR = BASE / "resources/[custom]/custom-quest/server/quest_vendor.lua"

LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

# 允许出现该形状的地方：注释里的说明文字（本文件与源码注释都写过反例）。
COMMENT = re.compile(r"--.*$")

# type( <任意>.Functions.<名字> ) ==|~= 'function' | "function"
GUARD = re.compile(
    r"""type\s*\(\s*[^()]*\.Functions\.[A-Za-z_]\w*\s*\)\s*[=~]=\s*(['"])function\1"""
)


def violations_in(source: str) -> list[str]:
    """返回命中的行（去掉注释后再判）。"""
    hits: list[str] = []
    for number, line in enumerate(source.splitlines(), start=1):
        stripped = COMMENT.sub("", line)
        if GUARD.search(stripped):
            hits.append(f"line {number}: {line.strip()}")
    return hits


def scan(root: Path) -> list[str]:
    found: list[str] = []
    for lua in sorted(root.rglob("*.lua")):
        hits = violations_in(lua.read_text(encoding="utf-8", errors="replace"))
        if hits:
            found.extend(f"{lua.relative_to(BASE).as_posix()}: {hit}" for hit in hits)
    return found


def test_custom_resources_do_not_type_check_qbcore_functions():
    """全 [custom] 树零命中。"""
    assert scan(CUSTOM_ROOT) == []


def test_gate_catches_the_real_regression():
    """反向注入：把真实写错的三种形状喂进来，必须被抓到。"""
    bad = """
    if type(qb.Functions.CreateCallback) ~= 'function' then return false end
    if qb and type(qb.Functions.TriggerCallback) == 'function' then
        qb.Functions.TriggerCallback('x', function() end)
    end
    if type(player.Functions.AddMoney) ~= 'function' then return false end
    """
    assert len(violations_in(bad)) == 3


def test_gate_accepts_the_fixed_shape_and_comments():
    """修好之后的写法（只判 nil + pcall）与注释里的反例都不能误报。"""
    good = """
    -- 不能写 type(qb.Functions.CreateCallback) ~= 'function'（恒假）
    local createCallback = qb and qb.Functions and qb.Functions.CreateCallback
    if not createCallback then return false end
    local ok = pcall(function() qb.Functions.TriggerCallback('x', cb) end)
    if type(TriggerEvent) ~= 'function' then return end   -- 全局原生，不是导出
    """
    assert violations_in(good) == []


# ══════════════════════════════════════════════════════════════════
# 行为对照：payCash 在「AddMoney 是可调用表」时真的付钱
# ══════════════════════════════════════════════════════════════════

PAYCASH = re.compile(r"^local function payCash\(.*?^end$", re.MULTILINE | re.DOTALL)


def _paycash_source() -> str:
    source = QUEST_VENDOR.read_text(encoding="utf-8")
    match = PAYCASH.search(source)
    assert match, "找不到 payCash 函数，闸门需要跟着重构更新"
    return match.group(0)


def _run_lua(script: str) -> str:
    assert LUA, "找不到 lua5.4"
    proc = subprocess.run([LUA, "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    return proc.stdout.strip()


def test_paycash_pays_when_addmoney_is_a_callable_table():
    """真机事故复现：AddMoney 是可调用表时，payCash 必须返回真并真的调一次。

    这条不是静态形状检查 —— 它把那笔账走一遍：旧写法（多一条 `type(...) ~= 'function'`）
    在这里返回 false 且调用次数 0，等于「卖东西从不付款」。
    """
    body = _paycash_source()
    script = (
        "local calls = 0\n"
        "local player = { Functions = {} }\n"
        "player.Functions.AddMoney = setmetatable({}, { __call = function(_, _, amount, reason)\n"
        "    calls = calls + 1\n"
        "    print('paid', amount, reason)\n"
        "    return true\n"
        "end })\n"
        + body
        + "\nlocal ok = payCash(player, 250)\n"
        "print(ok, calls)\n"
    )
    out = _run_lua(script).splitlines()
    assert out[0].startswith("paid") and "quest-vendor-sale" in out[0], out
    assert out[-1] == "true\t1", f"payCash 没付钱或调用次数不对：{out}"
