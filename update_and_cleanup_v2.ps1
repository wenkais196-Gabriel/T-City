$targetDir = Get-ChildItem -Path D:\ -Filter "v_40_hospseating1" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "Error: v_40_hospseating1 folder not found!"
    Exit
}

Write-Output "Found Folder: $($targetDir.FullName)"
Write-Output "⚡ Cleaning up old `.dds` files to prevent conflict..."

# Delete old DDS files in this folder
Get-ChildItem -Path $targetDir.FullName -Filter *.dds | ForEach-Object {
    Remove-Item -Path $_.FullName -Force
    Write-Output "Deleted: $($_.Name)"
}

Write-Output "`n⚡ Checking and updating OTX files to point to PNG and enable Mipmaps..."

# Update ss_v_hrcarpet.otx (cushion texture)
$hrcarpetOtx = Join-Path $targetDir.FullName "ss_v_hrcarpet.otx"
if (Test-Path $hrcarpetOtx) {
    $content = Get-Content -Path $hrcarpetOtx -Raw
    # Ensure it points to PNG
    $content = $content -replace "ss_v_hrcarpet.dds", "ss_v_hrcarpet.png"
    # Ensure it generates Mipmaps (Levels 5)
    $content = $content -replace "Levels 1", "Levels 5"
    Set-Content -Path $hrcarpetOtx -Value $content -NoNewline
    Write-Output "Updated: ss_v_hrcarpet.otx"
}

# Update ss_v_biochrome.otx
$biochromeOtx = Join-Path $targetDir.FullName "ss_v_biochrome.otx"
if (Test-Path $biochromeOtx) {
    $content = Get-Content -Path $biochromeOtx -Raw
    $content = $content -replace "ss_v_biochrome.dds", "ss_v_biochrome.png"
    # Make sure levels is 6
    if ($content -notmatch "Levels 6") {
        $content = $content -replace "Levels \d+", "Levels 6"
    }
    Set-Content -Path $biochromeOtx -Value $content -NoNewline
    Write-Output "Updated: ss_v_biochrome.otx"
}

# Update ss_v_reflect2_r.otx
$reflectOtx = Join-Path $targetDir.FullName "ss_v_reflect2_r.otx"
if (Test-Path $reflectOtx) {
    $content = Get-Content -Path $reflectOtx -Raw
    $content = $content -replace "ss_v_reflect2_r.dds", "ss_v_reflect2_r.png"
    # Make sure levels is 6
    if ($content -notmatch "Levels 6") {
        $content = $content -replace "Levels \d+", "Levels 6"
    }
    Set-Content -Path $reflectOtx -Value $content -NoNewline
    Write-Output "Updated: ss_v_reflect2_r.otx"
}

Write-Output "`n⚡ Printing updated ss_v_hrcarpet.otx for verification:"
Get-Content -Path $hrcarpetOtx

Write-Output "`n🎉 Cleanup and OTX updates completed successfully!"
