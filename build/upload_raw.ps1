# Raw upload of a gzip file to the board over the console UART.
#   stty raw (no echo, no signals, no flow control)
#   head -c <size> /dev/ttyPS0 > /tmp/<name>   (exits after exactly <size> bytes)
#   stty sane; gunzip; chmod
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$Remote = "/tmp/hub75d.gz",
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [string]$Out = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $root "build\reports\upload_raw_out.txt" }
if (-not (Test-Path -LiteralPath $File)) { throw "file not found: $File" }
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $File))
Write-Host ("Uploading {0} bytes at {1} baud (~{2:N0} s)" -f $bytes.Length, $Baud, ($bytes.Length * 10.0 / $Baud))

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400
$sp.WriteTimeout = 15000
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true

function Pump([int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        try { $s = $sp.ReadExisting() } catch { break }
        if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 30 }
    }
}

try {
    $sp.Open()
    # Make sure we are at a shell prompt.
    $sp.Write("`r")
    Pump 1500
    $sp.Write("stty -icanon -echo -isig -ixon -ixoff`r")
    Pump 1200
    $sp.Write("head -c $($bytes.Length) /dev/ttyPS0 > $Remote`r")
    Pump 1200

    $sent = 0
    for ($i = 0; $i -lt $bytes.Length; $i += 1024) {
        $n = [Math]::Min(1024, $bytes.Length - $i)
        $sp.Write($bytes, $i, $n)
        $sent += $n
        if (($sent % 65536) -lt 1024) { Write-Host ("  {0:N0} / {1:N0}" -f $sent, $bytes.Length) }
    }
    Pump 2500
    # Restore the console line discipline and check the transfer.
    $sp.Write("stty sane`r")
    Pump 800
    foreach ($cmd in @(
        "ls -la $Remote",
        "md5sum $Remote",
        "gunzip -f $Remote",
        "chmod +x $($Remote -replace '\.gz$','')",
        "md5sum $($Remote -replace '\.gz$','')"
    )) {
        Write-Host ">> $cmd"
        $sp.Write($cmd + "`r")
        Pump 900
    }
    Pump 2000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
