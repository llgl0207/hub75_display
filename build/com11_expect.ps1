# Prompt-aware COM11 session: wait for login:, send user/password, wait for
# the shell prompt, then send each command and wait for the prompt again.
# Usage: powershell -NoProfile -File build/com11_expect.ps1 -CommandFile cmds.txt

param(
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [string]$User = "root",
    [string]$Pass = "root",
    [Parameter(Mandatory = $true)][string]$CommandFile,
    [string]$Out = "",
    [int]$PromptTimeoutMs = 15000
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "build\reports\com11_expect.txt"
}
$dir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false
$sw = New-Object System.IO.StreamWriter($Out, $false, [System.Text.Encoding]::UTF8)
$sw.AutoFlush = $true

function Read-Until {
    param([string]$pattern, [int]$timeoutMs = 8000)
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        try { $s = $sp.ReadExisting() } catch { break }
        if ($s) {
            $sw.Write($s)
            $buf += $s
            if ($buf -match $pattern) { return $buf }
        }
        else { Start-Sleep -Milliseconds 50 }
    }
    return $buf
}

try {
    $sp.Open()
    Write-Host "Port $Port open"

    # Wake a pending login/password prompt and see where we are.
    $sp.Write("`r")
    $pre = Read-Until 'login:|:~# ' 40000
    if ($pre -notmatch ':~# ') {
        Write-Host ">> login"
        $sp.Write("$User`r")
        Read-Until 'Password:' 5000 | Out-Null
        $sp.Write("$Pass`r")
        $r = Read-Until ':~# ' 8000
        if ($r -notmatch ':~# ') { throw "login did not reach a shell prompt" }
    }
    Write-Host "Shell prompt reached"

    foreach ($cmd in Get-Content -LiteralPath $CommandFile) {
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        Write-Host ">> $cmd"
        $sp.Write($cmd + "`r")
        Read-Until ':~# ' $PromptTimeoutMs | Out-Null
    }
}
catch {
    Write-Host "ERROR: $_"
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    $sw.Close()
}
Write-Host "Done: $Out"
