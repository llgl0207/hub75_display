# Send a list of console lines to the PS UART and capture the replies.
# Each line of -CommandFile is sent followed by CR/LF, with -DelayMs between lines.
# Usage: powershell -NoProfile -File build/com11_session.ps1 -CommandFile build\reports\cmds.txt -Out build\reports\com11_session.txt

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [Parameter(Mandatory = $true)][string]$CommandFile,
    [string]$Out = "",
    [int]$DelayMs = 1500,
    [int]$TailSeconds = 3
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_session.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$commands = Get-Content -LiteralPath $CommandFile
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false

$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true
try {
    $sp.Open()
    foreach ($cmd in $commands) {
        Write-Host ">> $cmd"
        $sp.Write($cmd + "`r`n")
        Start-Sleep -Milliseconds $DelayMs
        $s = $sp.ReadExisting()
        if ($s) { $sw.Write($s) }
    }
    $deadline = (Get-Date).AddSeconds($TailSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = $sp.ReadExisting()
        if ($s) { $sw.Write($s) } else { Start-Sleep -Milliseconds 50 }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
