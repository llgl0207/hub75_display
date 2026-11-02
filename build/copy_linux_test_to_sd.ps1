# Copy the current Linux test boot image and user programs to the microSD FAT
# partition (the board's BOOT partition).
#
# Usage:
#   Get-Volume | Where-Object DriveType -eq 'Removable'
#   .\build\copy_linux_test_to_sd.ps1 -Drive E: -Boot build\work\vendor_linux\BOOT_hub75_bram32_ir3.bin
#
# Without -Boot, the newest BOOT_hub75_*.bin is used. A backup of the existing
# BOOT.bin is kept under build\work\sd_backup\.

param(
    [Parameter(Mandatory = $true)][string]$Drive,
    [string]$Boot = "",
    [switch]$KeepImageUb
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Boot)) {
    $Boot = Get-ChildItem (Join-Path $repo 'build\work\vendor_linux') -Filter 'BOOT_hub75_*.bin' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not (Test-Path -LiteralPath $Boot)) { throw "boot image not found: $Boot" }

$letter = $Drive.TrimEnd(':', '\').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as E:" }
$vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($vol.FileSystem -notin @('FAT', 'FAT32')) {
    throw ("{0}: is {1}; the Zynq BootROM needs the FAT/FAT32 BOOT partition." -f $letter, $vol.FileSystem)
}
$dest = "${letter}:\"

$backup = Join-Path $repo ('build\work\sd_backup\boot_before_test_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($name in @('BOOT.BIN', 'BOOT.bin')) {
    $p = Join-Path $dest $name
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $backup $name) -Force
        Write-Host "backed up $name -> $backup"
    }
}

Copy-Item $Boot (Join-Path $dest 'BOOT.bin') -Force
Write-Host ("Copied {0} -> BOOT.bin" -f (Split-Path -Leaf $Boot))

foreach ($bin in @('hub75_diag', 'hub75_pattern_bram32', 'hub75_pattern')) {
    $src = Join-Path $repo ('build\work\vendor_linux\' + $bin)
    if (Test-Path -LiteralPath $src) {
        Copy-Item $src (Join-Path $dest $bin) -Force
        Write-Host "copied $bin"
    }
}

$uEnv = Join-Path $repo 'build\work\vendor_linux\uEnv.txt'
if (Test-Path -LiteralPath $uEnv) {
    Copy-Item $uEnv (Join-Path $dest 'uEnv.txt') -Force
    Write-Host "copied uEnv.txt"
}

Get-FileHash (Join-Path $dest 'BOOT.bin') -Algorithm SHA256 | Format-List
Write-Host 'Done. Eject the card, insert it into the board, power-cycle.'
