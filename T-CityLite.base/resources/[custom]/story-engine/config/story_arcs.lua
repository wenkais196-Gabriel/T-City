-- config/story_arcs.lua — 剧情线定义
--
-- 字段:
--   id              唯一标识
--   title / description  显示文本
--   category        分类: criminal | law | civilian
--   sort_order      手机 UI 排序
--   enabled         总开关 (false 则所有 quest 不可接)
--   prerequisite    前置 arc (可选，需先完成该 arc)
--   season          版本标签 (可选，仅标注)

return {
    {
        id = 'cartel',
        title = '洛圣都地下帝国',
        description = '从街头小喽啰到贩毒帝国之主的崛起之路。',
        category = 'criminal',
        sort_order = 1,
        enabled = true,
        icon = 'skull',
    },
    {
        id = 'police',
        title = '蓝墙内外',
        description = '穿上警徽，面对洛圣都最深的腐败。',
        category = 'law',
        sort_order = 2,
        enabled = true,
        icon = 'shield',
    },
    {
        id = 'civilian',
        title = '洛圣都浮世绘',
        description = '从零开始，在吞噬梦想的城市里建造你的帝国。',
        category = 'civilian',
        sort_order = 3,
        enabled = true,
        icon = 'building',
    },
}
