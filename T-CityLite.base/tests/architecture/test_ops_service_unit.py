"""OPS-03 — systemd 单元必须被校验，而不是"写出来就算"。

守护配置最容易出现的失败是**看起来配了、其实没生效**：缺 `[Install]` 就不会开机自启，
`Restart=on-failure` 在 FXServer 被 SIGKILL 时不一定拉起，`ExecStart` 指到不存在的脚本时
systemd 只在启动那一刻报错。

所以这里逐个破坏单元文件，要求 `validate_unit()` 每次都能抓到并指认是哪一项；
反向再确认仓库里那份是合法的。`systemd-analyze verify` 可用时也跑一次（纯离线）。

    python3 -m pytest -q tests/architecture/test_ops_service_unit.py
"""
from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "ops" / "install_service.py"
UNIT = REPO / "tools" / "ops" / "tcity.service"


def _load_module():
    assert TOOL.is_file(), f"缺少工具: {TOOL}"
    spec = importlib.util.spec_from_file_location("ops_install_service", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ops_install_service", module)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    "mutation, expect_hint",
    [
        (lambda t: t.replace("[Install]", "[Installx]"), "Install"),
        (lambda t: t.replace("Restart=always", "Restart=no"), "Restart"),
        (lambda t: t.replace("RestartSec=5", "RestartSec=600"), "RestartSec"),
        (
            lambda t: t.replace(
                "ExecStart=/bin/bash " + str(REPO / "start.sh"),
                "ExecStart=/bin/bash /nope/start.sh",
            ),
            "ExecStart",
        ),
        (lambda t: t.replace("User=swk", "User=root"), "root"),
    ],
)
def test_validate_unit_rejects_broken_units_and_accepts_the_repo_one(mutation, expect_hint):
    """每种破坏都要被抓到并指认；同时反向确认仓库里那份本身合法。"""
    mod = _load_module()
    assert UNIT.is_file(), f"缺少单元文件: {UNIT}"
    original = UNIT.read_text(encoding="utf-8")
    assert mod.validate_unit(original, repo_root=REPO) == [], "仓库里的单元文件不合法"

    broken = mutation(original)
    assert broken != original, "变异没生效，用例本身坏了"
    problems = mod.validate_unit(broken, repo_root=REPO)
    assert problems, f"坏单元必须被拒（期望提示含 {expect_hint}）"
    assert any(expect_hint in p for p in problems), (
        f"提示要指出具体是哪一项（期望含 {expect_hint!r}），实际: {problems}"
    )


def test_install_rejects_non_root_and_check_only_never_needs_root(monkeypatch, capsys):
    """非 root 真安装必须失败并提示 sudo；--check-only 是只读校验，不该要求 root。"""
    mod = _load_module()
    monkeypatch.setattr(mod.os, "geteuid", lambda: 1000)
    assert mod.main(["--check-only"]) == 0, "--check-only 不该要求 root"
    code = mod.main([])
    assert code != 0, "非 root 安装必须失败，不能假装装好了"
    assert "sudo" in capsys.readouterr().err


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="本机没有 systemd-analyze")
def test_systemd_analyze_accepts_unit_and_detects_a_broken_copy(tmp_path):
    """systemd 自己的校验：真单元通过；把 ExecStart 改成不存在的命令必须被拒。"""
    proc = subprocess.run(["systemd-analyze", "verify", str(UNIT)], capture_output=True, text=True)
    assert proc.returncode == 0, f"systemd-analyze 拒绝了单元:\n{proc.stdout}\n{proc.stderr}"

    broken = tmp_path / "broken.service"
    broken.write_text(
        UNIT.read_text(encoding="utf-8").replace(
            "ExecStart=/bin/bash " + str(REPO / "start.sh"), "ExecStart=/nope/not-a-real-binary"
        ),
        encoding="utf-8",
    )
    proc = subprocess.run(
        ["systemd-analyze", "verify", str(broken)], capture_output=True, text=True
    )
    assert proc.returncode != 0, "systemd-analyze 没有发现坏掉的 ExecStart"
