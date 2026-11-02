$ErrorActionPreference='Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path 'F:\')) { Write-Host 'F: not present'; exit 1 }
Copy-Item (Join-Path $repo 'build\work\vendor_linux\hub75d') 'F:\hub75d' -Force
Write-Host 'copied hub75d'
try { Write-VolumeCache -DriveLetter F | Out-Null } catch {}
Get-ChildItem 'F:\' | Where-Object { $_.Name -match '^(BOOT|hub75|image|uEnv)' } | Select-Object Name,Length | Format-Table -AutoSize
Get-FileHash 'F:\BOOT.bin' -Algorithm MD5 | Format-List
Get-FileHash 'F:\hub75d' -Algorithm MD5 | Format-List
