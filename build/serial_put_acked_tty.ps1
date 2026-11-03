# Ack-paced serial upload for the 4.14 vendor kernel.
#
# Why not one big dd:
#   * BusyBox dd (1.24.1) counts a short read as a full block, so bs>1 cannot
#     be used on a tty.
#   * dd bs=1 on this board sustains only ~4 KB/s while the UART feeds 11.5 KB/s.
#     The PTY (4 KB) and tty (4 KB) buffers overflow, bytes are lost, and the
#     endless `dd count=N` waits forever - the console is then stuck.
#
# This script sends <=2 KB chunks, always below the 4 KB PTY buffer, and waits
# for a READY marker written after the PTY is raw and a DONE marker written
# after dd consumed the chunk.  A chunk can never overflow the buffer even if
# dd stalls completely, and the next chunk is not sent until dd drained this one.
#
# Requires: busybox dd, shell, ttyPS0 made raw by this script first.
#
# Usage:
#   .\build\serial_put_acked.ps1 -Path build/work/vendor_linux/hub75d `
#                               -Dest /run/media/mmcblk0p1/hub75d.new
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Dest,
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$ChunkSize = 2048,
    [int]$ReadyTimeout = 4,
    [int]$DoneTimeout = 10,
    [string]$Out = "build\reports\serial_put_acked.txt"
)
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
$root = Split-Path -Parent $PSScriptRoot
$outPath = Join-Path $root $Out
$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$log = New-Object System.IO.StreamWriter($outPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200
$sp.WriteTimeout = 20000
$sp.ReadBufferSize = 65536
$sp.DtrEnable = $false
$sp.RtsEnable = $false

function Read-Until([string]$marker, [int]$seconds) {
    $acc = ""
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $s = $sp.ReadExisting()
        if ($s) {
            $acc += $s
            $script:log.Write(("[{0}ms] " -f $script:sw.ElapsedMilliseconds) + $s)
        }
        if ($acc.Contains($marker)) { break }
        Start-Sleep -Milliseconds 40
    }
    return [string]$acc
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $sp.Open()
    # 1. Console tty raw; prove it before anything binary is sent.
    $sp.Write("stty raw -echo < /dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $null = $sp.ReadExisting()
    $sp.Write("echo RAWOK >/dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 500
    $probe = $sp.ReadExisting()
    $log.Write($probe)
    if ($probe -notlike "*RAWOK*" -or $probe -like "*echo RAWOK*") {
        throw "console tty raw probe failed; not sending data"
    }
    Write-Host "console tty raw: OK"

    # 2. Fresh destination.
    $sp.Write("rm -f $Dest" + [char]13)
    Start-Sleep -Milliseconds 300
    $null = $sp.ReadExisting()

    # 3. Ack-paced chunks.
    $nchunks = [Math]::Ceiling($bytes.Length / $ChunkSize)
    $t0 = Get-Date
    for ($i = 0; $i -lt $nchunks; $i++) {
        $off = $i * $ChunkSize
        $len = [Math]::Min($ChunkSize, $bytes.Length - $off)
        $tag = "{0:D4}" -f $i
        $cmd = "stty raw -echo < /dev/ttyPS0; echo R$tag >/dev/ttyPS0; dd bs=1 count=$len < /dev/ttyPS0 >> $Dest; stty sane < /dev/ttyPS0; echo D$tag >/dev/ttyPS0"
        $sp.Write($cmd + [char]13)
        $log.WriteLine(("[{0}ms] TX {1}" -f $sw.ElapsedMilliseconds, $cmd))
        $ready = [string](Read-Until "R$tag" $ReadyTimeout)
        if (-not $ready.Contains("R$tag")) {
            throw "chunk ${i}: no READY marker; dd not started. Console may be usable."
        }
        # dd must still be waiting here.  If DONE already arrived, it exited
        # without the payload (stdin EOF) and sending raw bytes now would feed
        # them to the shell; abort instead.
        if ($ready.Contains("D$tag")) {
            throw "chunk ${i}: DONE arrived before payload; dd exited early. Not sending bytes."
        }
        $sp.Write($bytes, $off, $len)
        $done = [string](Read-Until "D$tag" $DoneTimeout)
        if (-not $done.Contains("D$tag")) {
            throw "chunk ${i}: no DONE marker; dd is still waiting ($len bytes expected)."
        }
        if (($i % 20) -eq 0) {
            $sec = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
            Write-Host ("chunk {0}/{1}  {2} bytes  {3}s" -f $i, $nchunks, ($off + $len), $sec)
        }
    }
    # 4. Restore the console tty.
    $sp.Write("stty sane < /dev/ttyPS0" + [char]13)
    Start-Sleep -Milliseconds 300
    $null = $sp.ReadExisting()
    $sec = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Host "ACK_OK: $($bytes.Length) bytes in $sec s -> $Dest"
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
