# Send one or more shell lines to the board over the serial console and capture
# whatever the board writes to /dev/ttyPS0.
#
# The normal vendor image runs hub75d, which forwards its stdin (ttyPS0) to an
# interactive /bin/sh on a pty.  Shell stdout goes to the pty (the LED matrix),
# so commands must redirect diagnostics to /dev/ttyPS0 to be visible here.
#
# Usage:
#   powershell -NoProfile -File build/serial_cmd.ps1 -Cmd "echo PROBE > /dev/ttyPS0" -Wait 3
#   powershell -NoProfile -File build/serial_cmd.ps1 -CommandFile cmds.txt -Wait 20
param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [string]$Cmd = "",
    [string]$CommandFile = "",
    [int]$Wait = 5,
    [string]$Out = "build\reports\serial_cmd.txt",
    [switch]$Raw
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$outPath = Join-Path $root $Out
$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$log = New-Object System.IO.StreamWriter($outPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 100
$sp.ReadBufferSize = 65536
$sp.DtrEnable = $false
$sp.RtsEnable = $false

$lines = @()
if ($Cmd) { $lines += $Cmd }
if ($CommandFile) { $lines += (Get-Content -LiteralPath $CommandFile) }

try {
    $sp.Open()
    # Give the line discipline a moment, then submit the command(s).
    Start-Sleep -Milliseconds 200
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $sp.Write($line + "`r")
        Start-Sleep -Milliseconds 150
    }
    $deadline = (Get-Date).AddSeconds($Wait)
    while ((Get-Date) -lt $deadline) {
        $s = $sp.ReadExisting()
        if ($s) { $log.Write($s) }
        Start-Sleep -Milliseconds 30
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
Write-Host "Done: $outPath"
