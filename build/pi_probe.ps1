# Probe lain0 over the direct Ethernet link until it answers.
param([int]$Seconds = 240, [string]$V6 = "fe80::2ecf:67ff:feb6:b9c8%19")
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    ping -6 -n 1 -w 900 $V6 2>&1 | Out-Null
    $ok6 = ($LASTEXITCODE -eq 0)
    ping -n 1 -w 900 "lain0.local" 2>&1 | Out-Null
    $okname = ($LASTEXITCODE -eq 0)
    if ($ok6 -or $okname) {
        "PI_UP at $([math]::Round($sw.Elapsed.TotalSeconds,1))s v6=$ok6 name=$okname"
        exit 0
    }
    Start-Sleep -Seconds 2
}
"PI_TIMEOUT"
