# Reboot the board, stop U-Boot autoboot, and boot image_wifi.ub manually.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [string]$Out = "build\reports\uboot_wifi_boot.txt")
$root = Split-Path -Parent $PSScriptRoot
$outPath = Join-Path $root $Out
$log = New-Object System.IO.StreamWriter($outPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 100
$sp.ReadBufferSize = 65536
$sp.DtrEnable = $false
$sp.RtsEnable = $false

function ReadFor([int]$ms) {
    $end = (Get-Date).AddMilliseconds($ms)
    $acc = ""
    while ((Get-Date) -lt $end) {
        $s = $sp.ReadExisting()
        if ($s) { $acc += $s; $script:log.Write($s) }
        Start-Sleep -Milliseconds 30
    }
    return $acc
}

try {
    $sp.Open()
    $sp.Write("sync; reboot" + [char]13)
    $null = ReadFor 4000
    $stopped = $false
    for ($i = 0; $i -lt 30; $i++) {
        $sp.Write(" ")
        $s = ReadFor 400
        if ($s -match "Zynq>") { $stopped = $true; break }
    }
    if (-not $stopped) {
        $sp.Write([char]13)
        $s = ReadFor 800
        if ($s -match "Zynq>") { $stopped = $true }
    }
    if ($stopped) {
        $log.WriteLine("`r`n=== UBOOT_STOPPED ===")
        $sp.Write("setenv bootargs 'console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused cpuidle.off=1 idle=poll maxcpus=1 usbcore.autosuspend=-1'" + [char]13)
        $null = ReadFor 800
        $sp.Write("fatload mmc 0:1 0x18000000 image_wifi.ub" + [char]13)
        $null = ReadFor 3000
        $sp.Write("bootm 0x18000000" + [char]13)
    } else {
        $log.WriteLine("`r`n=== AUTOBOOT_NOT_STOPPED ===")
    }
    $null = ReadFor 60000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
