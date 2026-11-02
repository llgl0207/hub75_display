Add-Type -AssemblyName System.Drawing
$w = 8; $h = 16
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
$font = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoAntiAlias -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("#ifndef HUB75_FONT_H")
[void]$sb.AppendLine("#define HUB75_FONT_H")
[void]$sb.AppendLine("#include <stdint.h>")
[void]$sb.AppendLine("/* 8x16 glyphs for ASCII 32..126, row-major, bit7 = leftmost pixel */")
[void]$sb.AppendLine("static const uint8_t hub75_font8x16[95][16] = {")
for ($c = 32; $c -le 126; $c++) {
    $g.Clear([System.Drawing.Color]::Black)
    $ch = [string][char]$c
    $g.DrawString($ch, $font, [System.Drawing.Brushes]::White, -1, -2, $fmt)
    $rows = for ($y = 0; $y -lt $h; $y++) {
        $b = 0
        for ($x = 0; $x -lt $w; $x++) {
            $p = $bmp.GetPixel($x, $y)
            if ($p.R -gt 90) { $b = $b -bor (1 -shl (7 - $x)) }
        }
        $b
    }
    $hex = ($rows | ForEach-Object { "0x{0:X2}" -f $_ }) -join ", "
    [void]$sb.AppendLine("    {$hex}, /* " + $c + " */")
}
[void]$sb.AppendLine("};")
[void]$sb.AppendLine("#endif")
Set-Content -Path "sw/linux/hub75_font.h" -Value $sb.ToString() -Encoding ASCII
# Debug: print 'A' and 'g' as ASCII art
foreach ($cc in 65, 103) {
    $g.Clear([System.Drawing.Color]::Black)
    $g.DrawString([string][char]$cc, $font, [System.Drawing.Brushes]::White, -1, -2, $fmt)
    Write-Output ("char " + $cc + ":")
    for ($y = 0; $y -lt $h; $y++) {
        $line = ""
        for ($x = 0; $x -lt $w; $x++) {
            $p = $bmp.GetPixel($x, $y)
            $line += $(if ($p.R -gt 90) { "#" } else { "." })
        }
        Write-Output $line
    }
}
Write-Output "font generated"
