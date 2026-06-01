"""
check_cfgs.py — CFG 配置完整性检查
扫描 configs/modules/*.cfg，验证每个 ensure/start 的资源是否存在对应 fxmanifest.lua
"""

import os
import sys
import glob
import re

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES_DIR = os.path.join(BASE_DIR, "configs", "modules")
RESOURCES_DIR = os.path.join(BASE_DIR, "resources")

# FiveM 内置资源（无需 manifest 文件，由服务器二进制提供）
BUILTIN_RESOURCES = {
    "chat", "rconlog", "runcode", "webadmin",
    "sessionmanager", "spawnmanager", "mapmanager",
    "hardcap", "baseevents", "basic-gamemode",
}


def find_resource_manifest(resource_name: str) -> bool:
    """Check if a resource has a valid fxmanifest.lua somewhere under resources/"""
    # Check built-in resources first
    if resource_name.lower() in BUILTIN_RESOURCES:
        return True
    pattern = os.path.join(RESOURCES_DIR, "**", resource_name, "fxmanifest.lua")
    matches = glob.glob(pattern, recursive=True)
    return len(matches) > 0


def scan_cfg_files() -> list[dict]:
    """Scan all module CFGs and return list of {file, line, resource, status}"""
    results = []

    if not os.path.exists(MODULES_DIR):
        print(f"  ERROR: Modules directory not found: {MODULES_DIR}")
        return results

    cfg_files = sorted(glob.glob(os.path.join(MODULES_DIR, "*.cfg")))

    for cfg_path in cfg_files:
        cfg_name = os.path.basename(cfg_path)
        with open(cfg_path, "r", encoding="utf-8", errors="ignore") as f:
            for line_no, line in enumerate(f, 1):
                stripped = line.strip()
                # Skip comments and blank lines
                if not stripped or stripped.startswith("#"):
                    continue
                # Match ensure/start directives
                match = re.match(r"^\s*(ensure|start)\s+(\S+)", stripped, re.IGNORECASE)
                if match:
                    resource = match.group(2)
                    # Strip any trailing comments or inline config
                    resource = re.split(r"[\s#;]", resource)[0]
                    manifest_found = find_resource_manifest(resource)
                    results.append({
                        "cfg": cfg_name,
                        "line": line_no,
                        "directive": match.group(1),
                        "resource": resource,
                        "manifest_found": manifest_found,
                    })

    return results


def run():
    print("=" * 60)
    print("  CFG 配置完整性检查")
    print("=" * 60)

    if not os.path.exists(MODULES_DIR):
        print(f"\n  [ERROR] 模块目录不存在: {MODULES_DIR}")
        print(f"  请确保在项目根目录 (T-CityLite.base) 运行此脚本\n")
        return False

    results = scan_cfg_files()
    total = len(results)
    missing = [r for r in results if not r["manifest_found"]]
    found = [r for r in results if r["manifest_found"]]

    print(f"\n  扫描了 {len(glob.glob(os.path.join(MODULES_DIR, '*.cfg')))} 个 CFG 文件")
    print(f"  共 {total} 个 ensure/start 指令")
    print(f"  ✅ {len(found)} 个资源 manifest 存在")
    print(f"  ❌ {len(missing)} 个资源 manifest 缺失\n")

    if missing:
        print("  ── 缺失清单 ──")
        for r in missing:
            print(f"    {r['cfg']}:{r['line']}  {r['directive']} {r['resource']}  →  MANIFEST NOT FOUND")

    # Also check for duplicate resources across CFGs
    resource_cfg_map = {}
    for r in results:
        name = r["resource"]
        if name not in resource_cfg_map:
            resource_cfg_map[name] = []
        resource_cfg_map[name].append(r["cfg"])

    duplicates = {k: v for k, v in resource_cfg_map.items() if len(v) > 1}
    if duplicates:
        print(f"\n  ⚠️  发现 {len(duplicates)} 个资源在多个 CFG 中被 ensure（可能重复加载）：")
        for res, cfgs in sorted(duplicates.items()):
            print(f"    {res}: {', '.join(cfgs)}")

    print()
    return len(missing) == 0


if __name__ == "__main__":
    success = run()
    sys.exit(0 if success else 1)
