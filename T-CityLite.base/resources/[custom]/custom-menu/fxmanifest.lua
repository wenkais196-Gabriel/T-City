fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'Unified MenuSpec host resource for T-City Lite (M2)'
version '0.1.0'

dependencies {
    'core-framework',
}

shared_scripts {
    'shared/menu_spec.lua',
}

client_scripts {
    '@core-framework/client/shared.lua',
    'client/host.lua',
}

server_scripts {
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/renderer.js',
    'html/styles.css',
}
