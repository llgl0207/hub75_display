# Replace the SD card's BOOT.bin with the HUB75-enabled image
# (our FSBL + hub75_ps_stage1.bit + vendor U-Boot).
# Usage: .\build\copy_hub75_boot_to_sd.ps1 -Drive F:
param(
    [Parameter(Mandatory = $true)][string]$Drive
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'build\work\vendor_linux\BOOT_hub75.bin'

$letter = $Drive.TrimEnd('\', ':').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as F:" }

$vol = Get-Volume -DriveLetter $letter
if (-not $vol) { throw "No mounted volume on ${letter}:" }
Write-Host ("Target: {0}: {1} {2}" -f $letter, $vol.FileSystemLabel, $vol.FileSystem)
if ($vol.FileSystem -notin @('FAT', 'FAT32')) {
    throw ("{0}: is {1}; the Zynq BootROM needs a FAT/FAT32 partition." -f $letter, $vol.FileSystem)
}

$dest = "${letter}:\"
$backup = Join-Path $root ('build\work\sd_backup\boot_before_hub75_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($name in @('BOOT.BIN', 'BOOT.bin')) {
    $p = Join-Path $dest $name
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $backup $name) -Force
        Write-Host "backed up $name -> $backup"
    }
}

Copy-Item $src (Join-Path $dest 'BOOT.bin') -Force

$extras = @('hub75_probe', 'hub75_pattern', 'uEnv.txt')
foreach ($extra in $extras) {
    $p = Join-Path $root ('build\work\vendor_linux\' + $extra)
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $dest $extra) -Force
        Write-Host "copied $extra"
    }
}

Get-FileHash (Join-Path $dest 'BOOT.bin') -Algorithm SHA256 | Format-List
Get-ChildItem $dest | Where-Object { $_.Name -match '^(BOOT|image|hub75|uEnv)' } |
    Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host 'Done. Eject the card, set SW4 to SD, power-cycle.'
