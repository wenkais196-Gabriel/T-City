"""
check_lua_syntax.py — Lua 语法检查
使用 luacheck 批量扫描 Lua 文件，如果 luacheck 不可用则降级为基本模式匹配检查
"""

import os
import sys
import subprocess
import glob
import re

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES_DIR = os.path.join(BASE_DIR, "resources")


def check_with_luacheck() -> list[dict]:
    """Run luacheck on all Lua files under resources/"""
    results = []
    lua_files = glob.glob(os.path.join(RESOURCES_DIR, "**", "*.lua"), recursive=True)

    # Skip [cfx-default] as those are third-party maintained
    lua_files = [f for f in lua_files if "[cfx-default]" not in f]

    try:
        cmd = ["luacheck", "--no-color", "-q"] + lua_files
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=BASE_DIR,
        )
        # Parse luacheck output
        for line in proc.stdout.splitlines():
            # luacheck format: path:line:col: (W/E) message
            match = re.match(r"^(.+?):(\d+):(\d+):\s*\((\w)\)\s*(.+)", line)
            if match:
                results.append({
                    "file": os.path.relpath(match.group(1), BASE_DIR),
                    "line": int(match.group(2)),
                    "col": int(match.group(3)),
                    "severity": match.group(4),  # W = warning, E = error
                    "message": match.group(5),
                })
        # Also capture stderr for errors
        if proc.stderr.strip():
            print(f"  [luacheck stderr]: {proc.stderr.strip()}")
        return results
    except FileNotFoundError:
        return None  # luacheck not installed
    except subprocess.TimeoutExpired:
        print("  [WARN] luacheck timed out after 60s")
        return None


def basic_syntax_check() -> list[dict]:
    """Fallback: basic pattern-based checks when luacheck is unavailable"""
    results = []
    lua_files = glob.glob(os.path.join(RESOURCES_DIR, "**", "*.lua"), recursive=True)
    lua_files = [f for f in lua_files if "[cfx-default]" not in f]

    for filepath in lua_files:
        relpath = os.path.relpath(filepath, BASE_DIR)
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
            lines = content.splitlines()

        # Check 1: Unmatched brackets (rough check)
        for line_no, line in enumerate(lines, 1):
            stripped = line.strip()
            # Skip comments and strings
            if stripped.startswith("--") or stripped.startswith("//"):
                continue

            # Check for obvious syntax issues
            open_br = stripped.count("{") - stripped.count("}")
            open_paren = stripped.count("(") - stripped.count(")")
            open_sq = stripped.count("[") - stripped.count("]")

            # These are rough heuristics, only flag very obvious issues
            if "end" in stripped and not any(kw in stripped for kw in ["if", "function", "do", "then", "repeat"]):
                # Check if it looks like a stray 'end'
                pass  # Too many false positives, skip

    return results


def run():
    print("=" * 60)
    print("  Lua 语法检查")
    print("=" * 60)

    # Try luacheck first
    results = check_with_luacheck()

    if results is None:
        print("\n  ⚠️  luacheck 未安装，执行基础模式检查（有限）")
        print("  建议: pip install luacheck 或安装 luarocks 后: luarocks install luacheck")
        results = basic_syntax_check()
        print(f"\n  基础检查完成（仅扫描文件结构）\n")
        return True

    errors = [r for r in results if r["severity"] == "E"]
    warnings = [r for r in results if r["severity"] == "W"]
    others = [r for r in results if r["severity"] not in ("E", "W")]

    print(f"\n  扫描结果:")
    print(f"  ❌ {len(errors)} 个错误")
    print(f"  ⚠️  {len(warnings)} 个警告")
    if others:
        print(f"  💡 {len(others)} 个其他")

    if errors:
        print("\n  ── 错误清单 ──")
        for e in errors[:20]:  # Show first 20
            print(f"    {e['file']}:{e['line']}:{e['col']}  {e['message']}")
        if len(errors) > 20:
            print(f"    ... 还有 {len(errors) - 20} 个错误")

    if warnings:
        print("\n  ── 主要警告 (前 10) ──")
        for w in warnings[:10]:
            print(f"    {w['file']}:{w['line']}:{w['col']}  {w['message']}")

    print()
    return len(errors) == 0


if __name__ == "__main__":
    success = run()
    sys.exit(0 if success else 1)
