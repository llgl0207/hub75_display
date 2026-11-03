# Wait for the user to power-cycle, catch U-Boot autoboot, and boot the
# vendor 3.17 WiFi demo (uImage + devicetree.dtb + uramdisk.image.gz).
param([string]$Port = "COM11", [int]$Baud = 115200,
      [int]$WaitSeconds = 150, [string]$Out = "build\reports\uboot_demo_wait.txt")
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
        $sp.Write("setenv bootargs 'console=ttyPS0,115200 root=/dev/ram rw earlyprintk earlycon'" + [char]13)
        $null = Drain 600
        $sp.Write("fatload mmc 0:1 0x3000000 uImage" + [char]13)
        $null = Drain 3000
        $sp.Write("fatload mmc 0:1 0x1000000 uramdisk.image.gz" + [char]13)
        $null = Drain 3000
        $sp.Write("fatload mmc 0:1 0x2000000 devicetree.dtb" + [char]13)
        $null = Drain 2000
        $sp.Write("bootm 0x3000000 0x1000000 0x2000000" + [char]13)
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
