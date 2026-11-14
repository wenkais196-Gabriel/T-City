#!/usr/bin/env python3
"""从路网缓存里切出一块「摆摊判据」用的路面节点，生成 custom-quest 的 Lua 配置。

为什么要有这个工具：
    摊位的「挡在车道上」这条拒绝理由是**服务端权威**判据 —— 客户端说「我没挡路」
    不能信（客户端可以撒谎）。但服务端拿不到 `IsPointOnRoad`（那是客户端 native），
    所以把热狗摊位可能出现的区域（Legion Square 一带）的路面节点**离线**切出来，
    随资源一起加载，服务端只做一次最近点比较。

    数据源就是 `tools/dev/quest_map.py --build-roads` 产出的 `.cache/roads/road_points.bin`
    （地面车辆节点，已剔除水面）。换城市/换摊位区时改 `--center/--radius` 重跑。

用法：
    python tools/dev/booth_roads.py                       # 生成（默认 Legion Square 350 m）
    python tools/dev/booth_roads.py --center 215,-810 --radius 300
    python tools/dev/booth_roads.py --check               # 只校验现有产物是否过期
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ROAD_CACHE = REPO / ".cache/roads/road_points.bin"
OUT = REPO / "T-CityLite.base/resources/[custom]/custom-quest/config/quests/hotdog_roads.json"

MAGIC = b"RDP1"


def load_points() -> list[tuple[float, float, float]]:
    if not ROAD_CACHE.exists():
        sys.exit(f"缺路网缓存：{ROAD_CACHE}\n先跑 python tools/dev/quest_map.py --build-roads")
    raw = ROAD_CACHE.read_bytes()
    if raw[:4] != MAGIC:
        sys.exit(f"路网缓存格式不认识：magic={raw[:4]!r}（期望 {MAGIC!r}）")
    count = struct.unpack("<I", raw[4:8])[0]
    if len(raw) != 8 + count * 12:
        sys.exit(f"路网缓存长度不一致：{len(raw)} != {8 + count * 12}")
    return [struct.unpack_from("<fff", raw, 8 + i * 12) for i in range(count)]


def slice_points(
    points: list[tuple[float, float, float]], center: tuple[float, float], radius: float
) -> list[tuple[float, float]]:
    cx, cy = center
    r2 = radius * radius
    out = []
    for x, y, _z in points:
        if (x - cx) ** 2 + (y - cy) ** 2 <= r2:
            out.append((round(x, 1), round(y, 1)))
    # 只保留 (x, y)：判「是否压在路面上」不需要高度，省一半体积
    out.sort(key=lambda p: (p[0], p[1]))
    return out


def render(pts: list[tuple[float, float]], center: tuple[float, float], radius: float) -> str:
    """写成 JSON 而不是生成 Lua。

    两条理由：
      1. 生成物是**数据**，不是代码 —— 让服务端 `load()` 一段从磁盘读出来的字符串，
         等于给自己开一个「文件被替换就执行任意代码」的口子（Sonar 的安全闸也会拦）。
      2. `json.decode` 是 FiveM 现成的，比 `load` 少一层错误处理。
    """
    payload = {
        "center": {"x": center[0], "y": center[1]},
        "radius": radius,
        "points": [round(v, 1) for point in pts for v in point],
        "source": ".cache/roads/road_points.bin",
        "generator": "tools/dev/booth_roads.py",
    }
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--center", default="215,-810", help="切片中心 x,y")
    ap.add_argument("--radius", type=float, default=350.0)
    ap.add_argument("--check", action="store_true", help="只比对现有产物是否与缓存一致")
    args = ap.parse_args()

    # 先判缓存：load_points() 里是 sys.exit(1)（"缺数据"是一种**错误**），
    # 但 --check 面对"数据不在"只能是"无法判定"，必须在加载前分流。
    if args.check and not ROAD_CACHE.exists():
        print(f"[check] SKIP 缺路网缓存：{ROAD_CACHE}")
        return 2

    cx, cy = (float(v) for v in args.center.split(","))
    pts = slice_points(load_points(), (cx, cy), args.radius)
    text = render(pts, (cx, cy), args.radius)
    new_hash = hashlib.sha256(text.encode()).hexdigest()

    if args.check:
        if not ROAD_CACHE.exists():
            # 缓存是 gitignored 的（.cache/），CI 里没有它。这时「产物过期」这件事
            # **无法判定** —— 返回 2 让调用方跳过，而不是把「没数据」说成「不一致」。
            print(f"[check] SKIP 缺路网缓存：{ROAD_CACHE}")
            return 2
        if not OUT.exists():
            print(f"[check] 缺产物：{OUT}")
            return 1
        old = hashlib.sha256(OUT.read_text(encoding="utf-8").encode()).hexdigest()
        if old != new_hash:
            print("[check] 产物与路网缓存不一致 —— 需要重跑 tools/dev/booth_roads.py")
            return 1
        print(f"[check] OK 节点 {len(pts)} 个")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"[write] {OUT.relative_to(REPO)} 节点 {len(pts)} 个，{len(text)} 字节")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
