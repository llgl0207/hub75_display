# Robust version: tolerates the USB serial port disappearing when the board
# is powered off, reopens it after power-on, holds U-Boot autoboot, prints
# bootargs, sets the HUB75 bootargs and boots.
#
# Usage: powershell -NoProfile -File build/uboot_hub75_interact2.ps1 -WaitSeconds 300

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
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_uboot_interact2.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
$sp = $null
try {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $firstData = $null
    while ((Get-Date) -lt $deadline) {
        if (-not $sp) {
            try {
                $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
                $sp.ReadTimeout = 500
                $sp.DtrEnable = $false
                $sp.RtsEnable = $false
                $sp.Open()
                Write-Host "Port $Port opened"
            }
            catch {
                if ($sp) { try { $sp.Dispose() } catch {}; $sp = $null }
                Start-Sleep -Milliseconds 300
                continue
            }
        }
        try {
            $sp.Write(" ")
            Start-Sleep -Milliseconds 200
            $s = $sp.ReadExisting()
            if ($s) {
                $sw.Write($s)
                if (-not $firstData) {
                    $firstData = Get-Date
                    Write-Host "UART traffic seen"
                }
            }
        }
        catch {
            Write-Host "Serial port lost (board powered off?); waiting for it to return"
            try { $sp.Dispose() } catch {}
            $sp = $null
            $firstData = $null
            Start-Sleep -Milliseconds 300
            continue
        }
        if ($firstData -and ((Get-Date) - $firstData).TotalSeconds -ge $HoldAfterDataSeconds) { break }
    }
    if (-not $sp) { throw "Port $Port never became usable" }
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
