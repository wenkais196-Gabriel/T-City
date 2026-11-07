<#
.SYNOPSIS
  重启级联之后的「把依赖资源拉回来」—— Windows 侧（走 RCON）。

.DESCRIPTION
  FXServer 的 `restart X` 会**连带停掉所有把 X 写进 dependencies 的资源**，而且
  不会自动 ensure 回来。真机实测（2026-11-07）：`restart qb-core` 之后资源数
  85 → 42，客户端刷一屏 `No such export GetCoreObject in resource qb-core`。

  仓库里已有 `tools/dev/resync_modules.sh`，但它只在 Linux 布局（有 tcity-cmd）时才
  自动执行，Windows 本机不会跑。这个脚本用 `tools/dev/fivem_console.py`（RCON）做同样的事。

  执行清单**从 server.cfg 的 exec 顺序读**，不硬编码 —— `configs/modules/` 下有 18 个
  cfg，其中 dev.cfg 是开发/测试专用（文件头写明"生产环境不要 exec"），server.cfg 只
  exec 17 个。以 server.cfg 为准才不会漏也不会多。

.PARAMETER DryRun
  只打印将要发送的命令，不连服务器。

.PARAMETER ExpectedResources
  跑完之后期望的资源数（默认 85 —— server.cfg exec 的 17 个模块 cfg 里的 ensure
  去重后是 85 个唯一资源）。

.EXAMPLE
  pwsh tools/dev/resync_modules.ps1 -DryRun
  pwsh tools/dev/resync_modules.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$ExpectedResources = 85
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$base = Join-Path $repo 'T-CityLite.base'
$serverCfg = Join-Path $base 'server.cfg'
$modules = Join-Path $base 'configs/modules'

if (-not (Test-Path $modules)) {
    throw "找不到 $modules —— 请在仓库内运行这个脚本"
}
if (-not (Test-Path $serverCfg)) {
    throw "找不到 server.cfg（它不入库，本机必须有）"
}

# 以 server.cfg 的 exec 顺序为准（自动跳过注释行）
$commands = @(
    Get-Content -LiteralPath $serverCfg |
        Where-Object { $_ -match '^\s*exec\s+configs/modules/[A-Za-z0-9_\-]+\.cfg\s*$' } |
        ForEach-Object { ($_ -replace '^\s*exec\s+', '').Trim() } |
        ForEach-Object { "exec $_" }
)

if ($commands.Count -eq 0) {
    throw "server.cfg 里没有任何 exec configs/modules/*.cfg —— 检查这份配置是不是被改过"
}

# 目录里多出来的 cfg（例如 dev.cfg）必须显式说明被排除
$onDisk = @(Get-ChildItem -LiteralPath $modules -Filter *.cfg | ForEach-Object { $_.Name })
$executed = @($commands | ForEach-Object { Split-Path -Leaf ($_ -replace '^exec configs/modules/', '') })
$skipped = @($onDisk | Where-Object { $executed -notcontains $_ })

Write-Host ("将发送 {0} 条 exec（顺序取自 server.cfg）" -f $commands.Count) -ForegroundColor Cyan
$commands | ForEach-Object { Write-Host "  $_" }
if ($skipped.Count -gt 0) {
    Write-Host ("未 exec（按设计跳过）：{0}" -f ($skipped -join ', ')) -ForegroundColor DarkYellow
}

if ($DryRun) {
    Write-Host '（-DryRun：没有连接服务器）' -ForegroundColor Yellow
    return
}

$console = Join-Path $repo 'tools/dev/fivem_console.py'
if (-not (Test-Path $console)) { throw "找不到 $console" }

$python = 'python'
$venv = Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch/tc-venv/Scripts/python.exe'
if (Test-Path $venv) { $python = $venv }

foreach ($command in $commands) {
    & $python $console $command --wait 2 | Out-Null
    Start-Sleep -Milliseconds 300
}

Start-Sleep -Seconds 5

# 核对：server.cfg exec 的那些模块 cfg 里 ensure 的资源，必须全都在跑。
# 用集合差而不是硬编码数字 —— 地图资源（fivem-map-*）与 dev.cfg 的东西不该影响判定，
# 而 env 里的资源数会随启动方式变化（真机实测 85 与 86 都出现过）。
$port = if ($env:FIVEM_DEBUG_PORT) { ($env:FIVEM_DEBUG_PORT -split ':')[-1] } else { '30130' }
try {
    $info = Invoke-RestMethod -Uri "http://127.0.0.1:$port/info.json" -TimeoutSec 10
    $running = @($info.resources)
}
catch {
    Write-Warning "查不到 http://127.0.0.1:$port/info.json —— 服务没起或端口不对，无法核对：$_"
    exit 1
}

$expected = New-Object System.Collections.Generic.List[string]
foreach ($command in $commands) {
    $cfgPath = Join-Path $base ($command -replace '^exec\s+', '')
    if (-not (Test-Path $cfgPath)) { continue }
    Get-Content -LiteralPath $cfgPath |
        Where-Object { $_ -match '^\s*ensure\s+(\S+)' } |
        ForEach-Object { [void]$expected.Add((($_ -split '\s+')[1])) }  # 只取 ensure 后的第一个 token（行尾可能有注释）
}
$expected = @($expected | Select-Object -Unique)
$missing = @($expected | Where-Object { $running -notcontains $_ })

Write-Host ("运行中 {0} 个资源；server.cfg 期望 {1} 个" -f $running.Count, $expected.Count) -ForegroundColor Cyan
if ($missing.Count -gt 0) {
    Write-Warning ("还有 {0} 个资源没拉回来：{1}" -f $missing.Count, ($missing -join ', '))
    Write-Warning "看控制台是否有 SCRIPT ERROR / No such export"
    exit 1
}
Write-Host '核对通过：server.cfg 期望的资源全部在跑' -ForegroundColor Green
