"""审计桥接：`qb-log:server:CreateLog` 必须有消费者，且落盘前脱敏。

问题（2026-11-07 调研）：全仓 47 处 `TriggerEvent('qb-log:server:CreateLog', …)`，
唯一监听者在 `archive/`（不启动）→ 活跃服**零消费者**，经济/反作弊/进出服审计全丢。
这也是「小数金额 `%d` 崩溃」唯一可见症状只是报错的原因：审计根本没落地。

两条判据：
  1. 桥接存在、**不是** NetEvent（否则客户端可伪造审计）、落盘前调 `SanitizeLogText`；
  2. 脱敏函数本身：掩码 citizenid/license/ip/discord，保留普通文本，清掉控制字符。
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]        # T-CityLite.base/
LOGS = BASE / "resources" / "[custom]" / "custom-logs" / "server" / "logs.lua"
SANITIZE = BASE / "resources" / "[custom]" / "custom-logs" / "shared" / "sanitize.lua"


def test_bridge_is_trusted_and_sanitizes_before_writing():
    source = LOGS.read_text(encoding="utf-8")

    assert re.search(r"AddEventHandler\(\s*['\"]qb-log:server:CreateLog['\"]", source), (
        "custom-logs 没有监听 qb-log:server:CreateLog —— 47 处审计会被静默丢弃"
    )
    assert not re.search(r"RegisterNetEvent\(\s*['\"]qb-log:server:CreateLog['\"]", source), (
        "把 qb-log 注册成 NetEvent 会让客户端伪造审计（qb-ambulancejob 客户端就在 TriggerServerEvent）"
    )

    bridge = source[source.index("AddEventHandler('qb-log:server:CreateLog'"):]
    assert "SanitizeLogText(message)" in bridge, (
        "桥接没有对 message 脱敏 —— 经济审计带玩家名 + 完整 citizenid，多角色日志还带 license/ip/discord"
    )
    assert "SanitizeLogText(tostring(title" in bridge, (
        "标题也没有脱敏（它来自任何调用方）"
    )


def _run_sanitizer(payload: str) -> str:
    script = f'''
        dofile([[{SANITIZE.as_posix()}]])
        io.write(SanitizeLogText([==[{payload}]==]))
    '''
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False, encoding="utf-8") as fh:
        fh.write(script)
        tmp = fh.name
    try:
        proc = subprocess.run(["lua5.4", tmp], capture_output=True, text=True, timeout=20)
    finally:
        os.unlink(tmp)
    assert proc.returncode == 0, f"Lua 执行失败：\n{proc.stderr}"
    return proc.stdout


def test_sanitizer_masks_identifiers_and_keeps_plain_text():
    masked = _run_sanitizer("**Name** (citizenid: ABCD1234 | id: 1) added $500")
    assert "ABCD1234" not in masked, f"完整 citizenid 落盘了：{masked!r}"

    creds = _run_sanitizer("license:abc123 ip:1.2.3.4 discord:998877 steam:xyz")
    for secret in ("abc123", "1.2.3.4", "998877", "xyz"):
        assert secret not in creds, f"{secret} 没被脱敏：{creds!r}"

    plain = "Property tax: $61.75 processed"
    assert _run_sanitizer(plain) == plain, "普通文本被改动了（脱敏不能有副作用）"
    assert "\n" not in _run_sanitizer("line1\nline2"), "控制字符没清掉 —— 会把换行注入本地日志行"

def test_log_sink_does_not_use_a_bare_relative_logs_path():
    """审计落盘不能依赖进程 cwd —— 真机 2026-11-07 实测 `io.open("logs/…","a")` 恒失败。

    FXServer 的 cwd 不是 server.cfg 所在目录，所以相对路径写盘会抛
    `No such file or directory`，而降级分支写的子目录同样不存在 → **所有审计静默丢弃**
    （连既有 LogEconomy/LogSecurity 调用点也一样，等于整条审计链路从未落过盘）。
    修法是走 `GetResourcePath()` 的绝对路径 + 资源根目录兜底。
    """
    source = LOGS.read_text(encoding="utf-8")
    # 只看代码，不看注释（注释里会引用这条历史 bug 的原写法）
    code = chr(10).join(line for line in source.splitlines() if not line.lstrip().startswith("--"))

    assert "GetResourcePath(" in code, (
        "落盘没有用 GetResourcePath() 的绝对路径 —— 相对路径会随进程 cwd 失败"
    )
    for banned in ('io.open("logs/', "io.open('logs/", "io.open(folderPath"):
        assert banned not in code, f"又出现了裸相对路径写盘（{banned}）—— cwd 不是数据目录时静默失败"
    assert "SaveResourceFile(" in source, "缺少资源根目录兜底 —— 两条都失败就彻底丢了审计"
