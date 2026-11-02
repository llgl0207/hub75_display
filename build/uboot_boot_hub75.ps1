# Wait for the board to power on, stop U-Boot autoboot, set HUB75 bootargs
# (clk_ignore_unused so Linux does not gate FCLK0, mem=256M to reserve DDR
# for the PL frame buffers), then boot and capture the log.
#
# Usage: powershell -NoProfile -File build/uboot_boot_hub75.ps1 -WaitSeconds 300 -CaptureSeconds 70

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$WaitSeconds = 300,
    [int]$HoldSeconds = 12,
    [int]$CaptureSeconds = 70,
    [string]$Bootargs = "console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused",
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_uboot_hub75.txt"
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
    Write-Host "Port opened; holding U-Boot for $HoldSeconds s"

    # Keep sending spaces through FSBL + U-Boot countdown so autoboot stops.
    $holdEnd = (Get-Date).AddSeconds($HoldSeconds)
    while ((Get-Date) -lt $holdEnd) {
        $sp.Write(" ")
        Start-Sleep -Milliseconds 200
        $s = $sp.ReadExisting()
        if ($s) { $sw.Write($s) }
    }

    Start-Sleep -Milliseconds 800
    $s = $sp.ReadExisting(); if ($s) { $sw.Write($s) }

    $cmd = "setenv bootargs $Bootargs"
    Write-Host ">> $cmd"
    $sp.Write($cmd + "`r")
    Start-Sleep -Milliseconds 800
    $s = $sp.ReadExisting(); if ($s) { $sw.Write($s) }

    Write-Host ">> boot"
    $sp.Write("boot`r")

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
