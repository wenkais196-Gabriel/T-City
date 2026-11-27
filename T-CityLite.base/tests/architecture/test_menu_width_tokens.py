"""菜单主题 token 契约：宽度只能来自 `:root` 的 `--menu-width*`。

为什么要有这条闸门：2026-11-27 的 #383（标题是「产业面板方案 A —— 信息行语义」）
顺手把 `.menu-shell` 的 `width: 520px` 改成 `300px` —— 一个只该动 custom-industry 的
PR，静默压窄了**所有**走新菜单的界面（标题折行、配额折行、禁用行说明折成两行）。
字面量宽度藏在别的 PR 里，review 和 CI 都看不见；改成 token 之后，
「改宽度」必须是改 token 的一行 diff，绕不过去。
"""

from __future__ import annotations

import re
import json
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]
CSS = BASE / "resources" / "[custom]" / "custom-menu" / "html" / "styles.css"
BASELINE = Path(__file__).with_name("menu_theme_baseline.json")

#: 允许的宽度区间（px）。窄了折行、宽了挡视野，两端都算回归。
WIDTH_MIN = 300
WIDTH_MAX = 640

TOKENS = ("--menu-width", "--menu-width-min", "--menu-width-max")


def _strip_comments(css: str) -> str:
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def _root_block(css: str) -> str:
    m = re.search(r":root\s*\{(.*?)\}", _strip_comments(css), re.S)
    assert m, "styles.css 里找不到 :root 块"
    return m.group(1)


def _rule_body(css: str, selector: str) -> str:
    """取某个选择器的规则体（选择器必须整词匹配，避免 .menu-shell 命中 .cm-mount-embedded .menu-shell）。"""
    clean = _strip_comments(css)
    pattern = re.compile(r"(?<![\w.\-])" + re.escape(selector) + r"\s*\{([^}]*)\}", re.S)
    bodies = pattern.findall(clean)
    assert bodies, f"styles.css 里找不到 {selector} 的规则"
    return bodies[0]


def _px(token_value: str) -> int:
    m = re.fullmatch(r"\s*(\d+)px\s*", token_value)
    assert m, f"token 必须是 px 字面量，实际是 {token_value!r}"
    return int(m.group(1))


def check_css(css: str) -> list[str]:
    """返回违规清单；空列表表示合规。抽成函数是为了能拿"坏 CSS"自证闸门会红。"""
    errors: list[str] = []
    root = _root_block(css)

    for token in TOKENS:
        m = re.search(re.escape(token) + r"\s*:\s*([^;]+);", root)
        if not m:
            errors.append(f":root 缺少 {token}")
            continue
        value = m.group(1).strip()
        if token == "--menu-width":
            try:
                px = _px(value)
            except AssertionError as exc:
                errors.append(str(exc))
                continue
            if not (WIDTH_MIN <= px <= WIDTH_MAX):
                errors.append(f"--menu-width={px}px 超出 {WIDTH_MIN}–{WIDTH_MAX}px")

    # 与基线比对：区间闸只会拦"离谱值"，拦不住"520 → 440 这种看着也合理的偷偷改"。
    # 基线是唯一的声明：改 token 就必须同 commit 改基线，review 时一眼能看见。
    try:
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:  # pragma: no cover - 基线缺失即闸门失效
        errors.append(f"读不到基线 {BASELINE.name}：{exc}")
        baseline = {}
    for key, token in (("menu_width", "--menu-width"),
                       ("menu_width_min", "--menu-width-min"),
                       ("menu_width_max", "--menu-width-max")):
        want = baseline.get(key)
        if want is None:
            continue
        m = re.search(re.escape(token) + r"\s*:\s*(\d+)px", root)
        if not m:
            continue  # 缺 token 已在上面记过
        if int(m.group(1)) != int(want):
            errors.append(f"{token}={m.group(1)}px 与基线 {want}px 不一致（改宽度请同 commit 更新 menu_theme_baseline.json）")

    body = _rule_body(css, ".menu-shell")
    if "var(--menu-width)" not in body:
        errors.append(".menu-shell 的 width 必须引用 var(--menu-width)")
    # 字面量宽度：本块里任何 `width: 123px` 都算违规（含 min/max-width）
    for literal in re.findall(r"(?:min-|max-)?width\s*:\s*\d+px", body):
        errors.append(f".menu-shell 里出现字面量宽度：{literal}")
    return errors


def test_menu_shell_width_rejects_literal_px():
    """`--menu-width*` 必须在 `:root` 里，且 `.menu-shell` 不许写字面量宽度。

    名字带 rejects 是给 `gate_coverage` 看的：这条规则自己构造"字面量 px"这个坏形状
    并断言它会被抓（见 test_gate_rejects_regressions 的注入用例）。
    """
    errors = check_css(CSS.read_text(encoding="utf-8"))
    assert not errors, "菜单宽度必须走 token：\n" + "\n".join(errors)


def test_token_values_rejects_out_of_range_drift():
    root = _root_block(CSS.read_text(encoding="utf-8"))
    width = _px(re.search(r"--menu-width\s*:\s*([^;]+);", root).group(1))
    lo = _px(re.search(r"--menu-width-min\s*:\s*([^;]+);", root).group(1))
    hi = _px(re.search(r"--menu-width-max\s*:\s*([^;]+);", root).group(1))
    assert lo < width < hi, f"要求 min < width < max，实际 {lo} / {width} / {hi}"


@pytest.mark.parametrize(
    "old, new, expected",
    [
        # 把 token 改回 #383 那个值 → 与基线不符，必须被抓
        ("--menu-width: 520px;", "--menu-width: 300px;", "与基线"),
        # 改成看着也合理的 440 → 同样必须被抓（区间闸拦不住这种偷改）
        ("--menu-width: 520px;", "--menu-width: 440px;", "与基线"),
        # 在 shell 里塞字面量宽度 → 必须被抓
        ("width: var(--menu-width);", "width: 300px;", "字面量宽度"),
        # 删掉 token → 必须被抓
        ("--menu-width: 520px;", "", ":root 缺少 --menu-width"),
    ],
)
def test_gate_rejects_regressions(old, new, expected):
    """自证：把坏形状喂进去，闸门必须红（否则它只是在替当前文件背书）。"""
    css = CSS.read_text(encoding="utf-8")
    assert old in css, f"夹具与当前 CSS 不匹配：{old!r}"
    errors = check_css(css.replace(old, new, 1))
    assert errors, "注入坏形状后闸门仍然全绿 —— 这条闸门是假的"
    assert any(expected in e for e in errors), f"期望命中 {expected!r}，实际 {errors}"
