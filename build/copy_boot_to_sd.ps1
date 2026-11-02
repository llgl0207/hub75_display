# Copy board/output/BOOT.BIN to the root of a FAT32 removable drive.
#
# List candidate drives first:
#   Get-Volume | Where-Object DriveType -eq 'Removable'
# Then, with the microSD inserted:
#   .\build\copy_boot_to_sd.ps1 -Drive E:
#
# The script refuses non-removable or non-FAT32 volumes and only writes BOOT.BIN.

param(
    [Parameter(Mandatory = $true)][string]$Drive,
    [string]$Image = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Image)) {
    $Image = Join-Path $repo "board\output\BOOT.BIN"
}
if (-not (Test-Path -LiteralPath $Image)) {
    throw "BOOT.BIN not found: $Image (run build\run_build_sd_boot.bat first)"
}
$letter = $Drive.TrimEnd(':', '\')
$vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($vol.DriveType -ne "Removable") {
    throw ("Refusing to write {0}: drive type is {1}, not Removable" -f $Drive, $vol.DriveType)
}
if ($vol.FileSystem -notin @("FAT32", "FAT")) {
    throw ("Refusing to write {0}: filesystem is {1}, format it as FAT32 first" -f $Drive, $vol.FileSystem)
}
$dest = Join-Path ($letter + ":\") "BOOT.BIN"
Copy-Item -LiteralPath $Image -Destination $dest -Force
Write-Host ("Copied {0} ({1} bytes) -> {2}" -f $Image, (Get-Item -LiteralPath $Image).Length, $dest)
Write-Host "Eject the card, insert it into the board, set SW4 to the SD row, and power-cycle."
