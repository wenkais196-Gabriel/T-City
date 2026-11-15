-- client/entity_util.lua — 几个 NPC 服务共用的实体小工具。
--
-- 出现原因：验尸官与拖车各自抄了一份 `loadModel` / `deleteEntity`，
-- 重复实现预算（REUSE-01）当场就红了。合并到这里，两边只留一行别名。
--
-- 模型加载不再放这里：唯一实现是 `@core-framework/client/shared.lua` 的
-- `CFShared.LoadModel`（带 cdimage 检查、超时与失败上报）。本文件只保留无状态的
-- 实体删除；调用方直接 `CFShared.LoadModel(hash, 5000)`。

EntityUtil = EntityUtil or {}

--- 安全删除实体：先交回引擎再删，避免 mission entity 残留。
---@param entity number
function EntityUtil.Delete(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, false, true)
        DeleteEntity(entity)
    end
end

return EntityUtil
