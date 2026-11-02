param([string]$Line, [string]$Port="COM11", [int]$Baud=115200, [string]$Out="build\reports\send_line.txt")
$root = Split-Path -Parent $PSScriptRoot
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout=300;$sp.DtrEnable=$false;$sp.RtsEnable=$false
$sw=New-Object System.IO.StreamWriter((Join-Path $root $Out),$false,[System.Text.Encoding]::UTF8);$sw.AutoFlush=$true
try{
$sp.Open()
$sp.Write($Line + [char]13)
$d=(Get-Date).AddSeconds(2)
while((Get-Date) -lt $d){ $s=$sp.ReadExisting(); if($s){$sw.Write($s)}else{Start-Sleep -Milliseconds 50} }
}finally{if($sp.IsOpen){$sp.Close()};$sp.Dispose();$sw.Close()}
