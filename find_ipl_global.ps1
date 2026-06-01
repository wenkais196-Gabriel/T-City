$searchDir = "D:\txData\T-CityLite.base\resources"

if (-not (Test-Path -LiteralPath $searchDir)) {
    Write-Output "Resources folder not found."
    Exit
}

Write-Output "🔍 Searching for IPL or RemoveIpl globally across resources..."
$files = Get-ChildItem -Path $searchDir -Filter *.lua -Recurse -ErrorAction SilentlyContinue

$count = 0
foreach ($file in $files) {
    try {
        $content = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
        $lineNum = 1
        foreach ($line in $content) {
            if ($line -match "RemoveIpl" -or $line -match "RequestIpl" -or $line -match "pillbox_hospital" -or $line -match "rc12b_") {
                Write-Output " -> $($file.FullName) : Line $lineNum : $line"
                $count++
                if ($count -gt 50) {
                    Write-Output "Too many results, stopping search."
                    Exit
                }
            }
            $lineNum++
        }
    } catch {}
}
