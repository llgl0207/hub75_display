param([string]$Port = "COM11", [int]$Baud = 115200, [string]$Out = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $root "build\reports\recover_console.txt" }
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
function Pump([int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        try { $s = $sp.ReadExisting() } catch { break }
        if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 40 }
    }
}
try {
    $sp.Open()
    $sp.Write([byte[]](3), 0, 1)     # Ctrl-C
    Pump 400
    $sp.Write("stty sane`r")
    Pump 400
    $sp.Write("`r")
    Pump 400
    $sp.Write("echo RECOVER_OK`r")
    Pump 1500
    $sp.Write("ls -la /tmp/hub75_diag.gz; ls -la /tmp/hub75_diag`r")
    Pump 1500
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
