# Reproduce the ack-script preamble and watch whether dd runs or exits early.
param([string]$Port = "COM11")
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 20000; $sp.ReadBufferSize = 65536
$sp.DtrEnable = $false; $sp.RtsEnable = $false
$log = ""
$sp.Open()
try {
    $sp.Write("stty raw -echo < /dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $log += "A[" + $sp.ReadExisting() + "] "
    $sp.Write("echo RAWOK >/dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $log += "B[" + $sp.ReadExisting() + "] "
    $sp.Write("rm -f /tmp/t6" + [char]13)
    Start-Sleep -Milliseconds 300
    $log += "C[" + $sp.ReadExisting() + "] "
    $sp.Write("stty raw -echo; echo R7777 >/dev/ttyPS0; echo PRE >/dev/ttyPS0; dd bs=1 count=4 >> /tmp/t6; echo POST >/dev/ttyPS0; stty sane; echo D7777 >/dev/ttyPS0" + [char]13)
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline) {
        $s = $sp.ReadExisting()
        if ($s) { $log += $s }
        Start-Sleep -Milliseconds 40
    }
    Write-Host $log
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
