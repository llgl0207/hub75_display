Add-Type -AssemblyName System.Drawing
foreach ($cfg in @(@(13,-1,-2),@(13,0,-2),@(14,-1,-2),@(14,0,-2),@(14,-1,-3))) {
  $size=$cfg[0]; $ox=$cfg[1]; $oy=$cfg[2]
  $bmp = New-Object System.Drawing.Bitmap 8, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
  $font = New-Object System.Drawing.Font("Consolas", $size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoAntiAlias
  foreach ($ch in @("o","m","w","A")) {
    $g.Clear([System.Drawing.Color]::Black)
    $g.DrawString($ch, $font, [System.Drawing.Brushes]::White, $ox, $oy, $fmt)
    $art=""
    for ($y=0;$y -lt 16;$y++){ for($x=0;$x -lt 8;$x++){ $p=$bmp.GetPixel($x,$y); $art += $(if($p.R -gt 90){"#"}else{"."}) }; $art+="/" }
    Write-Output ("size=$size ox=$ox oy=$oy ch=$ch : $art")
  }
  $g.Dispose(); $bmp.Dispose()
}
