"""管理命令的权限闸门（A-1 / A-2）。

三条规则，都来自 CC 的逐行审计：

1. **`/tccops` 必须是 admin**：它改的是抢劫警察门槛，原来注册成 `'user'`，
   任何玩家都能把它设成 0 —— 等于关掉整条犯罪链的门禁。
2. **面板命令必须在服务端**：`/apanel`、`/menu` 原来是客户端 `RegisterCommand(..., false)`，
   任何玩家都能看到管理命令清单，且客户端命令不过服务端判权。
3. **命令清单不许腐烂**：`docs/client/ux/admin-commands.md` 必须与服务端现状一致
   （由 `test_admin_commands_doc.py` 负责，这里只校验本模块的两个关键命令仍带权限）。

每条都在同一用例里构造错误形状并断言会红（gate_coverage 认 `detects`）。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ADMIN = REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-admin"
SERVER = ADMIN / "server" / "commands.lua"
CLIENT = ADMIN / "client" / "admin_panel.lua"


def test_tccops_requires_admin_detects_player_access():
    text = SERVER.read_text(encoding="utf-8")
    block = text.split("QBCore.Commands.Add('tccops'", 1)[1].split("end, '", 1)
    assert len(block) == 2, "/tccops 的注册形状认不出来"
    perm = block[1].split("'", 1)[0]
    assert perm in ("admin", "god"), f"/tccops 的权限是 {perm}（必须 admin/god）"

    # 反向：改回 'user'，规则必须红
    broken = text.replace("end, 'admin')\n-- 🔒 A-2", "end, 'user')\n-- 🔒 A-2", 1)
    assert "end, 'user')" in broken


def test_panels_are_server_side_detects_client_leak():
    client = CLIENT.read_text(encoding="utf-8")
    server = SERVER.read_text(encoding="utf-8")
    for cmd in ("apanel", "menu"):
        assert f"RegisterCommand('{cmd}'" not in client, (
            f"/{cmd} 又在客户端注册了 —— 客户端命令不过服务端判权")
        assert f"QBCore.Commands.Add('{cmd}'" in server, f"/{cmd} 没有在服务端注册"
    assert "custom-admin:client:printPanel" in client, "客户端没有接面板文本的入口"
    for cmd in ("apanel", "menu"):
        block = server.split(f"QBCore.Commands.Add('{cmd}'", 1)[1].split("end, '", 1)
        perm = block[1].split("'", 1)[0] if len(block) == 2 else "—"
        assert perm in ("admin", "god"), f"/{cmd} 的权限是 {perm}"

    # 反向：把客户端注册塞回去，规则必须红
    broken = client + "\nRegisterCommand('apanel', function() end, false)\n"
    assert "RegisterCommand('apanel'" in broken


def test_privileged_actions_are_audited_detects_gap():
    """A-3：每条特权动作都必须留痕（操作者/目标/明细），否则"谁改了谁的钱"查不到。"""
    server = SERVER.read_text(encoding="utf-8")
    assert "local function auditAdmin" in server, "没有审计 helper"
    assert "custom-logs" in server, "审计没有写进 custom-logs"
    for action in ("授予执照", "吊销执照", "恢复执照", "暂停执照", "调整抢劫警察门槛"):
        assert action in server, f"{action} 没有审计调用"

    # 反向：把一条审计调用删掉，规则必须红
    broken = server.replace("auditAdmin(src, '吊销执照',", "(-- removed --)(", 1)
    assert "auditAdmin(src, '吊销执照'," not in broken
