# Build the Linux BOOT image (our FSBL + HP0/USB bitstream + vendor U-Boot)
# and copy the USB-keyboard payload onto the SD card FAT partition.
#
# Usage: .\build\flash_usb_boot.ps1 [-Drive F:] [-SkipBootgen]
param(
    [string]$Drive = "F:",
    [switch]$SkipBootgen,
    [string]$Out = "BOOT_hub75_hp0usb.bin"
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$wl = Join-Path $repo 'build\work\vendor_linux'
$bootgen = 'E:\AMD\2026.1\Vitis\bin\bootgen.bat'
$bif = Join-Path $wl 'hub75_linux.bif'
$boot = Join-Path $wl $Out

if (-not $SkipBootgen) {
    if (-not (Test-Path -LiteralPath $bootgen)) { throw "bootgen not found: $bootgen" }
    $fsbl = 'C:\Users\210\Documents\intcode\123\hub75_display\build\work\vitis_sd\hub75_sd_platform\export\hub75_sd_platform\sw\boot\fsbl.elf'
    if (-not (Test-Path -LiteralPath $fsbl)) { throw "FSBL not found: $fsbl" }
    Write-Host "bootgen -> $Out"
    & $bootgen -image $bif -arch zynq -o $boot -w on
    if ($LASTEXITCODE -ne 0) { throw "bootgen failed ($LASTEXITCODE)" }
}
if (-not (Test-Path -LiteralPath $boot)) { throw "boot image not found: $boot" }

$payload = [ordered]@{
    'BOOT.bin'          = $boot
    'image.ub'          = (Join-Path $wl 'image_usb_autostart.ub')
    'uEnv.txt'          = (Join-Path $wl 'uEnv.txt')
    'hub75d'            = (Join-Path $wl 'hub75d')
    'hub75_anim_heart'  = (Join-Path $wl 'hub75_anim_heart')
    'hub75_anim_spheres' = (Join-Path $wl 'hub75_anim_spheres')
    'hub75_boot.frm'    = (Join-Path $wl 'hub75_boot.frm')
    'hub75.conf'        = (Join-Path $wl 'hub75.conf')
}
foreach ($k in $payload.Keys) {
    if (-not (Test-Path -LiteralPath $payload[$k])) { throw "missing payload: $k -> $($payload[$k])" }
}
Get-Item -LiteralPath $boot | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize

$letter = $Drive.TrimEnd(':', '\').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as F:" }
if (-not (Test-Path -LiteralPath "${letter}:\")) {
    Write-Host "Drive ${letter}: not present; skip SD copy. Insert the card and re-run."
    return
}
$backup = Join-Path $repo ('build\work\sd_backup\usb_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($k in $payload.Keys) {
    Copy-Item "${letter}:\$k" (Join-Path $backup $k) -Force -ErrorAction SilentlyContinue
}
foreach ($k in $payload.Keys) {
    # Keep an existing hub75.conf: it may hold the user's edits.
    if ($k -eq 'hub75.conf' -and (Test-Path -LiteralPath "${letter}:\hub75.conf")) {
        Write-Host "kept existing hub75.conf"
        continue
    }
    Copy-Item $payload[$k] "${letter}:\$k" -Force
    Write-Host "copied $k"
}
try { Write-VolumeCache -DriveLetter $letter | Out-Null } catch {}
Get-FileHash "${letter}:\BOOT.bin" -Algorithm MD5 | Format-List
Get-FileHash "${letter}:\image.ub" -Algorithm MD5 | Format-List
Write-Host 'SD updated. Eject, insert into the board, power-cycle.'
