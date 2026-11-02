param([string]$Port="COM11",[int]$Baud=115200,[string]$Out="")
$root = Split-Path -Parent $PSScriptRoot
if(!$Out){$Out=Join-Path $root "build\reports\recover2.txt"}
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,([System.IO.Ports.Parity]::None),8,([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout=400;$sp.DtrEnable=$false;$sp.RtsEnable=$false
$sw=New-Object System.IO.StreamWriter($Out,$false,[System.Text.Encoding]::UTF8);$sw.AutoFlush=$true
function Pump([int]$ms){$d=(Get-Date).AddMilliseconds($ms);while((Get-Date)-lt $d){try{$s=$sp.ReadExisting()}catch{break};if($s){$sw.Write($s)}else{Start-Sleep -Milliseconds 40}}}
try{
$sp.Open()
for($i=0;$i -lt 5;$i++){ $sp.Write([byte[]](3),0,1); Pump 150 }
$sp.Write([byte[]](26),0,1); Pump 150    # Ctrl-Z
$sp.Write("`r"); Pump 300
$sp.Write("stty sane`r"); Pump 400
$sp.Write("`r"); Pump 300
$sp.Write("echo ALIVE_$((1+1))`r"); Pump 1500
$sp.Write("pwd`r"); Pump 1200
}finally{if($sp.IsOpen){$sp.Close()};$sp.Dispose();$sw.Close()}
Write-Host "Done: $Out"
