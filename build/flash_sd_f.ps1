$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dest = 'F:\'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $repo ('build\work\sd_backup\boot_before_new_' + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item (Join-Path $dest 'BOOT.bin') (Join-Path $backup 'BOOT.bin') -Force
Write-Host "backup -> $backup"
Copy-Item (Join-Path $repo 'build\work\vendor_linux\BOOT_hub75_bram32_ir3.bin') (Join-Path $dest 'BOOT.bin') -Force
Write-Host "BOOT.bin replaced"
foreach ($f in @('hub75_diag','hub75_pattern_bram32')) {
    Copy-Item (Join-Path $repo ('build\work\vendor_linux\' + $f)) (Join-Path $dest $f) -Force
    Write-Host "copied $f"
}
Get-ChildItem $dest | Where-Object { $_.Name -match '^(BOOT|hub75|image|uEnv)' } |
    Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
Get-FileHash (Join-Path $dest 'BOOT.bin') -Algorithm MD5 | Format-List
