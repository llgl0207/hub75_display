# Continuously monitor the Raspberry Pi UART while the user changes wiring.
# Sends CR every 2 s and logs any received bytes with a timestamp.
param(
    [string]$Port = "COM5",
    [int]$Baud = 115200,
    [int]$Seconds = 180,
    [string]$Out = "build\reports\pi_uart_scan.txt"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outPath = Join-Path $root $Out
$dir = Split-Path -Parent $outPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$log = New-Object System.IO.StreamWriter($outPath, $false, [System.Text.Encoding]::UTF8)
$log.AutoFlush = $true
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 100
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastTx = -10.0
try {
    $sp.Open()
    $log.WriteLine("monitor $Port $Baud for $Seconds s")
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        $t = $sw.Elapsed.TotalSeconds
        if ($t - $lastTx -ge 2.0) {
            $sp.Write([char]13)
            $lastTx = $t
        }
        $s = $sp.ReadExisting()
        if ($s -and $s.Length -gt 0) {
            $hex = -join ($s.ToCharArray() | ForEach-Object { '{0:X2} ' -f [int]$_ })
            $log.WriteLine(("[{0,7:F1}s] RX {1} bytes: {2}" -f $t, $s.Length, ($s -replace "`r", "<CR>" -replace "`n", "<LF>")))
            $log.WriteLine(("[{0,7:F1}s] HEX: {1}" -f $t, $hex))
        }
        Start-Sleep -Milliseconds 40
    }
    $log.WriteLine("done")
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $log.Close()
}
