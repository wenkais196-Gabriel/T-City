$targetDir = Get-ChildItem -Path D:\ -Filter "hospital_textures" -Directory -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -eq $targetDir) {
    Write-Output "Folder not found."
    Exit
}

Write-Output "Folder: $($targetDir.FullName)"
$otxFiles = Get-ChildItem -Path $targetDir.FullName -Filter *.otx -Recurse
Write-Output "Found $($otxFiles.Count) OTX files."
foreach ($otx in $otxFiles) {
    Write-Output "File: $($otx.FullName)"
    $content = Get-Content -Path $otx.FullName -Raw
    Write-Output $content
    Write-Output "----------------------------------"
}
