$ErrorActionPreference = 'SilentlyContinue'
function Section($name) { Write-Host "`n===== $name =====" -ForegroundColor Cyan }
function Line($k, $v) { Write-Host ("{0}: {1}" -f $k, $v) }

Section 'OS'
$os = Get-CimInstance Win32_OperatingSystem
Line 'Caption' $os.Caption
Line 'Version' $os.Version
Line 'Architecture' $os.OSArchitecture

Section 'Admin / SSH'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
Line 'User' (whoami)
Line 'IsAdmin' $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
Line 'sshd' ($(if ($sshd) { $sshd.Status } else { 'not installed' }))

Section 'Node'
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Line 'node' (& node -v); Line 'npm' (& npm -v) } else { Line 'node' 'not installed' }

Section '.NET runtimes'
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) { & dotnet --list-runtimes | Select-String 'Microsoft.NETCore.App|Microsoft.WindowsDesktop.App' } else { Line 'dotnet' 'not installed' }

Section 'FiveM installs'
Get-ChildItem $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'FiveM' } |
    ForEach-Object { Write-Host ('DIR: ' + $_.FullName) }

$fiveCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.exe'),
    (Join-Path $env:LOCALAPPDATA 'FiveM\FiveM.app\FiveM.exe'),
    (Join-Path $env:LOCALAPPDATA 'FiveM Enhanced\FiveM.exe'),
    (Join-Path $env:LOCALAPPDATA 'FiveM\FiveM Enhanced\FiveM.exe')
)
foreach ($p in $fiveCandidates) {
    if (Test-Path $p) {
        $f = Get-Item $p
        Write-Host ('EXE: ' + $f.FullName)
        Line '  ProductName' $f.VersionInfo.ProductName
        Line '  FileDescription' $f.VersionInfo.FileDescription
        Line '  ProductVersion' $f.VersionInfo.ProductVersion
    }
}

Section 'FiveM running process'
Get-CimInstance Win32_Process -Filter "Name='FiveM.exe'" -ErrorAction SilentlyContinue |
    Select-Object ProcessId, ExecutablePath, CommandLine | Format-List

Section 'devcon ports (Legacy only)'
$devcon = Get-NetTCPConnection -LocalPort 29200,29300 -State Listen -ErrorAction SilentlyContinue
if ($devcon) { $devcon | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table } else { Line 'devcon' 'no 29200/29300 listener (client may be closed, or Enhanced)' }

Section 'GTA V'
$gtaCandidates = @(
    'C:\Program Files\Rockstar Games\Grand Theft Auto V\GTA5.exe',
    'C:\Program Files\Rockstar Games\Grand Theft Auto V Enhanced\GTA5_Enhanced.exe',
    'C:\Program Files (x86)\Steam\steamapps\common\Grand Theft Auto V\GTA5.exe',
    'C:\Program Files\Epic Games\GTAV\GTA5.exe'
)
foreach ($p in $gtaCandidates) {
    if (Test-Path $p) {
        $f = Get-Item $p
        Write-Host ('EXE: ' + $f.FullName)
        Line '  ProductName' $f.VersionInfo.ProductName
    }
}
foreach ($reg in @(
    'HKLM:\SOFTWARE\WOW6432Node\Rockstar Games\Grand Theft Auto V',
    'HKLM:\SOFTWARE\Rockstar Games\Grand Theft Auto V'
)) {
    $v = Get-ItemProperty $reg -Name InstallFolder -ErrorAction SilentlyContinue
    if ($v) { Line 'Registry InstallFolder' $v.InstallFolder }
}

Section 'GPU / RAM / disk'
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, @{n='VRAM_GB';e={[math]::Round($_.AdapterRAM/1GB,1)}} | Format-List
$cs = Get-CimInstance Win32_ComputerSystem
Line 'RAM_GB' ([math]::Round($cs.TotalPhysicalMemory/1GB,1))
Line 'LogicalProcessors' $cs.NumberOfLogicalProcessors
$c = Get-PSDrive C
Line 'C_Free_GB' ([math]::Round($c.Free/1GB,1))

Section 'VM server reachability'
$t = Test-NetConnection 172.20.101.94 -Port 30120 -WarningAction SilentlyContinue
Line '30120_TCP' $t.TcpTestSucceeded

Write-Host "`nDONE. Copy this whole output back." -ForegroundColor Green
