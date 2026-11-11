-- client/main.lua — 统一交互提示（custom-prompt）
--
-- 现状（2026-11-10 扫描）：12 个资源用 `DrawText`（屏幕左中一条），21 个资源用 qb-target
-- 的 ALT 选项卡 —— 两套视觉、两套按键，玩家永远猜不到当前能按什么。
-- PO 拍板（D2=甲）：**E = 上下文动作**（身边单个、唯一入口），**ALT = 世界物件列表**。
--
-- 这个资源只负责"画"，不负责"判定谁能按什么"：
--   exports['custom-prompt']:Show({ key='E', label='打开商店', hold=0 })
--   exports['custom-prompt']:Hide()
--   exports['custom-prompt']:SetContext({ { key='E', label='搜身' }, { key='G', label='呼叫验尸官' } })
--   exports['custom-prompt']:ClearContext()
--
-- 判定（距离、职业、状态）永远在各自资源里做，这里只显示。

local contextEntries = {}

--- 主提示（准星下方，单条）
---@param opts table|nil { key: string, label: string, hold: number|nil }
local function Show(opts)
    opts = opts or {}
    local label = tostring(opts.label or '')
    if label == '' then
        SendNUIMessage({ action = 'prompt', main = false })
        return
    end
    SendNUIMessage({
        action = 'prompt',
        main = {
            key = tostring(opts.key or 'E'):sub(1, 12),
            label = label:sub(1, 64),
            hold = tonumber(opts.hold) or 0,
        },
    })
end

local function Hide()
    SendNUIMessage({ action = 'prompt', main = false })
end

--- 右侧上下文列表（≤3 条）
---@param entries table 数组：{ { key, label }, ... }
local function SetContext(entries)
    contextEntries = {}
    if type(entries) == 'table' then
        for index = 1, math.min(#entries, 3) do
            local entry = entries[index]
            if type(entry) == 'table' and entry.label then
                contextEntries[#contextEntries + 1] = {
                    key = tostring(entry.key or 'E'):sub(1, 12),
                    label = tostring(entry.label):sub(1, 48),
                }
            end
        end
    end
    SendNUIMessage({ action = 'prompt', list = contextEntries })
end

local function ClearContext()
    contextEntries = {}
    SendNUIMessage({ action = 'prompt', list = {} })
end

exports('Show', Show)
exports('Hide', Hide)
exports('SetContext', SetContext)
exports('ClearContext', ClearContext)

-- 开发自检：/prompttest（convar prompt_dev=1 才可用）
RegisterCommand('prompttest', function()
    if GetConvar('prompt_dev', '0') ~= '1' then
        print('[custom-prompt] /prompttest 已关闭（setr prompt_dev 1 打开）')
        return
    end
    Show({ key = 'E', label = '打开商店' })
    SetContext({
        { key = 'E', label = '搜身' },
        { key = 'G', label = '呼叫验尸官' },
        { key = 'Q', label = '放置标记' },
    })
    CreateThread(function()
        Wait(8000)
        Hide()
        ClearContext()
    end)
end, false)

print('[custom-prompt] 交互提示已就绪（exports: Show / Hide / SetContext / ClearContext）')
