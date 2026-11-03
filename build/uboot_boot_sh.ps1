# Catch U-Boot after a JTAG system reset, configure SD1, and boot image_wifi.ub
# with rdinit=/bin/sh so we get a root shell on ttyPS0 instead of hub75d.
# Deliberately does NOT drive MIO8: the board pulls WL_REG_ON up (R98 10K), so
# leaving MIO8 as an input keeps the AP6212 powered.  Driving it low (as the
# previous script did) held the radio in reset.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [int]$WaitSeconds = 120, [string]$Out = "build\reports\uboot_boot_sh.txt")
$root = Split-Path -Parent $PSScriptRoot
$log = New-Object System.IO.StreamWriter((Join-Path $root $Out), $false, [System.Text.Encoding]::UTF8)
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
        Start-Sleep -Milliseconds 25
    }
    return $acc
}

function SendLine([string]$s, [int]$wait = 200) {
    $sp.Write($s + [char]13)
    $null = Drain $wait
}

try {
    $sp.Open()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stopped = $false
    $acc = ""
    while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
        $sp.Write(" ")
        $acc += Drain 300
        if ($acc -match "Zynq>") { $stopped = $true; break }
        if ($acc.Length -gt 20000) { $acc = $acc.Substring($acc.Length - 2000) }
    }
    if ($stopped) {
        $log.WriteLine("`r`n=== UBOOT_STOPPED at $([math]::Round($sw.Elapsed.TotalSeconds,1))s ===")
        SendLine "setenv bootargs 'console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused cpuidle.off=1 idle=poll maxcpus=1 usbcore.autosuspend=-1 rdinit=/bin/sh'" 500
        foreach ($a in @("0xF8000728","0xF800072C","0xF8000730","0xF8000734","0xF8000738","0xF800073C")) {
            SendLine "mw.l $a 0x00001680" 120
        }
        SendLine "mw.l 0xF8000154 0x00000A03" 150
        SendLine "mw.l 0xF800012C 0x017C0C4D" 150
        SendLine "md.l 0xE000A040 1" 150
        SendLine "md.l 0xE000A060 1" 150
        SendLine "md.l 0xE000A204 1" 150
        SendLine "md.l 0xE000A208 1" 150
        SendLine "md.l 0xF8000720 1" 150
        SendLine "md.l 0xF8000728 1" 150
        SendLine "md.l 0xF800073C 1" 150
        SendLine "fatload mmc 0:1 0x18000000 image_wifi.ub" 3500
        SendLine "bootm 0x18000000" 200
    } else {
        $log.WriteLine("`r`n=== NO_UBOOT_PROMPT within $WaitSeconds s ===")
    }
    $null = Drain 30000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
