Add-Type -AssemblyName System.Drawing

$targetDir = $null
$possiblePaths = @(
    "D:\*\hospital_textures",
    "C:\Users\swkgb\Desktop\hospital_textures"
)

foreach ($path in $possiblePaths) {
    $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
    if ($resolved) {
        $targetDir = $resolved.Path
        break
    }
}

if ($null -eq $targetDir) {
    Write-Output "Folder not found."
    Exit
}

Write-Output "Folder: $targetDir"
$files = Get-ChildItem -Path $targetDir -Filter *.png
foreach ($file in $files) {
    $img = [System.Drawing.Image]::FromFile($file.FullName)
    Write-Output "$($file.Name) : $($img.Width)x$($img.Height)"
    $img.Dispose()
}
