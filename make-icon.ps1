# Draws sloth.ico (the Start menu icon) from the same sloth art panel.ps1 uses: the drawing block of panel.ps1
# (between "sloth drawing" and "$sloth = @{}") is loaded here, rendered at 16..256 px and packed as PNG frames.
# Keep this file ASCII-only (Windows PowerShell 5.1). Run: powershell -STA -File make-icon.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $dir "panel.ps1"))
$start = $src.IndexOf("# ---------- sloth drawing")
$end = $src.IndexOf('$sloth = @{}')
if ($start -lt 0 -or $end -le $start) { throw "sloth drawing block not found in panel.ps1" }
. ([scriptblock]::Create($src.Substring($start, $end - $start)))

function Render-Png($size) {
  $v = [System.Windows.Markup.XamlReader]::Parse((Sloth-Xaml "work"))
  $bg = New-Object System.Windows.Controls.Border
  $bg.Width = $size; $bg.Height = $size; $bg.CornerRadius = $size * 0.22
  $bg.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1C2430")
  $bg.Padding = $size * 0.06
  $bg.Child = $v
  $bg.Measure((New-Object System.Windows.Size($size, $size)))
  $bg.Arrange((New-Object System.Windows.Rect(0, 0, $size, $size)))
  $bg.UpdateLayout()
  $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
  $bmp.Render($bg)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
  $ms = New-Object System.IO.MemoryStream
  $enc.Save($ms)
  return ,$ms.ToArray()
}

$sizes = @(16, 32, 48, 256)
$pngs = @($sizes | ForEach-Object { ,(Render-Png $_) })
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = $(if ($s -ge 256) { 0 } else { $s })
  $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $dir "sloth.ico"), $out.ToArray())
Write-Output "sloth.ico written"
