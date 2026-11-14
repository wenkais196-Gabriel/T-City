#!/usr/bin/env python3
"""把 FiveM 任务配置里的坐标画到 GTA 地图上，离线出 PNG —— 不用进游戏就能看出「这个点在哪」。

为什么需要：一次要校 50+ 条任务模板、每条 4–10 个步骤点。靠肉身进游戏跑一遍才能发现
「点在楼里/半空/水里/根本没有路过去」，成本太高；而这类错误在纯数字上是看不出来的。

原理（社区标定，FiveDock 的 Leaflet CRS）：
    zoom 0 时整张图 256×256 px，游戏坐标 (x, y) 落在像素
        px = 0.02072 * x + 117.3
        py = -0.0205 * y + 172.8
    每提高一级 zoom 像素翻倍。y 系数为负，因为游戏 y 朝北、像素 y 朝下。
    瓦片到 z5 为止（8192 px，1 px ≈ 48 m），再细只能放大 z5 的瓦片。

用法：
    python tools/dev/quest_map.py --quest hotdog_vendor --out out/hotdog.png
    python tools/dev/quest_map.py --coords "-150,-250,44" --scale 3
    python tools/dev/quest_map.py --quest garbage_v1_city --style grid --scale 2

产出：PNG + 终端里每个点的像素位置与几条静态体检（世界边界、z 是否离谱、点间距）。
"""

from __future__ import annotations

import argparse
import io
import os
import math
import re
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
QUESTS_DIR = Path(os.environ.get(
    "QUEST_MAP_QUESTS_DIR",
    REPO / "T-CityLite.base/resources/[custom]/custom-quest/config/quests",
))  # 可用环境变量覆盖：测试拿临时目录喂坏形状

# 社区标定（FiveDock / gta-v-map-leaflet 系列）
PX_PER_UNIT_Z0 = 0.02072
PX_OFFSET_X = 117.3
PY_PER_UNIT_Z0 = -0.0205
PY_OFFSET_Y = 172.8

TILE = 256
MAX_TILE_ZOOM = 5  # 瓦片只有 z0–5；更高倍率靠放大 z5

STYLES = {
    "atlas": "https://assets.fivedock.dev/maps/styleatlas/{z}/{x}/{y}.jpg",
    "satellite": "https://assets.fivedock.dev/maps/stylesatelite/{z}/{x}/{y}.jpg",
    "grid": "https://assets.fivedock.dev/maps/stylegrid/{z}/{x}/{y}.png",
}

HEADERS = {
    # 不带 UA 会被 FiveDock 直接 403
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
    "Referer": "https://fivedock.dev/",
}

# 世界边界（用于静态体检，不是几何真值）
# 取值与 FiveM 官方示例的 SetWaterAreaClipRect、RageMP 高度图覆盖范围一致：
#   x -4000…4500，y -4000…8000（高度图 -4100,-4300 → 4300,7825）
# z 上限留到 1200：飞行任务（pilot / aviation）本来就在 150–300。
WORLD = {"x": (-4000, 4500), "y": (-4000, 8000), "z": (-300, 1200)}


@dataclass
class Point:
    x: float
    y: float
    z: float
    label: str = ""
    radius: float = 0.0


def pixel_of(x: float, y: float, zoom: int = MAX_TILE_ZOOM) -> tuple[float, float]:
    scale = 2 ** zoom
    return ((PX_PER_UNIT_Z0 * x + PX_OFFSET_X) * scale,
            (PY_PER_UNIT_Z0 * y + PY_OFFSET_Y) * scale)


def meters_per_pixel(zoom: int = MAX_TILE_ZOOM) -> float:
    return 1.0 / (PX_PER_UNIT_Z0 * (2 ** zoom))


