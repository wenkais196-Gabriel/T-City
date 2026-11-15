"""生成 custom-quest 的 CJK 子集字体。

为什么要有这一步：
    GTA 的原生文本渲染（DrawText / DrawText3D）没有中文字形，中文会画成一排方块
    （真机已实测：热狗摊状态条全是 □）。FiveM 提供了 RegisterFontFile，但它要求
    资源里自带一份带 CJK 的字体文件。

    这里从系统里现成的 NotoSansSC-VF.ttf（SIL OFL 1.1，允许再分发）取子集，
    只保留 custom-quest 源码里真正出现过的字符 —— 1552 个字形，约 100 KB，
    比整份字体（10 MB）轻两个数量级。

用法：
    python tools/dev/build_quest_font.py            # 生成
    python tools/dev/build_quest_font.py --check    # 只校验产物是否与源码字符集一致
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
QUEST = REPO / "T-CityLite.base/resources/[custom]/custom-quest"
OUT = QUEST / "fonts/hotdog_ui.ttf"
SRC_CANDIDATES = [
    Path("C:/Windows/Fonts/NotoSansSC-VF.ttf"),
    Path("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc"),
]

EXTRA = "，。！？：；、“”‘’（）【】《》…—·￥%×÷≥≤→←↑↓●○■□✅⚠"


def char_set() -> set[str]:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    for path in QUEST.rglob("*.lua"):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        chars.update(ch for ch in text if ord(ch) > 0x7F)
    chars.update(ch for ch in EXTRA if ord(ch) > 0x7F)
    return chars


def build(chars: set[str]) -> int:
    from fontTools.subset import Options, Subsetter
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont

    source = next((p for p in SRC_CANDIDATES if p.exists()), None)
    if source is None:
        print("[font] 找不到可用的中文字体源文件；跳过（CI 上不生成）")
        return 2

    font = TTFont(str(source))
    # 变体字体先定到常规字重：GTA 的文本渲染不做 variable axis 求值
    font = instantiateVariableFont(font, {"wght": 500}, inplace=True, updateFontNames=False)

    options = Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.recalc_bounds = True
    options.drop_tables += ["DSIG"]

    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=[ord(c) for c in sorted(chars)])
    subsetter.subset(font)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(OUT))
    print(f"[font] {OUT.relative_to(REPO)} 字形 {len(chars)} 个，{OUT.stat().st_size // 1024} KB")
    return 0


def fingerprint(chars: set[str]) -> str:
    return hashlib.sha256("".join(sorted(chars)).encode()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    chars = char_set()
    stamp = OUT.with_suffix(".sha256")

    if args.check:
        if not OUT.exists():
            print(f"[check] 缺产物：{OUT}")
            return 2
        if not stamp.exists():
            print("[check] 缺字符集指纹（重跑生成器）")
            return 1
        if stamp.read_text(encoding="utf-8").strip() != fingerprint(chars):
            print("[check] 源码里的中文字符集变了 —— 重跑 tools/dev/build_quest_font.py，否则新字会显示成方块")
            return 1
        print(f"[check] OK 字形 {len(chars)} 个")
        return 0

    rc = build(chars)
    if rc == 0:
        stamp.write_text(fingerprint(chars), encoding="utf-8")
    return rc


if __name__ == "__main__":
    sys.exit(main())
