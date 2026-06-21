-- ============================================================================
-- Standard PlayerData v2.0 — 三位一体架构内存数据结构
-- ============================================================================
-- 本文件为数据结构定义文档，不是可执行代码
-- 对应 DB: players 表 v2.0 (migrations/v2.0_trinity_schema.sql)
-- ============================================================================

---@class PlayerData_v2
---@field source        number                      服务器 ID (运行时赋值, 不持久化)
---@field license       string                       Rockstar License
---@field citizenid     string                       公民 ID (主键)
---@field cid           number                       角色序号 (1, 2, 3...)
---@field name          string                       玩家名
---@field optin         boolean                      管理员消息接收
---@field IsDirty       boolean                      脏标记 (运行时, 决定是否异步刷盘)
---@field LastSavedCoords vector4                   上次存盘坐标 (运行时)
---
---@field money         PlayerMoney                  货币
---@field job           PlayerJob                    职业 (三位一体第一维度)
---@field gang          PlayerGang|nil               帮派 (非法职业)
---@field qualifications PlayerQualifications        资质 (三位一体第三维度 - v2.0 独立列)
---@field charinfo      PlayerCharInfo               角色信息
---@field metadata      PlayerMetadata               元数据 (含 hunger/thirst/licenses 等)
---@field position      vector4                      最后位置
---@field items         table                        背包物品 (运行时从 qb-inventory 加载)

-- ── 货币 ──────────────────────────────────────────────────────────────

---@class PlayerMoney
---@field cash   number  现金     (默认 500)
---@field bank   number  银行存款  (默认 5000)
---@field crypto number  加密货币  (默认 0)

-- ── 职业 (三位一体第一维度) ───────────────────────────────────────────

---@class PlayerJob
---@field name    string  职业标识  (如 "police", "ems", "mechanic")
---@field label   string  职业显示名 (如 "Los Santos Police Department")
---@field type    string  职业类型  ("legal" | "illegal" | "none")
---@field onduty  boolean 是否执勤
---@field isboss  boolean 是否为一把手
---@field payment number  基础工资
---@field grade   JobGrade 组织等级

---@class JobGrade
---@field name   string  等级名 (如 "Officer", "Sergeant", "Chief")
---@field level  number  等级数值 (0=基层, 1=中级, 2=高级, 3=主管, 4=一把手)
---@field isboss boolean 此等级是否为 boss 等级

-- ── 资质 (三位一体第三维度) ── v2.0: 从 metadata 提升为独立 JSON 列 ──

---@class PlayerQualifications
---@field police_heli_pilot?     boolean  警用直升机驾驶
---@field civilian_heli_pilot?   boolean  民用直升机驾驶
---@field advanced_heli_pilot?   boolean  高级直升机驾驶
---@field emt_basic?             boolean  基础急救
---@field emt_field?             boolean  现场急救
---@field advanced_surgery?      boolean  高级外科手术
---@field civilian_concealed_carry? boolean 民用隐蔽持枪
---@field police_firearm?        boolean  警用持枪
---@field heavy_weapons?         boolean  重型武器
---@field heavy_truck?           boolean  重型卡车驾驶
---@field special_vehicle?       boolean  特种车辆驾驶
---@field undercover?            boolean  卧底行动
---@field diving?                boolean  商业潜水
---@field [string]               boolean  扩展: 第三方模组可自由添加新资质

-- ── 角色信息 ──────────────────────────────────────────────────────────

---@class PlayerCharInfo
---@field firstname  string
---@field lastname   string
---@field birthdate  string
---@field gender     number
---@field nationality string
---@field phone      string
---@field account    string

-- ── 元数据 ────────────────────────────────────────────────────────────

---@class PlayerMetadata
---@field hunger          number   饥饿值  (0-100)
---@field thirst          number   口渴值  (0-100)
---@field stress          number   压力值
---@field health          number   生命值
---@field armor           number   护甲值
---@field isdead          boolean  是否死亡
---@field inlaststand     boolean  是否倒地
---@field ishandcuffed    boolean  是否被铐
---@field tracker         boolean  是否被追踪
---@field injail          number   监禁剩余时间
---@field bloodtype       string   血型
---@field fingerprint     string   指纹ID
---@field walletid        string   钱包ID
---@field callsign        string   呼号
---@field rep             table    声望 {mining=10, security=5, ...}
---@field licences        PlayerLicences  旧版证件系统 (legacy, 将被 qualifications 取代)
---@field player_bonus    number   个人经济加成 (1.0=默认, VIP/活动buff可调)
---@field inside          table    室内位置
---@field phonedata       table    手机数据
---@field criminalrecord  table    犯罪记录

---@class PlayerLicences  -- [已废弃, 迁移至 qualifications]
---@field driver  boolean
---@field business boolean
---@field weapon  boolean
---@field pilot   boolean
---@field boat    boolean
---@field heavy   boolean

-- ============================================================================
-- 内存加载伪代码 (展示从 DB 行到 PlayerData_v2 的转换)
-- ============================================================================

--[[
function LoadPlayerFromDB(citizenid)
    local row = MySQL.single.await('SELECT * FROM players WHERE citizenid = ?', {citizenid})
    if not row then return nil end

    local PlayerData = {
        source      = nil,  -- 运行时赋值
        license     = row.license,
        citizenid   = row.citizenid,
        cid         = tonumber(row.cid),
        name        = row.name,
        optin       = true,
        IsDirty     = false,
        LastSavedCoords = nil,

        money       = json.decode(row.money),       -- {"cash":500, "bank":5000, "crypto":0}
        job         = json.decode(row.job),          -- {"name":"police", "grade":{"level":1, ...}, ...}
        gang        = json.decode(row.gang or 'null'),
        qualifications = json.decode(row.qualifications or '{}'),  -- v2.0: 独立列!
        charinfo    = json.decode(row.charinfo),
        metadata    = json.decode(row.metadata),
        position    = json.decode(row.position),
    }

    -- 资质从独立列加载; 如果为空则从 metadata.qualifications fallback (兼容旧数据)
    if next(PlayerData.qualifications) == nil then
        PlayerData.qualifications = PlayerData.metadata.qualifications or {}
    end

    return PlayerData
end
]]
