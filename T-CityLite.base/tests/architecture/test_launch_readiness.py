"""开服就绪闸门（repo 半区）。

`tools/dev/launch_check.py` 分两半：**repo**（入库文件，CI 能跑）与 **local**（本机 server.cfg / 备份）。
这里只锁 repo 半区 —— 它会红的典型情况：

* 有人把 `custom-testing` / `custom-debug` 这类调试资源加回默认启动集（模块 cfg **或** server.cfg，
  包括间接 `exec dev.cfg`、带引号、行尾注释、大小写变体、深链条、带空格的路径）；
* 新加的 dev/test 命令没有 `source ~= 0`、没有权限参数、也没有 convar 开关；
* 有人把密钥（license / 口令 / agent token）写进入库文件；
* 生产模板被删 / 少了关键开关。

local 半区（容量、OneSync、服务器名、agent 开关、DB 账号、备份、占位符）在**部署机**上跑，
本仓库不替那台机器做承诺。
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "dev" / "launch_check.py"


def _run(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(TOOL), *args],
        capture_output=True, text=True, cwd=REPO, timeout=180,
        env={**os.environ, **(env or {})},
    )


def test_launch_readiness_repo_half_is_green():
    result = _run("--ci")
    assert result.returncode == 0, (
        "开服就绪（repo 半区）有 P0 未解决：\n" + (result.stdout or result.stderr)[-2000:]
    )


def test_launch_check_rejects_dev_resource_in_default_boot():
    """反向形状：#1 必须在"默认启动集里出现调试资源"时变红。"""
    probe = REPO / "T-CityLite.base" / "configs" / "modules" / "core.cfg"
    original = probe.read_text(encoding="utf-8")
    try:
        probe.write_text(original.rstrip("\n") + "\nensure custom-testing\n", encoding="utf-8")
        result = _run("--ci")
        assert result.returncode != 0, "把 custom-testing 塞回默认启动集，闸门居然还是绿的"
        assert "custom-testing" in (result.stdout or ""), "报错里没点名 custom-testing"
    finally:
        probe.write_text(original, encoding="utf-8")
        assert _run("--ci").returncode == 0, "撤掉注入后没有恢复绿"


def test_launch_check_rejects_unguarded_dev_command():
    """反向形状：#2 必须在"新 dev 命令没守卫"时变红。"""
    probe = REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-career" / "server" / "score_probe.lua"
    assert not probe.exists()
    try:
        probe.write_text(
            "RegisterCommand('scoretest', function(source, args)\n"
            "    print('no guard here')\n"
            "end)\n",
            encoding="utf-8",
        )
        result = _run("--ci")
        assert result.returncode != 0, "新 dev 命令没有守卫，闸门居然还是绿的"
        assert "scoretest" in (result.stdout or ""), "报错里没点名 scoretest"
    finally:
        probe.unlink(missing_ok=True)
        assert _run("--ci").returncode == 0, "撤掉注入后没有恢复绿"


def test_reverse_launch_check_scans_the_real_server_cfg(tmp_path):
    """#1 必须扫**真正的启动集** —— `exec "configs/modules/dev.cfg"`（带引号）也算。"""
    probe = tmp_path / "server.cfg"
    probe.write_text(
        "sv_maxclients 32\n"
        "set onesync on\n"
        'exec "configs/modules/dev.cfg"\n',
        encoding="utf-8",
    )
    result = _run("--ci", env={"TCITY_SERVER_CFG": str(probe)})
    assert result.returncode != 0, "server.cfg 里 exec 了 dev.cfg，闸门居然还是绿的"
    assert "dev.cfg" in (result.stdout or ""), "报错里没点名 dev.cfg"


def test_reverse_launch_check_follows_nested_exec(tmp_path):
    """间接 exec 也要拦住：`configs/modules/core.cfg` 里 exec dev.cfg（server.cfg 里看不出来）。"""
    base = tmp_path / "T-CityLite.base"
    modules = base / "configs" / "modules"
    modules.mkdir(parents=True)
    (modules / "core.cfg").write_text(
        "ensure oxmysql\nexec configs/modules/dev.cfg\n", encoding="utf-8")
    (modules / "dev.cfg").write_text("ensure custom-testing\n", encoding="utf-8")
    probe = base / "server.cfg"
    probe.write_text("sv_maxclients 32\nexec configs/modules/core.cfg\n", encoding="utf-8")

    result = _run("--ci", env={"TCITY_SERVER_CFG": str(probe)})
    assert result.returncode != 0, "模块 cfg 里 exec 了 dev.cfg，闸门居然还是绿的"
    assert "dev.cfg" in (result.stdout or ""), "报错里没点名 dev.cfg"


def test_reverse_launch_check_sees_trailing_comment_and_case(tmp_path):
    """`exec configs/modules/dev.cfg # 开发用` 与 `DEV.CFG` 都要拦住。"""
    base = tmp_path / "T-CityLite.base"
    (base / "configs" / "modules").mkdir(parents=True)
    probe = base / "server.cfg"

    probe.write_text("sv_maxclients 32\nexec configs/modules/dev.cfg # 开发用\n", encoding="utf-8")
    assert _run("--ci", env={"TCITY_SERVER_CFG": str(probe)}).returncode != 0, \
        "行尾注释的 exec 漏了"

    probe.write_text("sv_maxclients 32\nexec configs/modules/DEV.CFG\n", encoding="utf-8")
    assert _run("--ci", env={"TCITY_SERVER_CFG": str(probe)}).returncode != 0, \
        "大写 DEV.CFG 漏了"


def test_reverse_launch_check_walks_a_deep_exec_chain(tmp_path):
    """`server → a → b → c → d`（5 跳）里的 dev 资源也要扫到。"""
    base = tmp_path / "T-CityLite.base"
    modules = base / "configs" / "modules"
    modules.mkdir(parents=True)
    chain = ["a", "b", "c", "d"]
    for index, name in enumerate(chain):
        if index + 1 < len(chain):
            body = "exec configs/modules/" + chain[index + 1] + ".cfg\n"
        else:
            body = "ensure custom-testing\n"
        (modules / (name + ".cfg")).write_text(body, encoding="utf-8")
    probe = base / "server.cfg"
    probe.write_text("sv_maxclients 32\nexec configs/modules/a.cfg\n", encoding="utf-8")

    result = _run("--ci", env={"TCITY_SERVER_CFG": str(probe)})
    assert result.returncode != 0, "5 跳 exec 链末尾的 dev 资源漏扫了"
    assert "custom-testing" in (result.stdout or ""), "报错里没点名 custom-testing"


def test_reverse_launch_check_handles_quoted_path_with_space(tmp_path):
    """`exec "configs/a b.cfg"` 这种带空格的引号路径也要跟进去。"""
    base = tmp_path / "T-CityLite.base"
    (base / "configs").mkdir(parents=True)
    (base / "configs" / "a b.cfg").write_text("ensure custom-testing\n", encoding="utf-8")
    probe = base / "server.cfg"
    probe.write_text('sv_maxclients 32\nexec "configs/a b.cfg"\n', encoding="utf-8")

    result = _run("--ci", env={"TCITY_SERVER_CFG": str(probe)})
    assert result.returncode != 0, "带空格的引号路径没跟进去"
