$targetDir = Get-ChildItem -Path D:\ -Filter "hospital_map" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "hospital_map folder not found."
    Exit
}

Write-Output "Folder: $($targetDir.FullName)"
Get-ChildItem -Path $targetDir.FullName | Select-Object Name, Length
