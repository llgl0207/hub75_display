# Send a binary file over the serial console in raw mode.
# The board side must already be running:
#   stty raw -echo; dd bs=1 count=<N> of=<path>; stty sane
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Port = "COM11",
    [int]$Baud = 115200,
    [int]$Chunk = 4096
)
$ErrorActionPreference = 'Stop'
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200
$sp.WriteTimeout = 20000
$sp.DtrEnable = $false
$sp.RtsEnable = $false
try {
    $sp.Open()
    for ($i = 0; $i -lt $bytes.Length; $i += $Chunk) {
        $n = [Math]::Min($Chunk, $bytes.Length - $i)
        $sp.Write($bytes, $i, $n)
    }
    Start-Sleep -Milliseconds 300
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
Write-Host "sent $($bytes.Length) bytes from $Path"
