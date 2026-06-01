$targetDir = Get-ChildItem -Path D:\ -Filter "hospital_textures" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "hospital_textures folder not found."
    Exit
}

$subFolder = Join-Path $targetDir.FullName "hospital_map"
if (Test-Path $subFolder) {
    Write-Output "Folder: $subFolder"
    Get-ChildItem -Path $subFolder | Select-Object Name, Length
} else {
    Write-Output "hospital_map subfolder not found."
}
