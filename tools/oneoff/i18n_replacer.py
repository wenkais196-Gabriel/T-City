#!/usr/bin/env python3
"""i18n_replacer.py — 批量将硬编码中文替换为 _L() 调用"""
import re, os, sys

BASE = r"T-CityLite.base/resources"

# 从 locales.lua 读取的中文→key 映射 (手工维护, 精确匹配)
MAP = {
    # cartel
    "'供应商暂时缺货'": "_L('cartel_supplier_empty')",
    "'暂时没有可接的任务'": "_L('cartel_no_quests')",
    "'你离实验室太远了'": "_L('cartel_too_far_lab')",
    "'没有可用的配方'": "_L('cartel_no_recipe')",
    ('开始生产 %s...'): "_L('cartel_production_start', data.label)",
    "'生产失败！操作失误'": "_L('cartel_production_fail')",
    "'生产已取消'": "_L('cartel_production_cancel')",
    "'Cartel 系统已禁用'": "_L('cartel_disabled')",
    "'你不是 Cartel 成员'": "_L('cartel_not_member')",
    "'未知配方: ' .. tostring(recipeId)": "_L('cartel_unknown_recipe', tostring(recipeId))",
    "'安全校验失败: ' .. (err or 'unknown')": "_L('cartel_security_fail', err or 'unknown')",
    "'配方数据异常'": "_L('cartel_recipe_error')",
    "'身份校验失败'": "_L('cartel_identity_fail')",
    "'仓库服务不可用'": "_L('cartel_storage_down')",
    "'当前没有 Cartel 成员在线'": "_L('cartel_no_members_online')",
    "'你不是 Cartel 成员，供应商不与你交易'": "_L('cartel_supplier_refuse')",
    "'无效的供应商'": "_L('cartel_invalid_supplier')",
    "'该供应商不卖此物品'": "_L('cartel_not_sell_item')",
    "'供应商库存不足'": "_L('cartel_supplier_no_stock')",
    "'无效的分销商'": "_L('cartel_invalid_distributor')",
    "'分销商不收这种货'": "_L('cartel_not_buy_item')",
    "'你不是 Cartel 成员，分销商不与你交易'": "_L('cartel_distributor_refuse')",
    "'你没有足够的 %s'": None,  # 需要特殊处理
    "'Cartel 毒品活动'": "_L('cartel_blip')",

    # mining
    "'你离矿点太远了'": "_L('mining_too_far')",
    "'你离开了矿点区域'": "_L('mining_left_area')",
    "'采矿已停止'": "_L('mining_stopped')",
    "'只有矿业公司员工才能采矿'": "_L('mining_staff_only')",
    "'矿业系统已禁用'": "_L('mining_disabled')",
    "'你需要一把矿镐才能采矿'": "_L('mining_need_pickaxe')",
    "'你离冶炼厂太远了'": "_L('mining_smelter_too_far')",
    "'没有可用的冶炼配方'": "_L('mining_no_smelt_recipe')",
    "'冶炼已取消'": "_L('mining_smelt_cancelled')",
    "'只有矿业公司员工才能使用冶炼厂'": "_L('mining_smelter_staff_only')",
    "'未知配方'": "_L('unknown_recipe')",

    # justice
    "'请指定至少一项罪名'": "_L('justice_no_charge')",
    "'无效的罪名'": "_L('justice_invalid_charge')",
    "'只有律师可以接案'": "_L('justice_lawyer_only')",
    "'案件不存在或已关闭'": "_L('justice_case_not_found')",
    "'此案件已有律师处理'": "_L('justice_case_taken')",
    "'你不在监狱系统中'": "_L('justice_not_in_prison')",
    "'无效的减刑类型'": "_L('justice_invalid_reduction')",
    "'你已经使用过此减刑'": "_L('justice_already_used')",
    "'刑期已满，你被释放了！'": "_L('justice_sentence_done')",
    "'囚犯当前不在线'": "_L('justice_inmate_offline')",
    "'该囚犯不在监狱系统中'": "_L('justice_not_inmate')",
    "'只有警察或法官可以查看'": "_L('justice_police_only')",
    "'当前没有在押囚犯'": "_L('justice_no_inmates')",
    "'只有法官可以开庭'": "_L('justice_judge_only')",
    "'此案已结'": "_L('justice_case_closed')",
    "'当前没有待审案件'": "_L('justice_no_pending')",
    "'只有法官或律师可以查看案件'": "_L('justice_lawyer_judge_only')",
    "'用法: /arrest [玩家ID] [罪名1,罪名2]'": "_L('justice_arrest_usage')",

    # storage
    "'你当前无业，没有职业仓库可用'": "_L('storage_no_job')",
    "'未找到所属组织'": "_L('storage_no_org')",
    "'你没有加入任何帮派'": "_L('storage_no_gang')",
    "'未找到所属帮派组织'": "_L('storage_no_gang_org')",

    # crime
    "'该犯罪玩法目前已禁用'": "_L('crime_disabled')",
    "'该位置刚刚被抢过，目前没有任何有价值的财务'": "_L('crime_recently_robbed')",
    "'现金不足，无法洗钱'": "_L('crime_not_enough_cash')",

    # security
    "'您的操作过于频繁，请慢一点'": "_L('security_too_frequent')",
    "'您没有权限生成此载具'": "_L('security_no_car_perm')",
    "'召唤载具过于频繁，请稍等 5 秒'": "_L('security_car_cooldown')",

    # admin
    "'你的标识符已打印到聊天窗口'": "_L('admin_id_printed')",
    "'已重置为 2'": "_L('admin_reset_to_2')",
    "'无效，请输入 0-10'": "_L('admin_invalid_0_10')",
    "'通缉状态已完全清除（含元数据、雷达、犯罪记录）'": "_L('admin_wanted_cleared')",
    "'❌ 无法读取身份缓存'": "_L('admin_career_no_cache')",
    "'身份信息未加载'": "_L('admin_identity_not_loaded')",

    # market
    "'用法: /marketsetprice [商品名] [价格]'": "_L('market_setprice_usage')",
    "'未知商品: ' .. itemName": "_L('market_unknown_item', itemName)",

    # dispatch
    "'你没有执行此命令的权限或尚未上岗！'": "_L('dispatch_no_permission')",
    "'请输入正确的玩家 ID！'": "_L('dispatch_invalid_id')",
    "'该玩家已离线！'": "_L('dispatch_player_offline')",
    "'你当前的职业类型不支持上下班状态切换！'": "_L('dispatch_no_duty_switch')",
    "'你已成功进入【执勤上班】状态！'": "_L('dispatch_on_duty')",
    "'你已成功进入【下班休息】状态！'": "_L('dispatch_off_duty')",

    # phone
    "'⚠️ 当前无活跃任务，无法导航'": "_L('phone_no_active_quest')",
    "'📍 任务已完成，GPS 导航已清除'": "_L('phone_quest_complete_gps')",

    # documents
    "'你身上没有该证件'": "_L('doc_no_cert')",
    "'⚠ 证件序列号异常，请联系管理员'": "_L('doc_serial_mismatch')",

    # testing
    "'你没有权限运行测试'": "_L('test_no_permission')",

    # banking
    "'[E] 打开银行账户'": "_L('banking_open')",

    # quest
    "'目标已被其他人抢先完成'": "_L('quest_target_locked')",
}

def replace_in_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    original = content
    for old, new in MAP.items():
        if new is None: continue
        content = content.replace(old, new)
    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False

if __name__ == '__main__':
    count = 0
    for root, dirs, files in os.walk(BASE):
        dirs[:] = [d for d in dirs if d not in ('node_modules','locale','locales','cache','.git')]
        for f in files:
            if f.endswith('.lua'):
                fp = os.path.join(root, f)
                if replace_in_file(fp):
                    count += 1
                    print(f'  ✅ {fp}')
    print(f'\n  Done. {count} files updated.')
