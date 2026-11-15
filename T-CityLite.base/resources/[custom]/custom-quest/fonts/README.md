# 字体来源与许可

`hotdog_ui.ttf` 是 **Noto Sans SC** 的子集（1550 个字形，约 450 KB）。

- 用途：GTA 的原生文本渲染（`DrawText` / `DrawText3D`）没有 CJK 字形，中文会画成方块。
  FiveM 的 `RegisterFontFile` 可以从资源里加载字体，客户端把它交给 `SetTextFont` 就能正常显示。
- 生成：`python tools/dev/build_quest_font.py`（从系统里的 `NotoSansSC-VF.ttf` 取子集，
  字符集 = custom-quest 源码里出现过的全部字符；改文案后要重跑，否则新字会变方块）。
- 校验：`python tools/dev/build_quest_font.py --check`（字符集指纹不一致就红）。
- 许可：Noto Sans SC 以 **SIL Open Font License 1.1** 发布，允许嵌入与再分发；
  子集仍是同一许可下的衍生作品。许可全文见 <https://scripts.sil.org/OFL>。
