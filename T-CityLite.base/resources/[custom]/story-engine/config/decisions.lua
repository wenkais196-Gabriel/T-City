-- config/decisions.lua — 三个序章的决策点定义
--
-- 每个决策: { id, arc_id, chapter, prompt, options[] }
-- options[i]: { id, text, effects: { player_flags, rewards } }
--
-- 安全: 服务端只接受 options 中已定义的 optionId（白名单校验）

return {
    -- ==============================================================
    -- Cartel 序章决策
    -- ==============================================================
    {
        id = 'cartel_ch1_logistics_or_enforcer',
        arc_id = 'cartel',
        chapter = 1,
        timeout = 120,
        prompt = 'Halcon 从腰间抽出一把手枪，在吧台上缓缓推到你面前。\n\n"听着，小子。送货只是入门。如果你想在这里真正立足——你得学会动手。"\n\n他盯着你的眼睛：\n"所以，你怎么说？只想安安稳稳跑腿送货，还是……想学点真本事？"',
        options = {
            {
                id = 'logistics_only',
                text = '"我只送货，不动手。" — 专注运输和走私路线',
                effects = {
                    player_flags = { logistics_only = true },
                },
            },
            {
                id = 'enforcer_path',
                text = '"教我怎么做。" — 走上暴力执法者之路',
                effects = {
                    player_flags = { enforcer_path = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Police 序章决策
    -- ==============================================================
    {
        id = 'police_ch1_honest_or_silent',
        arc_id = 'police',
        chapter = 1,
        timeout = 120,
        prompt = '你在嫌犯口袋里发现一张揉皱的纸条，上面只写着一个名字——"Det. Morrison"——*你的直属上司*\n\nCaptain Reyes 走过来："发现什么了？"',
        options = {
            {
                id = 'honest_cop',
                text = '把纸条交给 Reyes — "长官，这个可能有问题。"',
                effects = {
                    player_flags = { honest_cop = true },
                },
            },
            {
                id = 'silent_watcher',
                text = '悄悄收进口袋 — "没什么，空的。"',
                effects = {
                    player_flags = { silent_watcher = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Civilian 序章决策
    -- ==============================================================
    {
        id = 'civilian_ch1_honest_or_shadow',
        arc_id = 'civilian',
        chapter = 1,
        timeout = 120,
        prompt = 'Old Tony 帮你把第一笔工资存进银行，拍了拍你的肩。\n\n正要离开时，一个西装革履的男人从旁边的长椅上站起来，递来一张烫金名片：\n\n*"洛圣都商业咨询 — Marcus Chen"*\n\n"我看你刚来这座城市。有兴趣的话，我可以介绍一些……回报更高的项目。"',
        options = {
            {
                id = 'honest_citizen',
                text = '"谢谢，但我先靠自己。" — 走合法经商之路',
                effects = {
                    player_flags = { honest_citizen = true },
                },
            },
            {
                id = 'open_to_shadows',
                text = '"说说看什么生意。" — 打开地下经济之门',
                effects = {
                    player_flags = { open_to_shadows = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Cartel Ch1: 地盘之争 — 饶恕 vs 赶尽杀绝
    -- ==============================================================
    {
        id = 'cartel_ch2_mercy_or_ruthless',
        arc_id = 'cartel',
        chapter = 2,
        timeout = 120,
        prompt = 'Aztecas 的头目跪在你面前，血从他额头的伤口往下淌。\n\n"杀了我，会有更多的人来找你。饶了我——Aztecas 可以成为 Cartel 的盟友。"\n\nHalcon 在你身后冷冷地说："别心软。斩草要除根。"',
        options = {
            {
                id = 'cartel_mercy',
                text = '收起枪 — "起来。从今天起，Aztecas 归 Cartel。"',
                effects = {
                    player_flags = { cartel_mercy = true },
                },
            },
            {
                id = 'cartel_ruthless',
                text = '扣下扳机 — 不留活口。',
                effects = {
                    player_flags = { cartel_ruthless = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Cartel Ch2: 帝国之影 — 查清 vs 错杀
    -- ==============================================================
    {
        id = 'cartel_ch3_calculate_or_paranoid',
        arc_id = 'cartel',
        chapter = 3,
        timeout = 120,
        prompt = '你抓住了一个嫌疑人。他哭着说自己是无辜的，只是被 FIB 利用。\n\nHalcon 把枪递过来："做了他，别留后患。宁可错杀一千。"\n\n但你注意到他口袋里有一张家庭合影——他有妻子和两个孩子。',
        options = {
            {
                id = 'cartel_calculated',
                text = '收起枪 — "先查清楚。如果他是无辜的，我们需要真正的卧底。"',
                effects = {
                    player_flags = { cartel_calculated = true },
                },
            },
            {
                id = 'cartel_paranoid',
                text = '扣下扳机 — "宁可错杀。这是规矩。"',
                effects = {
                    player_flags = { cartel_paranoid = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Police Ch1: 腐败之网 — 提交证据 vs 留筹码
    -- ==============================================================
    {
        id = 'police_ch2_justice_or_pragmatic',
        arc_id = 'police',
        chapter = 2,
        timeout = 120,
        prompt = '你掌握了 Morrison 收受贿赂的铁证：银行转账记录、监控录像、证人证词。\n\nIA 调查官 Davis 伸出手："交给我，我会确保他受到应有惩罚。"\n\n但你的直觉告诉你——IA 内部也可能有人被 Morrison 收买了。',
        options = {
            {
                id = 'police_justice',
                text = '把证据交给 Davis — "我希望你做正确的事。"',
                effects = {
                    player_flags = { police_justice = true },
                },
            },
            {
                id = 'police_pragmatic',
                text = '复制一份留底，原件锁进保险箱 — "我先自己查。"',
                effects = {
                    player_flags = { police_pragmatic = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Police Ch2: 深渊 — 曝光 vs 交易
    -- ==============================================================
    {
        id = 'police_ch3_whistleblower_or_insider',
        arc_id = 'police',
        chapter = 3,
        timeout = 120,
        prompt = '你手里的证据足以掀翻半个市政府——市长、警察局长、三个市议员。\n\n深夜，一个陌生号码打来电话。声音经过变声处理：\n\n"我们知道你是谁。把证据交给我们，你下周就能坐到警监的位置。拒绝的话……你知道后果。"',
        options = {
            {
                id = 'police_whistleblower',
                text = '挂断电话，联系媒体 — "让全城人看看他们的真面目。"',
                effects = {
                    player_flags = { police_whistleblower = true },
                },
            },
            {
                id = 'police_insider',
                text = '沉默片刻 — "说说你的条件。"',
                effects = {
                    player_flags = { police_insider = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Civilian Ch1: 创业维艰 — 拒绝 vs 交钱
    -- ==============================================================
    {
        id = 'civilian_ch2_defiant_or_pragmatic',
        arc_id = 'civilian',
        chapter = 2,
        timeout = 120,
        prompt = '两个混混推开你的店门，其中一个把手按在你的收银台上。\n\n"新来的？这条街归我们管。每周 $500，保你平安。不交的话……"他敲了敲收银台的玻璃，"这玩意儿可能明天就碎了。"',
        options = {
            {
                id = 'civ_defiant',
                text = '直视他的眼睛 — "我不需要你的\'保护\'。现在请你们出去。"',
                effects = {
                    player_flags = { civ_defiant = true },
                },
            },
            {
                id = 'civ_pragmatic',
                text = '掏出 $500 — "拿着。让我安安静静做生意。"',
                effects = {
                    player_flags = { civ_pragmatic = true },
                },
            },
        },
    },

    -- ==============================================================
    -- Civilian Ch2: 帝国的代价 — 扩张 vs 守成
    -- ==============================================================
    {
        id = 'civilian_ch3_ambitious_or_cautious',
        arc_id = 'civilian',
        chapter = 3,
        timeout = 120,
        prompt = '银行经理把贷款合同推到你面前。$50,000——足够收购隔壁那家濒临倒闭的竞争对手，把你的店扩张成连锁品牌。\n\n但抵押品是你的店。如果失败，你连这家店都会失去。\n\nOld Tony 拍了拍你的肩："孩子，我见过太多人赌上一切，最后什么都没剩下。"',
        options = {
            {
                id = 'civ_ambitious',
                text = '签下名字 — "不冒险，永远不知道自己能走多远。"',
                effects = {
                    player_flags = { civ_ambitious = true },
                },
            },
            {
                id = 'civ_cautious',
                text = '把合同推回去 — "我不急。稳扎稳打，先做好这一家。"',
                effects = {
                    player_flags = { civ_cautious = true },
                },
            },
        },
    },
}
