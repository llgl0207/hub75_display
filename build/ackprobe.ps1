# Probe: does the per-chunk command line work at small scale?
param([string]$Port = "COM11")
$ErrorActionPreference = 'Stop'
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 20000; $sp.ReadBufferSize = 65536
$sp.DtrEnable = $false; $sp.RtsEnable = $false
$out = ""
$sp.Open()
try {
    $sp.Write("rm -f /tmp/t2" + [char]13)
    Start-Sleep -Milliseconds 300
    $null = $sp.ReadExisting()
    $cmd = "stty raw -echo; echo R1234 >/dev/ttyPS0; dd bs=1 count=5 >> /tmp/t2; stty sane; echo D1234 >/dev/ttyPS0"
    $sp.Write($cmd + [char]13)
    Start-Sleep -Milliseconds 400
    $sp.Write([byte[]](0x48,0x45,0x4c,0x4c,0x4f), 0, 5)   # HELLO
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline -and $out -notlike "*D1234*") {
        $s = $sp.ReadExisting()
        if ($s) { $out += $s } else { Start-Sleep -Milliseconds 50 }
    }
    Write-Host "markers: [$out]"
    $sp.Write("ls -l /tmp/t2 >/dev/ttyPS0 2>&1; od -An -tx1 /tmp/t2 >/dev/ttyPS0 2>&1; echo PEND >/dev/ttyPS0" + [char]13)
    $out2 = ""
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline -and $out2 -notlike "*PEND*") {
        $s = $sp.ReadExisting()
        if ($s) { $out2 += $s } else { Start-Sleep -Milliseconds 50 }
    }
    Write-Host "file: [$out2]"
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
