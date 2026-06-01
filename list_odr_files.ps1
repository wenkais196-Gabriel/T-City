$otxFile = Get-ChildItem -Path D:\ -Filter "v_40_hospseating1" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $otxFile) {
    Write-Output "Error: v_40_hospseating1 folder not found!"
    Exit
}

Write-Output "Found Folder: $($otxFile.FullName)"
Get-ChildItem -Path $otxFile.FullName | Select-Object Name, Length
