"""真机探针与真机控制台的离线契约。

这两个工具的失败模式很隐蔽：探针解析错连接串会静默给出空审计（看起来像"没有事件"），
控制台工具把密码塞错地方会在 initialize 之后才炸。所以这里只测能离线测的部分：
连接串解析、参数校验、MCP 报文形状。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
DEV = REPO / "tools" / "dev"


def load(name: str):
    path = DEV / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_mysql_dsn_parses_server_cfg(tmp_path, monkeypatch):
    probe = load("police_live_probe")
    fake_base = tmp_path / "T-CityLite.base"
    fake_base.mkdir()
    (fake_base / "server.cfg").write_text(
        'set mysql_connection_string '
        '"mysql://tcity:***@127.0.0.1:3307/TCityLite?charset=utf8mb4"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(probe, "BASE", fake_base)

    assert probe.mysql_dsn() == ("tcity", "***", "127.0.0.1:3307", "TCityLite")


def test_mysql_dsn_refuses_to_guess(tmp_path, monkeypatch):
    probe = load("police_live_probe")
    fake_base = tmp_path / "T-CityLite.base"
    fake_base.mkdir()
    (fake_base / "server.cfg").write_text("# 没有连接串\n", encoding="utf-8")
    monkeypatch.setattr(probe, "BASE", fake_base)

    with pytest.raises(SystemExit):
        probe.mysql_dsn()


def test_audit_sql_is_bounded_and_filtered(tmp_path, monkeypatch):
    """审计查询必须带 like 过滤 + limit，否则一次真机会把整张表拉进日志。"""
    probe = load("police_live_probe")
    seen: list[list[str]] = []

    def fake_run(argv, **kwargs):  # noqa: ANN001, ANN003
        seen.append(list(argv))
        class Result:
            returncode = 0
            stdout = "id\taction\ttarget\tdetail\tcreated_at\n1\tbackup.request\tX\tY\tZ\n"
            stderr = ""
        return Result()

    monkeypatch.setattr(probe.subprocess, "run", fake_run)
    monkeypatch.setattr(probe, "mysql_dsn", lambda: ("u", "p", "h", "db"))

    rows = probe.audit_rows("backup", 3)

    sql = seen[0][-1]
    assert "like 'backup%'" in sql
    assert "limit 3" in sql.lower()
    assert rows == [["1", "backup.request", "X", "Y", "Z"]]


def test_console_requires_password(monkeypatch):
    console = load("fivem_console")
    monkeypatch.delenv("FIVEM_RCON_PASSWORD", raising=False)

    with pytest.raises(SystemExit):
        console.call_tool("server_command", {"command": "status"}, 1.0)


def test_console_request_shape(monkeypatch):
    """tools/call 的报文必须是 JSON-RPC 2.0 + name/arguments，否则 mcp 服务端直接拒。"""
    console = load("fivem_console")
    sent: list[dict] = []

    class FakeSession:
        def __init__(self, argv, env):  # noqa: ANN001
            self.argv = argv

        def request(self, method, params, timeout):  # noqa: ANN001
            sent.append({"method": method, "params": params})
            if method == "initialize":
                return {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05"}}
            return {"jsonrpc": "2.0", "id": 2,
                    "result": {"content": [{"type": "text", "text": "ok"}]}}

        def notify(self, method, params):  # noqa: ANN001
            sent.append({"method": method, "params": params})

        def close(self):
            pass

    monkeypatch.setattr(console, "McpSession", FakeSession)
    monkeypatch.setattr(console, "find_npx", lambda: "npx")
    monkeypatch.setenv("FIVEM_RCON_PASSWORD", "pw")

    assert console.call_tool("server_command", {"command": "status"}, 5.0) == "ok"
    call = [item for item in sent if item["method"] == "tools/call"][0]
    assert call["params"] == {"name": "server_command", "arguments": {"command": "status"}}
    assert [item["method"] for item in sent][0] == "initialize"
    assert "notifications/initialized" in [item["method"] for item in sent]
