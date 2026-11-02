# Build the Linux BOOT image from the current bitstream, then (if the SD card's
# FAT partition is mounted) copy BOOT.bin and the test tools onto it.
#
# Usage: .\build\build_and_flash_sd.ps1 [-Drive F:] [-SkipBootgen]
param(
    [string]$Drive = "F:",
    [switch]$SkipBootgen,
    [string]$Out = "BOOT_hub75_bram32_ir4.bin"
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$wl = Join-Path $repo 'build\work\vendor_linux'
$bootgen = 'E:\AMD\2026.1\Vitis\bin\bootgen.bat'
$bif = Join-Path $wl 'hub75_linux.bif'
$boot = Join-Path $wl $Out

if (-not $SkipBootgen) {
    if (-not (Test-Path -LiteralPath $bootgen)) { throw "bootgen not found: $bootgen" }
    Write-Host "bootgen -> $Out"
    & $bootgen -image $bif -arch zynq -o $boot -w on
    if ($LASTEXITCODE -ne 0) { throw "bootgen failed ($LASTEXITCODE)" }
}
if (-not (Test-Path -LiteralPath $boot)) { throw "boot image not found: $boot" }
Get-Item -LiteralPath $boot | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize

$letter = $Drive.TrimEnd(':', '\').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as F:" }
if (-not (Test-Path -LiteralPath "${letter}:\")) {
    Write-Host "Drive ${letter}: not present; skip SD copy. Insert the card and re-run."
    return
}
$backup = Join-Path $repo ('build\work\sd_backup\boot_before_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item "${letter}:\BOOT.bin" (Join-Path $backup 'BOOT.bin') -Force -ErrorAction SilentlyContinue
Copy-Item $boot "${letter}:\BOOT.bin" -Force
foreach ($f in @('hub75_diag', 'hub75_pattern_bram32')) {
    $src = Join-Path $wl $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item $src "${letter}:\$f" -Force
        Write-Host "copied $f"
    }
}
try { Write-VolumeCache -DriveLetter $letter | Out-Null } catch {}
Get-FileHash "${letter}:\BOOT.bin" -Algorithm MD5 | Format-List
Write-Host 'SD updated. Eject, insert into the board, power-cycle.'
