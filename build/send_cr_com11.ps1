# Send a carriage return to the PS console and read whatever comes back.
# Useful to wake a login prompt or check whether Linux is alive.
# Usage: powershell -NoProfile -File build/send_cr_com11.ps1 -Seconds 5

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$Seconds = 5,
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_cr.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false

$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
try {
    $sp.Open()
    $sp.Write("`r`n")
    Write-Host "Sent CR to $Port, reading for $Seconds s -> $Out"
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $s = $sp.ReadExisting() } catch { break }
        if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 50 }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
