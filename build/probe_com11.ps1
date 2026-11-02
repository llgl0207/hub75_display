param([string]$Port = "COM11", [int]$Baud = 115200, [int]$Tries = 8)
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false
try { $sp.Open() } catch { Write-Host ("open failed: " + $_); exit 1 }
$sb = ""
for ($i = 0; $i -lt $Tries; $i++) {
    $sp.Write("`r")
    Start-Sleep -Milliseconds 700
    $sb += $sp.ReadExisting()
}
$sp.Close()
$sp.Dispose()
if ($sb.Length -eq 0) { Write-Host "NO_DATA" } else { Write-Host ("GOT " + $sb.Length + " chars"); Write-Host $sb }
