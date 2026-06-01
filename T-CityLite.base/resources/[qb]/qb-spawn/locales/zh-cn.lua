local Translations = {
    ui = {
        last_location = "上次离线位置",
        confirm = "确认选点",
        where_would_you_like_to_start = "您想要在哪里开始您的旅程？",
    }
}

Lang = Lang or Locale:new({
    phrases = Translations,
    warnOnMissing = true
})
