$otxFile = Get-ChildItem -Path D:\ -Filter "ss_v_hrcarpet.otx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $otxFile) {
    Write-Output "Error: ss_v_hrcarpet.otx not found!"
    Exit
}

Write-Output "Found OTX file: $($otxFile.FullName)"

# Read, replace, and save
$content = Get-Content -Path $otxFile.FullName -Raw
$newContent = $content -replace "Levels 1", "Levels 5"
Set-Content -Path $otxFile.FullName -Value $newContent -NoNewline

Write-Output "Successfully updated Levels 1 to Levels 5 inside the OTX file!"
