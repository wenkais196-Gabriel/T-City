local Translations = {
    error = {
        minimum_store_robbery_police = "Not Enough Police (%{MinimumStoreRobberyPolice} Required)",
        not_driver = "You Are Not The Driver",
        demolish_vehicle = "You Are Not Allowed To Demolish Vehicles Now",
        process_canceled = "Process canceled..",
        you_broke_the_lock_pick = "You Broke The Lock Pick",
    },
    text = {
        the_cash_register_is_empty = "The Cash Register Is Empty",
        try_combination = "~g~E~w~ - Try Combination",
        safe_opened = "Safe Opened",
        emptying_the_register= "Emptying The Register..",
        safe_code = "Safe Code: ",
        scouting_store = "Scouting Store..",
        looting_register = "Looting Register..",
        escape_choice = "Choose Escape Route",
        return_goods = "Return Stolen Goods",
        surrender_to_police = "Surrender to Police",
        conscience_reflect = "Reflect on Your Choices",
    },
    email = {
        shop_robbery = "10-31 | Shop Robbery",
        someone_is_trying_to_rob_a_store = "Someone Is Trying To Rob A Store At %{street} (CAMERA ID: %{cameraId1})",
        storerobbery_progress = "Storerobbery in progress",
        anonymous_return = "Thank You from the Store Owner",
        anonymous_return_desc = "Someone returned stolen goods anonymously. There is still kindness in this world.",
    },
    conscience = {
        monologue_good = "Your hands tremble as you hold the money. This isn't who you want to be.",
        monologue_mid = "The fear in the shopkeeper's eyes haunts you. Is this really what you want?",
        monologue_bad = "You can't tell right from wrong anymore. But someone is showing you another path.",
        surrender_hint = "Press ~g~G~w~ to call the surrender hotline",
        surrender_success = "⚖️ You surrendered. Conscience +50, reward coefficient up for 30 min.",
    },
}

Lang = Lang or Locale:new({
    phrases = Translations,
    warnOnMissing = true
})
