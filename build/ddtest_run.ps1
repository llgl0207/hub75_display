# One-off: does BusyBox dd fill a bs=4096 block from a tty (full_read), or
# does it count a short read as a block?  Safe payload: 'A' lines, so any
# leftover bytes reaching the shell are only "AAAA: not found".
param([string]$Payload = "build/work/ddtest.bin", [string]$Port = "COM11")
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Payload))
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 20000; $sp.ReadBufferSize = 65536
$sp.DtrEnable = $false; $sp.RtsEnable = $false
try {
    $sp.Open()
    $sp.Write("stty raw -echo < /dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $null = $sp.ReadExisting()
    $sp.Write("echo RAWOK >/dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 400
    $p = $sp.ReadExisting()
    Write-Host "raw probe: [$p]"
    if ($p -notlike "*RAWOK*" -or $p -like "*echo RAWOK*") { throw "raw probe failed" }
    $cmd = "rm -f /tmp/ddtest; dd bs=4096 count=2 of=/tmp/ddtest; stty sane < /dev/ttyPS0; (ls -l /tmp/ddtest; md5sum /tmp/ddtest; echo DDTEST_END) >/dev/ttyPS0 2>&1"
    $sp.Write($cmd + [char]13)
    Start-Sleep -Milliseconds 600
    $sp.Write($bytes, 0, $bytes.Length)
    $deadline = (Get-Date).AddSeconds(30)
    while ($sp.BytesToWrite -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    $out = ""
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and $out -notlike "*DDTEST_END*") {
        $s = $sp.ReadExisting()
        if ($s) { $out += $s } else { Start-Sleep -Milliseconds 100 }
    }
    Write-Host "--- board output ---"
    Write-Host $out
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
