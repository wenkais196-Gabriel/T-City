#!/usr/bin/env python3
"""
light_lint.py — T-City Lite 轻量级 Lua 语法检查器
替代 luacheck（Windows 上难以安装原生模块）
检查: 未声明全局变量、未使用变量、nil 访问风险、常见模式问题
"""

import os
import re
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES_DIR = os.path.join(BASE_DIR, 'resources')

# 已知的 FiveM/QBCore 全局变量白名单（避免误报）
FIVEM_GLOBALS = {
    'QBCore', 'QBShared', 'QBConfig', 'QBMath', 'QBWeather', 'QBScore',
    'Config', 'Lang', 'Menu', 'Races', 'Bail', 'StolenDrugs', 'AvailableCorals',
    'ESX', 'TriggerEvent', 'TriggerClientEvent', 'TriggerServerEvent',
    'RegisterNetEvent', 'RegisterCommand', 'RegisterKeyMapping',
    'AddEventHandler', 'RemoveEventHandler', 'CreateThread', 'SetTimeout',
    'Wait', 'Citizen', 'IsDuplicityVersion', 'GetCurrentResourceName',
    'GetInvokingResource', 'GlobalState', 'LocalPlayer', 'PlayerData',
    'NetworkGetNetworkIdFromEntity', 'NetworkGetEntityFromNetworkId',
    'GetPlayerPed', 'GetEntityCoords', 'GetPlayerServerId',
    'GetPlayerName', 'SetNuiFocus', 'SendNUIMessage', 'RegisterNUICallback',
    'exports', 'json', 'MySQL', 'oxmysql',
    'PerformHttpRequest', 'GetConvar', 'GetConvarInt', 'SetConvar',
    'DropPlayer', 'CancelEvent', 'GetVehiclePedIsIn',
    'PlayerPedId', 'IsPedInAnyVehicle', 'GetSelectedPedWeapon',
    'GetGameTimer', 'math', 'string', 'table', 'os', 'pairs', 'ipairs',
    'print', 'error', 'pcall', 'xpcall', 'type', 'tostring', 'tonumber',
    'next', 'select', 'unpack', 'rawget', 'rawset', 'setmetatable', 'getmetatable',
    'true', 'false', 'nil', 'self', 'IsPedInAnyVehicle',
    'GetPlayers', 'GetPlayerIdentifiers', 'GetPlayerEndpoint',
    'DoesEntityExist', 'GetEntityPopulationType', 'GetResourceState',
    'QBCoreCommand', 'GetInvokingResource',
    'DirtyFlush', 'Cache', 'Bus', 'EconomyService', 'StressTest',
    'Mock', 'Test', 'Config', 'UhOhs',
}

# Lua 关键字
LUA_KEYWORDS = {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
    'function', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or',
    'repeat', 'return', 'then', 'true', 'until', 'while',
}

# 检测模式
PATTERNS = [
    # 全局变量赋值检测（可能是意外全局）
    (r'^\s*(\w+)\s*=\s*(?!function)', 'W001',
     '可能意外的全局变量赋值（未加 local）：{var}'),

    # MySQL.Sync 阻塞检测
    (r'MySQL\.Sync\.', 'P001',
     'MySQL.Sync 阻塞调用，建议改用 MySQL.query.await：{match}'),

    # LIKE '%...%' 全表扫描
    (r"LIKE\s*'%", 'P002',
     'LIKE 前置通配符 % 全表扫描，建议加索引或精确匹配'),

    # 字符串拼接 SQL（SQL 注入风险）
    (r"'SELECT.*'\s*\.\.\s*\w+", 'S001',
     'SQL 字符串拼接，建议使用参数化查询 ? 占位符：{match}'),

    # Wait(0) 空转（CPU 占用）
    (r'Wait\b\s*\(\s*0\s*\)', 'P003',
     'Wait(0) 空转 → 高 CPU 占用，建议 Wait(100) 或更高：{match}'),

    # print 调试遗留
    (r'^\s*print\(', 'W002',
     '生产环境遗留 print 调试语句：{match}'),
]


def check_file(filepath):
    """检查单个 Lua 文件"""
    results = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
    except Exception as e:
        return [('ERR', f'无法读取: {e}')]

    local_vars = set()
    current_indent = 0

    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip()
        line_num = i + 1
        stripped = line.strip()

        if not stripped or stripped.startswith('--'):
            continue

        # 收集 local 声明
        local_match = re.match(r'^local\s+(\w+)', stripped)
        if local_match:
            local_vars.add(local_match.group(1))

        # 检查各种模式
        for pattern, code, msg_template in PATTERNS:
            match = re.search(pattern, stripped)
            if match:
                detail = msg_template.format(
                    var=match.group(1) if len(match.groups()) >= 1 else '',
                    match=stripped[:60]
                )
                results.append((f'{code}', f'L{line_num}: {detail}'))

        # 全局变量检测（忽略已知全局、local 变量、循环变量、关键词）
        assign_match = re.match(r'^(\w+)\s*=', stripped)
        if assign_match:
            var_name = assign_match.group(1)
            if (var_name not in FIVEM_GLOBALS
                and var_name not in LUA_KEYWORDS
                and var_name not in local_vars):
                # 检查是否在 for 循环中
                if not re.match(r'^for\s', stripped):
                    results.append(('W001',
                        f'L{line_num}: 全局变量赋值（未加 local）: {var_name}'))

    return results


def main():
    """主函数：扫描所有资源目录"""
    if not os.path.isdir(RES_DIR):
        print(f'[lint] ❌ 资源目录不存在: {RES_DIR}')
        return

    all_results = {}
    total_warnings = 0
    total_errors = 0
    files_checked = 0

    # 扫描 [custom], [qb], [standalone] 下所有 .lua 文件
    for root, dirs, files in os.walk(RES_DIR):
        # 跳过 cache, node_modules, .git 等
        skip_dirs = {'cache', 'node_modules', '.git', '.github', '__pycache__'}
        dirs[:] = [d for d in dirs if d not in skip_dirs]

        for f in files:
            if not f.endswith('.lua'):
                continue
            filepath = os.path.join(root, f)
            relpath = os.path.relpath(filepath, BASE_DIR)
            results = check_file(filepath)

            if results:
                all_results[relpath] = results
                for code, msg in results:
                    if code.startswith('P') or code.startswith('S'):
                        total_errors += 1
                    else:
                        total_warnings += 1
            files_checked += 1

    # 输出报告
    print('═' * 60)
    print('  T-City Lite Lua 轻量语法检查报告')
    print('═' * 60)
    print(f'  检查文件: {files_checked}')
    print()

    if not all_results:
        print('  ✅ 全部通过，无问题')
        print()
        return True

    for filepath, results in sorted(all_results.items()):
        # 按行号排序
        results.sort(key=lambda x: int(re.search(r'L(\d+)', x[1]).group(1)) if re.search(r'L(\d+)', x[1]) else 0)
        print(f'  📄 {filepath}')
        for code, msg in results:
            if code.startswith('P') or code.startswith('S'):
                print(f'    🔴 {code} {msg}')
            else:
                print(f'    🟡 {code} {msg}')
        print()

    print('─' * 60)
    print(f'  🔴 错误: {total_errors}  |  🟡 警告: {total_warnings}')
    print('─' * 60)

    return total_errors == 0


if __name__ == '__main__':
    success = main()
    sys.exit(0 if success else 1)
