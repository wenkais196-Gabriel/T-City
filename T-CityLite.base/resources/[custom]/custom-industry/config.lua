-- config.lua — S1 组织金库配置。
--
-- 组织名 = job/gang 名，来自 custom-storage 的 Organizations：
--   mining_co 是 job 型组织（jobs = { 'miner' }）
--   cartel    是 gang 型组织（gang = 'cartel'）
-- 本资源不引用 custom-storage（S1 只需要把 orgId 映射回玩家的 job/gang），
-- 所以映射写在 OrgWhitelist 里；custom-storage 增删组织时这里要同步。

Config = {}

Config.Industry = {
    -- 默认关闭：set industry_enable true 后 /orgfund* 才会注册。
    Enabled = GetConvar('industry_enable', 'false') == 'true',

    OrgWhitelist = {
        mining_co = { kind = 'job', name = 'miner' },
        cartel = { kind = 'gang', name = 'cartel' },
    },

    -- 该组织 Grade4 才能存取；Grade4 以下只返回 not_boss。
    BossGrade = 4,

    LedgerDefaultLimit = 20,
    LedgerMaxLimit = 100,
}
