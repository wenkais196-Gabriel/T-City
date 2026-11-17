-- ==============================================================
-- quest_booth.lua — 热狗摊位（S2）
-- ==============================================================
-- 一句话：玩家把推车推到某处「放下」，就成了一个摊位实体。这个文件负责
-- **服务端权威**的摆放判定，以及摊位实体的登记/回收。
--
-- 为什么不信任客户端：
--   客户端能拿到 `IsPointOnRoad`、坡度、水面这些 native（服务端没有），
--   所以它必须参与测算 —— 但它只能**让判定更严**（veto），不能放宽。
--   服务端自己算的是三条能离线算的硬判据：
--     1. 离租赁点的距离
--     2. 离路面节点的距离（离线切好的路面点，见 config/quests/hotdog_roads.lua）
--     3. 离其它摊位的最小间隔
--   外加配置里的禁摆区。
--
-- 设计取舍：判定拆成 `Evaluate`（纯函数，喂数据、返回 ok/reason）和
-- `ValidatePlacement`（取真实数据 → 调 Evaluate）。只有纯的那半能被离线探针覆盖，
-- 所以真正的判据必须全部写在 Evaluate 里。
--
-- 不变量：
--   - 同一 citizenid + questId 只能有一个摊位（重放不会堆实体）
--   - 登记的 netId 必须真的存在、在玩家 50 m 内、模型与申报一致
--   - 申报坐标必须与实体真坐标相差 ≤3 m，且**入库的是实体真坐标**（红线①）
--   - 任何关闭路径（归还/放弃/失败/断线）都要删实体，否则推车会永远留在地图上
-- ==============================================================

QuestBooth = QuestBooth or {}

--- 单个玩家最多持有的摊位记录（防御性上限，正常只会有一条）
local MAX_BOOTHS = 64

--- 摆放拒绝原因。前八条同时是玩家看到的文案（与 UX 规格 §4.4 一致）；
--- COORDS_MISMATCH 的值是内部错误码（探针按码断言），显示文案见 QuestBooth.ReasonText。
QuestBooth.REASON = {
    TOO_FAR         = '离租赁点太远',
    ON_ROAD         = '挡在车道上，换个位置',
    TOO_CLOSE       = '旁边已经有摊位',
    UNSTABLE        = '这里放不稳',
    FORBIDDEN       = '这里不许摆摊',
    BAD_PAYLOAD     = '摆放信息不完整',
    BAD_ENTITY      = '找不到那辆推车',
    TOO_MANY        = '摊位太多了，稍后再试',
    COORDS_MISMATCH = 'bad_coords',
}

--- citizenid → { questId, x, y, z, netId, model, placedAt, roadDegraded }
local Booths = {}

--- 路面点缓存（懒加载）
local Roads = nil
local RoadLoadFailed = false

