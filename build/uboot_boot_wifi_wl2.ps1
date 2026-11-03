# Wait for a fresh U-Boot prompt after an external JTAG system reset, then
# configure SD1 + WL_REG_ON correctly and boot image_wifi.ub.
#
# 2026-11-04 fix: WL_REG_ON is MIO8; the bank-0 DATA register is 0xE000A040
# (MASK_DATA_0_LSW 0xE000A000), not 0xE000A200.  The old script wrote the
# data bit to an unimplemented address, so the AP6212 was never powered.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [int]$WaitSeconds = 120, [string]$Out = "build\reports\uboot_boot_wifi_wl2.txt")
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
        SendLine "setenv bootargs 'console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused cpuidle.off=1 idle=poll maxcpus=1 usbcore.autosuspend=-1'" 500
        # SD1 pin mux: MIO10..15 = SDIO1 (L2 function, 3.3V, pull-up)
        foreach ($a in @("0xF8000728","0xF800072C","0xF8000730","0xF8000734","0xF8000738","0xF800073C")) {
            SendLine "mw.l $a 0x00001680" 120
        }
        # SDIO1 clock: IO PLL / 10, both gates on (0xA03); APER gates
        SendLine "mw.l 0xF8000154 0x00000A03" 150
        SendLine "mw.l 0xF800012C 0x017C0C4D" 150
        # MIO8 = WL_REG_ON. 0x0600 = GPIO (already set by the FSBL).
        SendLine "mw.l 0xF8000720 0x00000600" 150
        # Bank-0 GPIO: MIO8 output, output-enable, data high.
        SendLine "mw.l 0xE000A204 0x00000100" 150
        SendLine "mw.l 0xE000A208 0x00000100" 150
        SendLine "mw.l 0xE000A000 0x01000100" 150
        SendLine "md.l 0xE000A040 1" 200
        SendLine "md.l 0xE000A204 1" 200
        SendLine "md.l 0xE000A208 1" 200
        SendLine "md.l 0xF8000720 1" 200
        SendLine "md.l 0xF8000728 1" 200
        SendLine "md.l 0xF800073C 1" 200
        SendLine "fatload mmc 0:1 0x18000000 image_wifi.ub" 3500
        SendLine "bootm 0x18000000" 200
    } else {
        $log.WriteLine("`r`n=== NO_UBOOT_PROMPT within $WaitSeconds s ===")
    }
    $null = Drain 90000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