def fetch_tile(style: str, z: int, x: int, y: int, cache: Path):
    from PIL import Image
    cache.mkdir(parents=True, exist_ok=True)
    f = cache / f"{style}_{z}_{x}_{y}.img"
    if f.exists():
        try:
            return Image.open(f).convert("RGB")
        except Exception:
            f.unlink(missing_ok=True)
    url = STYLES[style].format(z=z, x=x, y=y)
    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
        f.write_bytes(data)
        return Image.open(io.BytesIO(data)).convert("RGB")
    except Exception as exc:  # noqa: BLE001 - 缺瓦片不该整脚本失败
        print(f"  ! 瓦片缺失 {url}: {exc}", file=sys.stderr)
        return None


def render(points: list[Point], style: str, scale: int, margin: int, out: Path):
    # 延迟导入：--scan 是纯文本体检，CI 里没有 Pillow 也必须能跑
    from PIL import Image, ImageDraw, ImageFont
    z = MAX_TILE_ZOOM
    px = [pixel_of(p.x, p.y, z) for p in points]
    xs = [p[0] for p in px]
    ys = [p[1] for p in px]
    x0, x1 = min(xs) - margin, max(xs) + margin
    y0, y1 = min(ys) - margin, max(ys) + margin

    tx0, tx1 = int(x0 // TILE), int(x1 // TILE)
    ty0, ty1 = int(y0 // TILE), int(y1 // TILE)

    cache = REPO / ".cache/quest_map_tiles"
    canvas = Image.new("RGB", ((tx1 - tx0 + 1) * TILE, (ty1 - ty0 + 1) * TILE), (18, 18, 20))
    missing = 0
    for ty in range(ty0, ty1 + 1):
        for tx in range(tx0, tx1 + 1):
            tile = fetch_tile(style, z, tx, ty, cache)
            if tile is None:
                missing += 1
                continue
            canvas.paste(tile, ((tx - tx0) * TILE, (ty - ty0) * TILE))

    crop = canvas.crop((int(x0 - tx0 * TILE), int(y0 - ty0 * TILE),
                        int(x1 - tx0 * TILE), int(y1 - ty0 * TILE)))
    if scale > 1:
        resample = getattr(Image, "Resampling", Image).LANCZOS
        crop = crop.resize((crop.width * scale, crop.height * scale), resample)

    draw = ImageDraw.Draw(crop, "RGBA")
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 15)
        small = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 13)
    except Exception:
        font = small = ImageFont.load_default()

    mpp = meters_per_pixel(z) / scale  # 每个**输出像素**对应多少米
    for idx, (p, (gx, gy)) in enumerate(zip(points, px), start=1):
        cx = (gx - x0) * scale
        cy = (gy - y0) * scale
        if p.radius > 0:
            rpx = p.radius / mpp
            draw.ellipse([cx - rpx, cy - rpx, cx + rpx, cy + rpx], outline=(255, 210, 0, 235), width=2)
        draw.ellipse([cx - 7, cy - 7, cx + 7, cy + 7], fill=(230, 40, 40, 235), outline=(255, 255, 255, 255), width=2)
        label = p.label or str(idx)
        tw = draw.textlength(label, font=font)
        draw.rectangle([cx + 10, cy - 11, cx + 18 + tw, cy + 9], fill=(0, 0, 0, 165))
        draw.text((cx + 14, cy - 9), label, fill=(255, 255, 255, 255), font=font)

    # 比例尺（50 米）
    bar_px = 50 / mpp
    bx, by = 16, crop.height - 22
    draw.line([bx, by, bx + bar_px, by], fill=(255, 255, 255, 235), width=3)
    draw.text((bx, by - 18), "50 m", fill=(255, 255, 255, 240), font=small)

    # 角标：源与坐标框
    bbox = (min(p.x for p in points), min(p.y for p in points),
            max(p.x for p in points), max(p.y for p in points))
    footer = (f"{style} z{z} ×{scale}   1px≈{mpp:.1f}m   "
              f"x {bbox[0]:.0f}…{bbox[2]:.0f}  y {bbox[1]:.0f}…{bbox[3]:.0f}")
    draw.rectangle([0, crop.height - 16, crop.width, crop.height], fill=(0, 0, 0, 140))
    draw.text((10, crop.height - 16), footer, fill=(220, 220, 220, 255), font=small)
    if missing:
        draw.text((10, 8), f"{missing} 瓦片缺失", fill=(255, 90, 90, 255), font=small)

    out.parent.mkdir(parents=True, exist_ok=True)
    crop.save(out)
    return crop


