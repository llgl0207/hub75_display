Add-Type -AssemblyName System.Drawing
foreach ($size in 13, 14, 15) {
  foreach ($ox in -2, -1, 0) {
    foreach ($oy in -2, -3, -4) {
      $bmp = New-Object System.Drawing.Bitmap 8, 16
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
      $font = New-Object System.Drawing.Font("Consolas", $size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoAntiAlias
      $g.Clear([System.Drawing.Color]::Black)
      $g.DrawString("A", $font, [System.Drawing.Brushes]::White, $ox, $oy, $fmt)
      $art = ""
      for ($y = 0; $y -lt 16; $y++) { for ($x = 0; $x -lt 8; $x++) { $p = $bmp.GetPixel($x,$y); $art += $(if ($p.R -gt 90) {"#"} else {"."}) }; $art += "/" }
      Write-Output ("size=$size ox=$ox oy=$oy : $art")
      $g.Dispose(); $bmp.Dispose()
    }
  }
}