--- 纯判据：全部输入都从外面喂进来，方便离线探针逐条打靶。
---@param cfg table 步骤配置：max_distance / road_clearance / min_separation
---@param pos table { x, y, z }
---@param hints table|nil 客户端测算：onRoad / slope / water / inside（只能更严）
---@param otherBooths table 其它已摆好的摊位坐标数组
---@param roadDistance number|nil 到最近路面节点的距离；nil 表示没有路网数据
---@return boolean ok
---@return string|nil reason
function QuestBooth.Evaluate(cfg, pos, hints, otherBooths, roadDistance)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end
    cfg = cfg or {}
    hints = hints or {}
    otherBooths = otherBooths or {}

    -- 1) 客户端测算的「不能放」信号：只要它说不行就是不行（veto 只能收紧）
    if hints.slope == true or hints.water == true or hints.inside == true then
        return false, QuestBooth.REASON.UNSTABLE
    end

    -- 2) 离租赁点
    local rental = cfg.rental_point
    local maxDistance = tonumber(cfg.max_distance) or 200.0
    if type(rental) == 'table' and type(rental.x) == 'number' then
        local dx, dy = pos.x - rental.x, pos.y - rental.y
        if (dx * dx + dy * dy) > (maxDistance * maxDistance) then
            return false, QuestBooth.REASON.TOO_FAR
        end
    end

    -- 3) 压在车道上。客户端说 onRoad 也算数（它比离线点更精确）；
    --    离线点是我们自己能验的那一份，两边任意一边说压路就拒绝。
    local clearance = tonumber(cfg.road_clearance) or 6.0
    if hints.onRoad == true then
        return false, QuestBooth.REASON.ON_ROAD
    end
    if type(roadDistance) == 'number' and roadDistance < clearance then
        return false, QuestBooth.REASON.ON_ROAD
    end

    -- 4) 离其它摊位
    local separation = tonumber(cfg.min_separation) or 15.0
    for _, other in ipairs(otherBooths) do
        if type(other) == 'table' and type(other.x) == 'number' then
            local dx, dy = pos.x - other.x, pos.y - other.y
            if (dx * dx + dy * dy) < (separation * separation) then
                return false, QuestBooth.REASON.TOO_CLOSE
            end
        end
    end

    -- 5) 配置里的禁摆区（圆心 + 半径）
    for _, zone in ipairs(cfg.forbidden_zones or {}) do
        if type(zone) == 'table' and type(zone.x) == 'number' then
            local dx, dy = pos.x - zone.x, pos.y - zone.y
            local r = tonumber(zone.r) or 10.0
            if (dx * dx + dy * dy) < (r * r) then
                return false, QuestBooth.REASON.FORBIDDEN
            end
        end
    end

    return true, nil
end

