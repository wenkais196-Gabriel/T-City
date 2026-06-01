$ytypFile = "D:\txData\T-CityLite.base\resources\[defaultmaps]\hospital_map\stream\v_int_40.ytyp"

if (-not (Test-Path -LiteralPath $ytypFile)) {
    Write-Output "v_int_40.ytyp not found at literal path."
    Exit
}

# Read bytes using LiteralPath
$bytes = [System.IO.File]::ReadAllBytes($ytypFile)
$text = [System.Text.Encoding]::ASCII.GetString($bytes)

# Find all unique model references
$matches = [regex]::Matches($text, "[a-zA-Z0-9_\-]{4,30}")
$words = $matches | ForEach-Object { $_.Value } | Select-Object -Unique | Where-Object { $_ -match "v_40" -or $_ -match "hosp" -or $_ -match "light" }

Write-Output "🔍 Archetype analysis of v_int_40.ytyp:"
Write-Output "Unique model references found in the interior definition:"
Write-Output "=================================================="
foreach ($word in $words) {
    Write-Output " - $word"
}
Write-Output "=================================================="
Write-Output "Total unique model references: $($words.Count)"
