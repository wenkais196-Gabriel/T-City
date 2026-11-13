<#
.SYNOPSIS
    T-City 整套开发栈一键启动：Docker 引擎 → MariaDB → 等 3307 → FXServer → 自检。

.DESCRIPTION
    2026-11-12 真机事故：关掉 Docker Desktop 后 MariaDB 容器一起没了，FXServer 起得来、
    `oxmysql` 却卡在 `connect ETIMEDOUT`，表现是"服务器在跑但所有要库的功能都空转"。
    另外 FXServer 抢在 MariaDB 就绪之前连接时，oxmysql 不会自己重试，
    必须 `quit` + 重起整服（中途 `restart oxmysql` 会连带停掉 qb-core 等 41 个依赖，别这么干）。

    所以启动顺序被固定成：引擎 → 容器 → 端口 → 服务端；每一步都有超时和明确报错。

.PARAMETER Stop
    只停 FXServer（走 RCON quit，让玩家落盘），不动 Docker/DB。

.PARAMETER Restart
    停完再起（等价于 -Stop 然后默认启动）。

.PARAMETER Status
    只看状态，不动任何东西。

.PARAMETER TimeoutSeconds
    等资源加载完成的上限，默认 300。

.EXAMPLE
    .\start-tcity.ps1
    .\start-tcity.ps1 -Status
    .\start-tcity.ps1 -Restart
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Restart,
    [switch]$Status,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 源码是 UTF-8（带 BOM）；控制台默认是 GBK，中文会花。统一成 UTF-8 再输出。
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ── 路径与常量（要改只看这一段） ────────────────────────────────────────────
$Repo      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Base      = Join-Path $Repo 'T-CityLite.base'
$ServerCfg = Join-Path $Base 'server.cfg'
$FXServer  = if ($env:TCITY_FXSERVER) { $env:TCITY_FXSERVER } else { 'E:/FXServer/FXServer.exe' }
$DockerExe = 'C:/Program Files/Docker/Docker/Docker Desktop.exe'
$Container = if ($env:TCITY_DB_CONTAINER) { $env:TCITY_DB_CONTAINER } else { 'tcity-mariadb' }
$LogFile   = Join-Path $env:TEMP 'tcity_console.log'

$Required = @(
    'qb-core', 'qb-hud', 'qb-garages', 'custom-notify', 'custom-prompt', 'custom-ui',
    'custom-phone', 'qb-vehicleshop', 'custom-mining', 'custom-police', 'custom-justice',
    'custom-market', 'custom-quest', 'custom-security', 'custom-logs'
)

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   OK  $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "   !!  $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "   XX  $Text" -ForegroundColor Red }

