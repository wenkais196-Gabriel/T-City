#!/usr/bin/env python3
"""交付前的最后一道自检（宪法第 10 条）。

三件事，全部离线、确定性：

1. **凭据扫描**：跟踪文件里的 license key / webhook / API key / 私钥 / 带真实口令的
   MySQL 连接串。占位符（`***`、`YOUR_USER`、`<token>`）不算。
2. **债务到期**：`tests/architecture/*.json` 里带 `expires` 的条目，过期就红
   （allowlist 是债务清单，不是永久豁免）。
3. **文档同步提示**：本次 diff 改了资源代码但没改 `CHANGELOG.md`，给出警告
   （警告不阻断；是否例外由人判断）。

用法::

    python3 tools/dev/release_check.py            # 交付前跑
    python3 tools/dev/release_check.py --strict    # 有警告也失败（CI 用）

退出码：0 通过 / 1 有阻断问题 / 2 运行环境不对。
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
REGISTRIES = BASE / "tests" / "architecture"

SECRET_PATTERNS = {
    "license key": re.compile(r"sv_licenseKey\s+[A-Za-z0-9]{10,}"),
    "discord webhook": re.compile(r"https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}"),
    "openai/deepseek key": re.compile(r"\bsk-[A-Za-z0-9]{24,}"),
    "github token": re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"),
    "aws key": re.compile(r"\bAKIA[0-9A-Z]{16}"),
    "telegram bot": re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}
MYSQL_DSN = re.compile(r"mysql://([^\s:/@]+):([^\s@/]+)@")
PLACEHOLDER = re.compile(
    r"^(\*\*\*|YOUR_\w+|your_\w+|<[^>]+>|xxx+|password|pass|changeme|example|密码|口令|用户名)$",
    re.I,
)


def is_placeholder(password: str) -> bool:
    """文档里的占位写法：`***`、`YOUR_PASSWORD`、`<token>`、以及纯中文的「密码」。"""
    if PLACEHOLDER.match(password):
        return True
    return not re.search(r"[A-Za-z0-9]", password)   # 纯 CJK/标点 → 说明是说明文字
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".ogg", ".mp3", ".wav", ".ytd", ".ttf", ".woff", ".woff2", ".ico", ".pdf"}
MAX_BYTES = 3_000_000


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True, errors="replace").stdout


def tracked_files() -> list[Path]:
    out = git("ls-files").splitlines()
    return [REPO / f for f in out if f]


def scan_secrets(paths: list[Path]) -> list[str]:
    hits: list[str] = []
    for path in paths:
        if not path.is_file() or path.suffix in SKIP_SUFFIXES:
            continue
        try:
            if path.stat().st_size > MAX_BYTES:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for name, rx in SECRET_PATTERNS.items():
            for m in rx.finditer(text):
                hits.append(f"{path.relative_to(REPO)}: {name} — {m.group(0)[:60]}")
        for m in MYSQL_DSN.finditer(text):
            password = m.group(2)
            if is_placeholder(password):
                continue
            hits.append(f"{path.relative_to(REPO)}: mysql dsn with a real password")
    return hits


def expired_entries(today: date | None = None) -> tuple[list[str], list[str]]:
    """返回 (已过期, 已失效/解析不了)。"""
    today = today or date.today()
    expired, broken = [], []
    if not REGISTRIES.is_dir():
        return expired, [f"登记表目录不存在: {REGISTRIES.relative_to(REPO)}"]
    for path in sorted(REGISTRIES.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            broken.append(f"{path.name}: JSON 解析失败 — {exc}")
            continue
        entries = data.get("entries", data) if isinstance(data, dict) else data
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            raw = entry.get("expires")
            if not raw:
                continue
            try:
                when = date.fromisoformat(str(raw))
            except ValueError:
                broken.append(f"{path.name}: expires 不是 ISO 日期 — {raw!r}")
                continue
            if when < today:
                label = entry.get("id") or entry.get("event") or entry.get("table") or entry.get("name") or "?"
                expired.append(f"{path.name}: {label} 已于 {when} 到期")
    return expired, broken


def changelog_stale() -> list[str]:
    """改动集中在资源代码却忘了 CHANGELOG 时给一条提示（不阻断）。"""
    changed = [line for line in git("status", "--porcelain").splitlines() if line.strip()]
    if not changed:
        return []
    touched_code = any(
        re.search(r"resources/.*\.(lua|ts|svelte|sql)$", line) for line in changed
    )
    touched_changelog = any("CHANGELOG.md" in line for line in changed)
    if touched_code and not touched_changelog:
        return ["改了资源代码但没有 CHANGELOG.md 改动（交付三件套之一）"]
    return []


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    if not (REPO / ".git").exists():
        print("[release_check] 这里不是 git 仓库根目录", file=sys.stderr)
        return 2

    files = tracked_files()
    secrets = scan_secrets(files)
    expired, broken = expired_entries()
    warnings = changelog_stale()

    print(f"[release_check] 扫描 {len(files)} 个跟踪文件")

    blocking = 0
    if secrets:
        blocking += len(secrets)
        print("\n✗ 凭据（必须处理）:")
        for hit in secrets:
            print("   -", hit)
    if expired:
        blocking += len(expired)
        print("\n✗ 到期债务（修掉或删除对应登记条目）:")
        for hit in expired:
            print("   -", hit)
    if broken:
        blocking += len(broken)
        print("\n✗ 登记表本身有问题:")
        for hit in broken:
            print("   -", hit)
    if warnings:
        print("\n! 提示:")
        for hit in warnings:
            print("   -", hit)

    if blocking:
        print(f"\n结论: 失败（{blocking} 项阻断）")
        return 1
    if warnings and strict:
        print("\n结论: 失败（--strict：有提示即失败）")
        return 1
    print("\n结论: 通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
