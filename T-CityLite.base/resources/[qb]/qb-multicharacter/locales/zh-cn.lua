local Translations = {
    notifications = {
        ["char_deleted"] = "角色已成功注销！",
        ["deleted_other_char"] = "您已成功注销公民 ID 为 %{citizenid} 的角色。",
        ["forgot_citizenid"] = "请输入公民 ID！",
    },

    commands = {
        -- /deletechar
        ["deletechar_description"] = "注销其他玩家的角色",
        ["citizenid"] = "公民 ID",
        ["citizenid_help"] = "您想要注销的角色的公民 ID",

        -- /logout
        ["logout_description"] = "登出当前角色（仅限管理员）",

        -- /closeNUI
        ["closeNUI_description"] = "关闭多角色 NUI 界面"
    },

    misc = {
        ["droppedplayer"] = "您已断开与 QBCore 的连接"
    },

    ui = {
        -- Main
        characters_header = "我的角色列表",
        emptyslot = "空角色槽",
        play_button = "进入游戏",
        create_button = "创建新角色",
        delete_button = "注销角色",

        -- Character Information
        charinfo_header = "角色详细信息",
        charinfo_description = "选择一个角色槽以查看关于该角色的所有详细信息。",
        name = "姓名",
        male = "男",
        female = "女",
        firstname = "名字",
        lastname = "姓氏",
        nationality = "国籍",
        gender = "性别",
        birthdate = "出生日期",
        job = "职业",
        jobgrade = "职级",
        cash = "现金",
        bank = "银行存款",
        phonenumber = "电话号码",
        accountnumber = "银行账号",

        chardel_header = "新角色注册",

        -- Delete character
        deletechar_header = "注销角色确认",
        deletechar_description = "您确定要彻底注销该角色吗？此操作无法撤销！",

        -- Buttons
        cancel = "取消",
        confirm = "确认",

        -- Loading Text
        retrieving_playerdata = "正在检索玩家数据",
        validating_playerdata = "正在验证玩家数据",
        retrieving_characters = "正在检索角色列表",
        validating_characters = "正在验证角色数据",

        -- Notifications
        ran_into_issue = "我们遇到了一个问题",
        profanity = "检测到您的名字或国籍中含有敏感词，请重新输入！",
        forgotten_field = "您似乎遗漏了必填字段，请完整填写！"
    }
}

Lang = Lang or Locale:new({
    phrases = Translations,
    warnOnMissing = true
})
