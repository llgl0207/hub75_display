# Reboot from the live shell, stop U-Boot, and probe how the 361-byte uEnv.txt
# imports.  Read-only with respect to the SD card: load + env import + printenv,
# then continue booting the normal image.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [int]$StopWaitSeconds = 30, [string]$Out = "build\reports\uboot_env_probe.txt")
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

try {
    $sp.Open()
    $null = SendLine "reboot -f" 500

    # Wait for the U-Boot banner, then keep tapping space to interrupt autoboot.
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
        $null = SendLine "load mmc 0:1 0x00100000 uEnv.txt" 800
        $null = SendLine "env import -t 0x00100000 `${filesize}" 800
        $log.WriteLine("`r`n=== PRINTENV ===")
        $null = SendLine "printenv uenvcmd" 500
        $null = SendLine "printenv bootargs" 500
        $null = SendLine "printenv filesize" 500
        $log.WriteLine("`r`n=== GATE ===")
        $null = SendLine "if test -n `${uenvcmd}; then echo GATE_TRUE; else echo GATE_FALSE; fi" 500
        $log.WriteLine("`r`n=== BOOT ===")
        $null = SendLine "boot" 1000
        $null = Drain 4000
    }
    $null = Drain 3000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
Write-Host "Done: $logPath"
