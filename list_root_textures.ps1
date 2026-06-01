$targetDir = Get-ChildItem -Path D:\ -Filter "hospital_textures" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "hospital_textures folder not found."
    Exit
}

Write-Output "Folder: $($targetDir.FullName)"
Get-ChildItem -Path $targetDir.FullName | Select-Object Name, Length
