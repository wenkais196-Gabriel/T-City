"""
check_bus_wiring.py — Bus 接线检查

背景:
  FiveM 每个 resource 是独立 Lua state，`_G.Bus` 不跨资源。
  core-framework 的 Bus.RegisterService(name, methods) 会通过
  exports('service_<name>_<method>', fn) 把服务导出到**当前资源**。

  因此：任何调用 Bus.RegisterService 的资源，都必须在自己的
  fxmanifest 里 include `@core-framework/bus.lua`（server_scripts），
  否则 Bus 为 nil，服务从未注册（静默失效）。

本脚本检查:
  1. [ERROR] 使用 Bus.RegisterService 但 manifest 未 include bus.lua
  2. [WARN]  仍在使用 Bus.<PascalCase> 服务名（跨资源不可见，应改为 export）
"""

import os
import re
import sys
from pathlib import Path

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES_DIR = os.path.join(BASE_DIR, "resources")

# Bus 自身的 API，不是服务名
BUS_API = {
    "RegisterService", "GetService", "SafeCall", "Plugin",
    "_services", "Status",
}

PASCAL_SERVICE_RE = re.compile(
    r"\bBus\.(EconomyService|JobService|SecurityService|StorageService|"
    r"MarketService|CartelService|MetadataService|PersistenceManager|"
    r"NotifyService|WorldStateService|PatronService)\b"
)


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def strip_comments(text: str) -> str:
    """粗粒度去掉 Lua 注释，避免把文档里的示例当成真实调用。"""
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def find_manifests() -> list[Path]:
    # 注意：不能用 glob，资源目录名含 []（如 [standalone]），会被当成字符类
    return sorted(Path(RESOURCES_DIR).rglob("fxmanifest.lua"))


def server_lua_files(resource_dir: Path) -> list[Path]:
    files = []
    for path in resource_dir.rglob("*.lua"):
        rel = path.relative_to(resource_dir).as_posix()
        if rel.startswith("client/") or "/client/" in rel:
            continue
        files.append(path)
    return files


def main() -> int:
    print("=" * 60)
    print("  Bus 接线检查")
    print("=" * 60)

    errors = []
    warnings = []

    for manifest in find_manifests():
        resource_dir = manifest.parent
        resource = resource_dir.name
        if resource == "core-framework":
            continue

        manifest_text = read(str(manifest))
        includes_bus = "@core-framework/bus.lua" in manifest_text
        # 自建 Bus（如 qb-vehicleshop 的 dealership bus）不需要 core-framework 的 Bus
        has_own_bus = (not includes_bus) and ("bus.lua" in manifest_text)

        uses_register = False
        uses_pascal = []

        for lua_file in server_lua_files(resource_dir):
            text = strip_comments(read(str(lua_file)))
            if "Bus.RegisterService(" in text:
                uses_register = True
            for match in PASCAL_SERVICE_RE.finditer(text):
                line_no = text[: match.start()].count("\n") + 1
                uses_pascal.append(f"{lua_file.relative_to(Path(BASE_DIR)).as_posix()}:{line_no} -> Bus.{match.group(1)}")

        if uses_register and not includes_bus and not has_own_bus:
            errors.append(
                f"{resource}: 使用 Bus.RegisterService，但 fxmanifest 未 include @core-framework/bus.lua"
            )

        if uses_pascal and resource != "qb-core":
            warnings.append((resource, uses_pascal))

    if errors:
        print(f"\n  ❌ 注册未接线 ({len(errors)}):")
        for e in errors:
            print(f"    {e}")

    if warnings:
        print(f"\n  ⚠️  仍在使用跨资源不可见的 Bus.<PascalCase> ({len(warnings)} 个资源):")
        for resource, items in warnings:
            print(f"    {resource}:")
            for item in items[:6]:
                print(f"      {item}")
            if len(items) > 6:
                print(f"      ... 还有 {len(items) - 6} 处")

    if not errors and not warnings:
        print("\n  ✅ Bus 接线检查通过")

    print()
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
