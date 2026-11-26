"""剧情抉择 UI 的契约。

历史：2026-11-01 曾判定"CEF 回程通道不通"，实为 `decision_nui.html` 的 **回调地址写错**
（`cfx-nui-<res>` 是页面 host，回调要 POST 到 `https://<GetParentResourceName()>/...`）
＋焦点顺序反了（必须先 `SetNuiFocusKeepInput` 再 `SetNuiFocus`）。修好后键鼠都可用。
本闸门只守护这两条，防止退回错误形态。
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRV = REPO / "T-CityLite.base/resources/[custom]/story-engine"
HTML = SRV / "client/decision_nui.html"
MAIN = SRV / "client/main.lua"


def test_nui_callback_rejects_the_page_host() -> None:
    html = HTML.read_text(encoding="utf-8")
    assert "GetParentResourceName" in html, "回调必须用 GetParentResourceName 拼 host"
    # 只允许出现在注释里，不许出现在 fetch 的 URL 里
    code = chr(10).join(l for l in html.splitlines() if not l.lstrip().startswith("//"))
    assert "https://cfx-nui-story-engine/" not in code, "回调地址不能是页面 host（会 404，且被 catch 吞掉）"


def _focus_order_problems(src: str) -> list[str]:
    problems: list[str] = []
    start = src.find("local function applyStoryFocus(")
    if start == -1:
        return ["missing applyStoryFocus"]
    end = src.find("\nend\n", start)
    block = src[start:end + 4] if end != -1 else src[start:]
    keep = block.find("SetNuiFocusKeepInput(keepInput == true)")
    focus = block.find("SetNuiFocus(true,")
    if keep == -1:
        problems.append("applyStoryFocus missing SetNuiFocusKeepInput(keepInput == true)")
    if focus == -1:
        problems.append("applyStoryFocus missing SetNuiFocus(true, ...)")
    if keep != -1 and focus != -1 and keep > focus:
        problems.append("必须先 keepInput 再 SetNuiFocus，否则丢光标")
    return problems


def test_focus_rejects_setting_keepinput_after_focus() -> None:
    src = MAIN.read_text(encoding="utf-8")
    assert _focus_order_problems(src) == []

    broken = (
        "local function applyStoryFocus(hasFocus, hasCursor, keepInput)\n"
        "    SetNuiFocus(true, hasCursor ~= false)\n"
        "    SetNuiFocusKeepInput(keepInput == true)\n"
        "end\n"
    )
    assert _focus_order_problems(broken), "keepInput 放在 SetNuiFocus 之后必须被抓到"
