# Reboot, stop U-Boot, pre-configure SD1/WiFi power at the U-Boot stage, then
# boot our 4.14 kernel (image_wifi.ub).
param([string]$Port = "COM11", [int]$Baud = 115200,
      [string]$Out = "build\reports\uboot_boot_wifi_wl.txt")
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
    $sp.Write("sync; reboot" + [char]13)
    $null = Drain 4000
    $stopped = $false
    $acc = ""
    for ($i = 0; $i -lt 30; $i++) {
        $sp.Write(" ")
        $acc += Drain 350
        if ($acc -match "Zynq>") { $stopped = $true; break }
    }
    if (-not $stopped) {
        $sp.Write([char]13)
        $acc += Drain 800
        if ($acc -match "Zynq>") { $stopped = $true }
    }
    if (-not $stopped) {
        $log.WriteLine("`r`n=== AUTOBOOT_NOT_STOPPED ===")
        $null = Drain 30000
    } else {
        $log.WriteLine("`r`n=== UBOOT_STOPPED ===")
        SendLine "setenv bootargs 'console=ttyPS0,115200 earlyprintk mem=256M clk_ignore_unused cpuidle.off=1 idle=poll maxcpus=1 usbcore.autosuspend=-1'" 500
        # SD1 pin mux (MIO10..15) and SDI1 clock enable
        SendLine "mw.l 0xF8000728 0x00001680" 150
        SendLine "mw.l 0xF800072C 0x00001680" 150
        SendLine "mw.l 0xF8000730 0x00001680" 150
        SendLine "mw.l 0xF8000734 0x00001680" 150
        SendLine "mw.l 0xF8000738 0x00001680" 150
        SendLine "mw.l 0xF800073C 0x00001680" 150
        SendLine "mw.l 0xF8000154 0x00000A03" 150
        SendLine "mw.l 0xF800012C 0x017C0C4D" 150
        SendLine "mw.l 0xF8000830 0x00380037" 150
        SendLine "mw.l 0xF8000834 0x003A0039" 150
        # WL_REG_ON = MIO8 (GPIO function, output high)
        SendLine "mw.l 0xF8000708 0x00000600" 150
        SendLine "mw.l 0xE000A204 0x00000100" 150
        SendLine "mw.l 0xE000A208 0x00000100" 150
        SendLine "mw.l 0xE000A200 0x00000100" 150
        SendLine "fatload mmc 0:1 0x18000000 image_wifi.ub" 2500
        SendLine "bootm 0x18000000" 200
    }
    $null = Drain 60000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
