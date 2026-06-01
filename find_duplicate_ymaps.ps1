$searchDir = "D:\txData\T-CityLite.base\resources"

if (-not (Test-Path -LiteralPath $searchDir)) {
    Write-Output "Resources folder not found."
    Exit
}

Write-Output "🔍 Searching for duplicate 'rc12b_hospitalinterior.ymap' or 'v_int_40.ytyp' in T-CityLite resources..."
$files = Get-ChildItem -Path $searchDir -Filter "*hospitalinterior.ymap" -Recurse -ErrorAction SilentlyContinue

Write-Output "Found $($files.Count) instances of the hospital interior ymap:"
foreach ($file in $files) {
    Write-Output " -> $($file.FullName) (Size: $($file.Length) bytes)"
}

$ytypFiles = Get-ChildItem -Path $searchDir -Filter "*v_int_40.ytyp" -Recurse -ErrorAction SilentlyContinue
Write-Output "`nFound $($ytypFiles.Count) instances of the v_int_40 ytyp:"
foreach ($ytyp in $ytypFiles) {
    Write-Output " -> $($ytyp.FullName) (Size: $($ytyp.Length) bytes)"
}
