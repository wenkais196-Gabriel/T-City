"""A10 — 旁观者 payload 的字段白名单（运行时探针）。

真跑 `quest_vendor_bridge.lua` 里标记块 `[vendor-bystander]` 的实现（不是复制逻辑）：
喂一个带 citizenid / 收入 / 库存 / 报价的假会话，断言返回表只含
isOwner / boothNetId / state / coords / items，且深扫不到任何摊主私有值。

反向：把 `citizenid` 与 `revenue` 塞进返回表，同一个探针必须红。

    python -m pytest -q tests/unit/layer3_business/test_quest_vendor_bystander.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SOURCE = BASE / "resources/[custom]/custom-quest/server/quest_vendor_bridge.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "vendor_bystander_probe.lua"

# 优先 .exe：Windows 的 PATH 里同时有 lua5.4（可能是 Git Bash 包装脚本）
# 和 lua5.4.exe，subprocess 只能直接执行后者。
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def marked_block(text: str) -> str:
    match = re.search(
        r"-- \[vendor-bystander\] begin\n(.*?)\n-- \[vendor-bystander\] end",
        text,
        re.S,
    )
    assert match, "找不到标记块 vendor-bystander"
    return match.group(1)


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_bystander_payload_probe_rejects_leaked_owner_fields(tmp_path: Path):
    proc = run_probe(SOURCE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 10/10" in proc.stdout, proc.stdout
    assert "FAIL" not in proc.stdout, proc.stdout

    source = read(SOURCE)
    block = marked_block(source)
    assert "isOwner = false," in block, "变异点不见了：先更新这条反向校验"
    poisoned = block.replace(
        "isOwner = false,",
        "isOwner = false,\n"
        "        citizenid = 'cid-secret-001', revenue = 424242,",
        1,
    )
    assert poisoned != block
    mutant = tmp_path / "quest_vendor_bridge_mutant.lua"
    mutant.write_text(source.replace(block, poisoned, 1), encoding="utf-8")

    bad = run_probe(mutant)
    assert bad.returncode != 0, (
        "旁观者 payload 带了 citizenid / revenue，探针仍然通过 —— 字段白名单形同虚设")
    failed = [line for line in bad.stdout.splitlines() if "FAIL" in line]
    assert any("citizenid" in line for line in failed), (
        f"期望 no_owner_data / payload_keys 指出 citizenid，实际失败行：{failed}")