function Get-ServerSetting([string]$Name) {
    # server.cfg 不入库、也不该被脚本猜；这里只读两个值：rcon 口令与 DB 连接串
    if (-not (Test-Path $ServerCfg)) { return $null }
    $m = Select-String -Path $ServerCfg -Pattern ('^\s*set\s+' + $Name + '\s+"?([^"\r\n]+)"?') -AllMatches
    if ($m.Matches.Count -gt 0) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

function Get-DbEndpoint {
    $cs = Get-ServerSetting 'mysql_connection_string'
    if (-not $cs) { return @{ Host = '127.0.0.1'; Port = 3306; Password = $null } }
    $m = [regex]::Match($cs, 'mysql://(?<user>[^:@/]*):(?<pass>[^@]*)@(?<host>[^:/]+):(?<port>\d+)')
    if (-not $m.Success) { throw "server.cfg 里的 mysql_connection_string 解析不出 host:port：$cs" }
    return @{ Host = $m.Groups['host'].Value; Port = [int]$m.Groups['port'].Value; Password = $m.Groups['pass'].Value }
}

function Test-Tcp([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($TargetHost, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Dispose() }
}

function Get-ResourceList {
    try {
        $info = Invoke-RestMethod -Uri 'http://127.0.0.1:30130/info.json' -TimeoutSec 3
        return @($info.resources)
    } catch { return $null }
}

# ── 0. 状态 ────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Step 'Docker 引擎'
    $dockerUp = $false
    try { docker info *> $null; $dockerUp = ($LASTEXITCODE -eq 0) } catch { $dockerUp = $false }
    if ($dockerUp) { Write-Ok '引擎在跑' } else { Write-Bad '引擎没起（Docker Desktop 未开）' }

    if ($dockerUp) {
        Write-Step "容器 $Container"
        $state = (docker inspect -f '{{.State.Status}}' $Container 2>$null)
        if ($LASTEXITCODE -eq 0) { Write-Ok "状态 $state" } else { Write-Bad '容器不存在' }
    }

    $db = Get-DbEndpoint
    Write-Step "数据库端口 $($db.Host):$($db.Port)"
    if (Test-Tcp $db.Host $db.Port) { Write-Ok '可连接' } else { Write-Bad '连不上' }

    Write-Step 'FXServer (:30130)'
    $res = Get-ResourceList
    if ($null -eq $res) {
        Write-Bad '未响应'
    } else {
        Write-Ok "资源 $($res.Count) 个"
        $missing = $Required | Where-Object { $res -notcontains $_ }
        if ($missing) { Write-Bad ("关键资源缺失: " + ($missing -join ', ')) } else { Write-Ok '关键资源齐全' }
    }
    if (Test-Path $LogFile) {
        $bad = Select-String -Path $LogFile -Pattern 'SCRIPT ERROR|awaitConnection failed' -SimpleMatch:$false |
               Select-Object -Last 3
        if ($bad) { Write-Warn2 "日志里有 $($bad.Count) 条可疑行（$LogFile）" } else { Write-Ok '日志无 SCRIPT ERROR / 连接失败' }
    }
}

# ── 1. 停服 ────────────────────────────────────────────────────────────────
function Stop-Stack {
    Write-Step '停 FXServer（RCON quit，让玩家落盘）'
    if (-not (Test-Tcp '127.0.0.1' 30130)) { Write-Ok '本来就没在跑'; return }
    $rcon = Get-ServerSetting 'rcon_password'
    if (-not $rcon) { throw 'server.cfg 里没有 rcon_password，无法优雅停服；请手动关掉 FXServer 窗口' }
    $env:FIVEM_RCON_PASSWORD = $rcon
    python (Join-Path $Repo 'tools/dev/fivem_console.py') 'quit' '--wait' '8' | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Test-Tcp '127.0.0.1' 30130)) { Write-Ok '端口已释放'; return }
        Start-Sleep -Milliseconds 500
    }
    throw 'quit 之后 20 秒端口仍被占用（检查是否有第二个 FXServer 实例）'
}

# ── 2. Docker 引擎 ─────────────────────────────────────────────────────────
function Ensure-DockerEngine {
    Write-Step 'Docker 引擎'
    try { docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Ok '已在运行'; return } } catch { }

    if (-not (Test-Path $DockerExe)) { throw "找不到 Docker Desktop：$DockerExe" }
    Write-Warn2 '引擎没起，正在拉起 Docker Desktop（首次可能要 1–2 分钟）'
    Start-Process -FilePath $DockerExe | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        try { docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Ok "引擎就绪（$($i * 3 + 3)s）"; return } } catch { }
    }
    throw '等了 180 秒 Docker 引擎仍未就绪'
}

