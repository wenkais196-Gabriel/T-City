#!/usr/bin/env python3
"""
run_all.py — T-City Lite 离线检测一键执行入口
依次运行：CFG完整性 → Lua语法 → 数据库表结构 → 依赖图
"""

import os
import sys
import subprocess
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Test modules: (name, file, critical)
TESTS = [
    ("CFG 配置完整性", "check_cfgs.py", True),
    ("Lua 语法检查", "check_lua_syntax.py", False),
    ("数据库表结构", "check_db_schema.py", False),
    ("资源依赖图", "check_dependencies.py", True),
]


def print_banner():
    print()
    print("╔══════════════════════════════════════════════════════╗")
    print("║       T-City Lite 离线检测套件                      ║")
    print("║       Automated Offline Test Suite                  ║")
    print("╚══════════════════════════════════════════════════════╝")
    print()


def run_test(name: str, script: str, critical: bool) -> tuple[bool, float]:
    """Run a single test script and return (passed, duration_seconds)"""
    script_path = os.path.join(BASE_DIR, script)
    if not os.path.exists(script_path):
        print(f"\n  [SKIP] {script} 不存在，跳过")
        return True, 0

    start = time.time()
    result = subprocess.run(
        [sys.executable, script_path],
        capture_output=False,
        cwd=BASE_DIR,
    )
    duration = time.time() - start
    passed = result.returncode == 0
    return passed, duration


def main():
    print_banner()
    print(f"  项目目录: {os.path.dirname(BASE_DIR)}")
    print(f"  开始时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  测试模块: {len(TESTS)} 个")
    print()

    results = []
    total_start = time.time()

    for name, script, critical in TESTS:
        print(f"──[{name}]──")
        passed, duration = run_test(name, script, critical)
        results.append((name, passed, critical, duration))
        print()

    total_duration = time.time() - total_start

    # Summary
    print("═" * 60)
    print("  测试报告摘要")
    print("═" * 60)
    print()

    passed_count = sum(1 for _, p, _, _ in results if p)
    failed_count = sum(1 for _, p, _, _ in results if not p)
    critical_failures = [n for n, p, c, _ in results if not p and c]

    for name, passed, critical, duration in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        tag = " [CRITICAL]" if critical else ""
        print(f"  {status}{tag}  {name}  ({duration:.1f}s)")

    print()
    print(f"  总计: {passed_count}/{len(TESTS)} 通过, {failed_count} 失败")
    print(f"  耗时: {total_duration:.1f}s")
    print()

    if critical_failures:
        print(f"  🔴 关键失败: {', '.join(critical_failures)}")
        print(f"  请修复后再继续开发")
        print()
        return False
    elif failed_count > 0:
        print(f"  ⚠️  有非关键失败，建议查看详情")
        print()
        return True
    else:
        print(f"  ✅ 全部通过！")
        print()
        return True


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
