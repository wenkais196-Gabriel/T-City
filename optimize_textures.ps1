Add-Type -AssemblyName System.Drawing

$desktop = [Environment]::GetFolderPath("Desktop")
$documents = [Environment]::GetFolderPath("MyDocuments")

$possiblePaths = @(
    (Join-Path $desktop "hospital_textures"),
    (Join-Path $documents "hospital_textures"),
    "C:\Users\swkgb\Desktop\hospital_textures",
    "C:\Users\swkgb\OneDrive\Desktop\hospital_textures"
)

$targetDir = $null
foreach ($path in $possiblePaths) {
    if (Test-Path $path -PathType Container) {
        $targetDir = $path
        break
    }
}

if ($null -eq $targetDir) {
    Write-Error "Could not find hospital_textures folder on Desktop or Documents."
    Exit
}

Write-Output "Target folder located: $targetDir"
Write-Output "Starting texture compression (Limit: 1024 max)..."

$files = Get-ChildItem -Path $targetDir -Filter *.png
$optimizedCount = 0
$skippedCount = 0

foreach ($file in $files) {
    try {
        $img = [System.Drawing.Image]::FromFile($file.FullName)
        $width = $img.Width
        $height = $img.Height
        
        if ($width -gt 1024 -or $height -gt 1024) {
            if ($width -ge $height) {
                $newW = 1024
                $newH = [int]($height * 1024 / $width)
            } else {
                $newH = 1024
                $newW = [int]($width * 1024 / $height)
            }
            
            # Make even
            if ($newW % 2 -ne 0) { $newW = $newW - 1 }
            if ($newH % 2 -ne 0) { $newH = $newH - 1 }
            
            $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $newW, $newH)
            
            $g.Dispose()
            $img.Dispose()
            
            $bmp.Save($file.FullName, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            
            Write-Output "Optimized: $($file.Name) ($width x $height -> $newW x $newH)"
            $optimizedCount++
        } else {
            $img.Dispose()
            $skippedCount++
        }
    } catch {
        Write-Warning "Failed to process $($file.Name): $_"
    }
}

Write-Output ""
Write-Output "Optimization Complete!"
Write-Output "Optimized: $optimizedCount, Skipped: $skippedCount"
