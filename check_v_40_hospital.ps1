$targetDir = Get-ChildItem -Path D:\ -Filter "v_40_hospital" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "v_40_hospital folder not found."
    Exit
}

Write-Output "Folder: $($targetDir.FullName)"
$otxFiles = Get-ChildItem -Path $targetDir.FullName -Filter *.otx
foreach ($otx in $otxFiles) {
    $content = Get-Content -Path $otx.FullName -Raw
    if ($content -match "Levels 1") {
        Write-Output "⚠️ Unoptimized (Levels 1): $($otx.Name)"
    } else {
        # Check if levels matches something else
        if ($content -match "Levels (\d+)") {
            $levels = $Matches[1]
            Write-Output "Optimized (Levels $levels): $($otx.Name)"
        }
    }
}
