"""M5 架构闸门：非排除资源中不得存在活跃的 backdrop-filter / filter: blur( 样式。

背景（issue #347）：
- `backdrop-filter: blur()` 在 FiveM CEF 中会导致整页合成模糊重算，属于明确禁止的 NUI 反模式；
- `[system]/monitor` 是第三方 txAdmin 打包产物，在 `menu_surface_baseline.json` 的
  `backdrop_filter.excluded` 中显式排除，不计入阻断；
- 注释中的提示说明（如「不要用 backdrop-filter」）不计作违规，但真实 CSS/style 命中必须拦住。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
BASELINE = Path(__file__).with_name("menu_surface_baseline.json")

SCAN_EXTS = {".lua", ".js", ".ts", ".html", ".css", ".scss", ".svelte", ".vue"}
SKIP_DIRS = {"node_modules", ".git", "cache", ".pytest_cache"}
BACKDROP_RE = re.compile(
    r"(?:(?:-webkit-)?backdrop-filter\b|backdropFilter\s*:|filter\s*:\s*blur\()",
    re.IGNORECASE,
)

TARGET_SOURCE_DIRS = (
    RESOURCES / "[system]" / "tcity-dashboard" / "nui" / "src",
    RESOURCES / "[qb]" / "qb-banking" / "web" / "src",
    RESOURCES / "[custom]" / "hud-position-tool" / "html",
)


def _resource_of(path: Path, resources_dir: Path) -> str:
    """将 resources/<bracket>/<resource>/... 映射为 <resource>。"""
    try:
        rel = path.relative_to(resources_dir).as_posix()
    except ValueError:
        return "?"
    segments = rel.split("/")
    if len(segments) >= 2:
        return segments[1]
    return segments[0] if segments else "?"


def _blank_span(buf: list[str], start: int, end: int) -> None:
    """用空格替换注释字符，保留换行符以维持行号一致。"""
    for idx in range(start, end):
        if buf[idx] != "\n":
            buf[idx] = " "


def _strip_comments(text: str, suffix: str) -> str:
    """按文件扩展名剥离注释（保留字符串字面量与换行符）。"""
    buf = list(text)
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch in ("'", '"', "`"):
            i = _skip_string(text, i, ch)
            continue
        if suffix in {".html", ".vue", ".svelte"} and text.startswith("<!--", i):
            end = text.find("-->", i + 4)
            end = n if end < 0 else end + 3
            _blank_span(buf, i, end)
            i = end
            continue
        if suffix == ".lua" and text.startswith("--", i):
            end = _find_lua_comment_end(text, i)
            _blank_span(buf, i, end)
            i = end
            continue
        if suffix != ".lua" and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            _blank_span(buf, i, end)
            i = end
            continue
        if suffix in {".js", ".ts", ".vue", ".svelte"} and text.startswith("//", i):
            end = text.find("\n", i + 2)
            end = n if end < 0 else end
            _blank_span(buf, i, end)
            i = end
            continue
        i += 1
    return "".join(buf)


def _skip_string(text: str, start: int, quote: str) -> int:
    i = start + 1
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == quote:
            return i + 1
        i += 1
    return n


def _find_lua_comment_end(text: str, start: int) -> int:
    n = len(text)
    long_open = re.match(r"\[(=*)\[", text[start + 2:])
    if long_open:
        close = "]" + long_open.group(1) + "]"
        end = text.find(close, start + 2 + long_open.end())
        return n if end < 0 else end + len(close)
    end = text.find("\n", start + 2)
    return n if end < 0 else end


def load_excluded_resources(baseline_path: Path = BASELINE) -> dict[str, dict]:
    """从基线文件读取 backdrop_filter.excluded，并验证每项都附带理由。"""
    data = json.loads(baseline_path.read_text(encoding="utf-8"))
    section = data.get("backdrop_filter", {})
    excluded = section.get("excluded", {})
    assert isinstance(excluded, dict), "backdrop_filter.excluded 必须是对象"
    for name, meta in excluded.items():
        assert isinstance(meta, dict), f"excluded.{name} 必须是对象"
        assert str(meta.get("reason", "")).strip(), f"excluded.{name} 必须写明排除理由"
    return excluded


def _iter_source_files(root: Path):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in SCAN_EXTS:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def scan_backdrop_filter(
    root: Path,
    excluded: set[str] | None = None,
    resources_dir: Path | None = None,
) -> list[str]:
    """扫描目录中非排除资源的活跃 backdrop-filter / filter: blur( 命中。"""
    excluded_set = excluded or set()
    res_root = resources_dir or root
    hits: list[str] = []
    for path in _iter_source_files(root):
        resource = _resource_of(path, res_root)
        if resource in excluded_set:
            continue
        raw = path.read_text(encoding="utf-8", errors="ignore")
        stripped = _strip_comments(raw, path.suffix)
        for line_no, line in enumerate(stripped.splitlines(), start=1):
            match = BACKDROP_RE.search(line)
            if match:
                rel = path.relative_to(res_root).as_posix()
                snippet = line[max(0, match.start() - 30):match.end() + 40].strip()
                hits.append(f"{rel}:{line_no}: {snippet}")
    return hits


def test_backdrop_filter_gate_detects_injection_and_allows_excluded_monitor(tmp_path: Path) -> None:
    """验证三项目标源码已清零、monitor 排除为绿，且注入恶意样式会立即变红。"""
    excluded = load_excluded_resources(BASELINE)
    assert "monitor" in excluded
    assert excluded["monitor"].get("count") == 6

    for target_dir in TARGET_SOURCE_DIRS:
        assert target_dir.is_dir()
        source_hits = scan_backdrop_filter(target_dir, resources_dir=RESOURCES)
        assert source_hits == []

    # 正向对照：monitor 在 excluded 中不报红；移出 excluded 则立刻命中
    fake_res = tmp_path / "resources"
    monitor_css = fake_res / "[system]" / "monitor" / "panel" / "index.css"
    monitor_css.parent.mkdir(parents=True)
    monitor_css.write_text(".m { backdrop-filter: blur(10px); }\n", encoding="utf-8")
    assert scan_backdrop_filter(fake_res, excluded=set(excluded)) == []
    assert len(scan_backdrop_filter(fake_res, excluded=set())) == 1

    # 反向注入 1：非排除资源写入 backdrop-filter -> 闸门变红
    probe_css = fake_res / "[custom]" / "probe-ui" / "html" / "panel.css"
    probe_css.parent.mkdir(parents=True)
    probe_css.write_text(".panel { backdrop-filter: blur(8px); }\n", encoding="utf-8")
    injected_hits = scan_backdrop_filter(fake_res, excluded=set(excluded))
    assert len(injected_hits) == 1

    # 反向注入 2：新写入 filter: blur( -> 闸门同样变红
    probe_css.write_text(".panel { filter: blur(6px); }\n", encoding="utf-8")
    blur_hits = scan_backdrop_filter(fake_res, excluded=set(excluded))
    assert len(blur_hits) == 1

    # 撤回为纯注释 + 半透明渐变 -> 恢复绿灯
    probe_css.write_text(
        "/* 禁止使用 backdrop-filter: blur(8px) */\n"
        ".panel { background: linear-gradient(180deg, rgba(20, 24, 34, 0.9), rgba(10, 12, 18, 0.95)); }\n",
        encoding="utf-8",
    )
    assert scan_backdrop_filter(fake_res, excluded=set(excluded)) == []


def test_non_excluded_resources_detects_zero_backdrop_filter(tmp_path: Path) -> None:
    """全仓非排除资源（含构建产物）中 backdrop-filter 命中数必须为 0，且对临时注入敏感。"""
    excluded = set(load_excluded_resources(BASELINE))

    sandbox = tmp_path / "resources"
    bad_html = sandbox / "[custom]" / "demo-panel" / "html" / "overlay.html"
    bad_html.parent.mkdir(parents=True)
    bad_html.write_text("<style>.box { backdrop-filter: blur(4px); }</style>\n", encoding="utf-8")
    assert len(scan_backdrop_filter(sandbox, excluded=excluded)) == 1

    hits = scan_backdrop_filter(RESOURCES, excluded=excluded)
    assert hits == [], "以下非排除资源仍存在 backdrop-filter / filter: blur(：\n" + "\n".join(hits)
