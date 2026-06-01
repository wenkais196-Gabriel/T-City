"""
check_dependencies.py — 资源依赖图检查
扫描每个资源的 fxmanifest.lua，提取依赖关系，检查循环依赖和缺失依赖
"""

import os
import sys
import glob
import re

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES_DIR = os.path.join(BASE_DIR, "resources")

# FiveM 内置资源（无需 manifest 文件）
BUILTIN_RESOURCES = {
    "chat", "rconlog", "runcode", "webadmin",
    "sessionmanager", "spawnmanager", "mapmanager",
    "hardcap", "baseevents", "basic-gamemode",
}

# 已知延期资源（已规划但后续版本启用，不在 CFG 中属于正常）
DEFERRED_RESOURCES = {
    "qb-phone", "qb-smallresources", "qb-doorlock", "qb-prison",
    "qb-houses", "qb-bankrobbery", "qb-jewelery", "qb-lapraces",
    "qb-streetraces", "qb-weed", "qb-crypto", "qb-truckrobbery",
    "qb-garbagejob", "qb-hotdogjob", "qb-busjob", "qb-taxijob",
    "qb-newsjob", "qb-diving", "qb-recyclejob", "qb-scrapyard",
    "qb-towjob", "qb-vineyard", "qb-crafting", "qb-cityhall",
    "qb-vehiclesales", "qb-minigames", "qb-radialmenu", "qb-shops",
    "prison_meeting", "prison_main", "prison_canteen",
    "connectqueue", "interact-sound", "safecracker",
    "playernames", "player-data", "ped-money-drops",
    "money", "money-fountain", "money-fountain-example-map",
    "chat-theme-gtao", "fivem-map-skater", "fivem-map-hipster",
    "redm-map-one", "sessionmanager-rdr3", "runcode",
    "example-loadscreen", "fivem", "yarn", "webpack",
    "custom-debug",
    "screenshot-basic", "qb-radio",
}