--- 到最近路面节点的距离（米）。没有路网数据返回 nil。
---@param x number
---@param y number
---@return number|nil
function QuestBooth.NearestRoadDistance(x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    if Roads == nil and not RoadLoadFailed then
        local raw = LoadResourceFile(GetCurrentResourceName(), 'config/quests/hotdog_roads.json')
        if type(raw) == 'string' and raw ~= '' then
            -- 数据文件用 json.decode，**不**用 load()：那份文件是生成物，内容是坐标；
            -- 用 load 执行从磁盘读回的字符串等于开一个「文件被替换就执行任意代码」的口子，
            -- 而它本来只是一张点表。
            local ok, data = pcall(json.decode, raw)
            if ok and type(data) == 'table' and type(data.points) == 'table' then
                Roads = data
                print(('[quest-booth] 🛣️ 路网点已加载：%d 个（%s 米半径）')
                    :format(#data.points // 2, tostring(data.radius)))
            else
                RoadLoadFailed = true
                print('[quest-booth] ⚠️ 路网点解析失败 —— 「挡在车道上」这条判据会退化成只看客户端信号')
            end
        else
            RoadLoadFailed = true
            print('[quest-booth] ⚠️ 缺 config/quests/hotdog_roads.json —— 先跑 tools/dev/booth_roads.py')
        end
    end
    if Roads == nil then return nil end

    local pts = Roads.points
    local best = math.huge
    for i = 1, #pts - 1, 2 do
        local dx, dy = x - pts[i], y - pts[i + 1]
        local d2 = dx * dx + dy * dy
        if d2 < best then best = d2 end
    end
    if best == math.huge then return nil end
    return math.sqrt(best)
end

--- 其它玩家已摆好的摊位坐标（不含自己）
---@param excludeCitizenid string
---@return table
local function otherBoothPositions(excludeCitizenid)
    local out = {}
    for cid, booth in pairs(Booths) do
        if cid ~= excludeCitizenid then
            out[#out + 1] = { x = booth.x, y = booth.y, z = booth.z }
        end
    end
    return out
end

--- 取真实数据 → 交给 Evaluate。
---@param citizenid string
---@param cfg table
---@param pos table
---@param hints table|nil
---@return boolean ok
---@return string|nil reason
function QuestBooth.ValidatePlacement(citizenid, cfg, pos, hints)
    local roadDistance = nil
    if type(pos) == 'table' and type(pos.x) == 'number' then
        roadDistance = QuestBooth.NearestRoadDistance(pos.x, pos.y)
    end
    return QuestBooth.Evaluate(cfg, pos, hints, otherBoothPositions(citizenid), roadDistance)
end

--- 网络 ID → 实体。抽出来是为了让离线探针能替换掉它（原生在测试里不存在）。
function QuestBooth.ResolveEntity(netId)
    return NetworkGetEntityFromNetworkId(netId)
end

--- 实体真坐标。取不到时返回 nil —— 调用方必须当失败处理，不能跳过校验。
---@param entity number 已解析的实体句柄
---@return table|nil coords { x, y, z }
function QuestBooth.EntityCoords(entity)
    if not entity or entity == 0 then return nil end
    local coords = GetEntityCoords(entity)
    if coords == nil or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' then
        return nil
    end
    return { x = coords.x, y = coords.y, z = coords.z }
end

--- 申报点到实体真坐标的距离（米）。纯函数：只读 native、不写状态。
--- 取不到实体坐标时返回 nil —— 调用方必须按失败处理（不能把 nil 当 0 放行）。
--- 生产环境两端都是 vector3，`#(a - b)` 就是原生长度；离线探针把两端喂成同样形状。
---@param pos table { x, y, z } 客户端申报点
---@param entity number 已解析的实体句柄
---@return number|nil
function QuestBooth.EntityDistance(pos, entity)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then
        return nil
    end
    if not entity or entity == 0 then return nil end
    local coords = GetEntityCoords(entity)
    if coords == nil or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' then
        return nil
    end

    local z = tonumber(pos.z) or coords.z
    if type(vector3) == 'function' then
        -- 原生路径：`#(vector3 - vector3)` 返回米。探针把 vector3 桩成同样的元表形状。
        local ok, distance = pcall(function() return #(vector3(pos.x, pos.y, z) - coords) end)
        if ok and type(distance) == 'number' then return distance end
    end
    -- 兜底（离线环境没有 vector3 原生）：同样的语义，手算。
    local dx, dy, dz = pos.x - coords.x, pos.y - coords.y, z - coords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- 服务端复验客户端申报的摊位位置（红线①）。Register 与 move 共用这一套判据，
--- 避免两条路径漂移。判据顺序即短路顺序（原因码与每一步一一对应）：
---   1) pos 形状                  → BAD_PAYLOAD
---   2) netId 可转成正整数        → BAD_ENTITY
---   3) ResolveEntity(netId)      → BAD_ENTITY（无句柄 / 0）
---   4) DoesEntityExist(entity)   → BAD_ENTITY（句柄已失效）
---   5) 玩家与实体 ≤ 50 m        → BAD_ENTITY（不是自己的 / 早被回收的推车）
---   6) 模型匹配                  → BAD_ENTITY（申报模型与实体不符）
---   7) 申报点与实体 ≤ 3 m        → COORDS_MISMATCH（客户端坐标不可信）
--- 通过时返回**实体真坐标**：入库 / 挪位只能写这一份，不能写客户端申报值。
---@param source number 玩家 source
---@param pos table 客户端申报的 { x, y, z }
---@param netId number|string 服务端认定的实体 netId
---@param model string|nil 申报模型；'unknown' 表示登记时就没拿到模型
---@return boolean ok
---@return string|nil reason
---@return table|nil coords 实体真坐标
function QuestBooth.VerifyEntity(source, pos, netId, model)
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end

    local numericNetId = tonumber(netId)
    if not numericNetId or numericNetId <= 0 then
        return false, QuestBooth.REASON.BAD_ENTITY
    end

    local entity = QuestBooth.ResolveEntity(numericNetId)
    if not entity or entity == 0 then
        return false, QuestBooth.REASON.BAD_ENTITY
    end
    if not DoesEntityExist(entity) then
        return false, QuestBooth.REASON.BAD_ENTITY
    end

    local ped = GetPlayerPed(source)
    if ped and ped ~= 0 and #(GetEntityCoords(ped) - GetEntityCoords(entity)) > 50.0 then
        -- 申报的推车不在玩家附近：要么是别人的实体，要么早被回收了
        return false, QuestBooth.REASON.BAD_ENTITY
    end

    -- 'unknown' 是「登记时就没拿到模型」的占位，不当成可校验的申报值
    if type(model) == 'string' and model ~= '' and model ~= 'unknown' then
        local entityModel = GetEntityModel(entity)
        if GetHashKey(model) ~= entityModel and joaat(model) ~= entityModel then
            return false, QuestBooth.REASON.BAD_ENTITY
        end
    end

    local distance = QuestBooth.EntityDistance(pos, entity)
    if distance == nil then
        -- 取不到坐标 = 无法复验。静默放行等于把「信任客户端」留在原地。
        return false, QuestBooth.REASON.BAD_ENTITY
    end
    if distance > 3.0 then
        return false, QuestBooth.REASON.COORDS_MISMATCH
    end

    local coords = QuestBooth.EntityCoords(entity)
    if not coords then
        return false, QuestBooth.REASON.BAD_ENTITY
    end
    return true, nil, coords
