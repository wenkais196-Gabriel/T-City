<#
.SYNOPSIS
  重启级联之后的「把依赖资源拉回来」—— Windows 侧（走 RCON）。

.DESCRIPTION
  FXServer 的 `restart X` 会**连带停掉所有把 X 写进 dependencies 的资源**，而且
  不会自动 ensure 回来。真机实测（2026-11-07）：`restart qb-core` 之后资源数
  85 → 42，客户端刷一屏 `No such export GetCoreObject in resource qb-core`。

  仓库里已有 `tools/dev/resync_modules.sh`，但它只在 Linux 布局（有 tcity-cmd）时才
  自动执行，Windows 本机不会跑。这个脚本用 `tools/dev/fivem_console.py`（RCON）做同样的事。

  顺序取自 `Startup` 的 `start.cfg`：先 `exec configs/modules/*.cfg`（`ensure` 对已启动
  资源是幂等的，只会拉起被停的），再核对资源数。

.PARAMETER DryRun
  只打印将要发送的命令，不连服务器。

.PARAMETER ExpectedResources
  跑完之后期望的资源数（默认 85 —— `configs/modules/*.cfg` 的 86 条 `ensure` 里
  `custom-director` 重复一次，唯一资源 85）。

.EXAMPLE
  pwsh tools/dev/resync_modules.ps1 -DryRun
  $env:FIVEM_DEBUG_PORT = "127.0.0.1:30130"; pwsh tools/dev/resync_modules.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$ExpectedResources = 85
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$base = Join-Path $repo 'T-CityLite.base'
$modules = Join-Path $base 'configs/modules'

if (-not (Test-Path $modules)) {
    throw "找不到 $modules —— 请在仓库内运行这个脚本"
}

# 顺序与 server.cfg 的 exec 顺序一致，避免依赖资源先于被依赖资源启动
$order = @(
    'core', 'career', 'player', 'voice', 'custom', 'quest', 'police', 'vehicles',
    'jobs', 'banking', 'medical', 'economy', 'security', 'crime', 'story',
    'atmosphere', 'admin'
)

$commands = foreach ($name in $order) {
    $path = Join-Path $modules "$($name).cfg"
    if (Test-Path $path) { "exec configs/modules/$($name).cfg" }
}

Write-Host ("将要发送 {0} 条 exec：" -f @($commands).Count) -ForegroundColor Cyan
$commands | ForEach-Object { Write-Host "  $_" }

if ($DryRun) {
    Write-Host '（-DryRun：没有连接服务器）' -ForegroundColor Yellow
    return
}

$console = Join-Path $repo 'tools/dev/fivem_console.py'
if (-not (Test-Path $console)) { throw "找不到 $console" }

# 解释器：优先仓库 venv，其次 PATH 上的 python
$python = 'python'
$venv = Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch/tc-venv/Scripts/python.exe'
if (Test-Path $venv) { $python = $venv }

foreach ($command in $commands) {
    & $python $console $command --wait 2 | Out-Null
    Start-Sleep -Milliseconds 300
}

Start-Sleep -Seconds 5

# 核对资源数：RCON 的 info.json 是服务器自己报的，比控制台输出可靠
$port = if ($env:FIVEM_DEBUG_PORT) { ($env:FIVEM_DEBUG_PORT -split ':')[-1] } else { '30130' }
try {
    $info = Invoke-RestMethod -Uri "http://127.0.0.1:$port/info.json" -TimeoutSec 10
    $count = @($info.resources).Count
}
catch {
    Write-Warning "查不到 http://127.0.0.1:$port/info.json（服务没起？）：$_"
    return
}

Write-Host ("资源数：{0}（期望 {1}）" -f $count, $ExpectedResources) -ForegroundColor Cyan
if ($count -lt $ExpectedResources) {
    Write-Warning "还有资源没拉回来 —— 看控制台是否有 SCRIPT ERROR / No such export"
    exit 1
}
