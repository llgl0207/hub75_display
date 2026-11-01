# Read IR snapshots from the board UART and append measurements to a CSV.
#
# Packet (10 bytes): 0x55 0xAA, last interval LE32, five-interval mean LE32.
# Counts are 20 ns PL ticks at 50 MHz.
#
# Usage (PowerShell):
#   .\build\capture_uart.ps1 -Port COM5 -Seconds 8
# Writes: data/board_test_log.csv (one row per snapshot), data/uart_raw.log (hex)

param(
    [Parameter(Mandatory = $true)][string]$Port,
    [int]$Baud = 115200,
    [int]$Seconds = 8,
    [string]$Label = "static_ir_test",
    [string]$OutCsv = "",
    [string]$RawLog = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutCsv)) { $OutCsv = Join-Path $repo "data\uart_measurements.csv" }
if ([string]::IsNullOrWhiteSpace($RawLog)) { $RawLog = Join-Path $repo "data\uart_raw.log" }
$CSV_HEADER = "timestamp_utc,test_label,port,last_interval_ticks,mean_ticks,period_ms,rpm"

function New-Row {
    param([datetime]$Stamp, [uint32]$Last, [uint32]$Mean)
    $periodMs = if ($Mean -gt 0) { $Mean / 50000.0 } else { 0 }
    $rpm = if ($Mean -gt 0) { 3000000000.0 / $Mean } else { 0 }
    return [pscustomobject]@{
        timestamp_utc       = $Stamp.ToString("yyyy-MM-ddTHH:mm:ssZ")
        test_label          = $Label
        port                = $Port
        last_interval_ticks = $Last
        mean_ticks          = $Mean
        period_ms           = "{0:F3}" -f $periodMs
        rpm                 = "{0:F1}" -f $rpm
    }
}

if (-not (Test-Path -LiteralPath $OutCsv)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $OutCsv) | Out-Null
    Set-Content -LiteralPath $OutCsv -Value $CSV_HEADER -Encoding UTF8
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 2000
$sp.Open()
Write-Host "Opened $Port at $Baud. Capturing for $Seconds s ..."

$buf = New-Object System.Collections.Generic.List[byte]
$rows = New-Object System.Collections.Generic.List[object]
$rawLines = New-Object System.Collections.Generic.List[string]
$deadline = (Get-Date).AddSeconds($Seconds)

try {
    while ((Get-Date) -lt $deadline) {
        try { $chunk = $sp.ReadExisting() } catch { break }
        if ($chunk) {
            foreach ($b in [System.Text.Encoding]::Latin1.GetBytes($chunk)) { $buf.Add($b) }
        } else {
            Start-Sleep -Milliseconds 20
        }
        # Consume every complete 10-byte frame currently buffered.
        while ($true) {
            if ($buf.Count -lt 10) { break }
            $syncIdx = -1
            for ($i = 0; $i -le ($buf.Count - 2); $i++) {
                if ($buf[$i] -eq 0x55 -and $buf[$i + 1] -eq 0xAA) { $syncIdx = $i; break }
            }
            if ($syncIdx -lt 0) { if ($buf.Count -gt 1) { $buf.RemoveRange(0, $buf.Count - 1) }; break }
            if ($syncIdx -gt 0) { $buf.RemoveRange(0, $syncIdx) }
            if ($buf.Count -lt 10) { break }
            $frame = $buf.GetRange(0, 10).ToArray()
            $buf.RemoveRange(0, 10)
            $last = [BitConverter]::ToUInt32($frame, 2)
            $mean = [BitConverter]::ToUInt32($frame, 6)
            $rawLines.Add(([BitConverter]::ToString($frame)))
            if ($mean -gt 0) { $rows.Add((New-Row -Stamp (Get-Date).ToUniversalTime() -Last $last -Mean $mean)) }
        }
    }
}
finally {
    $sp.Close()
    $sp.Dispose()
}

if ($rawLines.Count -gt 0) {
    Add-Content -LiteralPath $RawLog -Value ("# {0} {1} {2}" -f (Get-Date).ToUniversalTime().ToString("o"), $Label, $Port)
    $rawLines | ForEach-Object { Add-Content -LiteralPath $RawLog -Value $_ }
}

if ($rows.Count -eq 0) {
    Write-Warning "No valid packets. Check: TX on JP1-35/V12 -> adapter RX, common ground, 115200 8N1, sensor triggered >=6 times."
    exit 2
}

$rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Append -Encoding UTF8
$meanAvg = ($rows | Measure-Object -Property mean_ticks -Average).Average
$meanLast = $rows[-1].mean_ticks
Write-Host ("Captured {0} snapshots." -f $rows.Count)
Write-Host ("Last mean ticks : {0}" -f $meanLast)
Write-Host ("Average RPM     : {0:F1}" -f (3000000000.0 / $meanAvg))
Write-Host ("CSV             : {0}" -f $OutCsv)
Write-Host ("Raw hex         : {0}" -f $RawLog)
exit 0