end

--- 拒绝原因 → 玩家可见文案。`COORDS_MISMATCH` 的值是内部错误码，
--- 其余 reason 本身就是中文文案；nil 用通用兜底。
---@param reason string|nil
---@return string
function QuestBooth.ReasonText(reason)
    if reason == QuestBooth.REASON.COORDS_MISMATCH then
        return 'bad_coords：摊位位置对不上，靠近推车再试'
    end
    return reason or '这里放不了'
end

--- 登记一个摆好的摊位。netId 必须真的存在、在玩家附近、模型对得上，
--- 且申报坐标必须落在实体 3 m 内（红线①）。
---@param source number 玩家 source（用于取实体与距离）
---@param citizenid string
---@param questId string
---@param pos table { x, y, z }
---@param netId number
---@param model string
---@param cfg table|nil 摆放配置（step.data）。传了才跑 ValidatePlacement；
---  探针 / 仅做实体复验的调用方可以不传。
---@param hints table|nil 客户端测算信号（只能更严）
---@return boolean ok
---@return string|nil reason
function QuestBooth.Register(source, citizenid, questId, pos, netId, model, cfg, hints)
    -- 判据顺序（短路原因与错误码一一对应）：
    --   1) payload 形状                      → BAD_PAYLOAD
    --   2) ResolveEntity(netId)              → BAD_ENTITY
    --   3) DoesEntityExist                   → BAD_ENTITY
    --   4) 玩家离实体 ≤ 50 m                → BAD_ENTITY
    --   5) 模型匹配                          → BAD_ENTITY
    --   6) 申报点离实体 ≤ 3 m                → COORDS_MISMATCH（bad_coords）
    --   7) ValidatePlacement（摆放规则）
    --   8) 入库：写**实体真坐标**（不是客户端申报值）
    if type(citizenid) ~= 'string' or type(questId) ~= 'string' then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end

    -- 同一玩家同一任务只留一条；先清旧的，免得重放堆实体
    if Booths[citizenid] and Booths[citizenid].questId == questId then
        QuestBooth.RemoveBooth(citizenid, questId, 'replaced')
    end

    local count = 0
    for _ in pairs(Booths) do count = count + 1 end
    if count >= MAX_BOOTHS then
        return false, QuestBooth.REASON.TOO_MANY
    end

    -- 2)~6) 实体解析**必须**跑：写成 `if type(_resolveEntity) == 'function' then ... end`
    -- 的话，生产环境里那个钩子是 nil，整段「存在/距离/模型/坐标」校验就被静默跳过。
    -- 探针通过替换 ResolveEntity 来喂假实体；move 走同一个 VerifyEntity。
    local numericNetId = tonumber(netId)
    local verified, verifyReason, trueCoords =
        QuestBooth.VerifyEntity(source, pos, numericNetId, model)
    if not verified then
        return false, verifyReason
    end

    -- 7) 摆放规则对着**实体真坐标**算：申报值在 3 m 内也可能是偏的，
    --    规则不该对着一个偏掉的点判断。
    if cfg ~= nil then
        local placeOk, placeReason = QuestBooth.ValidatePlacement(citizenid, cfg, trueCoords, hints)
        if not placeOk then
            return false, placeReason
        end
    end

    -- 8) 入库坐标取实体真值。存 pos 等于把「客户端申报」当权威，红线①原样留下。
    Booths[citizenid] = {
        questId = questId,
        x = trueCoords.x, y = trueCoords.y, z = trueCoords.z,
        netId = numericNetId,
        model = model or 'unknown',
        placedAt = os.time(),
    }

    if QuestEntityRegistry and QuestEntityRegistry.Register then
        QuestEntityRegistry.Register(citizenid, questId, 'booth', numericNetId, {
            model = model or 'unknown',
            -- 摊位不能走 on_leave：玩家走开去卖货是常态，走远不等于不要了
            recyclePolicy = 'on_quest_end',
        })
    end

    print(('[quest-booth] 📋 摊位登记：%s | %s | netId=%d | (%.1f, %.1f, %.1f)')
        :format(citizenid, questId, numericNetId, trueCoords.x, trueCoords.y, trueCoords.z))
    return true, nil
