QBConfig = QBConfig or {}
QBConfig.Career = QBConfig.Career or {}

-- 职业主类常量定义
QBConfig.Career.Roles = {
    police   = { label = "警察",   tiers = {"leader", "mid", "entry"} },
    medic    = { label = "医护",   tiers = {"leader", "entry"} },
    mayor    = { label = "市长",   tiers = {"leader", "entry"} },
    gang     = { label = "帮派",   tiers = {"leader", "mid", "entry"} },
    civilian = { label = "平民",   tiers = {"entry"} }
}

-- 阶层定义及其权限标识
QBConfig.Career.Tiers = {
    leader = { label = "领袖", permissions = {"kpi_terminal", "catalyst"} },
    mid    = { label = "中层", permissions = {"dept_manage"} },
    entry  = { label = "基层", permissions = {} }
}
