"""OPS-03 — systemd 单元必须被校验，而不是"写出来就算"。

守护配置最容易出现的失败是**看起来配了、其实没生效**：缺 `[Install]` 就不会开机自启，
`Restart=on-failure` 在 FXServer 被 SIGKILL 时不一定拉起，`ExecStart` 指到不存在的脚本时
systemd 只在启动那一刻报错——而 `systemd-analyze verify` **不检查 ExecStart 的可执行文件
是否存在**（实测：指向一个不存在的二进制仍然返回 0），所以路径存在性必须由我们自己校验。

于是这个文件逐个破坏单元文件，要求 `validate_unit()` 每次都能抓到并指认是哪一项；反向再
确认仓库里那份在**任意检出路径**下都合法（CI 的仓库不在开发机的绝对路径上，第一次推上去
就是这里红的）。

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
        (lambda t: t.replace("@REPO@/start.sh", "/nope/start.sh"), "ExecStart"),
        (lambda t: t.replace("User=swk", "User=root"), "root"),
    ],
)
def test_validate_unit_rejects_broken_units_and_accepts_the_repo_one(mutation, expect_hint, tmp_path):
    """每种破坏都要被抓到并指认；同时确认好文件在任意检出路径下都通过。"""
    mod = _load_module()
    assert UNIT.is_file(), f"缺少单元文件: {UNIT}"
    original = UNIT.read_text(encoding="utf-8")
    assert mod.validate_unit(original, repo_root=REPO) == [], "仓库里的单元文件不合法"

    if expect_hint == "Install":  # 这几项每个参数都会跑，额外的全局断言只跑一次
        assert "@REPO@" in original, "单元文件应当是模板（@REPO@ 占位），不能写死本机路径"
        other = tmp_path / "another-checkout"
        other.mkdir()
        (other / "start.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        assert mod.validate_unit(original, repo_root=other) == [], "换了检出路径后校验不该失败"
        assert str(other / "start.sh") in mod.render(original, other), "render 要替换成目标路径"

        if shutil.which("systemd-analyze"):
            rendered = tmp_path / "tcity.service"
            rendered.write_text(mod.render(original, REPO), encoding="utf-8")
            proc = subprocess.run(
                ["systemd-analyze", "verify", str(rendered)], capture_output=True, text=True
            )
            assert proc.returncode == 0, (
                f"systemd-analyze 拒绝了渲染后的单元:\n{proc.stdout}\n{proc.stderr}"
            )

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
