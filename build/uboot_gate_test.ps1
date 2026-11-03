# Diagnose the vendor `uenvboot` gate: it runs `if test -n $uenvcmd`, and the
# unquoted expansion fails for some values.  Boot-stops U-Boot, tests short /
# 340-byte / 361-byte values and a split-variable variant, then boots normally.
# Does not write the SD card.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [int]$StopWaitSeconds = 35, [string]$Out = "build\reports\uboot_gate_test.txt")
$root = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $root $Out
$dir = Split-Path -Parent $logPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$log = New-Object System.IO.StreamWriter($logPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 100
$sp.ReadBufferSize = 65536
$sp.DtrEnable = $false
$sp.RtsEnable = $false

function Drain([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    $acc = ""
    while ((Get-Date) -lt $end) {
        $s = $sp.ReadExisting()
        if ($s) { $acc += $s; $script:log.Write($s) }
        Start-Sleep -Milliseconds 20
    }
    return $acc
}

function SendLine([string]$s, [int]$wait = 400) {
    $sp.Write($s + "`r")
    return (Drain $wait)
}

$v340 = 'mw.l 0xE000A20C 0x4000; mw.l 0xE000A210 0x4000; mw.l 0xE000A044 0x4000; if fatload mmc 0:1 0x18000000 hub75_boot.frm; then mw.l 0x41200000 0x18000000; mw.l 0x41200008 0x2; sleep 1; mw.l 0x41200008 0x3; fi'
$v361 = 'mw.l 0xE000A20C 0x4000; mw.l 0xE000A210 0x4000; mw.l 0xE000A044 0x4000; mw.l 0xE0002140 0x2; if fatload mmc 0:1 0x18000000 hub75_boot.frm; then mw.l 0x41200000 0x18000000; mw.l 0x41200008 0x2; sleep 1; mw.l 0x41200008 0x3; fi'

try {
    $sp.Open()
    $null = SendLine "reboot -f" 500
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stopped = $false
    $acc = ""
    while ($sw.Elapsed.TotalSeconds -lt $StopWaitSeconds) {
        $sp.Write(" ")
        $acc += Drain 250
        if ($acc -match "Zynq>") { $stopped = $true; break }
        if ($acc.Length -gt 30000) { $acc = $acc.Substring($acc.Length - 3000) }
    }
    if (-not $stopped) {
        $log.WriteLine("`r`n=== NO_UBOOT_PROMPT ===")
    } else {
        $log.WriteLine("`r`n=== UBOOT_STOPPED ===")
        $null = SendLine "setenv t1 'mw.l 0xE0002140 0x2'" 400
        $null = SendLine "if test -n `$t1; then echo T1_TRUE; else echo T1_FALSE; fi" 400
        $null = SendLine "setenv t2 'mw.l 0xE000A20C 0x4000; mw.l 0xE000A210 0x4000; mw.l 0xE000A044 0x4000'" 400
        $null = SendLine "if test -n `$t2; then echo T2_TRUE; else echo T2_FALSE; fi" 400
        $null = SendLine "setenv t340 '$v340'" 800
        $null = SendLine "printenv t340" 500
        $null = SendLine "if test -n `$t340; then echo T340_TRUE; else echo T340_FALSE; fi" 500
        $null = SendLine "setenv t361 '$v361'" 800
        $null = SendLine "printenv t361" 500
        $null = SendLine "if test -n `$t361; then echo T361_TRUE; else echo T361_FALSE; fi" 500
        $log.WriteLine("`r`n=== SPLIT VARIANT ===")
        $null = SendLine "setenv bootfx 'mw.l 0xE000A20C 0x4000; mw.l 0xE000A210 0x4000; mw.l 0xE000A044 0x4000; mw.l 0xE0002140 0x2'" 600
        $null = SendLine "setenv splash 'if fatload mmc 0:1 0x18000000 hub75_boot.frm; then mw.l 0x41200000 0x18000000; mw.l 0x41200008 0x2; sleep 1; mw.l 0x41200008 0x3; fi'" 600
        $null = SendLine "setenv uenvcmd 'run bootfx; run splash'" 400
        $null = SendLine "if test -n `$uenvcmd; then echo SPLIT_TRUE; else echo SPLIT_FALSE; fi" 500
        $null = SendLine "run uenvcmd" 2500
        $log.WriteLine("`r`n=== BOOT ===")
        $null = SendLine "boot" 1000
        $null = Drain 4000
    }
    $null = Drain 2000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
Write-Host "Done: $logPath"
