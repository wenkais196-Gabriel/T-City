$targetDir = Get-ChildItem -Path D:\ -Filter "hospital_textures" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Error "Error: hospital_textures folder not found on D: drive!"
    Exit
}

Write-Output "🔍 Found main textures folder: $($targetDir.FullName)"
Write-Output "⚡ Scanning all exported ODR subfolders for optimization..."

$subFolders = Get-ChildItem -Path $targetDir.FullName -Directory
$optimizedCount = 0
$cleanedDdsCount = 0

foreach ($folder in $subFolders) {
    Write-Output "`n📂 Processing model folder: $($folder.Name)"
    
    # 1. Clean up old conflicting DDS files in this subfolder
    $ddsFiles = Get-ChildItem -Path $folder.FullName -Filter *.dds
    foreach ($dds in $ddsFiles) {
        Remove-Item -Path $dds.FullName -Force
        $cleanedDdsCount++
    }
    
    # 2. Scan and optimize all OTX descriptor files in this subfolder
    $otxFiles = Get-ChildItem -Path $folder.FullName -Filter *.otx
    foreach ($otx in $otxFiles) {
        try {
            $content = Get-Content -Path $otx.FullName -Raw
            $updated = $false
            
            # Ensure the OTX references PNG instead of DDS
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($otx.Name)
            $expectedPng = "$baseName.png"
            
            if ($content -match "\.dds") {
                $content = $content -replace "$baseName.dds", $expectedPng
                $updated = $true
            }
            
            # Check if Levels is hardcoded to 1 (No Mipmaps)
            if ($content -match "Levels 1") {
                $content = $content -replace "Levels 1", "Levels 5"
                $updated = $true
                Write-Output "   -> Force-enabled Mipmaps (Levels 1 -> 5) for: $($otx.Name)"
            }
            
            if ($updated) {
                Set-Content -Path $otx.FullName -Value $content -NoNewline
                $optimizedCount++
            }
        } catch {
            Write-Warning "   ⚠️ Failed to optimize OTX file $($otx.Name): $_"
        }
    }
}

Write-Output "`n=================================================="
Write-Output "🎉 Bulk Optimization Complete!"
Write-Output "📊 Summary Report:"
Write-Output "   - Conflicting DDS files deleted: $cleanedDdsCount"
Write-Output "   - OTX texture descriptors optimized: $optimizedCount"
Write-Output "=================================================="
