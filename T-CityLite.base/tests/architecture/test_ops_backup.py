"""OPS-02 — 备份脚本的契约：口令不进命令行、失败不静默、保留期不误删。

备份是最容易"看起来有、真要用时没有"的东西。每条规则都是反向形状：

* 把 `server.cfg` 里的连接串喂进去，要求解析对、日志里**没有口令**、argv 里**没有口令**
  （argv 会进 `ps` 与 shell history）；
* 8 天前的文件必须删、当天必须留、不是备份的文件不碰；
* `--dry-run` 一个字节都不写、一次 `mysqldump` 都不跑；
* `mysqldump` 非 0 或产出 0 字节都必须被判失败，并且不留下 0 字节文件冒充备份。

    python3 -m pytest -q tests/architecture/test_ops_backup.py
"""
from __future__ import annotations

import importlib.util
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "ops" / "backup_db.py"

PW = "YOUR_PASSWORD"  # 明显占位符：凭据扫描不会把它当成真口令

CFG = """\
# 假配置，口令是占位符
set mysql_connection_string "mysql://swk:YOUR_PASSWORD@localhost/TCityLite?charset=utf8mb4"
sv_endpointPrivacy true
"""


def _load_module():
    assert TOOL.is_file(), f"缺少工具: {TOOL}"
    spec = importlib.util.spec_from_file_location("ops_backup_db", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ops_backup_db", module)
    spec.loader.exec_module(module)
    return module


def test_backup_rejects_password_in_argv_and_masks_it_in_logs(tmp_path):
    """解析要正确，但口令不许出现在 argv 和日志里。"""
    mod = _load_module()
    url = mod.find_connection_string(CFG)
    assert url is not None, "要从 server.cfg 里找到 mysql_connection_string"

    conn = mod.parse_mysql_url(url)
    assert (conn["user"], conn["password"], conn["host"], conn["database"]) == (
        "swk",
        PW,
        "localhost",
        "TCityLite",
    )

    masked = mod.mask_url(url)
    assert PW not in masked, "日志里不能出现口令"
    assert "swk" in masked and "TCityLite" in masked

    argv = mod.build_dump_argv(conn, tmp_path / "tcity.sql")
    assert isinstance(argv, list), "必须是 argv 列表，不能是拼起来的 shell 字符串"
    joined = " ".join(argv)
    assert PW not in joined, "口令不许出现在 argv（ps 可见）"
    assert "--single-transaction" in argv, "InnoDB 要有一致性快照，不能锁表"
    assert "TCityLite" in joined and str(tmp_path / "tcity.sql") in joined


def test_retention_deletes_expired_and_never_fires_on_fresh_or_foreign_files(tmp_path):
    """8 天前删、当天留、别的文件不碰——三条一起验，防止保留策略误删。"""
    mod = _load_module()
    now = datetime(2026, 10, 25, 12, 0, 0)
    fresh = tmp_path / "tcity-2026-10-25_0400.sql.gz"
    old = tmp_path / "tcity-2026-10-17_0400.sql.gz"
    other = tmp_path / "notes.txt"
    for path in (fresh, old, other):
        path.write_bytes(b"x")
    stale = (now - timedelta(days=8)).timestamp()
    os.utime(old, (stale, stale))

    doomed = mod.plan_retention([fresh, old, other], now=now, keep_days=7)
    assert doomed == [old], f"只该删 8 天前那份，实际: {doomed}"


def test_dry_run_rejects_writing_or_running_anything(tmp_path, monkeypatch, capsys):
    """dry-run 一旦真跑，就会在 cron 之外产生备份文件和一次全库扫描。"""
    mod = _load_module()
    cfg = tmp_path / "server.cfg"
    cfg.write_text(CFG, encoding="utf-8")
    dest = tmp_path / "backups"

    def explode(*_a, **_k):
        raise AssertionError("dry-run 不该执行任何外部命令")

    monkeypatch.setattr(mod.subprocess, "run", explode)
    code = mod.main(["--cfg", str(cfg), "--dest", str(dest), "--dry-run", "--no-retention"])
    assert code == 0
    assert not list(dest.glob("*.sql.gz")) if dest.exists() else True
    assert "mysqldump" in capsys.readouterr().out, "dry-run 要把将要执行的命令打出来"


def test_failed_dump_rejects_and_leaves_no_half_file(tmp_path, monkeypatch, capsys):
    """mysqldump 失败必须返回非 0（否则 cron 以为成功），且不留半截文件。"""
    mod = _load_module()
    cfg = tmp_path / "server.cfg"
    cfg.write_text(CFG, encoding="utf-8")
    dest = tmp_path / "backups"

    class FakeProc:
        returncode = 2
        stderr = b"mysqldump: Got error: 1045: Access denied"

    monkeypatch.setattr(mod.subprocess, "run", lambda *a, **k: FakeProc())
    code = mod.main(["--cfg", str(cfg), "--dest", str(dest), "--no-retention"])
    assert code != 0
    out = capsys.readouterr()
    assert "Access denied" in (out.out + out.err), "错误原因要打出来"
    assert not list(dest.glob("*.sql.gz")), "失败不能留下 0 字节文件冒充备份"


def test_empty_dump_detects_zero_bytes_as_failure(tmp_path, monkeypatch):
    """命令退出 0 但没有任何输出（磁盘满时就是这样）不算备份。"""
    mod = _load_module()
    cfg = tmp_path / "server.cfg"
    cfg.write_text(CFG, encoding="utf-8")
    dest = tmp_path / "backups"

    def fake_run(argv, **kwargs):
        out_index = argv.index("-r")
        Path(argv[out_index + 1]).write_bytes(b"")
        return type("P", (), {"returncode": 0, "stderr": b""})()

    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    code = mod.main(["--cfg", str(cfg), "--dest", str(dest), "--no-retention"])
    assert code != 0
    assert not list(dest.glob("*.sql.gz"))
