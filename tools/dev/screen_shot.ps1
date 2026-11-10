param(
    [string]$Out = "C:\Users\swkgb\AppData\Local\hermes\cache\scratch\playtest\screen.png",
    [int]$Left = 0, [int]$Top = 0, [int]$Width = 0, [int]$Height = 0
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if ($Width -le 0 -or $Height -le 0) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $Left = $bounds.Left; $Top = $bounds.Top
    $Width = $bounds.Width; $Height = $bounds.Height
}

$bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($Left, $Top, 0, 0, $bitmap.Size)
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
Write-Output "$Out ${Width}x${Height}"
