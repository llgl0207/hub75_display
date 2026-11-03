# Upload a binary to the board over the PS UART (COM11).
#
# The naive "stty raw; dd" recipe only puts the *PTY* in raw mode; the console
# tty ttyPS0 keeps ISIG/ICANON and treats 0x03/0x1c/0x1a inside the payload as
# ^C/^\^Z, killing hub75d (first 0x03 in hub75d is at byte 284).  This script
# first puts ttyPS0 itself in raw mode, which also stops canonical buffering.
#
# The board shell runs the receiver with an ack marker, so "sent all bytes"
# and "dd consumed all bytes" are distinct: ACK_OK is printed only when the
# marker arrives after the count is satisfied.
#
# Usage:
#   .\build\serial_put.ps1 -Path build/work/vendor_linux/hub75d `
#                         -Dest /run/media/mmcblk0p1/hub75d.new
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Dest,
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$Chunk = 4096,
    [int]$AckSeconds = 90,
    [string]$Out = "build\reports\serial_put.txt"
)
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
$root = Split-Path -Parent $PSScriptRoot
$outPath = Join-Path $root $Out
$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$log = New-Object System.IO.StreamWriter($outPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true

$marker = "HUB75RX9"
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200
$sp.WriteTimeout = 20000
$sp.ReadBufferSize = 65536
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$ack = ""
try {
    $sp.Open()
    # 1. Console tty raw: no ISIG, no canonical, no echo.  Redirection form
    #    works whether or not this busybox stty knows -F.
    $sp.Write("stty raw -echo < /dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $log.Write($sp.ReadExisting())
    # 2. Prove it before running dd: with ECHO off only RAWOK comes back;
    #    if the command line is echoed too, raw mode did not take effect and
    #    a payload 0x03 would kill hub75d.
    $sp.Write("echo RAWOK >/dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $probe = $sp.ReadExisting()
    $log.Write($probe)
    if ($probe -notlike "*RAWOK*" -or $probe -like "*echo RAWOK*") {
        throw "console tty raw probe failed (RAWOK missing or command echoed); not starting dd. Capture: $outPath"
    }
    # 3. Receiver on the PTY (ttyPS0 is already raw; the first stty keeps it
    #    that way if something restored it).
    $cmd = "stty raw -echo < /dev/ttyPS0; stty raw -echo; dd bs=1 count=$($bytes.Length) of=$Dest; sync; stty sane; stty sane < /dev/ttyPS0; echo $marker >/dev/ttyPS0"
    $sp.Write($cmd + [char]13)
    Write-Host $cmd
    Start-Sleep -Milliseconds 600
    $log.Write($sp.ReadExisting())
    # 4. Payload.
    for ($i = 0; $i -lt $bytes.Length; $i += $Chunk) {
        $n = [Math]::Min($Chunk, $bytes.Length - $i)
        $sp.Write($bytes, $i, $n)
    }
    $deadline = (Get-Date).AddSeconds(180)
    while ($sp.BytesToWrite -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    Write-Host "payload queued to UART: $($bytes.Length) bytes"
    # 5. Wait for the shell to reach the ack after dd consumed every byte.
    $deadline = (Get-Date).AddSeconds($AckSeconds)
    while ((Get-Date) -lt $deadline -and $ack -notlike "*$marker*") {
        $s = $sp.ReadExisting()
        if ($s) { $ack += $s; $log.Write($s) } else { Start-Sleep -Milliseconds 100 }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
if ($ack -like "*$marker*") {
    Write-Host "ACK_OK: board consumed $($bytes.Length) bytes -> $Dest"
} else {
    Write-Host "NO ACK: dd may still be waiting; do NOT send commands. Capture: $outPath"
    exit 2
}
