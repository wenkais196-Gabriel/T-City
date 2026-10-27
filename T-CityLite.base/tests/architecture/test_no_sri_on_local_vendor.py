"""自定义资源里的 HTML 不许对本地 vendor 文件用 SRI。

真机事故：custom-police 的 index.html 给 bootstrap/jquery/popper 写了 integrity，
但那些是仓库内的本地文件，git 的 LF/CRLF 转换一变哈希就对不上，CEF 直接
"Failed to find a valid digest ... The resource has been blocked."，
jQuery 没加载 → script.js 里 `$ is not defined` → 整个警务面板白屏。

SRI 只对"从 CDN 取、不可信"的资源有意义；这里全是 cfx-nui 本地文件。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"

INTEGRITY = re.compile(r'\bintegrity\s*=')


def test_custom_html_has_no_integrity_attributes() -> None:
    offenders: list[str] = []
    for path in sorted(CUSTOM.rglob("*.html")):
        if "node_modules" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if INTEGRITY.search(text):
            offenders.append(str(path.relative_to(BASE)))
    assert not offenders, (
        "以下自定义资源的 HTML 对本地文件用了 SRI（换行符一变就会被 CEF 拦截）："
        + ", ".join(offenders)
    )
