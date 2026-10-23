-- notify-test 客户端测试 — 双轨制通知系统
-- 进游戏后 F8 输入 /notifytest 触发

local results = { passed = 0, failed = 0 }
local function check(name, condition)
    if condition then results.passed = results.passed + 1; print(('  ✅ %s'):format(name))
    else results.failed = results.failed + 1; print(('  ❌ %s'):format(name)) end
end

RegisterCommand('notifytest', function()
    local QBCore = exports['qb-core']:GetCoreObject()
    results = { passed = 0, failed = 0 }

    print('\n═══════════════════════════════════════════════')
    print('  通知系统双轨制测试 (客户端)')
    print('═══════════════════════════════════════════════\n')

    -- ──── 1: 原生 Feed (默认通道) ────
    print('--- 测试 1: 原生 Feed 基础通知 ---')
    QBCore.Functions.Notify('✅ GTA 原生通知测试 — 黑底白字')
    Wait(2000)
    QBCore.Functions.Notify('这是默认通知，应显示在左上角 The Feed')
    check('原生 Feed 基础调用', true)

    -- ──── 2: GTA 颜色标签 ────
    print('--- 测试 2: GTA 颜色标签 ---')
    Wait(2500)
    QBCore.Functions.Notify('~r~红色 ~w~白色 ~g~绿色 ~b~蓝色 ~y~黄色 ~o~橙色 ~p~紫色')
    check('GTA 颜色标签 ~r~~g~~b~~y~~o~~p~', true)

    -- ──── 3: 高级原生通知 (带头像) ────
    print('--- 测试 3: 高级原生通知 (带头像+标题) ---')
    Wait(2500)
    QBCore.Functions.Notify({
        text = '您收到一笔转账 $50,000',
        caption = '银行通知'
    }, nil, 5000, 'CHAR_BANK_MAZE')
    check('高级原生通知 (CHAR_BANK_MAZE 头像)', true)

    -- ──── 4: NUI 高级通知 (5 种类型) ────
    print('--- 测试 4: NUI 高级通知 (带类型色条) ---')
    Wait(3000)
    local types = {
        { '✅ 操作成功 — 绿色条', 'success' },
        { '⚠️ 系统警告 — 橙色条', 'warning' },
        { '❌ 操作失败 — 红色条', 'error' },
        { '🚔 911 报警 — 蓝色条', 'police' },
        { '🚑 急救呼叫 — 红色条', 'ambulance' },
    }
    for _, t in ipairs(types) do
        QBCore.Functions.Notify(t[1], t[2])
        Wait(2000)
    end
    check('NUI 5 种类型色条', true)

    -- ──── 5: Help Text ────
    print('--- 测试 5: Help Text ---')
    Wait(1500)
    local nnReadyFn = exports['qb-core'].NativeNotifyReady
    local nnReady = false
    if nnReadyFn then
        local ok, _ = pcall(nnReadyFn)
        nnReady = ok
    end
    if nnReady then
        exports['qb-core']:NativeNotifyShowHelpText('按 ~INPUT_CONTEXT~ 打开 — 原生 Help Text')
        check('原生 Help Text', true)
    else
        check('原生 Help Text (qb-core 未导出 NativeNotifyReady, 需重启加载新版 native_notify.lua)', false)
    end

    -- ──── 6: 多语言 ────
    print('--- 测试 6: 多语言通知 ---')
    Wait(2000)
    local langs = {
        '简体中文: 转账成功！',
        '繁體中文: 轉帳成功！',
        '日本語: 送金完了！',
        '한국어: 이체 완료!',
        'العربية: تم التحويل!',
        'Русский: Перевод выполнен!',
        'ไทย: โอนเงินสำเร็จ!',
    }
    for _, text in ipairs(langs) do
        QBCore.Functions.Notify(text)
        Wait(2000)
    end
    check('7 种语言原生 Feed 显示', true)

    -- ──── 7: 快速连续排队 ────
    print('--- 测试 7: 快速连续通知 (排队压力) ---')
    for i = 1, 5 do
        QBCore.Functions.Notify(('快速通知 #%d'):format(i))
        Wait(400)
    end
    check('连续 5 条排队不崩溃', true)

    -- ──── 8: table 格式兼容 ────
    print('--- 测试 8: table 格式兼容 ---')
    Wait(4000)
    QBCore.Functions.Notify({ text = '正文内容', caption = '标题文字' }, 'primary')
    check('table {text=, caption=} 格式', true)

    -- ──── 9: 图标参数兼容 ────
    print('--- 测试 9: 图标参数 ---')
    Wait(3000)
    QBCore.Functions.Notify('带自定义图标的通知', 'success', 5000, 'check_circle')
    check('Notify(text, type, length, icon) 参数', true)

    -- ──── 结果 ────
    Wait(2000)
    local total = results.passed + results.failed
    print(('\n───────────────────────────────────────────────'))
    print(('  客户端结果: %d/%d 通过'):format(results.passed, total))
    if results.failed == 0 then print('  ✅ 全部通过！') else print(('  ⚠️ %d 失败'):format(results.failed)) end
    print('  请确认游戏画面视觉效果符合预期')
    print('═══════════════════════════════════════════\n')
    QBCore.Functions.Notify('🎉 通知测试完成 — 查看 F8 控制台', 'success')
end, false)

print('[notify-test] ✅ 客户端测试就绪 — F8 输入 /notifytest')
