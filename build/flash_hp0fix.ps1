$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path 'F:\')) { Write-Host 'F: not present'; exit 1 }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $repo ('build\work\sd_backup\boot_before_hp0fix_' + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item 'F:\BOOT.bin' (Join-Path $backup 'BOOT.bin') -Force
Write-Host "backup -> $backup"
Copy-Item (Join-Path $repo 'build\work\vendor_linux\BOOT_hub75_hp0fix.bin') 'F:\BOOT.bin' -Force
Copy-Item (Join-Path $repo 'build\work\vendor_linux\hub75_pattern_ddr') 'F:\hub75_pattern_ddr' -Force
Copy-Item (Join-Path $repo 'build\work\vendor_linux\hub75_diag') 'F:\hub75_diag' -Force
try { Write-VolumeCache -DriveLetter F | Out-Null } catch {}
Get-ChildItem 'F:\' | Where-Object { $_.Name -match '^(BOOT|hub75|image|uEnv)' } | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
Get-FileHash 'F:\BOOT.bin' -Algorithm MD5 | Format-List
