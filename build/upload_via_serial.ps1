# Upload a gzip-compressed binary to the board over the console UART using a
# raw tty read (`cat /dev/ttyPS0 > file`), then decompress and run it.
# Usage: .\build\upload_via_serial.ps1 -File build\work\hub75_diag.gz
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [string]$Out = "",
    [string]$RemoteName = "/tmp/hub75_diag.gz",
    [string]$RunCommand = "/tmp/hub75_diag"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path $root "build\reports\upload_out.txt"
}
if (-not (Test-Path -LiteralPath $File)) { throw "file not found: $File" }
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $File))
Write-Host ("Uploading {0} bytes ({1:N0} KiB) at {2} baud (~{3:N0} s)" -f `
    $bytes.Length, ($bytes.Length / 1KB), $Baud, ($bytes.Length * 10.0 / $Baud))

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.WriteTimeout = 10000
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
    # Raw, no echo, no software flow control, keep ISIG so Ctrl-C stops cat.
    $sp.Write("stty -icanon -echo -ixon -ixoff isig`r")
    Pump 400
    $sp.Write("cat /dev/ttyPS0 > $RemoteName`r")
    Pump 600

    $sent = 0
    for ($i = 0; $i -lt $bytes.Length; $i += 512) {
        $n = [Math]::Min(512, $bytes.Length - $i)
        $sp.Write($bytes, $i, $n)
        $sent += $n
        if (($sent % 32768) -lt 512) { Write-Host ("  {0:N0} / {1:N0}" -f $sent, $bytes.Length) }
    }
    # Ctrl-C ends cat (ISIG consumes it, so it is not written to the file).
    $sp.Write([byte[]](3), 0, 1)
    Pump 800
    $sp.Write("`r")
    Pump 500
    # Restore the normal console line discipline before running commands.
    $sp.Write("stty sane`r")
    Pump 600

    foreach ($cmd in @(
        "ls -la $RemoteName",
        "md5sum $RemoteName",
        "gunzip -f $RemoteName",
        "chmod +x $RunCommand",
        "ls -la $RunCommand",
        "md5sum $RunCommand",
        $RunCommand
    )) {
        Write-Host ">> $cmd"
        $sp.Write($cmd + "`r")
        Pump 900
    }
    Pump 6000
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
