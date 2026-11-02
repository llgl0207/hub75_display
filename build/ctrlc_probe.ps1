param([string]$Out="build\reports\ctrlc_probe.txt")
$root = Split-Path -Parent $PSScriptRoot
$sp=New-Object System.IO.Ports.SerialPort "COM11",115200,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout=400;$sp.DtrEnable=$false;$sp.RtsEnable=$false
$sw=New-Object System.IO.StreamWriter((Join-Path $root $Out),$false,[System.Text.Encoding]::UTF8);$sw.AutoFlush=$true
function Pump([int]$ms){$d=(Get-Date).AddMilliseconds($ms);while((Get-Date)-lt $d){try{$s=$sp.ReadExisting()}catch{break};if($s){$sw.Write($s)}else{Start-Sleep -Milliseconds 40}}}
try{
$sp.Open()
$sp.Write([byte[]](3),0,1); Pump 500
$sp.Write("`r"); Pump 300
$sp.Write("echo SHELL_OK`r"); Pump 800
$sp.Write("cat /proc/uptime; usleep 1000000; cat /proc/uptime; date +%s; usleep 1000000; date +%s`r"); Pump 2500
}finally{if($sp.IsOpen){$sp.Close()};$sp.Dispose();$sw.Close()}
