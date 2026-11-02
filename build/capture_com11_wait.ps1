# Wait for the PS UART to enumerate (board power-on), then capture its output.
# Use this when the board is powered off and COM11 does not exist yet.
# Usage: powershell -NoProfile -File build/capture_com11_wait.ps1 -WaitSeconds 300 -CaptureSeconds 90

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$WaitSeconds = 300,
    [int]$CaptureSeconds = 90,
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_wait_capture.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
$sp = $null
try {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $candidate = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
            $candidate.ReadTimeout = 500
            $candidate.DtrEnable = $false
            $candidate.RtsEnable = $false
            $candidate.Open()
            $sp = $candidate
            break
        }
        catch {
            if ($candidate) { $candidate.Dispose() }
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $sp -or -not $sp.IsOpen) { throw "Port $Port did not appear within $WaitSeconds s" }
    Write-Host "Port $Port opened; capturing $CaptureSeconds s -> $Out"
    $end = (Get-Date).AddSeconds($CaptureSeconds)
    while ((Get-Date) -lt $end) {
        try { $s = $sp.ReadExisting() } catch { break }
        if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 50 }
    }
}
finally {
    if ($sp) {
        if ($sp.IsOpen) { $sp.Close() }
        $sp.Dispose()
    }
    $sw.Close()
}
Write-Host "Capture done: $Out"
