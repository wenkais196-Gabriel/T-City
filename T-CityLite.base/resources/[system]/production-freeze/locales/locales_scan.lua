-- ============================================================================
-- 追加到 locales/locales.lua 末尾 — 全项目扫描到的所有硬编码中文
-- ============================================================================

    -- cartel
    cartel_supplier_empty     = { zh = '供应商暂时缺货',             en = 'Supplier is out of stock' },
    cartel_no_quests          = { zh = '暂时没有可接的任务',         en = 'No quests available right now' },
    cartel_too_far_lab        = { zh = '你离实验室太远了',           en = 'You are too far from the lab' },
    cartel_no_recipe          = { zh = '没有可用的配方',             en = 'No recipe available' },
    cartel_production_start   = { zh = '开始生产 %s...',              en = 'Starting production: %s...' },
    cartel_production_fail    = { zh = '生产失败！操作失误',         en = 'Production failed! Error in process' },
    cartel_production_cancel  = { zh = '生产已取消',                 en = 'Production cancelled' },
    cartel_disabled           = { zh = 'Cartel 系统已禁用',          en = 'Cartel system is disabled' },
    cartel_not_member         = { zh = '你不是 Cartel 成员',         en = 'You are not a Cartel member' },
    cartel_unknown_recipe     = { zh = '未知配方: %s',               en = 'Unknown recipe: %s' },
    cartel_security_fail      = { zh = '安全校验失败: %s',           en = 'Security check failed: %s' },
    cartel_recipe_error       = { zh = '配方数据异常',               en = 'Recipe data error' },
    cartel_identity_fail      = { zh = '身份校验失败',               en = 'Identity verification failed' },
    cartel_storage_down       = { zh = '仓库服务不可用',             en = 'Storage service unavailable' },
    cartel_no_members_online  = { zh = '当前没有 Cartel 成员在线',   en = 'No Cartel members online' },
    cartel_supplier_refuse    = { zh = '你不是 Cartel 成员，供应商不与你交易', en = 'Supplier refuses to trade with non-Cartel members' },
    cartel_invalid_supplier   = { zh = '无效的供应商',               en = 'Invalid supplier' },
    cartel_not_sell_item      = { zh = '该供应商不卖此物品',         en = 'Supplier does not sell this item' },
    cartel_supplier_no_stock  = { zh = '供应商库存不足',             en = 'Supplier out of stock' },
    cartel_distributor_refuse = { zh = '你不是 Cartel 成员，分销商不与你交易', en = 'Distributor refuses to trade with you' },
    cartel_invalid_distributor= { zh = '无效的分销商',               en = 'Invalid distributor' },
    cartel_not_buy_item       = { zh = '分销商不收这种货',           en = 'Distributor does not accept this item' },
    cartel_not_enough_item    = { zh = '你没有足够的 %s',             en = 'You do not have enough %s' },
    cartel_blip               = { zh = 'Cartel 毒品活动',            en = 'Cartel Drug Activity' },

    -- justice / prison
    justice_prison_remaining  = { zh = '你在监狱中，剩余刑期: %d 分钟', en = 'You are in prison. Remaining: %d minutes' },
    justice_prison_soon       = { zh = '还有 %d 分钟出狱',           en = '%d minutes until release' },
    justice_released          = { zh = '你已出狱，重新获得自由！',   en = 'You have been released!' },
    justice_no_charge         = { zh = '请指定至少一项罪名',         en = 'Please specify at least one charge' },
    justice_invalid_charge    = { zh = '无效的罪名',                 en = 'Invalid charge' },
    justice_lawyer_only       = { zh = '只有律师可以接案',           en = 'Only lawyers can take cases' },
    justice_case_not_found    = { zh = '案件不存在或已关闭',         en = 'Case not found or closed' },
    justice_case_taken        = { zh = '此案件已有律师处理',         en = 'This case already has a lawyer' },
    justice_case_accepted     = { zh = '你已接受案件 %s | 嫌疑人: %s', en = 'Case accepted: %s | Suspect: %s' },
    justice_arrest_usage      = { zh = '用法: /arrest [玩家ID] [罪名1,罪名2]', en = 'Usage: /arrest [playerID] [charge1,charge2]' },
    justice_not_in_prison     = { zh = '你不在监狱系统中',           en = 'You are not in the prison system' },
    justice_invalid_reduction = { zh = '无效的减刑类型',             en = 'Invalid reduction type' },
    justice_already_used      = { zh = '你已经使用过此减刑',         en = 'You have already used this reduction' },
    justice_reduction_ok      = { zh = '减刑成功: -%d分钟 (%s)',     en = 'Reduction: -%d min (%s)' },
    justice_sentence_done     = { zh = '刑期已满，你被释放了！',     en = 'Sentence complete, you are free!' },
    justice_inmate_offline    = { zh = '囚犯当前不在线',             en = 'Inmate is offline' },
    justice_visit_sent        = { zh = '探视请求已发送给 %s',        en = 'Visit request sent to %s' },
    justice_not_inmate        = { zh = '该囚犯不在监狱系统中',       en = 'That inmate is not in the prison system' },
    justice_police_only       = { zh = '只有警察或法官可以查看',     en = 'Only police or judges can view' },
    justice_no_inmates        = { zh = '当前没有在押囚犯',           en = 'No inmates currently' },
    justice_judge_only        = { zh = '只有法官可以开庭',           en = 'Only judges can open court' },
    justice_case_closed       = { zh = '此案已结',                   en = 'Case is closed' },
    justice_no_pending        = { zh = '当前没有待审案件',           en = 'No pending cases' },
    justice_lawyer_judge_only = { zh = '只有法官或律师可以查看案件', en = 'Only judges or lawyers can view cases' },

    -- mining
    mining_too_far            = { zh = '你离矿点太远了',             en = 'Too far from mining site' },
    mining_start              = { zh = '开始采矿: %s',                en = 'Mining: %s' },
    mining_left_area          = { zh = '你离开了矿点区域',           en = 'You left the mining area' },
    mining_stopped            = { zh = '采矿已停止',                 en = 'Mining stopped' },
    mining_staff_only         = { zh = '只有矿业公司员工才能采矿',   en = 'Only mining company employees can mine' },
    mining_disabled           = { zh = '矿业系统已禁用',             en = 'Mining system is disabled' },
    mining_need_pickaxe       = { zh = '你需要一把矿镐才能采矿',     en = 'You need a pickaxe to mine' },
    mining_smelter_too_far    = { zh = '你离冶炼厂太远了',           en = 'Too far from smelter' },
    mining_no_smelt_recipe    = { zh = '没有可用的冶炼配方',         en = 'No smelting recipe available' },
    mining_smelt_cancelled    = { zh = '冶炼已取消',                 en = 'Smelting cancelled' },
    mining_smelt_fail         = { zh = '冶炼失败！%s已损坏',         en = 'Smelting failed! %s damaged' },
    mining_smelter_staff_only = { zh = '只有矿业公司员工才能使用冶炼厂', en = 'Only mining employees can use the smelter' },

    -- storage
    storage_no_job            = { zh = '你当前无业，没有职业仓库可用', en = 'No job storage available (unemployed)' },
    storage_no_org            = { zh = '未找到所属组织',             en = 'Organization not found' },
    storage_no_gang           = { zh = '你没有加入任何帮派',         en = 'Not in a gang' },
    storage_no_gang_org       = { zh = '未找到所属帮派组织',         en = 'Gang organization not found' },

    -- market
    market_no_category        = { zh = '没有找到分类: %s',           en = 'Category not found: %s' },
    market_setprice_usage     = { zh = '用法: /marketsetprice [商品名] [价格]', en = 'Usage: /marketsetprice [item] [price]' },
    market_unknown_item       = { zh = '未知商品: %s',               en = 'Unknown item: %s' },
    market_price_set          = { zh = '%s 价格已设为 $%d',          en = '%s price set to $%d' },

    -- admin
    admin_id_printed          = { zh = '你的标识符已打印到聊天窗口', en = 'Identifiers printed to chat' },
    admin_current_threshold   = { zh = '当前门槛: %s',               en = 'Current threshold: %s' },
    admin_reset_to_2          = { zh = '已重置为 2',                 en = 'Reset to 2' },
    admin_invalid_0_10        = { zh = '无效，请输入 0-10',          en = 'Invalid. Enter 0-10' },
    admin_threshold_set       = { zh = '门槛已设为 %d',              en = 'Threshold set to %d' },
    admin_wanted_cleared      = { zh = '通缉状态已完全清除（含元数据、雷达、犯罪记录）', en = 'Wanted status fully cleared' },
    admin_career_testing      = { zh = '🧪 career v2 联合测试...',   en = 'Career v2 test...' },
    admin_career_no_cache     = { zh = '❌ 无法读取身份缓存',        en = 'Cannot read identity cache' },
    admin_career_all_pass     = { zh = '🎉 career v2 测试全部通过！', en = 'Career v2 tests all passed!' },
    admin_identity_not_loaded = { zh = '身份信息未加载',             en = 'Identity not loaded' },

    -- crime
    crime_disabled            = { zh = '该犯罪玩法目前已禁用',       en = 'This crime activity is currently disabled' },
    crime_need_police         = { zh = '需要至少 %d 名执勤警察才能进行此活动', en = 'Requires at least %d police on duty' },
    crime_recently_robbed     = { zh = '该位置刚刚被抢过，目前没有任何有价值的财务', en = 'Recently robbed. Nothing valuable left.' },
    crime_delivery_cooldown   = { zh = '交付过于频繁，请等待 %d 秒', en = 'Too frequent. Wait %d seconds' },
    crime_min_launder         = { zh = '最低洗钱金额为 $%d',         en = 'Minimum laundering amount: $%d' },
    crime_not_enough_cash     = { zh = '现金不足，无法洗钱',         en = 'Not enough cash to launder' },
    crime_need_police_launder = { zh = '需要至少 %d 名执勤警察才能进行洗钱', en = 'Requires at least %d police to launder' },
    crime_launder_cooldown    = { zh = '洗钱冷却中，请等待 %d 秒',   en = 'Laundering cooldown. Wait %d seconds' },
    crime_launder_success     = { zh = '洗钱成功！$%d 已转入银行（折旧率: %.0f%%，损失: $%d）', en = 'Laundered! $%d to bank (rate: %.0f%%, loss: $%d)' },

    -- security
    security_too_frequent     = { zh = '您的操作过于频繁，请慢一点', en = 'Too fast. Please slow down' },
    security_no_car_perm      = { zh = '您没有权限生成此载具',       en = 'No permission to spawn this vehicle' },
    security_car_cooldown     = { zh = '召唤载具过于频繁，请稍等 5 秒', en = 'Vehicle spawn too frequent. Wait 5 seconds' },

    -- dispatch
    dispatch_wanted_blip       = { zh = '【通缉犯】%s (%d星)',       en = '[WANTED] %s (%d stars)' },
    dispatch_wanted_alert      = { zh = '【高星通缉】在逃犯 %s (%d星) 最后出现在 %s！', en = '[WANTED] Fugitive %s (%d stars) last seen at %s!' },
    dispatch_no_permission     = { zh = '你没有执行此命令的权限或尚未上岗！', en = 'No permission or not on duty!' },
    dispatch_invalid_id        = { zh = '请输入正确的玩家 ID！',      en = 'Enter a valid player ID!' },
    dispatch_player_offline    = { zh = '该玩家已离线！',             en = 'Player is offline!' },
    dispatch_wanted_cleared_by = { zh = '【通缉销案】嫌疑人 %s 的通缉已被警官 %s 销案清除！', en = '[CLEARED] %s wanted status cleared by Officer %s!' },
    dispatch_wanted_restored   = { zh = '【逃犯警告】你上次离线时处于 %d 星通缉，警方已恢复雷达定位！', en = '[WARNING] Your %d-star wanted level has been restored!' },
    dispatch_wanted_block_duty = { zh = '【执勤拦截】你当前处于通缉在逃状态，无法打卡上班或切换执勤状态！', en = 'Cannot clock in while wanted!' },
    dispatch_on_duty           = { zh = '你已成功进入【执勤上班】状态！', en = 'You are now ON DUTY' },
    dispatch_off_duty          = { zh = '你已成功进入【下班休息】状态！', en = 'You are now OFF DUTY' },
    dispatch_no_duty_switch    = { zh = '你当前的职业类型不支持上下班状态切换！', en = 'Your job does not support duty switching' },
    dispatch_wanted_block_clock= { zh = '【执勤拦截】你当前处于通缉在逃状态，无法打卡上班以逃避罪责！', en = 'Cannot clock in to evade wanted status!' },

    -- phone / gps
    phone_no_active_quest      = { zh = '⚠️ 当前无活跃任务，无法导航', en = 'No active quest to navigate' },
    phone_wrong_quest_location = { zh = '⚠️ 非本次任务地点（偏差 %.0fm），请确认当前任务', en = 'Wrong quest location (%.0fm off). Check current quest.' },
    phone_gps_set              = { zh = '📍 导航已设置: %s',         en = 'GPS set: %s' },
    phone_gps_active           = { zh = '📍 GPS 导航已激活: %s',     en = 'GPS active: %s' },
    phone_quest_complete_gps   = { zh = '📍 任务已完成，GPS 导航已清除', en = 'Quest complete. GPS cleared' },

    -- documents
    doc_showed                 = { zh = '📋 你出示了 %s',             en = 'You showed %s' },
    doc_no_cert                = { zh = '你身上没有该证件',           en = 'You do not have this certificate' },
    doc_serial_mismatch        = { zh = '⚠ 证件序列号异常，请联系管理员', en = 'Certificate serial mismatch. Contact admin' },

    -- testing
    test_no_permission         = { zh = '你没有权限运行测试',         en = 'No permission to run tests' },

    -- banking
    banking_open               = { zh = '[E] 打开银行账户',           en = '[E] Open Bank Account' },

    -- quest
    quest_target_locked        = { zh = '目标已被其他人抢先完成',     en = 'Target already claimed by another player' },

    -- unknown recipe
    unknown_recipe             = { zh = '未知配方',                   en = 'Unknown recipe' },

    -- storage (custom-main compat)
    storage_service_down       = { zh = '仓库服务不可用',             en = 'Storage unavailable' },
    storage_not_cartel         = { zh = '你不是 Cartel 成员',         en = 'Not a Cartel member' },
}