def parse_manifest(manifest_path: str) -> dict:
    """Extract resource name, dependencies, and server_scripts from a manifest"""
    info = {
        "path": manifest_path,
        "name": os.path.basename(os.path.dirname(manifest_path)),
        "dependencies": [],
        "exports_needed": [],
    }

    with open(manifest_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Extract dependency() declarations
    for match in re.finditer(r'dependency\s*\(\s*["\']([^"\']+)["\']\s*\)', content):
        info["dependencies"].append(match.group(1))

    # Extract @exports references in server_scripts
    for match in re.finditer(r"exports\[?['\"]([^'\"\]]+)['\"]", content):
        info["exports_needed"].append(match.group(1))

    return info


def build_resource_index() -> dict[str, str]:
    """Build {resource_name: manifest_path} mapping"""
    index = {}
    for manifest in glob.glob(os.path.join(RESOURCES_DIR, "**", "fxmanifest.lua"), recursive=True):
        # For nested resources like menuv/menuv_example, use the immediate parent
        name = os.path.basename(os.path.dirname(manifest))
        index[name.lower()] = manifest
    return index


def get_cfg_resource_list() -> set[str]:
    """Get all resources that are ensured in active CFGs"""
    resources = set()
    modules_dir = os.path.join(BASE_DIR, "configs", "modules")
    if not os.path.exists(modules_dir):
        return resources

    for cfg_path in glob.glob(os.path.join(modules_dir, "*.cfg")):
        with open(cfg_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                match = re.match(r"^\s*(ensure|start)\s+(\S+)", line.strip(), re.IGNORECASE)
                if match:
                    resource = re.split(r"[\s#;]", match.group(2))[0]
                    resources.add(resource.lower())
    return resources


def run():
    print("=" * 60)
    print("  资源依赖图检查")
    print("=" * 60)

    resource_index = build_resource_index()
    active_resources = get_cfg_resource_list()

    print(f"\n  代码库中资源总数: {len(resource_index)}")
    print(f"  CFG 中启用的资源: {len(active_resources)}")
    unused = len(resource_index) - len(active_resources & set(resource_index.keys()))
    deferred = len(DEFERRED_RESOURCES & set(resource_index.keys()))
    print(f"  未启用: {unused}（其中 {deferred} 为已知延期资源，不计入问题）")

    issues = []

    # 1. Check enabled resources exist
    for res_name in active_resources:
        if res_name not in resource_index and res_name not in BUILTIN_RESOURCES:
            issues.append({
                "type": "missing_resource",
                "resource": res_name,
                "msg": f"CFG 中启用了 {res_name}，但 resources/ 下未找到对应目录",
            })

    # 2. Parse manifests for active resources
    resource_deps = {}
    for res_name in active_resources:
        if res_name in resource_index:
            info = parse_manifest(resource_index[res_name])
            resource_deps[res_name] = info

    # 3. Check dependencies of active resources
    for res_name, info in resource_deps.items():
        for dep in info["dependencies"]:
            dep_lower = dep.lower()
            if dep_lower not in active_resources and dep_lower not in resource_index:
                issues.append({
                    "type": "missing_dependency",
                    "resource": res_name,
                    "dep": dep,
                    "msg": f"{res_name} 依赖 {dep}，但该资源既不在 CFG 中也不在代码库里",
                })
            elif dep_lower not in active_resources and dep_lower in resource_index:
                issues.append({
                    "type": "inactive_dependency",
                    "resource": res_name,
                    "dep": dep,
                    "msg": f"{res_name} 依赖 {dep}，该资源存在但未在任何 CFG 中启用",
                })

    # 4. Check for orphan resources (exist but not referenced by anything)
    for res_name, manifest_path in resource_index.items():
        if res_name in active_resources:
            continue
        if res_name in BUILTIN_RESOURCES:
            continue
        if res_name in DEFERRED_RESOURCES:
            continue
        # Skip [cfx-default] resources as they're system-level
        if "[cfx-default]" in manifest_path:
            continue
        # Skip sub-resources like menuv_example
        parent_dir = os.path.dirname(os.path.dirname(manifest_path))
        if os.path.exists(os.path.join(parent_dir, "fxmanifest.lua")):
            continue
        issues.append({
            "type": "orphan",
            "resource": res_name,
            "msg": f"{res_name} 存在但未在任何 CFG 中启用",
        })

    # 5. Detect circular dependencies (simple DFS)
    visited = set()
    path = []

    def dfs(node: str) -> bool:
        if node in path:
            cycle_start = path.index(node)
            cycle = path[cycle_start:] + [node]
            issues.append({
                "type": "circular_dep",
                "resource": node,
                "msg": f"循环依赖: {' → '.join(cycle)}",
            })
            return True
        if node in visited or node not in resource_deps:
            return False
        visited.add(node)
        path.append(node)
        for dep in resource_deps[node].get("dependencies", []):
            if dfs(dep.lower()):
                return True
        path.pop()
        return False

    for res_name in resource_deps:
        dfs(res_name)

    # Report
    categories = {
        "missing_resource": ("❌ 资源缺失", []),
        "missing_dependency": ("❌ 依赖缺失", []),
        "inactive_dependency": ("⚠️  依赖未启用", []),
        "orphan": ("💡 孤儿资源", []),
        "circular_dep": ("🔴 循环依赖", []),
    }

    for issue in issues:
        cat = issue["type"]
        if cat in categories:
            categories[cat][1].append(issue)

    has_error = False
    for cat_type, (title, items) in categories.items():
        if items:
            print(f"\n  {title} ({len(items)}):")
            for item in items[:15]:
                print(f"    {item['msg']}")
            if len(items) > 15:
                print(f"    ... 还有 {len(items) - 15} 个")
            if cat_type in ("missing_resource", "missing_dependency", "circular_dep"):
                has_error = True

    if not any(items for _, items in categories.values()):
        print(f"\n  ✅ 依赖图检查通过，无问题")

    print()
    return not has_error


if __name__ == "__main__":
    success = run()
    sys.exit(0 if success else 1)