COORD_RE = re.compile(r"coords\s*=\s*\{\s*x\s*=\s*(-?[\d.]+)\s*,\s*y\s*=\s*(-?[\d.]+)\s*,\s*z\s*=\s*(-?[\d.]+)")
STEP_RE = re.compile(r"id\s*=\s*'(step_[^']+)'")


def template_blocks(text: str):
    """把一份配置文件切成 {模板 id: 模板正文}（花括号配对，避免跨模板串味）。"""
    out: dict[str, str] = {}
    for m in re.finditer(r"id\s*=\s*'([a-z0-9_]+)'", text):
        name = m.group(1)
        if name.startswith("step_"):
            continue
        open_at = text.rindex("{", 0, m.start())
        depth, close_at = 0, None
        for pos in range(open_at, len(text)):
            ch = text[pos]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    close_at = pos + 1
                    break
        if close_at:
            out.setdefault(name, text[open_at:close_at])
    return out


def scan_all() -> int:
    """扫全部任务配置，分两档报：硬错误（一定有问题）与提示（需要人看一眼）。"""
    errors = hints = 0
    total_templates = total_points = 0
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        text = cfg.read_text(encoding="utf-8", errors="replace")
        for name, block in template_blocks(text).items():
            total_templates += 1
            # 飞行类任务本来就在空中：z 高不是问题
            airborne_ok = any(k in name for k in ("aviation", "pilot", "flight", "airlift"))
            seen: dict[tuple[float, float, float], list[str]] = {}
            step = None
            for line in block.splitlines():
                m = STEP_RE.search(line)
                if m:
                    step = m.group(1)
                m = COORD_RE.search(line)
                if not m:
                    continue
                total_points += 1
                x, y, z = (float(v) for v in m.groups())
                seen.setdefault((x, y, z), []).append(step or "?")
                hard = []
                if not (WORLD["x"][0] <= x <= WORLD["x"][1] and WORLD["y"][0] <= y <= WORLD["y"][1]):
                    hard.append("世界边界外")
                if not (WORLD["z"][0] <= z <= WORLD["z"][1]):
                    hard.append(f"z={z:.0f} 越界")
                if hard:
                    errors += 1
                    print(f"  ✗ {cfg.name:<34} {name:<28} {step or '?':<22} ({x:.0f}, {y:.0f}, {z:.0f})  "
                          + "；".join(hard))
                elif z > 120 and not airborne_ok:
                    hints += 1
                    print(f"  ? {cfg.name:<34} {name:<28} {step or '?':<22} ({x:.0f}, {y:.0f}, {z:.0f})  "
                          "z 偏高 —— 确认在楼顶还是空中")
            for coords, steps in seen.items():
                if len(set(steps)) >= 3:
                    hints += 1
                    print(f"  ? {cfg.name:<34} {name:<28} {len(set(steps))} 个步骤共用同一点 "
                          f"({coords[0]:.0f}, {coords[1]:.0f}, {coords[2]:.0f}) —— 确认不需要移动？")
    print(f"\n扫描：{total_templates} 个模板 / {total_points} 个坐标点 | 硬错误 {errors} | 提示 {hints}")
    print("硬错误 = 世界边界外或 z 越界（一定有问题）；提示 = 需要人看一眼（楼顶/同一地点多步骤）。")
    return 0 if errors == 0 else 1


