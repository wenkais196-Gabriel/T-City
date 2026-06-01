fx_version 'cerulean'
game 'gta5'

author 'T-City Lite Dev'
description 'T-City Lite 自动化游戏内测试框架 — 使用 /test 命令运行测试套件'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua',
}

server_scripts {
    'lib/test_runner.lua',
    'lib/mock_events.lua',
    'server_test.lua',
    'suites/*.lua',
}

dependencies {
    'qb-core',
    'custom-logs',
}
