# Capture COM11 across a board power cycle: keep trying to open the port and
# write everything received to a file until the deadline.
#
# Run this first, then power-cycle the board (SD boot). It picks up the FSBL
# and application banner as soon as the CP2102 re-enumerates.
#
#   powershell -NoProfile -File build/capture_com11_retry.ps1 -Seconds 40

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$Seconds = 40,
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_sd_boot.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
$sp = $null
$deadline = (Get-Date).AddSeconds($Seconds)
$opened = $false

try {
    while ((Get-Date) -lt $deadline) {
        if ($null -eq $sp -or -not $sp.IsOpen) {
            try {
                $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
                $sp.ReadTimeout = 500
                $sp.DtrEnable = $false
                $sp.RtsEnable = $false
                $sp.Open()
                if (-not $opened) {
                    Write-Host "Opened $Port at $Baud"
                    $opened = $true
                }
            }
            catch {
                if ($null -ne $sp) { try { $sp.Dispose() } catch {} }
                $sp = $null
                Start-Sleep -Milliseconds 200
                continue
            }
        }
        try {
            $s = $sp.ReadExisting()
            if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 50 }
        }
        catch {
            try { $sp.Close() } catch {}
            try { $sp.Dispose() } catch {}
            $sp = $null
            Start-Sleep -Milliseconds 200
        }
    }
}
finally {
    if ($null -ne $sp) {
        try { if ($sp.IsOpen) { $sp.Close() } } catch {}
        try { $sp.Dispose() } catch {}
    }
    $sw.Close()
}
Write-Host "Capture done: $Out"
