-- client/entity_util.lua — 几个 NPC 服务共用的实体小工具。
--
-- 出现原因：验尸官与拖车各自抄了一份 `loadModel` / `deleteEntity`，
-- 重复实现预算（REUSE-01）当场就红了。合并到这里，两边只留一行别名。

EntityUtil = EntityUtil or {}

--- 加载模型（带超时），失败返回 false。
---@param hash number
---@return boolean
function EntityUtil.LoadModel(hash)
    if not hash or hash == 0 or not IsModelInCdimage(hash) then return false end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

--- 安全删除实体：先交回引擎再删，避免 mission entity 残留。
---@param entity number
function EntityUtil.Delete(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, false, true)
        DeleteEntity(entity)
    end
end

return EntityUtil
