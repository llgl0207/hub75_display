# Manual USB recovery with the SIGSTOP/GPIO-clock/RST/rebind sequence from
# report §15.4.1, executed while hub75d's 1 s kick loop is paused.
param([string]$Port = "COM11", [int]$Seconds = 12)
$ErrorActionPreference = 'Stop'
$line = 'kill -STOP $(pidof hub75d); A=$(devmem 0xF800012C); echo APER=$A >/dev/ttyPS0; devmem 0xF800012C 32 0x017C044D >/dev/ttyPS0; devmem 0xE000A20C 32 0x4000 >/dev/ttyPS0; devmem 0xE000A210 32 0x4000 >/dev/ttyPS0; devmem 0xE000A044 32 0x4000 >/dev/ttyPS0; U=$(devmem 0xE0002140); echo USBCMD=$U >/dev/ttyPS0; devmem 0xE0002140 32 $((U | 2)) >/dev/ttyPS0; sleep 0.2; echo RST_AFTER=$(devmem 0xE0002140) >/dev/ttyPS0; echo e0002000.usb > /sys/bus/platform/drivers/chipidea-usb2/unbind; sleep 0.1; echo e0002000.usb > /sys/bus/platform/drivers/chipidea-usb2/bind; sleep 1.5; ls /sys/bus/usb/devices/ >/dev/ttyPS0 2>&1; dmesg | tail -12 >/dev/ttyPS0 2>&1; kill -CONT $(pidof hub75d); echo RCDONE >/dev/ttyPS0'
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 20000; $sp.ReadBufferSize = 65536
$sp.DtrEnable = $false; $sp.RtsEnable = $false
$out = ""
$sp.Open()
try {
    $sp.Write($line + [char]13)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline -and $out -notlike "*RCDONE*") {
        $s = $sp.ReadExisting()
        if ($s) { $out += $s } else { Start-Sleep -Milliseconds 50 }
    }
    Write-Host $out
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