def load_quest(quest_id: str) -> tuple[str, list[Point]]:
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        text = cfg.read_text(encoding="utf-8", errors="replace")
        if f"id = '{quest_id}'" not in text:
            continue
        id_at = text.index(f"id = '{quest_id}'")
        # 向前找到这个模板自己的开括号，再向后按深度配对，避免把后面几个任务也读进来
        open_at = text.rindex("{", 0, id_at)
        depth, close_at = 0, None
        for pos in range(open_at, len(text)):
            ch = text[pos]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    close_at = pos + 1
                    break
        assert close_at, f"{quest_id} 的表格没有闭合"
        block = text[open_at:close_at]
        points: list[Point] = []
        current_step = None
        for line in block.splitlines():
            m = re.search(r"id\s*=\s*'(step_[^']+)'", line)
            if m:
                current_step = m.group(1)
            m = re.search(r"coords\s*=\s*\{\s*x\s*=\s*(-?[\d.]+)\s*,\s*y\s*=\s*(-?[\d.]+)\s*,\s*z\s*=\s*(-?[\d.]+)", line)
            if m:
                points.append(Point(float(m.group(1)), float(m.group(2)), float(m.group(3)),
                                    label=(current_step or "pt").replace("step_", "")))
            if line.strip() == "}," and points and "id = '" in line:
                break
        return cfg.name, points
    raise SystemExit(f"没找到任务模板 {quest_id}")


def sanity(points: list[Point]) -> list[str]:
    notes: list[str] = []
    for i, p in enumerate(points, 1):
        if not (WORLD["x"][0] <= p.x <= WORLD["x"][1] and WORLD["y"][0] <= p.y <= WORLD["y"][1]):
            notes.append(f"#{i} {p.label}: ({p.x}, {p.y}) 在世界边界之外")
        if not (WORLD["z"][0] <= p.z <= WORLD["z"][1]):
            notes.append(f"#{i} {p.label}: z={p.z} 不在合理高度范围")
    for i in range(1, len(points)):
        a, b = points[i - 1], points[i]
        d = math.dist((a.x, a.y, a.z), (b.x, b.y, b.z))
        if d > 0 and d < 2.0:
            notes.append(f"#{i}→#{i+1} 距离仅 {d:.1f} m（同一点复用？）")
    if points and max(p.z for p in points) > 100:
        notes.append(f"最高点 z={max(p.z for p in points):.0f} —— 确认不是在空中")
    return notes


def main() -> int:
    ap = argparse.ArgumentParser(description="把任务坐标画到 GTA 地图上")
    ap.add_argument("--quest", help="任务模板 id（如 hotdog_vendor）")
    ap.add_argument("--coords", help="直接给坐标：x,y,z 或 x,y,z;x,y,z")
    ap.add_argument("--scan", action="store_true", help="扫全部任务配置，只报可疑坐标")
    ap.add_argument("--style", default="atlas", choices=sorted(STYLES))
    ap.add_argument("--scale", type=int, default=3, help="放大倍数（瓦片只到 z5，靠放大看清街道）")
    ap.add_argument("--margin", type=int, default=110, help="边距（z5 像素）")
    ap.add_argument("--out", default=".cache/quest_map/out.png")
    args = ap.parse_args()

    if args.scan:
        return scan_all()

    if args.quest:
        source, points = load_quest(args.quest)
    elif args.coords:
        source = "cli"
        points = []
        for chunk in args.coords.split(";"):
            parts = [float(v) for v in chunk.split(",")]
            points.append(Point(parts[0], parts[1], parts[2] if len(parts) > 2 else 0.0))
    else:
        ap.error("要么 --quest / --coords / --scan")

    if not points:
        raise SystemExit(f"{source} 里没解析到坐标")

    out = (REPO / args.out) if not Path(args.out).is_absolute() else Path(args.out)
    img = render(points, args.style, args.scale, args.margin, out)

    print(f"来源: {source}")
    for i, p in enumerate(points, 1):
        gx, gy = pixel_of(p.x, p.y)
        print(f"  #{i} {p.label:<14} ({p.x:>9.1f}, {p.y:>9.1f}, {p.z:>6.1f})  z5px=({gx:>7.1f}, {gy:>7.1f})"
              + (f"  r={p.radius}m" if p.radius else ""))
    notes = sanity(points)
    if notes:
        print("体检:")
        for n in notes:
            print("  !", n)
    print(f"图: {out}  ({img.width}x{img.height})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
