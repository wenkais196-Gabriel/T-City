"""审计留存：过期分片要被删掉，**当天的文件必须留着**。

背景（P1-6）：`<type>_audit.log` 原来永不轮转，跑几个月就是几百 MB。现在按天分片
（`<type>_audit-YYYY-MM-DD.log`）+ 保留 N 天。清理逻辑一旦写错（比如把当天也删、
或者按通配盲删），后果是**审计永久丢失**且没人立刻发现 —— 所以要有反向用例。

做法：从 logs.lua 抽出真实的 `SweepOldLogs`，在临时目录里铺三个文件：
很久以前、刚过期一天、今天，然后断言只有前两个被删。
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
from pathlib import Path

LOGS = Path(__file__).resolve().parents[2] / "resources" / "[custom]" / "custom-logs" / "server" / "logs.lua"


def _sweep_source() -> str:
    lines = LOGS.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("local AUDIT_TYPES"))
    end = next(i for i in range(start, len(lines)) if lines[i].startswith("-- 周期性异步批量刷盘协程"))
    while lines[end - 1].strip() != "end":
        end -= 1
    return "\n".join(lines[start:end])


def _run_sweep(tmpdir: Path, retention_days: int) -> str:
    script = f'''
        RETENTION_DAYS = {retention_days}
        resourcePath = [[{tmpdir.as_posix()}/]]
        fileSizes = {{}}
{_sweep_source()}
        print('REMOVED ' .. tostring(SweepOldLogs(3650)))
    '''
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(script)
        path = fh.name
    try:
        proc = subprocess.run(["lua5.4", path], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(path)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}\n{proc.stdout}"
    return proc.stdout


def _fake_logs(directory: Path) -> dict[str, Path]:
    today = time.strftime("%Y-%m-%d")
    old = time.strftime("%Y-%m-%d", time.localtime(time.time() - 400 * 86400))
    expired = time.strftime("%Y-%m-%d", time.localtime(time.time() - 40 * 86400))
    recent = time.strftime("%Y-%m-%d", time.localtime(time.time() - 5 * 86400))
    files = {
        "old": directory / f"economy_audit-{old}.log",
        "expired": directory / f"economy_audit-{expired}.log",
        "recent": directory / f"economy_audit-{recent}.log",
        "today": directory / f"economy_audit-{today}.log",
    }
    for path in files.values():
        path.write_text("x\n", encoding="utf-8")
    return files


def test_sweep_deletes_expired_shards_keeps_today_and_is_idempotent():
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        files = _fake_logs(directory)

        output = _run_sweep(directory, retention_days=30)
        assert "REMOVED 2" in output, f"应删 2 个过期分片（400 天前 + 40 天前），实际输出：{output!r}"
        assert not files["old"].exists(), "很久以前的分片没被删"
        assert not files["expired"].exists(), "刚过期一天的分片没被删"
        assert files["today"].exists(), "**当天**的审计被删了 —— 这是数据丢失，不是清理"
        assert files["recent"].exists(), (
            "保留窗口内（5 天前）的分片被删了 —— 说明清理没按 retention 截断，而是清了个精光"
        )

        second = _run_sweep(directory, retention_days=30)
        assert "REMOVED 0" in second, f"第二次清理不该再删东西：{second!r}"
        assert files["today"].exists(), "第二次清理误删了当天文件"
