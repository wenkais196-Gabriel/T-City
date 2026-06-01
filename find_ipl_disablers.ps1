$searchDir = "D:\txData\T-CityLite.base\resources\[qb]\qb-ambulancejob\client"

if (-not (Test-Path -LiteralPath $searchDir)) {
    Write-Output "Ambulance client folder not found."
    Exit
}

Write-Output "🔍 Searching for IPL requests/removals in qb-ambulancejob client..."
$files = Get-ChildItem -Path $searchDir -Filter *.lua -Recurse

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName
    $lineNum = 1
    foreach ($line in $content) {
        if ($line -match "Ipl" -or $line -match "pillbox" -or $line -match "Remove") {
            Write-Output " -> $($file.Name) : Line $lineNum : $line"
        }
        $lineNum++
    }
}
