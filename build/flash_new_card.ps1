# Rebuild a fresh SD card from the files kept on the PC.
#
# Usage:
#   .\build\flash_new_card.ps1 -Drive F:            # copy only (card already FAT32)
#   .\build\flash_new_card.ps1 -Drive F: -Format    # format FAT32 first (destructive)
#
# The new card needs a single FAT32 partition; U-Boot reads mmc 0:1.
# Everything needed to boot the Linux side comes from build/work/vendor_linux.
param(
    [string]$Drive = "F:",
    [switch]$Format
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$wl = Join-Path $repo 'build\work\vendor_linux'
$letter = $Drive.TrimEnd(':', '\').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as F:" }
$root = "${letter}:\"
if (-not (Test-Path -LiteralPath $root)) { throw "Drive ${letter}: not present" }

if ($Format) {
    Write-Host "formatting ${letter}: as FAT32 (destructive)"
    Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel BOOT -Confirm:$false | Out-Null
}

$map = [ordered]@{
    'BOOT.bin'           = (Join-Path $wl 'BOOT_hub75_hp0usb.bin')
    'image.ub'           = (Join-Path $wl 'image_usb_autostart.ub')
    'uEnv.txt'           = (Join-Path $wl 'uEnv.txt')
    'hub75d'             = (Join-Path $wl 'hub75d')
    '3dplay'             = (Join-Path $wl '3dplay')
    'hub75.conf'         = (Join-Path $wl 'hub75.conf')
    'hub75_anim_heart'   = (Join-Path $wl 'hub75_anim_heart')
    'hub75_anim_spheres' = (Join-Path $wl 'hub75_anim_spheres')
    'hub75_boot.frm'     = (Join-Path $wl 'hub75_boot.frm')
}
foreach ($k in $map.Keys) {
    if (-not (Test-Path -LiteralPath $map[$k])) { throw "missing payload: $($map[$k])" }
}
foreach ($k in $map.Keys) {
    Copy-Item -LiteralPath $map[$k] -Destination "$root$k" -Force
    Write-Host "copied $k"
}
foreach ($k in @('BOOT.bin','image.ub','hub75d','hub75_boot.frm')) {
    Get-FileHash "$root$k" -Algorithm MD5 | Select-Object Hash, Path | Format-List
}
Write-Host 'New card ready. Eject, set SW4=SD, power-cycle.'
