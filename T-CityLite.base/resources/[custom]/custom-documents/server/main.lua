-- ============================================================
-- Server Authority Layer
-- 文档出示授权 · 查验证照 · 序列号校验
-- ============================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ─────────────────────────────────────────────
-- 工具：从物品 info 中解析展示文本模板
-- ─────────────────────────────────────────────
local function expandTemplate(template, info, playerName)
    local result = template
    if playerName then
        -- playerName = firstname lastname
        local parts = {}
        for part in string.gmatch(playerName, '%S+') do
            parts[#parts + 1] = part
        end
        result = result:gsub('{firstname}', parts[1] or 'Unknown')
        result = result:gsub('{lastname}', parts[2] or '')
    end
    for _, field in ipairs(info.fields or {}) do
        local val = info.data[field]
        if val ~= nil then
            result = result:gsub('{' .. field .. '}', tostring(val))
        end
    end
    return result
end

-- ─────────────────────────────────────────────
-- 格式化 info 字段用于3D文字展示
-- ─────────────────────────────────────────────
local function formatFieldsForDisplay(docConfig, itemInfoRaw)
    if not docConfig or not docConfig.fields then return '' end
    local parts = {}
    for _, f in ipairs(docConfig.fields) do
        local val = itemInfoRaw[f]
        if val ~= nil then
            local displayVal
            if f == 'gender' then
                displayVal = (tonumber(val) == 0) and 'Male' or 'Female'
            else
                displayVal = tostring(val)
            end
            parts[#parts + 1] = ('%s: %s'):format(f, displayVal)
        end
    end
    return table.concat(parts, ' | ')
end

-- ─────────────────────────────────────────────
-- 事件: 出示文档
-- 由 qb-inventory use 分支调用
-- ─────────────────────────────────────────────
RegisterNetEvent('custom-documents:server:presentDocument', function(itemName, slot)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local docConfig = Config.Documents[itemName]
    if not docConfig then
        print('[custom-documents] Unknown document type requested: ' .. tostring(itemName))
        return
    end

    -- ── 从背包获取物品 (直接遍历 items 表，避免 AddPlayerMethod 时序问题) ──
    local itemData = nil
    local pItems = Player.PlayerData.items
    if slot and pItems[slot] and pItems[slot].name == itemName then
        itemData = pItems[slot]
    else
        -- 回退：按名称搜索
        for _, v in pairs(pItems or {}) do
            if v.name == itemName then
                itemData = v
                break
            end
        end
    end
    if not itemData then
        TriggerClientEvent('QBCore:Notify', src, _L(src, 'doc_no_cert'), 'error')
        return
    end

    local itemInfo = itemData.info or {}

    -- ── 安全校验：序列号与持有者绑定 ──
    if itemInfo.serial then
        local cid = Player.PlayerData.citizenid
        if cid and not tostring(itemInfo.serial):find(tostring(cid), 1, true) then
            TriggerClientEvent('QBCore:Notify', src, _L(src, 'doc_serial_mismatch'), 'error')
            return
        end
    end

    -- ── 装配展示数据 ──
    local charName = Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
    local displayText = ('📋 [%s] %s'):format(docConfig.label, charName)
    local fieldsText = formatFieldsForDisplay(docConfig, itemInfo)

    -- ── 附近提示模板 ──
    local nearbyText = expandTemplate(
        docConfig.presentText or '{firstname} {lastname} 出示了证件',
        { fields = docConfig.fields, data = itemInfo },
        charName
    )

    -- ── 推送给出示者客户端 ──
    TriggerClientEvent('custom-documents:client:showDocument', src, {
        docType = itemName,
        label = docConfig.label,
        displayText = displayText,
        fieldsText = fieldsText,
        nearbyText = nearbyText,
        radius = Config.NotifyNearbyRadius,
        duration = Config.PresentDuration,
    })
    print(('[custom-documents] %s presented %s'):format(charName, itemName))

    -- ── 通知附近玩家（Notify + 头顶 3D 文字）──
    if Config.NotifyNearbyEnabled then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local allPlayers = QBCore.Functions.GetPlayers()
        for _, pid in ipairs(allPlayers) do
            if tonumber(pid) ~= tonumber(src) then
                local targetPed = GetPlayerPed(pid)
                local dist = #(playerCoords - GetEntityCoords(targetPed))
                if dist < Config.NotifyNearbyRadius then
                    TriggerClientEvent('QBCore:Notify', pid, nearbyText, 'primary', 3000)
                    TriggerClientEvent('custom-documents:client:showNearbyDocument', pid, {
                        presenterId = tonumber(src),
                        displayText = displayText,
                        duration = Config.PresentDuration,
                    })
                end
            end
        end
    end
end)

-- ─────────────────────────────────────────────
-- 回调: 警察查验玩家所有证照
-- ─────────────────────────────────────────────
QBCore.Functions.CreateCallback('custom-documents:server:verifyPlayer', function(source, cb, targetSrc)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb(nil) return end

    -- ── 权限检查 ──
    local job = Player.PlayerData.job.name
    local grade = Player.PlayerData.job.grade.level
    local allowed = false
    for jName, minGrade in pairs(Config.PoliceJobs) do
        if job == jName and grade >= minGrade then
            allowed = true
            break
        end
    end
    if not allowed then
        cb({ error = '你不是执法人员，无权查验证照' })
        return
    end

    if not Player.PlayerData.job.onduty then
        cb({ error = '你必须值勤才能查验证照' })
        return
    end

    -- ── 获取目标玩家数据 ──
    local Target = QBCore.Functions.GetPlayer(tonumber(targetSrc))
    if not Target then
        cb({ error = '目标玩家不在线' })
        return
    end

    local licences = Target.PlayerData.metadata.licences or {}
    local certStatus = Target.PlayerData.metadata.cert_status or {}
    local targetName = Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname
    local targetCitizenId = Target.PlayerData.citizenid

    -- ── 装配结果 ──
    local results = {}
    for _, certKey in ipairs({ 'driver', 'weapon', 'pilot', 'boat', 'heavy', 'business' }) do
        local label = Config.CertLabelMap[certKey] or certKey
        local hasLicence = licences[certKey] or false
        local status = certStatus[certKey] or 'unclaimed'
        local statusLabel = Config.CertStatusLabels[status] or status
        results[#results + 1] = {
            key = certKey,
            label = label,
            hasLicence = hasLicence,
            status = status,
            statusLabel = statusLabel,
        }
    end

    cb({
        success = true,
        targetName = targetName,
        targetCitizenId = targetCitizenId,
        licenses = results,
    })
end)

-- ─────────────────────────────────────────────
-- 导出: 验证单份文档序列号真伪
-- @param serial string  序列号
-- @return table { valid:bool, type:string, citizenid:string, issuedAt:string }
-- ─────────────────────────────────────────────
local function VerifyDocument(serial)
    if not serial then
        return { valid = false, reason = 'no serial' }
    end
    -- 解析 cert-{type}-{citizenid} 格式
    local docType, citizenid = serial:match('^cert%-(.+)%-(.+)$')
    if not docType or not citizenid then
        return { valid = false, reason = 'invalid format' }
    end
    -- 查找在线玩家是否有匹配的 citizenid
    local players = QBCore.Functions.GetPlayers()
    for _, pid in ipairs(players) do
        local ply = QBCore.Functions.GetPlayer(pid)
        if ply and ply.PlayerData.citizenid == citizenid then
            local status = (ply.PlayerData.metadata.cert_status or {})[docType]
            return {
                valid = true,
                type = docType,
                citizenid = citizenid,
                status = status or 'unknown',
            }
        end
    end
    return { valid = false, reason = 'owner offline' }
end
exports('VerifyDocument', VerifyDocument)

-- ─────────────────────────────────────────────
-- 导出: 获取所有注册的文档类型列表
-- ─────────────────────────────────────────────
local function GetDocumentRegistry()
    local list = {}
    for name, doc in pairs(Config.Documents) do
        list[#list + 1] = { name = name, label = doc.label, icon = doc.icon }
    end
    return list
end
exports('GetDocumentRegistry', GetDocumentRegistry)
