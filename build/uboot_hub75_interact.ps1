# Wait for actual UART traffic (board power-on), hold U-Boot autoboot,
# print the bootargs environment, set the HUB75 bootargs and boot.
#
# Usage: powershell -NoProfile -File build/uboot_hub75_interact.ps1 -WaitSeconds 300

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$WaitSeconds = 300,
    [int]$HoldAfterDataSeconds = 8,
    [int]$CaptureSeconds = 70,
    [string]$Bootargs = "console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused",
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_uboot_interact.txt"
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
    if (-not $sp -or -not $sp.IsOpen) { throw "Port $Port did not open within $WaitSeconds s" }

    Write-Host "Port open; waiting for UART traffic and sending spaces..."
    $firstData = $null
    while ((Get-Date) -lt $deadline) {
        $sp.Write(" ")
        Start-Sleep -Milliseconds 200
        $s = $sp.ReadExisting()
        if ($s) {
            $sw.Write($s)
            if (-not $firstData) { $firstData = Get-Date; Write-Host "UART traffic seen" }
        }
        if ($firstData -and ((Get-Date) - $firstData).TotalSeconds -ge $HoldAfterDataSeconds) { break }
    }
    if (-not $firstData) { throw "No UART traffic within $WaitSeconds s" }

    Start-Sleep -Milliseconds 500
    $sp.Write("`r")
    Start-Sleep -Milliseconds 500
    $s = $sp.ReadExisting(); if ($s) { $sw.Write($s) }

    Write-Host ">> printenv bootargs"
    $sp.Write("printenv bootargs`r")
    Start-Sleep -Milliseconds 800
    $s = $sp.ReadExisting(); if ($s) { $sw.Write($s) }

    Write-Host ">> setenv bootargs $Bootargs"
    $sp.Write("setenv bootargs $Bootargs`r")
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
