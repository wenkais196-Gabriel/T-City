$targetDir = Get-ChildItem -Path D:\ -Filter "v_40_hospital" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "v_40_hospital folder not found."
    Exit
}

Write-Output "Folder: $($targetDir.FullName)"
Get-ChildItem -Path $targetDir.FullName | Select-Object Name, Length
