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
import json
import math
import os
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


COORD_RE = re.compile(
    r"(?:dest|return)?[cC]oords\s*=\s*\{\s*x\s*=\s*(-?[\d.]+)\s*,\s*y\s*=\s*(-?[\d.]+)\s*,\s*z\s*=\s*(-?[\d.]+)"
)
STEP_RE = re.compile(r"id\s*=\s*'(step_[^']+)'")


# ── 路网（判「这个点离能开车/走人的地面有多远」）─────────────────────────────
# 数据：DurtyFree/gta-v-data-dumps 的 nodes.zip（67,454 个车辆节点，MIT）
# 缓存：.cache/roads/road_points.bin —— 'RDP1' + uint32 计数 + 每点 3×float32(x,y,z)，水面节点已剔除
ROAD_NODES_URL = "https://raw.githubusercontent.com/DurtyFree/gta-v-data-dumps/master/nodes.zip"
ROAD_CACHE = REPO / ".cache/roads/road_points.bin"
ROAD_CELL = 50.0
#: 离最近路面节点超过这么多米 → 提示（非飞行任务）
ROAD_FAR_M = 60.0
#: 与最近路面节点的高差超过这么多米 → 提示（非飞行任务；楼顶/空中/地下）
ROAD_DZ_M = 25.0


