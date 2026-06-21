QBShared = QBShared or {}
QBShared.Gangs = {
    -- ==============================================================
    -- 统一五级组织模板 — 帮派 (Gangs)
    -- 等级体系: 0=实习 → 1=正式 → 2=小组长 → 3=副部长 → 4=Boss
    -- ==============================================================
    none = { label = 'No Gang', grades = { ['0'] = { name = 'Unaffiliated' } } },

    -- === 摩托帮 / The Lost MC ===
    lostmc = {
        label = 'The Lost MC',
        grades = {
            ['0'] = { name = 'Prospect' },           -- 见习成员
            ['1'] = { name = 'Patch Member' },        -- 正式成员
            ['2'] = { name = 'Road Captain' },        -- 小队领骑
            ['3'] = { name = 'Vice President' },      -- 副会长
            ['4'] = { name = 'President', isboss = true }, -- 会长
        },
    },

    -- === 黑人街头帮派 / Ballas (原型 Bloods) ===
    ballas = {
        label = 'Ballas',
        grades = {
            ['0'] = { name = 'Tiny' },               -- 小喽啰
            ['1'] = { name = 'Soldier' },             -- 正式帮众
            ['2'] = { name = 'Lieutenant' },          -- 小队头目
            ['3'] = { name = 'Underboss' },           -- 二老板
            ['4'] = { name = 'Kingpin', isboss = true }, -- 大头目
        },
    },

    -- === 墨西哥街头帮派 / Vagos (原型 Sureños) ===
    vagos = {
        label = 'Vagos',
        grades = {
            ['0'] = { name = 'Chavala' },             -- 小崽子
            ['1'] = { name = 'Soldado' },             -- 正式士兵
            ['2'] = { name = 'Jefe de Calle' },       -- 街长
            ['3'] = { name = 'Subjefe' },             -- 副首领
            ['4'] = { name = 'El Padrino', isboss = true }, -- 教父
        },
    },

    -- === 墨西哥毒枭卡特尔 / Cartel ===
    cartel = {
        label = 'Cartel',
        grades = {
            ['0'] = { name = 'Halcon' },              -- 鹰眼/放哨
            ['1'] = { name = 'Sicario' },             -- 职业杀手
            ['2'] = { name = 'Jefe de Plaza' },       -- 堂口主管
            ['3'] = { name = 'Subteniente' },         -- 副中尉
            ['4'] = { name = 'El Jefe', isboss = true }, -- 大头目
        },
    },

    -- === 黑人街头帮派 / Families (原型 Crips) ===
    families = {
        label = 'Families',
        grades = {
            ['0'] = { name = 'Youngster' },           -- 街坊小子
            ['1'] = { name = 'Hustler' },             -- 主力成员
            ['2'] = { name = 'Big Homie' },           -- 老大哥
            ['3'] = { name = 'Underboss' },           -- 二当家
            ['4'] = { name = 'Godfather', isboss = true }, -- 教父
        },
    },

    -- === 三合会 / Triads (华人黑帮) ===
    triads = {
        label = 'Triads',
        grades = {
            ['0'] = { name = 'Blue Lantern' },        -- 蓝灯笼/见习
            ['1'] = { name = '49 Boy' },              -- 四九仔/正式
            ['2'] = { name = 'Red Pole' },            -- 红棍/行动组长
            ['3'] = { name = 'White Paper Fan' },     -- 白纸扇/军师
            ['4'] = { name = 'Dragon Head', isboss = true }, -- 龙头/坐馆
        },
    },
}
