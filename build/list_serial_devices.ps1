# List present serial/USB devices and devices with driver problems.
Write-Host "=== Serial ports ==="
Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Description, PNPDeviceID | Format-List

Write-Host "=== PnP devices matching serial bridges ==="
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Class -in @('Ports', 'USB') -or $_.FriendlyName -match 'CH340|CP210|USB-SERIAL|UART|Serial' } |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-Table -AutoSize | Out-String -Width 220

Write-Host "=== Devices with problems ==="
Get-PnpDevice -PresentOnly |
    Where-Object { $_.Status -ne 'OK' } |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-Table -AutoSize | Out-String -Width 220
