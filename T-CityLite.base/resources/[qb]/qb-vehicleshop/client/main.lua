-- main.lua — qb-vehicleshop 客户端入口 (v2.2.0)
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 架构:
--   util.lua      — 共享工具 + 全局状态 + 玩家生命周期
--   zones.lua     — 区域管理 + 展示车辆 + Blip
--   menus.lua     — qb-menu / qb-input 菜单逻辑
--   testdrive.lua — 试驾逻辑
--   nui.lua       — NUI 回调 + 焦点管理
--
-- 向后兼容: 所有事件名未变, qb-menu 作为默认交互方式
-- NUI 模式: Config.UseNui = true 时启用 (Phase 3 开关)

local QBCore = exports['qb-core']:GetCoreObject()

print('^2[qb-vehicleshop] ^7🏪 车店客户端已启动 v2.2.0')
print('^2[qb-vehicleshop] ^7  模块: util.lua | zones.lua | menus.lua | testdrive.lua | nui.lua')
local useNui = Config and Config.UseNui
print('^2[qb-vehicleshop] ^7  交互: ' .. (useNui and 'NUI' or 'qb-menu'))
