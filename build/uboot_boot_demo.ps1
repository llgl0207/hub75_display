# Interrupt U-Boot autoboot and boot the vendor 3.17 WiFi demo uImage.
param([string]$Port = "COM11", [int]$Baud = 115200,
      [string]$Out = "build\reports\uboot_demo_boot.txt")
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

try {
    $sp.Open()
    $stopped = $false
    $acc = ""
    for ($i = 0; $i -lt 80; $i++) {
        $sp.Write(" ")
        $acc += Drain 220
        if ($acc -match "Zynq>") { $stopped = $true; break }
    }
    if ($stopped) {
        $log.WriteLine("`r`n=== UBOOT_STOPPED ===")
        $sp.Write("setenv bootargs 'console=ttyPS0,115200 root=/dev/ram rw earlyprintk earlycon'" + [char]13)
        $null = Drain 600
        $sp.Write("fatload mmc 0:1 0x3000000 uImage" + [char]13)
        $null = Drain 2500
        $sp.Write("fatload mmc 0:1 0x1000000 uramdisk.image.gz" + [char]13)
        $null = Drain 2500
        $sp.Write("fatload mmc 0:1 0x2000000 devicetree.dtb" + [char]13)
        $null = Drain 1500
        $sp.Write("bootm 0x3000000 0x1000000 0x2000000" + [char]13)
    } else {
        $log.WriteLine("`r`n=== AUTOBOOT_NOT_STOPPED ===")
    }
    $null = Drain 60000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
