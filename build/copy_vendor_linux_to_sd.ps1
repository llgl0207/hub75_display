# Copy the MicroPhase Mizar-Z7 Linux demo (BOOT.bin + image.ub) to an SD card.
# Usage: .\build\copy_vendor_linux_to_sd.ps1 -Drive F:
param(
    [Parameter(Mandatory = $true)][string]$Drive
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'build\work\vendor_linux'

$letter = $Drive.TrimEnd('\', ':').ToUpper()
if ($letter -notmatch '^[A-Z]$') { throw "Drive must be a letter such as F:" }

$vol = Get-Volume -DriveLetter $letter
if (-not $vol) { throw "No mounted volume on ${letter}:" }
Write-Host ("Target: {0}: {1} {2}" -f $letter, $vol.FileSystemLabel, $vol.FileSystem)
if ($vol.DriveType -ne 'Removable') {
    Write-Warning ("{0}: is reported as {1}, not Removable. Ctrl+C now if this is not the SD card." -f $letter, $vol.DriveType)
    Start-Sleep -Seconds 3
}
if ($vol.FileSystem -notin @('FAT', 'FAT32')) {
    throw ("{0}: is {1}; the Zynq BootROM needs a FAT/FAT32 partition." -f $letter, $vol.FileSystem)
}

$dest = "${letter}:\"
$backup = Join-Path $root ('build\work\sd_backup\boot_before_linux_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($name in @('BOOT.BIN', 'BOOT.bin', 'image.ub')) {
    $p = Join-Path $dest $name
    if (Test-Path $p) {
        Copy-Item $p (Join-Path $backup $name) -Force
        Write-Host "backed up $name -> $backup"
    }
}

Copy-Item (Join-Path $src 'BOOT.bin') (Join-Path $dest 'BOOT.bin') -Force
Copy-Item (Join-Path $src 'image.ub') (Join-Path $dest 'image.ub') -Force

Write-Host ''
Get-FileHash (Join-Path $dest 'BOOT.bin') -Algorithm SHA256 | Format-List
Get-FileHash (Join-Path $dest 'image.ub') -Algorithm SHA256 | Format-List
Get-ChildItem $dest | Where-Object { $_.Name -match '^(BOOT|image)' } |
    Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host 'Done. Eject the card, set SW4 to SD, power-cycle, capture COM11 at 115200 8N1.'