def build_road_cache() -> int:
    """下载 nodes.zip 并写出紧凑缓存（只留非水面节点的 x,y,z）。"""
    import struct
    import zipfile

    ROAD_CACHE.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(ROAD_NODES_URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=180) as resp:
        blob = resp.read()
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        cells = json.loads(archive.read("nodes.json").decode("utf-8", errors="replace"))

    triples: list[float] = []
    for cell in cells:
        for node in cell.get("Nodes") or []:
            pos = node.get("Position") or {}
            if "X" not in pos or "Y" not in pos or node.get("IsOnWater"):
                continue
            triples.extend((float(pos["X"]), float(pos["Y"]), float(pos.get("Z") or 0.0)))

    with open(ROAD_CACHE, "wb") as fh:
        fh.write(b"RDP1")
        fh.write(struct.pack("<I", len(triples) // 3))
        fh.write(struct.pack(f"<{len(triples)}f", *triples))
    return len(triples) // 3


class RoadIndex:
    """按 50 m 网格分桶的路面节点索引；只回答「最近节点的水平距离 + 高差」。"""

    def __init__(self, points: list[tuple[float, float, float]]):
        self.grid: dict[tuple[int, int], list[tuple[float, float, float]]] = {}
        for x, y, z in points:
            self.grid.setdefault((int(x // ROAD_CELL), int(y // ROAD_CELL)), []).append((x, y, z))

    def nearest(self, x: float, y: float, max_ring: int = 14) -> tuple[float, float] | None:
        """返回（水平距离 m，与该节点的高差 m）；max_ring 之外没节点时返回 None。"""
        best: tuple[float, float] | None = None
        gx, gy = int(x // ROAD_CELL), int(y // ROAD_CELL)
        for ring in range(max_ring + 1):
            for dx in range(-ring, ring + 1):
                for dy in range(-ring, ring + 1):
                    if max(abs(dx), abs(dy)) != ring:
                        continue
                    for cx, cy, cz in self.grid.get((gx + dx, gy + dy), ()):
                        dist = math.hypot(cx - x, cy - y)
                        if best is None or dist < best[0]:
                            best = (dist, cz)
            if best and best[0] <= ring * ROAD_CELL:
                return best
        return best


def load_road_index() -> RoadIndex | None:
    """读缓存；没有缓存返回 None（CI 不联网，也不该被 4 MB 下载卡住）。"""
    import struct

    if not ROAD_CACHE.exists():
        return None
    raw = ROAD_CACHE.read_bytes()
    if raw[:4] != b"RDP1":
        return None
    (count,) = struct.unpack("<I", raw[4:8])
    values = struct.unpack(f"<{count * 3}f", raw[8:8 + count * 12])
    return RoadIndex([(values[i], values[i + 1], values[i + 2]) for i in range(0, count * 3, 3)])


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


def _road_hint(x: float, y: float, z: float, road: "RoadIndex | None", airborne_ok: bool) -> str:
    """离路太远 / 与路面高差太大 —— 这两条能把「点在楼里/空中」拣出来。"""
    if road is None or airborne_ok:
        return ""
    found = road.nearest(x, y)
    if found is None:
        return "附近 700 m 内没有路面节点"
    dist, road_z = found
    if dist > ROAD_FAR_M:
        return f"离最近路面 {dist:.0f} m —— 确认有路过去"
    dz = z - road_z
    if abs(dz) > ROAD_DZ_M:
        return f"比最近路面{'高' if dz > 0 else '低'} {abs(dz):.0f} m（路面 z={road_z:.0f}）"
    return ""


def _point_issues(x: float, y: float, z: float, airborne_ok: bool,
                  road: "RoadIndex | None" = None) -> tuple[list[str], str]:
    """单点判定：返回（硬错误列表，提示文本）。硬错误 = 玩家一定到不了。"""
    hard: list[str] = []
    if x == 0 and y == 0 and z == 0:
        # (0,0,0) 从来不是真实目标点，就是没填。这类占位点会让 validate_delivery_arrival
        # 要求玩家开到原点（实测在路面下方 70 m），整条任务永远交不掉。
        return ["坐标是占位 (0, 0, 0)"], ""
    if not (WORLD["x"][0] <= x <= WORLD["x"][1] and WORLD["y"][0] <= y <= WORLD["y"][1]):
        hard.append("世界边界外")
    if not (WORLD["z"][0] <= z <= WORLD["z"][1]):
        hard.append(f"z={z:.0f} 越界")
    if hard:
        return hard, ""
    hint = _road_hint(x, y, z, road, airborne_ok)
    if not hint and z > 120 and not airborne_ok:
        hint = "z 偏高 —— 确认在楼顶还是空中"
    return [], hint


def parse_points(block: str) -> list[Point]:
    """从一段模板正文里抽出步骤坐标（step id 作为标签）。"""
    points: list[Point] = []
    step = None
    for line in block.splitlines():
        found = STEP_RE.search(line)
        if found:
            step = found.group(1)
        coords = COORD_RE.search(line)
        if not coords:
            continue
        x, y, z = (float(v) for v in coords.groups())
        points.append(Point(x, y, z, label=(step or "pt").replace("step_", "")))
    return points


def _scan_template(cfg_name: str, name: str, block: str,
                   road: "RoadIndex | None" = None) -> tuple[int, int, int]:
    """扫一个模板：返回（点数、硬错误数、提示数），边扫边打印。"""
    airborne_ok = any(k in name for k in ("aviation", "pilot", "flight", "airlift"))
    errors = hints = 0
    seen: dict[tuple[float, float, float], list[str]] = {}
    step = None
    lines = block.splitlines()
    for line in lines:
        found = STEP_RE.search(line)
        if found:
            step = found.group(1)
        coords = COORD_RE.search(line)
        if not coords:
            continue
        x, y, z = (float(v) for v in coords.groups())
        seen.setdefault((x, y, z), []).append(step or "?")
        hard, hint = _point_issues(x, y, z, airborne_ok, road)
        where = f"{cfg_name:<34} {name:<28} {step or '?':<22} ({x:.0f}, {y:.0f}, {z:.0f})"
        if hard:
            errors += 1
            print(f"  ✗ {where}  " + "；".join(hard))
        elif hint:
            hints += 1
            print(f"  ? {where}  {hint}")
    for coords, steps in seen.items():
        if len(set(steps)) >= 3:
            hints += 1
            print(f"  ? {cfg_name:<34} {name:<28} {len(set(steps))} 个步骤共用同一点 "
                  f"({coords[0]:.0f}, {coords[1]:.0f}, {coords[2]:.0f}) —— 确认不需要移动？")
    return len(lines), errors, hints


def scan_all() -> int:
    """扫全部任务配置，分两档报：硬错误（一定有问题）与提示（需要人看一眼）。"""
    errors = hints = total_templates = total_points = 0
    road = load_road_index()
    if road is None:
        print("  (没有路网缓存：跳过「离路多远 / 高差」两条判据 —— 跑 --build-roads 生成)")
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        text = cfg.read_text(encoding="utf-8", errors="replace")
        for name, block in template_blocks(text).items():
            total_templates += 1
            total_points += len(COORD_RE.findall(block))
            _, hard, soft = _scan_template(cfg.name, name, block, road)
            errors += hard
            hints += soft
    print(f"\n扫描：{total_templates} 个模板 / {total_points} 个坐标点 | 硬错误 {errors} | 提示 {hints}")
    print("硬错误 = 世界边界外或 z 越界（一定有问题）；提示 = 需要人看一眼（楼顶/同一地点多步骤）。")
    return 0 if errors == 0 else 1


def template_block_of(text: str, quest_id: str) -> str | None:
    """按花括号配对截出某个模板的正文（避免把后面的任务也读进来）。"""
    needle = f"id = '{quest_id}'"
    if needle not in text:
        return None
    id_at = text.index(needle)
    open_at = text.rindex("{", 0, id_at)
    depth = 0
    for pos in range(open_at, len(text)):
        ch = text[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:pos + 1]
    return None


def load_quest(quest_id: str) -> tuple[str, list[Point]]:
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        block = template_block_of(cfg.read_text(encoding="utf-8", errors="replace"), quest_id)
        if block is not None:
            return cfg.name, parse_points(block)
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


def points_from_cli(spec: str) -> list[Point]:
    points: list[Point] = []
    for chunk in spec.split(";"):
        parts = [float(v) for v in chunk.split(",")]
        points.append(Point(parts[0], parts[1], parts[2] if len(parts) > 2 else 0.0))
    return points


def resolve_points(args) -> tuple[str, list[Point]]:
    if args.quest:
        return load_quest(args.quest)
    if args.coords:
        return "cli", points_from_cli(args.coords)
    raise SystemExit("要么 --quest / --coords / --scan")


def render_and_report(args) -> int:
    source, points = resolve_points(args)
    if not points:
        raise SystemExit(f"{source} 里没解析到坐标")

    out = Path(args.out) if Path(args.out).is_absolute() else REPO / args.out
    img = render(points, args.style, args.scale, args.margin, out)

    print(f"来源: {source}")
    for i, p in enumerate(points, 1):
        gx, gy = pixel_of(p.x, p.y)
        extra = f"  r={p.radius}m" if p.radius else ""
        print(f"  #{i} {p.label:<14} ({p.x:>9.1f}, {p.y:>9.1f}, {p.z:>6.1f})  "
              f"z5px=({gx:>7.1f}, {gy:>7.1f}){extra}")
    notes = sanity(points)
    if notes:
        print("体检:")
        for note in notes:
            print("  !", note)
    print(f"图: {out}  ({img.width}x{img.height})")
    return 0


# ── 联络图（一次看完所有模板的点位）──────────────────────────────────────────
SHEET_COLS = 4
SHEET_ROWS = 3
SHEET_TILE = 320


def all_templates() -> list[tuple[str, list[Point]]]:
    """把全仓任务模板都解析出来：(模板名, 点列表)。"""
    out: list[tuple[str, list[Point]]] = []
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        text = cfg.read_text(encoding="utf-8", errors="replace")
        for name, block in template_blocks(text).items():
            points = parse_points(block)
            if points:
                out.append((name, points))
    return out


def _sheet_tile(points: list[Point], style: str, name: str, workdir: Path, tile_px: int = SHEET_TILE):
    """渲染单块缩略图（失败不中断整页）。"""
    from PIL import Image, ImageDraw, ImageFont, ImageOps

    tmp = workdir / f"{name}.png"
    try:
        img = render(points, style, 3, 70, tmp)
    except Exception as exc:  # noqa: BLE001 - 单块失败不该毁掉整张联络图
        img = Image.new("RGB", (tile_px, tile_px), (40, 20, 20))
        ImageDraw.Draw(img).text((8, 8), f"render failed: {exc}"[:40], fill=(255, 120, 120))
        return img
    thumb = ImageOps.fit(img, (tile_px, tile_px))
    draw = ImageDraw.Draw(thumb, "RGBA")
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 16)
    except Exception:
        font = ImageFont.load_default()
    draw.rectangle([0, 0, tile_px, 26], fill=(0, 0, 0, 175))
    draw.text((6, 4), name, fill=(255, 255, 255, 255), font=font)
    return thumb


def build_sheets(style: str, out_prefix: Path, only: list[str] | None = None,
                 tile_px: int = SHEET_TILE) -> list[Path]:
    """每页 12 个模板的联络图；返回生成的页文件。"""
    from PIL import Image

    templates = all_templates()
    if only:
        wanted = {n.strip() for n in only}
        templates = [t for t in templates if t[0] in wanted]
        missing = wanted - {t[0] for t in templates}
        if missing:
            print(f"  ! 没找到这些模板：{sorted(missing)}")
    workdir = REPO / ".cache/quest_map/tiles"
    workdir.mkdir(parents=True, exist_ok=True)
    per_page = SHEET_COLS * SHEET_ROWS
    pages: list[Path] = []
    for page_no, start in enumerate(range(0, len(templates), per_page), start=1):
        chunk = templates[start:start + per_page]
        sheet = Image.new("RGB", (SHEET_COLS * tile_px, SHEET_ROWS * tile_px), (12, 12, 14))
        for idx, (name, points) in enumerate(chunk):
            tile = _sheet_tile(points, style, name, workdir, tile_px)
            sheet.paste(tile, ((idx % SHEET_COLS) * tile_px, (idx // SHEET_COLS) * tile_px))
        out = out_prefix.with_name(f"{out_prefix.name}_{page_no:02d}.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out)
        pages.append(out)
        names = ", ".join(n for n, _ in chunk)
        print(f"  第 {page_no} 页（{len(chunk)} 个）：{names}")
    return pages


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="把任务坐标画到 GTA 地图上")
    ap.add_argument("--quest", help="任务模板 id（如 hotdog_vendor）")
    ap.add_argument("--coords", help="直接给坐标：x,y,z 或 x,y,z;x,y,z")
    ap.add_argument("--scan", action="store_true", help="扫全部任务配置，只报可疑坐标")
    ap.add_argument("--build-roads", action="store_true", help="下载并生成路网缓存（约 4 MB，一次性）")
    ap.add_argument("--sheet", action="store_true", help="所有模板渲染成联络图（每页 12 个）")
    ap.add_argument("--only", help="配合 --sheet：只渲染这些模板（逗号分隔）")
    ap.add_argument("--tile", type=int, default=SHEET_TILE, help="联络图每格像素")
    ap.add_argument("--style", default="atlas", choices=sorted(STYLES))
    ap.add_argument("--scale", type=int, default=3, help="放大倍数（瓦片只到 z5，靠放大看清街道）")
    ap.add_argument("--margin", type=int, default=110, help="边距（z5 像素）")
    ap.add_argument("--out", default=".cache/quest_map/out.png")
    return ap


def main() -> int:
    args = build_parser().parse_args()
    if args.sheet:
        only = [s for s in (args.only or "").split(",") if s.strip()]
        pages = build_sheets(args.style, Path(args.out).with_suffix(""), only or None, args.tile)
        print(f"共 {len(pages)} 页")
        return 0
    if args.build_roads:
        count = build_road_cache()
        print(f"路网缓存已生成：{count} 个路面节点 → {ROAD_CACHE}")
        return 0
    if args.scan:
        return scan_all()
    return render_and_report(args)

if __name__ == "__main__":
    raise SystemExit(main())