# ── 3. MariaDB ────────────────────────────────────────────────────────────
function Ensure-Database {
    $db = Get-DbEndpoint
    Write-Step "MariaDB（容器 $Container，端口 $($db.Port)）"

    docker inspect -f '{{.State.Status}}' $Container *> $null
    if ($LASTEXITCODE -ne 0) { throw "容器 $Container 不存在（先按 docs/engineering 里的建库步骤恢复）" }

    $state = (docker inspect -f '{{.State.Status}}' $Container).Trim()
    if ($state -ne 'running') {
        Write-Warn2 "容器状态 $state，正在启动"
        docker start $Container *> $null
        if ($LASTEXITCODE -ne 0) { throw "docker start $Container 失败" }
    } else {
        Write-Ok '容器已在运行'
    }

    # 端口通了还不够：InnoDB 恢复期间端口会先开、查询仍会失败，所以再 ping 一次
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Tcp $db.Host $db.Port) {
            if ($db.Password) {
                docker exec $Container mariadb-admin ping -h 127.0.0.1 -uroot "-p$($db.Password)" *> $null
                if ($LASTEXITCODE -eq 0) { Write-Ok "数据库可查询（$($i * 2 + 2)s）"; return }
            } else {
                Write-Ok "端口可连接（$($i * 2 + 2)s）"; return
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "等了 120 秒 $($db.Host):$($db.Port) 仍不可用（看 docker logs $Container）"
}

# ── 4. FXServer ───────────────────────────────────────────────────────────
function Start-Server {
    Write-Step 'FXServer'
    if (-not (Test-Path $FXServer)) { throw "找不到 FXServer：$FXServer（设环境变量 TCITY_FXSERVER 可改）" }
    if (Test-Tcp '127.0.0.1' 30130) {
        Write-Warn2 '30130 已被占用 —— 已有实例在跑。要重启请用 -Restart'
        return
    }

    # 单实例：重复启动的代价是烧掉一次 licence 配额（Cfx 会 429）
    $logDir = Split-Path -Parent $LogFile
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    Remove-Item $LogFile -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath $FXServer `
        -ArgumentList '+exec', 'server.cfg' `
        -WorkingDirectory $Base `
        -RedirectStandardOutput $LogFile `
        -RedirectStandardError (Join-Path $env:TEMP 'tcity_console.err.log') `
        -PassThru -WindowStyle Hidden
    Write-Ok "已拉起（PID $($proc.Id)），日志 $LogFile"
}

function Wait-Ready([int]$Timeout) {
    Write-Step '等资源加载完成'
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastCount = -1
    $stableSince = $null
    while ((Get-Date) -lt $deadline) {
        $res = Get-ResourceList
        if ($null -ne $res) {
            if ($res.Count -ne $lastCount) {
                Write-Host "   … 资源 $($res.Count)" -NoNewline
                $lastCount = $res.Count
                $stableSince = Get-Date
            } elseif ($stableSince -and ((Get-Date) - $stableSince).TotalSeconds -ge 20) {
                Write-Host ''
                break
            }
        }
        Start-Sleep -Seconds 5
    }
    Write-Host ''

    $res = Get-ResourceList
    if ($null -eq $res) { throw "服务端在 $Timeout 秒内没有响应 :30130" }

    $fail = 0
    $missing = $Required | Where-Object { $res -notcontains $_ }
    if ($missing) { Write-Bad ("关键资源缺失: " + ($missing -join ', ')); $fail++ }
    else { Write-Ok "资源 $($res.Count) 个，关键资源齐全" }

    $errors = Select-String -Path $LogFile -Pattern 'SCRIPT ERROR' | Select-Object -Last 5
    if ($errors) { Write-Bad "日志里有 SCRIPT ERROR（$($errors.Count) 条）"; $errors | ForEach-Object { Write-Host "      $($_.Line.Trim())" }; $fail++ }

    # 这一条是本脚本存在的理由：oxmysql 不会自己重试，抢跑一次就得重起整服
    $dbFail = Select-String -Path $LogFile -Pattern 'awaitConnection failed|ETIMEDOUT' | Select-Object -Last 3
    if ($dbFail) { Write-Bad 'oxmysql 连接数据库失败 —— 说明它抢在 MariaDB 就绪之前连了，请 -Restart 重试'; $fail++ }
    else { Write-Ok 'oxmysql 连接正常' }

    if ($fail -gt 0) { throw '启动自检未通过（见上面几条）' }
    Write-Host "`n  服已就绪：http://127.0.0.1:30130/players.json`n" -ForegroundColor Green
}

# ── 主流程 ─────────────────────────────────────────────────────────────────
try {
    if ($Status) { Show-Status; exit 0 }
    if ($Stop)   { Stop-Stack;  exit 0 }
    if ($Restart) { Stop-Stack }
    Ensure-DockerEngine
    Ensure-Database
    Start-Server
    if (Test-Tcp '127.0.0.1' 30130) { Wait-Ready $TimeoutSeconds }
    exit 0
} catch {
    Write-Bad $_.Exception.Message
    Write-Host "`n   看日志：Get-Content '$LogFile' -Tail 40" -ForegroundColor Yellow
    exit 1
}
