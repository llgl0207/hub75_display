Add-Type -AssemblyName System.Drawing
foreach ($bold in @($false,$true)) {
  $bmp = New-Object System.Drawing.Bitmap 8, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
  $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
  $font = New-Object System.Drawing.Font("Consolas", 14, $style, [System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat
  $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoAntiAlias
  foreach ($ch in @("o","m","w")) {
    $g.Clear([System.Drawing.Color]::Black)
    $g.DrawString($ch, $font, [System.Drawing.Brushes]::White, -1, -2, $fmt)
    $art=""
    for ($y=0;$y -lt 16;$y++){ for($x=0;$x -lt 8;$x++){ $p=$bmp.GetPixel($x,$y); $art += $(if($p.R -gt 90){"#"}else{"."}) }; $art+="/" }
    Write-Output ("bold=$bold ch=$ch : $art")
  }
  $g.Dispose(); $bmp.Dispose()
}
