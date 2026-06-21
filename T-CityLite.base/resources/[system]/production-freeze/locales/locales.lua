-- ============================================================================
-- locales.lua — 全服统一中英文语言包 v1.0
-- ============================================================================
-- 使用: _L('key') → 根据玩家 GTA5 语言自动返回 zh 或 en
-- 规则: GetCurrentLanguage() == 12 (简体中文) → zh, 其余 → en (兜底)
-- ============================================================================

return {
    -- ── 通用 UI ──────────────────────────────────────────────────────
    ui_yes               = { zh = '是',           en = 'Yes' },
    ui_no                = { zh = '否',           en = 'No' },
    ui_confirm           = { zh = '确认',         en = 'Confirm' },
    ui_cancel            = { zh = '取消',         en = 'Cancel' },
    ui_close             = { zh = '关闭',         en = 'Close' },
    ui_back              = { zh = '返回',         en = 'Back' },
    ui_loading           = { zh = '加载中...',    en = 'Loading...' },
    ui_error             = { zh = '错误',         en = 'Error' },
    ui_success           = { zh = '成功',         en = 'Success' },
    ui_warning           = { zh = '警告',         en = 'Warning' },
    ui_none              = { zh = '无',           en = 'None' },

    -- ── 通知 ────────────────────────────────────────────────────────
    notify_insufficient_funds  = { zh = '余额不足',             en = 'Insufficient funds' },
    notify_item_received       = { zh = '获得: %s ×%d',         en = 'Received: %s ×%d' },
    notify_item_removed        = { zh = '失去: %s ×%d',         en = 'Lost: %s ×%d' },
    notify_reward_granted      = { zh = '奖励已发放: $%d',      en = 'Reward granted: $%d' },
    notify_quest_accepted      = { zh = '任务已接取: %s',       en = 'Quest accepted: %s' },
    notify_quest_completed     = { zh = '任务完成: %s!',        en = 'Quest completed: %s!' },
    notify_quest_failed        = { zh = '任务失败: %s',         en = 'Quest failed: %s' },
    notify_quest_abandoned     = { zh = '任务已放弃',           en = 'Quest abandoned' },
    notify_step_completed      = { zh = '步骤完成: %s',         en = 'Step completed: %s' },
    notify_target_locked       = { zh = '目标已被其他人抢先完成', en = 'Target already claimed by another player' },
    notify_too_far             = { zh = '距离目标太远',         en = 'Too far from target' },
    notify_wrong_vehicle       = { zh = '需要正确的载具',       en = 'Wrong vehicle required' },
    notify_missing_items       = { zh = '缺少所需物品: %s ×%d', en = 'Missing required items: %s ×%d' },
    notify_cooldown            = { zh = '冷却中，剩余 %d 分钟',  en = 'On cooldown, %d min remaining' },
    notify_max_quests          = { zh = '已达到最大任务数 (%d)', en = 'Maximum quests reached (%d)' },

    -- ── 任务节点 ────────────────────────────────────────────────────
    node_goto_label         = { zh = '前往目标地点',    en = 'Go to destination' },
    node_interact_label     = { zh = '按 ~g~E~s~ 交互', en = 'Press ~g~E~s~ to interact' },
    node_interact_progress  = { zh = '交互中...',       en = 'Interacting...' },
    node_deliver_label      = { zh = '送达点',          en = 'Delivery point' },
    node_combat_label       = { zh = '消灭敌人',        en = 'Eliminate hostiles' },
    node_combat_progress    = { zh = '已消灭: %d/%d',   en = 'Eliminated: %d/%d' },
    node_combat_done        = { zh = '全部敌人已消灭!',  en = 'All hostiles eliminated!' },
    node_wait_label         = { zh = '坚守位置',        en = 'Hold position' },
    node_wait_progress      = { zh = '坚守 %d 秒...',   en = 'Hold for %d more seconds...' },
    node_wait_done          = { zh = '坚守完成!',       en = 'Hold complete!' },
    node_wait_left_area     = { zh = '你离开了区域! 计时重置.', en = 'You left the area! Timer reset.' },
    node_completed          = { zh = '✅ %s 完成!',     en = '✅ %s completed!' },

    -- ── 经济 ────────────────────────────────────────────────────────
    econ_purchase_tax       = { zh = '车辆购置税: $%d',       en = 'Vehicle purchase tax: $%d' },
    econ_transfer_tax       = { zh = '过户印花税: $%d',       en = 'Transfer stamp duty: $%d' },
    econ_insurance_renewed  = { zh = '车辆保险已续期: $%d (%d小时有效)', en = 'Insurance renewed: $%d (valid %dh)' },
    econ_insurance_expired  = { zh = '车辆保险已过期! 需 $%d 才能呼出.', en = 'Insurance expired! $%d required.' },
    econ_overhaul_needed    = { zh = '引擎需要大修! 费用 $%d. 性能已下降.', en = 'Engine overhaul needed! $%d. Performance reduced.' },
    econ_overhaul_done      = { zh = '引擎大修完成: $%d',     en = 'Engine overhaul complete: $%d' },
    econ_property_tax       = { zh = '房产税: $%d 已处理 (%d套房产)', en = 'Property tax: $%d processed (%d houses)' },
    econ_property_foreclose = { zh = '🏚️ 因欠税, 一处房产已被充公!', en = '🏚️ Property foreclosed due to unpaid taxes!' },
    econ_property_warning   = { zh = '⚠️ %s 税款逾期! 欠费 $%d. 再有 %d 次将充公.', en = '⚠️ %s tax overdue! $%d due. Foreclosure in %d cycles.' },
    econ_large_transfer_tax = { zh = '大额转账税: $%d (5%% of $%d)', en = 'Large transfer tax: $%d (5%% of $%d)' },
    econ_atm_fee            = { zh = 'ATM 手续费: $%d',       en = 'ATM service fee: $%d' },

    -- ── 组队 ────────────────────────────────────────────────────────
    group_joined            = { zh = '已加入任务组队. 队长: %d | 成员: %d', en = 'Joined quest group. Leader: %d | Members: %d' },
    group_left              = { zh = '你已被移出队伍. 原因: %s',  en = 'Removed from group. Reason: %s' },
    group_member_joined     = { zh = '玩家 %d 加入了队伍.',    en = 'Player %d joined the group.' },
    group_member_left       = { zh = '玩家 %d 离开了队伍.',    en = 'Player %d left the group.' },
    group_disbanded         = { zh = '队伍已解散: %s',         en = 'Group disbanded: %s' },

    -- ── 交互 / 道具 ─────────────────────────────────────────────────
    interact_mine           = { zh = '[E] 采集 %s',            en = '[E] Mine %s' },
    interact_search         = { zh = '[E] 搜索',              en = '[E] Search' },
    interact_pickup         = { zh = '[E] 拾取',              en = '[E] Pick up' },
    item_broken             = { zh = '%s 已损坏并被销毁!',     en = '%s has broken and been destroyed!' },
    item_low_durability     = { zh = '⚠️ %s 耐久度低: %d/%d',  en = '⚠️ %s durability low: %d/%d' },
    item_repaired           = { zh = '%s 已修复至满耐久, 费用 $%d', en = '%s repaired to full durability for $%d' },

    -- ── 仪表盘 ──────────────────────────────────────────────────────
    dash_title              = { zh = '📊 经济仪表盘',         en = '📊 Economy Dashboard' },
    dash_cashflow           = { zh = '💰 现金流: 入 $%d | 出 $%d | 净 $%d | Sink %.1f%%', en = '💰 Cash: In $%d | Out $%d | Net $%d | Sink %.1f%%' },
    dash_multiplier         = { zh = '📈 全局乘数: %.2f',     en = '📈 Global Multiplier: %.2f' },
    dash_assets             = { zh = '🏠 房产: %d | 🚗 载具: %d', en = '🏠 Houses: %d | 🚗 Vehicles: %d' },
    dash_hotrank            = { zh = '🔥 热门活动排行',       en = '🔥 Activity Heat Ranking' },
    dash_report_generated   = { zh = '周报已生成! 查看 data/telemetry_weekly.json', en = 'Weekly report generated! Check data/telemetry_weekly.json' },

    -- ── 安全 ────────────────────────────────────────────────────────
    security_cheat_blocked  = { zh = '操作被拒绝 (安全校验)',  en = 'Action blocked (security check)' },
    security_rate_limit     = { zh = '请稍后再试',             en = 'Please wait before trying again' },
    security_exploit_ban    = { zh = '作弊行为已被记录',       en = 'Exploit attempt logged' },

    -- ── cartel ──────────────────────────────────────────────────────
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
    cartel_storage_down       = { zh = '仓库服务不可用',             en = 'Storage service unavailable' },

    -- ── justice / prison ────────────────────────────────────────────
    justice_prison_remaining  = { zh = '你在监狱中，剩余刑期: %d 分钟', en = 'You are in prison. Remaining: %d minutes' },
    justice_prison_soon       = { zh = '还有 %d 分钟出狱',           en = '%d minutes until release' },
    justice_released          = { zh = '你已出狱，重新获得自由！',   en = 'You have been released!' },
    justice_imprisoned        = { zh = '你已被判入狱 %d 分钟',       en = 'You have been sentenced to %d minutes in prison' },
    justice_visit_request     = { zh = '%s 请求探视你',              en = '%s is requesting to visit you' },
    justice_inmate_row        = { zh = '%s | 剩余: %d分钟 | 状态: %s', en = '%s | Remaining: %d min | Status: %s' },
    justice_inmates_title     = { zh = '在押囚犯',                  en = 'Inmates' },
    justice_offline           = { zh = '离线',                      en = 'Offline' },
    justice_online            = { zh = '在线',                      en = 'Online' },
    justice_verdict_judge     = { zh = '已判决 %s | 刑期: %d分钟 | 罚款: $%d', en = 'Sentenced: %s | %d min | Fine: $%d' },
    justice_verdict_lawyer    = { zh = '案件 %s 已判决 | 刑期: %d分钟 (原始:%d, 减刑:%d)', en = 'Case %s verdict: %d min (original: %d, reduced: %d)' },
    justice_pending_cases     = { zh = '待审案件',                  en = 'Pending Cases' },
    justice_pending           = { zh = '待接案',                    en = 'Pending' },
    justice_assigned          = { zh = '已指定',                    en = 'Assigned' },
    justice_no_charge         = { zh = '请指定至少一项罪名',         en = 'Please specify at least one charge' },
    justice_invalid_charge    = { zh = '无效的罪名',                 en = 'Invalid charge' },
    justice_lawyer_only       = { zh = '只有律师可以接案',           en = 'Only lawyers can take cases' },
    justice_case_not_found    = { zh = '案件不存在或已关闭',         en = 'Case not found or closed' },
    justice_case_taken        = { zh = '此案件已有律师处理',         en = 'This case already has a lawyer' },
    justice_case_accepted     = { zh = '你已接受案件 %s | 嫌疑人: %s', en = 'Case accepted: %s | Suspect: %s' },
    justice_arrested          = { zh = '你已被逮捕！指控: %s | 基础刑期: %d 分钟', en = 'You are under arrest! Charges: %s | Base sentence: %d min' },
    justice_case_registered   = { zh = '案件 %s 已登记 | 嫌疑人: %s | 律师: %s', en = 'Case %s registered | Suspect: %s | Lawyer: %s' },
    justice_lawyer_assigned   = { zh = '律师 %s 已接受你的案件！将为你争取减刑', en = 'Lawyer %s has taken your case! They will defend you' },
    justice_case_taken_by     = { zh = '案件 %s 已被律师 %s 接走', en = 'Case %s has been taken by Lawyer %s' },
    justice_arrest_usage      = { zh = '用法: /arrest [玩家ID] [罪名1,罪名2]', en = 'Usage: /arrest [playerID] [charge1,charge2]' },
    justice_lawyer_notified   = { zh = '已通知', en = 'Notified' },
    justice_no_lawyer_online  = { zh = '无在线律师', en = 'No lawyer online' },
    justice_yes               = { zh = '是', en = 'Yes' },
    justice_no                = { zh = '否', en = 'No' },
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

    -- ── mining ──────────────────────────────────────────────────────
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
    unknown_recipe            = { zh = '未知配方',                   en = 'Unknown recipe' },

    -- ── storage ─────────────────────────────────────────────────────
    storage_no_job            = { zh = '你当前无业，没有职业仓库可用', en = 'No job storage available (unemployed)' },
    storage_no_org            = { zh = '未找到所属组织',             en = 'Organization not found' },
    storage_no_gang           = { zh = '你没有加入任何帮派',         en = 'Not in a gang' },
    storage_no_gang_org       = { zh = '未找到所属帮派组织',         en = 'Gang organization not found' },
    storage_service_down      = { zh = '仓库服务不可用',             en = 'Storage unavailable' },

    -- ── crime ───────────────────────────────────────────────────────
    crime_disabled            = { zh = '该犯罪玩法目前已禁用',       en = 'This crime activity is currently disabled' },
    crime_need_police         = { zh = '需要至少 %d 名执勤警察才能进行此活动', en = 'Requires at least %d police on duty' },
    crime_recently_robbed     = { zh = '该位置刚刚被抢过，目前没有任何有价值的财务', en = 'Recently robbed. Nothing valuable left.' },
    crime_delivery_cooldown   = { zh = '交付过于频繁，请等待 %d 秒', en = 'Too frequent. Wait %d seconds' },
    crime_min_launder         = { zh = '最低洗钱金额为 $%d',         en = 'Minimum laundering amount: $%d' },
    crime_not_enough_cash     = { zh = '现金不足，无法洗钱',         en = 'Not enough cash to launder' },
    crime_need_police_launder = { zh = '需要至少 %d 名执勤警察才能进行洗钱', en = 'Requires at least %d police to launder' },
    crime_launder_cooldown    = { zh = '洗钱冷却中，请等待 %d 秒',   en = 'Laundering cooldown. Wait %d seconds' },
    crime_launder_success     = { zh = '洗钱成功！$%d 已转入银行（折旧率: %.0f%%，损失: $%d）', en = 'Laundered! $%d to bank (rate: %.0f%%, loss: $%d)' },
    crime_tier_max            = { zh = '该层级单次最多洗 $%d',       en = 'This tier max $%d per transaction' },
    crime_tier_cooldown       = { zh = '%s 冷却中，请等待 %d 秒',   en = '%s cooldown: wait %d seconds' },

    -- ── security ────────────────────────────────────────────────────
    security_too_frequent     = { zh = '您的操作过于频繁，请慢一点', en = 'Too fast. Please slow down' },
    security_no_car_perm      = { zh = '您没有权限生成此载具',       en = 'No permission to spawn this vehicle' },
    security_car_cooldown     = { zh = '召唤载具过于频繁，请稍等 5 秒', en = 'Vehicle spawn too frequent. Wait 5 seconds' },

    -- ── dispatch ────────────────────────────────────────────────────
    dispatch_wanted_blip       = { zh = '【通缉犯】%s (%d星)',       en = '[WANTED] %s (%d stars)' },
    dispatch_wanted_alert      = { zh = '【高星通缉】在逃犯 %s (%d星) 最后出现在 %s！', en = '[WANTED] Fugitive %s (%d stars) last seen at %s!' },
    dispatch_no_permission     = { zh = '你没有执行此命令的权限或尚未上岗！', en = 'No permission or not on duty!' },
    dispatch_invalid_id        = { zh = '请输入正确的玩家 ID！',      en = 'Enter a valid player ID!' },
    dispatch_player_offline    = { zh = '该玩家已离线！',             en = 'Player is offline!' },
    dispatch_wanted_cleared_by = { zh = '【通缉销案】嫌疑人 %s 的通缉已被警官 %s 销案清除！', en = '[CLEARED] %s wanted status cleared by Officer %s!' },
    dispatch_wanted_restored   = { zh = '【逃犯警告】你上次离线时处于 %d 星通缉，警方已恢复雷达定位！', en = '[WARNING] Your %d-star wanted level has been restored!' },
    dispatch_stars_transfer   = { zh = '【警星移交】你的警星达到 %d 星！NPC 警车已撤退，通缉权已移交玩家警察！', en = '[WANTED] %d stars! NPC patrols withdrawn — player police now tracking you!' },
    dispatch_heli_tracking    = { zh = '【警用直升机】你的 GPS 信号正被警方基站雷达三角定位，位置已被广播！', en = '[HELI] Police helicopter is tracking your GPS signal!' },
    dispatch_wanted_cleared   = { zh = '你已被解除通缉，警方的雷达定位信号已消失。', en = 'Your wanted status has been cleared. Police tracking disabled.' },
    career_identity_title     = { zh = '你的身份', en = 'Your Identity' },
    dispatch_wanted_block_duty = { zh = '【执勤拦截】你当前处于通缉在逃状态，无法打卡上班或切换执勤状态！', en = 'Cannot clock in while wanted!' },
    dispatch_on_duty           = { zh = '你已成功进入【执勤上班】状态！', en = 'You are now ON DUTY' },
    dispatch_off_duty          = { zh = '你已成功进入【下班休息】状态！', en = 'You are now OFF DUTY' },
    dispatch_no_duty_switch    = { zh = '你当前的职业类型不支持上下班状态切换！', en = 'Your job does not support duty switching' },
    dispatch_wanted_block_clock= { zh = '【执勤拦截】你当前处于通缉在逃状态，无法打卡上班以逃避罪责！', en = 'Cannot clock in to evade wanted status!' },

    -- ── phone / gps ─────────────────────────────────────────────────
    phone_no_active_quest      = { zh = '⚠️ 当前无活跃任务，无法导航', en = 'No active quest to navigate' },
    phone_wrong_quest_location = { zh = '⚠️ 非本次任务地点（偏差 %.0fm），请确认当前任务', en = 'Wrong quest location (%.0fm off). Check current quest.' },
    phone_gps_set              = { zh = '📍 导航已设置: %s',         en = 'GPS set: %s' },
    phone_gps_active           = { zh = '📍 GPS 导航已激活: %s',     en = 'GPS active: %s' },
    phone_quest_complete_gps   = { zh = '📍 任务已完成，GPS 导航已清除', en = 'Quest complete. GPS cleared' },

    -- ── documents ───────────────────────────────────────────────────
    doc_showed                 = { zh = '📋 你出示了 %s',             en = 'You showed %s' },
    doc_no_cert                = { zh = '你身上没有该证件',           en = 'You do not have this certificate' },
    doc_serial_mismatch        = { zh = '⚠ 证件序列号异常，请联系管理员', en = 'Certificate serial mismatch. Contact admin' },

    -- ── admin ───────────────────────────────────────────────────────
    admin_id_printed          = { zh = '你的标识符已打印到聊天窗口', en = 'Identifiers printed to chat' },
    admin_current_threshold   = { zh = '当前门槛: %s',               en = 'Current threshold: %s' },
    admin_reset_to_2          = { zh = '已重置为 2',                 en = 'Reset to 2' },
    admin_invalid_0_10        = { zh = '无效，请输入 0-10',          en = 'Invalid. Enter 0-10' },
    admin_threshold_set       = { zh = '门槛已设为 %d',              en = 'Threshold set to %d' },
    admin_wanted_cleared      = { zh = '通缉状态已完全清除',         en = 'Wanted status fully cleared' },
    admin_career_no_cache     = { zh = '❌ 无法读取身份缓存',        en = 'Cannot read identity cache' },
    admin_identity_not_loaded = { zh = '身份信息未加载',             en = 'Identity not loaded' },

    -- ── market ──────────────────────────────────────────────────────
    market_no_category        = { zh = '没有找到分类: %s',           en = 'Category not found: %s' },
    market_setprice_usage     = { zh = '用法: /marketsetprice [商品名] [价格]', en = 'Usage: /marketsetprice [item] [price]' },
    market_unknown_item       = { zh = '未知商品: %s',               en = 'Unknown item: %s' },
    market_price_set          = { zh = '%s 价格已设为 $%d',          en = '%s price set to $%d' },

    -- ── testing ─────────────────────────────────────────────────────
    test_no_permission         = { zh = '你没有权限运行测试',         en = 'No permission to run tests' },

    -- ── banking ─────────────────────────────────────────────────────
    banking_open               = { zh = '[E] 打开银行账户',           en = '[E] Open Bank Account' },

    -- ── quest ───────────────────────────────────────────────────────
    quest_target_locked        = { zh = '目标已被其他人抢先完成',     en = 'Target already claimed by another player' },

    -- ── blip 分类标签 (map sidebar) ─────────────────────────────────
    blip_cat_parking        = { zh = '公共停车场',       en = 'Public Parking' },
    blip_cat_police         = { zh = '警察局',           en = 'Police Stations' },
    blip_cat_hospitals      = { zh = '医院',             en = 'Hospitals' },
    blip_cat_gang_hqs       = { zh = '帮派据点',         en = 'Gang HQs' },
    blip_cat_hangars        = { zh = '机库',             en = 'Hangars' },
    blip_cat_boathouses     = { zh = '船坞',             en = 'Boathouses' },
    blip_cat_depots         = { zh = '扣押场',           en = 'Depots' },
    blip_cat_shops          = { zh = '商店',             en = 'Shops' },
    blip_title              = { zh = '地图标记',         en = 'Map Markers' },

    -- ── 警察局 blip ────────────────────────────────────────────────
    blip_police_mission_row = { zh = '警察局 (Mission Row)',   en = 'Police Station (Mission Row)' },
    blip_police_paleto      = { zh = '警察局 (Paleto)',        en = 'Police Station (Paleto)' },
    blip_police_sandy       = { zh = '警察局 (Sandy Shores)',  en = 'Police Station (Sandy Shores)' },
    blip_prison             = { zh = '监狱',                    en = 'Prison' },

    -- ── 帮派据点 blip ──────────────────────────────────────────────
    blip_cartel_hq          = { zh = '卡特尔总部',              en = 'Cartel HQ' },
    blip_cartel_garage      = { zh = '卡特尔车库',              en = 'Cartel Garage' },
    blip_cartel_boss        = { zh = '卡特尔首脑控制台',        en = 'Cartel Boss Suite' },
    blip_ballas_hq          = { zh = '巴拉斯总部',              en = 'Ballas HQ' },
    blip_families_hq        = { zh = '家族帮总部',              en = 'Families HQ' },
    blip_lostmc_hq          = { zh = '失落摩托总部',            en = 'Lost MC HQ' },
    blip_vagos_hq           = { zh = '维戈斯总部',              en = 'Vagos HQ' },

    -- ── 公共停车场 blip ────────────────────────────────────────────
    blip_parking_motel          = { zh = 'Motel 停车场',          en = 'Motel Parking' },
    blip_parking_casino         = { zh = '赌场停车场',            en = 'Casino Parking' },
    blip_parking_san_andreas    = { zh = 'San Andreas 停车场',    en = 'San Andreas Parking' },
    blip_parking_spanish        = { zh = 'Spanish Ave 停车场',    en = 'Spanish Ave Parking' },
    blip_parking_caears24       = { zh = 'Caears 24 停车场',      en = 'Caears 24 Parking' },
    blip_parking_caears242      = { zh = 'Caears 24 停车场 #2',   en = 'Caears 24 Parking #2' },
    blip_parking_laguna         = { zh = 'Laguna 停车场',         en = 'Laguna Parking' },
    blip_parking_airport        = { zh = '机场停车场',            en = 'Airport Parking' },
    blip_parking_beach          = { zh = '海滩停车场',            en = 'Beach Parking' },
    blip_parking_motor_hotel    = { zh = 'Motor Hotel 停车场',    en = 'The Motor Hotel Parking' },
    blip_parking_liqour         = { zh = 'Liqour 停车场',         en = 'Liqour Parking' },
    blip_parking_shore          = { zh = 'Shore 停车场',          en = 'Shore Parking' },
    blip_parking_bell_farms     = { zh = 'Bell Farms 停车场',     en = 'Bell Farms Parking' },
    blip_parking_dumbo          = { zh = 'Dumbo 停车场',          en = 'Dumbo Private Parking' },
    blip_parking_pillbox        = { zh = 'Pillbox 停车场',        en = 'Pillbox Garage Parking' },
    blip_parking_grapeseed      = { zh = 'Grapeseed 停车场',      en = 'Grapeseed Parking' },

    -- ── 医院 blip ──────────────────────────────────────────────────
    blip_hospital_pillbox       = { zh = 'Pillbox 医院',         en = 'Pillbox Hospital' },
    blip_hospital_sandy         = { zh = 'Sandy Shores 医疗中心', en = 'Sandy Shores Medical' },
    blip_hospital_paleto        = { zh = 'Paleto Bay 医疗中心',  en = 'Paleto Bay Medical' },

    -- ── 司法 blip ──────────────────────────────────────────────────
    blip_courthouse             = { zh = '法院',           en = 'Courthouse' },
    blip_state_prison           = { zh = '州立监狱',       en = 'State Prison' },

    -- ── 采矿 blip ──────────────────────────────────────────────────
    blip_quarry                 = { zh = '砂石场',         en = 'Quarry' },
    blip_mountain               = { zh = '山区矿脉',       en = 'Mountain Vein' },
    blip_desert                 = { zh = '煤矿',           en = 'Coal Mine' },
    blip_coast                  = { zh = '海岸矿场',       en = 'Coastal Site' },
    blip_smelter                = { zh = '冶炼厂',         en = 'Smelter' },

    -- ── 通缉 / 警察 blip ─────────────────────────────────────────────
    blip_wanted_suspect         = { zh = '【通缉犯】%s (%d星)',       en = '【WANTED】%s (%d stars)' },

    -- ── 毒品 / 珠宝 / 回收 / 洗车 blip ───────────────────────────────
    blip_drugs_buyer            = { zh = '买家',               en = 'Buyer' },
    blip_vangelico_jewelry      = { zh = 'Vangelico 珠宝店',  en = 'Vangelico Jewelry' },
    blip_recycle_center         = { zh = '回收中心',           en = 'Recycle Center' },
    blip_carwash                = { zh = '自助洗车',           en = 'Hands Free Carwash' },

    -- ── 商店抢劫 blip ───────────────────────────────────────────────
    blip_surrender              = { zh = '⚖️ 自首: %s',        en = '⚖️ Surrender: %s' },

    -- ── 运钞车 blip ─────────────────────────────────────────────────
    blip_truckrobbery_assault   = { zh = '运钞车袭击',         en = 'Assault on the transport of cash' },
    blip_truckrobbery_10_90     = { zh = '10-90: 运钞车抢劫',  en = '10-90: Armored Truck Robbery' },
    blip_truckrobbery_van       = { zh = '运钞车',             en = 'Van with Cash' },

    -- ── 葡萄园 / 任务 blip ────────────────────────────────────────────
    blip_vineyard_dropoff       = { zh = '交货点',             en = 'Drop Off' },
    blip_quest_target           = { zh = '任务目标',           en = 'Quest Target' },
    blip_atom_target            = { zh = '目标',               en = 'Target' },

    -- ── internal ────────────────────────────────────────────────────
    _lang                   = { zh = 'zh',  en = 'en' },
}