end

--- 取摊位记录
function QuestBooth.Get(citizenid)
    return Booths[citizenid]
end

--- 按 netId 找摊位（买家要买别人的摊，所以不能只按 citizenid 查）
---@param netId number
---@return table|nil booth  附带 ownerCitizenid
function QuestBooth.FindByNetId(netId)
    local numeric = tonumber(netId)
    if not numeric then return nil end
    for cid, booth in pairs(Booths) do
        if booth.netId == numeric then
            local copy = { ownerCitizenid = cid, questId = booth.questId }
            for k, v in pairs(booth) do copy[k] = v end
            return copy
        end
    end
    return nil
end

--- 当前摊位总数
function QuestBooth.Count()
    local n = 0
    for _ in pairs(Booths) do n = n + 1 end
    return n
end

--- 挪摊位：只更新坐标，实体 netId 不变（推车还是那辆）。
--- 为什么不在服务端重建记录：netId 变了就意味着客户端要重新上报、实体注册表要重登记，
--- 而玩家想做的只是「挪一米」，副作用越小越好。
--- 入库坐标**必须**重新取实体真值：`pos` 只是已通过的申报点（≤3 m），
--- 直接落库等于把客户端申报当权威（红线①）。
---@param citizenid string
---@param pos table { x, y, z } 已复验的申报点，仅用于日志与形状校验
---@return boolean ok
---@return string|nil reason
function QuestBooth.MoveTo(citizenid, pos)
    local booth = Booths[citizenid]
    if not booth then return false, QuestBooth.REASON.BAD_ENTITY end
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.y) ~= 'number' then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end

    local entity = QuestBooth.ResolveEntity(booth.netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return false, QuestBooth.REASON.BAD_ENTITY
    end
    local coords = QuestBooth.EntityCoords(entity)
    if not coords then
        -- 取不到实体坐标 = 不能保证入库值是真值，拒绝挪位
        return false, QuestBooth.REASON.BAD_ENTITY
    end

    booth.x, booth.y, booth.z = coords.x, coords.y, coords.z
    print(('[quest-booth] ↔️ 摊位挪位：%s | 申报 (%.1f, %.1f) → 实体 (%.1f, %.1f, %.1f)')
        :format(citizenid, pos.x, pos.y, booth.x, booth.y, booth.z))
    return true, nil
end

--- 关摊位：删实体 + 清记录（名字别叫 Release：那个词全仓已有 4 份实现，会撞复用量闸）。四条关闭路径都走这里（归还/放弃/失败/断线）。
---@param citizenid string
---@param questId string|nil 传了才按任务关；不传关该玩家所有摊位
---@param reason string
function QuestBooth.RemoveBooth(citizenid, questId, reason)
    local booth = Booths[citizenid]
    if not booth then return false end
    if questId and booth.questId ~= questId then return false end

    Booths[citizenid] = nil
    if QuestEntityRegistry and QuestEntityRegistry.ForceRecycleAll then
        pcall(QuestEntityRegistry.ForceRecycleAll, citizenid, booth.questId)
    end
    print(('[quest-booth] 🧹 摊位关闭：%s | %s | reason=%s | netId=%s')
        :format(citizenid, tostring(booth.questId), tostring(reason), tostring(booth.netId)))
    return true
end

--- 测试/运维用：清内存态（不删实体、不碰钱）
function QuestBooth.Reset()
    Booths = {}
    Roads = nil
    RoadLoadFailed = false
end

-- ==============================================================
-- 接线：校验器
-- ==============================================================
-- 步骤形状（配置侧）：
--   { id='place_stand', type='booth',
--     data = { validator_id='validate_booth_place',
--              model='prop_hotdogstand_01',
--              rental_point={x=...,y=...,z=...},
--              max_distance=200.0, road_clearance=6.0, min_separation=15.0 } }
--
-- 客户端在放下时把坐标与 netId 放进 clientData.booth，走**既有**的 nodeComplete。
-- 所以这里不需要新的 net event。
local function validate_booth_place(source, stepData, questData)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return false, 'no_player' end
    local citizenid = Player.PlayerData.citizenid
    local questId = questData and questData.questId or 'unknown'

    local clientData = questData and questData.clientData or {}
    local booth = clientData.booth
    if type(booth) ~= 'table' then
        return false, '摆放信息没传上来（客户端未上报坐标）'
    end

    local pos = { x = tonumber(booth.x), y = tonumber(booth.y), z = tonumber(booth.z) }
    if not pos.x or not pos.y then
        return false, QuestBooth.REASON.BAD_PAYLOAD
    end

    -- 判据顺序集中在 Register：实体复验（含 ≤3 m 坐标复验）→ ValidatePlacement → 入库。
    -- 摆放规则拿**实体真坐标**算，不拿客户端申报值。
    local registered, regReason = QuestBooth.Register(
        source, citizenid, questId, pos, booth.netId, booth.model or stepData.model,
        stepData, booth.hints)
    if not registered then
        return false, QuestBooth.ReasonText(regReason)
    end

    -- 摊位一摆好就开卖：玩家不需要再按一次「开卖」，符合 UX 规格里
    -- 「放下即开张，收摊要主动做」的节奏。开卖失败只记日志 ——
    -- 摆放本身成功了，不能因为生意开不起来就把摊位判死。
    if type(QuestVendorBridge) == 'table' and type(QuestVendorBridge.OpenFor) == 'function' then
        local ok, err = QuestVendorBridge.OpenFor(source, citizenid, questId,
            booth.netId, stepData.vendor, stepData.nodeId)
        if not ok then
            print(('[quest-booth] ⚠️ 开卖失败：%s | %s | %s'):format(
                citizenid, tostring(questId), tostring(err)))
        end
    end

    return true, nil
end

if QuestValidators and QuestValidators.Register then
    local ok, err = QuestValidators.Register('validate_booth_place', validate_booth_place)
    if ok then
        print('[quest-booth] ✅ validate_booth_place 已注册')
    else
        print(('[quest-booth] ⚠️ validate_booth_place 注册失败：%s'):format(tostring(err)))
    end
end
