"""猴补闸门（P1-4 阶段 A）：冻结新增，存量带 owner 与到期日。

规则：往 `QBCore` / `QBCore.Functions` / `Player.Functions` 上赋值 = 猴补。
为什么需要它：`core-framework` 的 compat 就是靠这种赋值把 qb-core 的 `GetPlayer` / `Notify` /
`AddMoney` 换掉的，而"换掉"这件事在 diff 里看不出来（调用点一行没变）。新增一条猴补的代价
远大于新增一个普通函数，所以它必须显式出现在 diff 里。

判据四条：
1. 未登记的猴补 → 红；
2. 登记项缺 owner / reason / expires，或已过期 → 红；
3. 登记项当前**一处都不命中**（死条目）→ 红（删了猴补却忘清登记，等于给未来开口子）；
4. 扫描器自己覆盖四种赋值形态 + 排除 API owner 与测试目录（用 tmp_path 夹具自证）。

扫描器是唯一实现：`monkey_patch_scan.py`（闸门与未来的迁移工具共用）。
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

import pytest

import monkey_patch_scan as scan

REQUIRED_FIELDS = ("file", "symbol", "owner", "reason", "expires")


def test_no_unregistered_monkey_patch():
    """未登记的猴补不许存在。"""
    hits = scan.scan_repo()
    bad = scan.unregistered(hits)
    if bad:
        detail = "\n".join(f"  {hit.where()}  {hit.symbol}  ({hit.kind})" for hit in bad)
        raise AssertionError(
            "发现未登记的猴补（往别人的 API 上赋值）：\n"
            f"{detail}\n"
            "修法：优先改成 export / Bus 服务；确属兼容层则登记到 "
            "tests/architecture/monkey_patches_allowlist.json（带 owner + expires）。"
        )


def test_allowlist_entries_are_complete_and_not_expired():
    entries = scan.allowlist_entries()
    assert entries, "登记表为空 —— 这条规则等于没写"
    today = date.today()
    seen: set[tuple[str, str]] = set()
    for entry in entries:
        for field in REQUIRED_FIELDS:
            value = entry.get(field)
            assert isinstance(value, str) and value.strip(), f"{entry}: 缺 {field}"
        key = (entry["file"], entry["symbol"])
        assert key not in seen, f"重复登记：{key}"
        seen.add(key)
        expires = date.fromisoformat(entry["expires"])
        assert expires >= today, (
            f"{entry['file']} {entry['symbol']} 的登记已在 {entry['expires']} 过期 —— "
            "要么删掉这处猴补，要么续期并写清理由"
        )


def test_allowlist_has_no_dead_entries():
    """登记了却一处都不命中 = 死条目（删了猴补没清登记，或符号名写错）。"""
    hits = scan.scan_repo()
    dead = scan.stale_entries(hits)
    assert dead == [], "\n".join(
        f"死登记：{entry['file']} {entry['symbol']} 当前一处都不命中" for entry in dead
    )


def _write(root: Path, rel: str, body: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")


def test_scanner_catches_all_four_forms_and_skips_excluded(tmp_path: Path):
    """自证：四种赋值形态都要被抓到；qb-core（API owner）与 tests 目录下的不算。

    为什么必须有这一条：`core-framework` 的两处猴补是 `function QBCore.Functions.X(` 写法，
    只写 `X =` 的正则会全绿放行 —— 闸门看起来在工作，实际漏掉现存全部猴补。
    """
    root = tmp_path / "resources"
    _write(root, "[custom]/probe/server/function_form.lua", "function QBCore.Functions.GetPlayer(src) end\n")
    _write(root, "[custom]/probe/server/assign_form.lua", "QBCore.Functions.Notify = function() end\n")
    _write(root, "[custom]/probe/server/bracket_dq.lua", 'Player.Functions["AddMoney"] = function() end\n')
    _write(root, "[custom]/probe/server/bracket_sq.lua", "Player.Functions['RemoveMoney'] = function() end\n")
    _write(root, "[custom]/probe/server/bare_form.lua", "QBCore.Debug = function() end\n")
    # 反面对照：API owner 与测试目录、注释、比较运算都不算
    _write(root, "[qb]/qb-core/server/functions.lua", "function QBCore.Functions.GetPlayer(src) end\n")
    _write(root, "[custom]/probe/tests/fixture.lua", "QBCore.Functions.Notify = function() end\n")
    _write(root, "[custom]/probe/server/comment.lua", "-- QBCore.Functions.Notify = function() end\n")
    _write(root, "[custom]/probe/server/compare.lua", "if QBCore.Functions.Notify == nil then return end\n")
    # 文档字符串里贴的代码片段不算（下标形态必须跳过字符串内部）
    _write(
        root,
        "[custom]/probe/server/docstring.lua",
        "local msg = \"QBCore.Functions['Notify'] = function() end\"\n",
    )
    # server/ 目录下的 client_*.lua 是服务端文件（不能按文件名前缀判客户端）
    _write(root, "[custom]/probe/server/client_bridge.lua", "QBCore.PlayerData = {}\n")

    hits = scan.scan_repo(root)
    kinds = sorted({(hit.symbol, hit.kind) for hit in hits})
    symbols = {fact[0] for fact in kinds}

    assert "QBCore.Functions.GetPlayer" in symbols, "function 形态没抓到（现存猴补正是这种写法）"
    assert "QBCore.Functions.Notify" in symbols, "赋值形态没抓到"
    assert "Player.Functions.AddMoney" in symbols, "双引号下标形态没抓到"
    assert "Player.Functions.RemoveMoney" in symbols, "单引号下标形态没抓到"
    assert "QBCore.Debug" in symbols, "裸命名空间形态没抓到"
    assert len(hits) == 6, f"正/反面对照判断错了：{[(hit.file, hit.symbol) for hit in hits]}"
    files = {hit.file for hit in hits}
    assert not any("docstring" in name for name in files), (
        f"字符串里贴的代码片段被误报了：{sorted(files)}"
    )
    # server/ 目录下的 client_*.lua 是**服务端**文件，不能被当成客户端放过
    assert any("client_bridge" in name for name in files), (
        f"server 目录下的 client_*.lua 被误判成客户端：{sorted(files)}"
    )
