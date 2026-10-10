# Clumsy Sloth: a draggable desktop sloth that reports every VS Code Claude Code tab.
# - Sleeps when nothing runs, types when a tab works, waves when a tab waits for you.
# - Says what happened in a slow speech bubble.
# - Click it: list of tabs (click a row to jump to that tab) and permission cards (Allow / Deny).
# - Drag it anywhere; position is remembered. First start: bottom-left. Hover: minimize / close.
# Tab state comes from hooks\status.js (data\sessions\<session>.json); permission requests from
# hooks\permission.js (data\requests\<id>.json, answered in data\answers\<id>.json).
# Only tabs whose Claude Code process still runs are shown (<claude home>\sessions\<pid>.json).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less .ps1 files as cp1252.
# UI strings live in lang\<code>.json (UTF-8).
# Run: powershell -STA -WindowStyle Hidden -File panel.ps1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# Started from a VS Code terminal this is set, and Code.exe would then run as plain node.
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\ClumsySloth", [ref]$created)
# Another sloth runs, or one is just shutting down (restart): wait a moment for it to let go.
if (-not $created) {
  $owned = $false
  try { $owned = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { exit 0 }
}

$dir = $PSScriptRoot
$dataDir = Join-Path $dir "data"
$stateDir = Join-Path $dataDir "sessions"
$reqDir = Join-Path $dataDir "requests"
$ansDir = Join-Path $dataDir "answers"
$aliveFile = Join-Path $dataDir "panel.alive"
$settingsFile = Join-Path $dir "config.json"
foreach ($d in @($stateDir, $reqDir, $ansDir)) { New-Item -ItemType Directory -Force $d | Out-Null }
$maxAgeHours = 12
$logFile = Join-Path $dataDir "panel.log"
function Log($what) { try { [System.IO.File]::AppendAllText($logFile, (Get-Date -Format "MM-dd HH:mm:ss") + " " + [string]$what + "`r`n") } catch {} }
$workStaleMinutes = 45

# ---------- language ----------
$langCode = $env:SLOTH_LANG
if (-not $langCode) { try { $langCode = ([System.IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json).lang } catch {} }
if (-not $langCode) { $langCode = $(if ((Get-UICulture).TwoLetterISOLanguageName -eq "tr") { "tr" } else { "en" }) }
$langFile = Join-Path $dir "lang\$langCode.json"
if (-not (Test-Path $langFile)) { $langFile = Join-Path $dir "lang\en.json" }
$T = [System.IO.File]::ReadAllText($langFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
function Fmt([string]$s, [hashtable]$map) { foreach ($k in $map.Keys) { $s = $s.Replace("{" + $k + "}", [string]$map[$k]) }; return $s }

function Brush($hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }
# Bahnschrift is the DIN-like face Windows ships; it reads like a queue display board.
$ui = New-Object System.Windows.Media.FontFamily("Bahnschrift, Segoe UI")
function Up($s) { try { return ([string]$s).ToUpper([System.Globalization.CultureInfo]::GetCultureInfo($langCode)) } catch { return ([string]$s).ToUpper() } }
$statusColor = @{ working = "#5AD08A"; done = "#8A8F99"; waiting = "#FFB347"; question = "#C084FC"; permission = "#F4505E" }
$statusOrder = @{ permission = 0; waiting = 1; question = 2; working = 3; done = 4 }
$attention = @("waiting", "question", "permission")
# Every tab gets its own color and initial, so news from different tabs is easy to tell apart.
$tabPalette = @("#E57373", "#64B5F6", "#81C784", "#FFB74D", "#BA68C8", "#4DB6AC", "#F06292", "#9FA8DA", "#DCE775", "#A1887F")
function Tab-Color($sid) { $n = 0; foreach ($ch in ([string]$sid).ToCharArray()) { $n = ($n * 31 + [int]$ch) % 100003 }; return $tabPalette[$n % $tabPalette.Count] }
function Tab-Initial($title) { $t = ([string]$title).Trim(); if ($t) { return $t.Substring(0, 1).ToUpper() } else { return "?" } }
function Avatar($sid, $title, $size) {
  $a = New-Object System.Windows.Controls.Border
  $a.Width = $size; $a.Height = $size; $a.CornerRadius = $size / 2; $a.Background = Brush (Tab-Color $sid)
  $a.VerticalAlignment = "Top"
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = Tab-Initial $title; $t.FontSize = $size * 0.5; $t.FontWeight = "Bold"; $t.Foreground = Brush "#FFFFFF"
  $t.HorizontalAlignment = "Center"; $t.VerticalAlignment = "Center"
  $a.Child = $t
  return $a
}

# ---------- sloth drawing (100 x 100 units, same art as taslak\maskot.html) ----------
$C = @{ fur = "#8C7663"; furDark = "#6B5747"; hair = "#5E4C3E"; mask = "#CBB79D"; patch = "#6E5848"; lid = "#7D6656"
        muzzle = "#7A6555"; nose = "#3A302A"; iris = "#8A5426"; shirt = "#9CC0E4"; tie = "#2F4A6D"
        desk = "#D9A35F"; deskTop = "#EBB878"; laptop = "#C4C8CE"; laptopEdge = "#A9AEB6"; claw = "#EFE4D0" }

function N($v) { [string]([math]::Round([double]$v, 3)) }
function El($cx, $cy, $rx, $ry, $fill, $rot = 0, $op = 1) {
  $s = "<Ellipse Canvas.Left='$(N ($cx - $rx))' Canvas.Top='$(N ($cy - $ry))' Width='$(N (2 * $rx))' Height='$(N (2 * $ry))' Fill='$fill' Opacity='$op'"
  if ($rot -ne 0) { return $s + " RenderTransformOrigin='0.5,0.5'><Ellipse.RenderTransform><RotateTransform Angle='$rot'/></Ellipse.RenderTransform></Ellipse>" }
  return $s + "/>"
}
function PF($d, $fill) { "<Path Data='$d' Fill='$fill'/>" }
function PSt($d, $stroke, $w) { "<Path Data='$d' Stroke='$stroke' StrokeThickness='$w' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>" }
function Rc($x, $y, $w, $h, $fill) { "<Rectangle Canvas.Left='$x' Canvas.Top='$y' Width='$w' Height='$h' Fill='$fill'/>" }

function Eye($cx, $cy) {
  (El $cx $cy 5.4 4.4 "#F8F2EA") + (El ($cx + 0.5) ($cy + 0.6) 3 3 $C.iris) + (El ($cx + 0.5) ($cy + 0.6) 1.5 1.5 "#120C08") + (El ($cx + 1.4) ($cy - 0.3) 0.8 0.8 "#FFFFFF")
}
function Lid($cx, $cy, $ly) {
  $a = N ($cx - 6.4); $b = N ($cx + 6.4); $top = N ($cy - 5.6); $l1 = N ($ly - 1); $q = N ($ly + 2.6)
  $c1 = N ($cx - 5.6); $c2 = N ($cx + 5.6); $l2 = N ($ly - 0.6); $q2 = N ($ly + 2.8)
  (PF "M$a $top L$b $top L$b $l1 Q$cx $q $a $l1 Z" $C.lid) + (PSt "M$c1 $l2 Q$cx $q2 $c2 $l2" "#3A2B20" 0.9)
}

function Sloth-Xaml($state) {
  $asleep = $state -eq "sleep"; $calling = $state -eq "call"
  $lidOff = $(if ($asleep) { 4.6 } elseif ($calling) { -2.6 } else { -0.6 })
  $lift = $(if ($calling) { -2 } else { 0 })
  $tilt = $(if ($asleep) { "<RotateTransform Angle='5' CenterX='52' CenterY='66'/><TranslateTransform Y='3'/>" } elseif ($calling) { "<RotateTransform Angle='-4' CenterX='52' CenterY='66'/>" } else { "<TranslateTransform/>" })
  $mouth = $(if ($calling) { PSt "M45 55 Q52 60 59 55" "#2E231B" 1.4 } else { PSt "M46.5 55.6 Q52 57.6 57.5 55.6" "#2E231B" 1.2 })
  $brows = (PSt "M35 $(33 + $lift) Q40 $(30 + $lift) 47 $(30.5 + $lift)" $C.hair 1.5) + (PSt "M57 $(30.5 + $lift) Q64 $(30 + $lift) 69 $(33 + $lift)" $C.hair 1.5)
  if ($calling) {
    $hand = "<Canvas x:Name='arm'>" + (PSt "M76 80 Q87 68 87 54" $C.shirt 9) + (El 87 48 5 6 $C.fur) +
            (PSt "M84 43 q-1 -6 0 -8 M87 42 q0 -6 1 -8 M90 43 q1 -6 2 -7" $C.claw 1.5) + "</Canvas>"
  } else {
    $hand = "<Canvas x:Name='hand'>" + (PSt "M80 92 Q80 84 74 82" $C.shirt 8) + (El 70 83 6 3.6 $C.fur) +
            (PSt "M66 84 q-2 3 -1 5 M70 85 q-1 3 0 5 M74 84 q0 3 1 5" $C.claw 1.4) + "</Canvas>"
  }
  $zz = ""
  if ($asleep) {
    $zz = "<TextBlock x:Name='z1' Text='z' FontSize='12' FontWeight='Bold' Foreground='#9FB3FF' Canvas.Left='76' Canvas.Top='10'/>" +
          "<TextBlock x:Name='z2' Text='z' FontSize='12' FontWeight='Bold' Foreground='#9FB3FF' Canvas.Left='82' Canvas.Top='4'/>"
  }
  @"
<Viewbox xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Stretch='Uniform'>
 <Canvas Width='100' Height='100' ClipToBounds='False'>
  $(PF "M14 100 Q16 66 52 62 Q88 66 90 100 Z" $C.shirt)
  $(PF "M40 63 L52 72 L46 76 Z M64 63 L52 72 L58 76 Z" "#F4F7FB")
  $(PF "M50 71 L54 71 L56 88 L52 92 L48 88 Z" $C.tie)
  <Canvas x:Name='head'>
   <Canvas>
    <Canvas.RenderTransform><TransformGroup>$tilt</TransformGroup></Canvas.RenderTransform>
    $(El 52 38 25 26 $C.fur)
    $(PF "M27 36 Q28 11 52 11 Q76 11 77 36 L72 27 L67 33 L62 24 L56 30 L51 22 L45 30 L39 24 L34 32 Z" $C.hair)
    $(El 52 43 20 18 $C.mask)
    $(El 42 41.5 7.6 5 $C.patch 12)
    $(El 62 41.5 7.6 5 $C.patch -12)
    $(Eye 43 41)
    $(Eye 61 41)
    <Canvas x:Name='lids'>$(Lid 43 41 (41 + $lidOff))$(Lid 61 41 (41 + $lidOff))</Canvas>
    $brows
    $(El 52 51.5 9.5 7.5 $C.muzzle)
    $(PF "M45 47 Q52 42.5 59 47 Q58.5 53.5 52 54 Q45.5 53.5 45 47 Z" $C.nose)
    $(El 49.2 46.6 2.3 1.1 "#7A6B60" 0 0.7)
    $mouth
   </Canvas>
  </Canvas>
  $(Rc 0 86 100 14 $C.desk)
  $(Rc 0 86 100 2.2 $C.deskTop)
  $(PF "M9 70 L41 70 Q43 70 43 72 L43 86 L7 86 L7 72 Q7 70 9 70 Z" $C.laptop)
  $(Rc 7 84.4 36 1.8 $C.laptopEdge)
  $hand
  $zz
 </Canvas>
</Viewbox>
"@
}

$sloth = @{}
foreach ($st in @("sleep", "work", "call")) {
  $v = [System.Windows.Markup.XamlReader]::Parse((Sloth-Xaml $st))
  $parts = @{ root = $v }
  $head = $v.FindName("head")
  $parts.headMove = New-Object System.Windows.Media.TranslateTransform
  $parts.headRot = New-Object System.Windows.Media.RotateTransform(0, 52, 66)
  $g = New-Object System.Windows.Media.TransformGroup
  $g.Children.Add($parts.headRot); $g.Children.Add($parts.headMove)
  $head.RenderTransform = $g
  $parts.lidScale = New-Object System.Windows.Media.ScaleTransform(1, 1, 0, 35.4)
  $v.FindName("lids").RenderTransform = $parts.lidScale
  $hand = $v.FindName("hand")
  if ($hand) { $parts.handMove = New-Object System.Windows.Media.TranslateTransform; $hand.RenderTransform = $parts.handMove }
  $arm = $v.FindName("arm")
  if ($arm) { $parts.armRot = New-Object System.Windows.Media.RotateTransform(0, 76, 80); $arm.RenderTransform = $parts.armRot }
  foreach ($z in @("z1", "z2")) {
    $tb = $v.FindName($z)
    if ($tb) { $parts[$z] = $tb; $tb.RenderTransform = New-Object System.Windows.Media.TranslateTransform }
  }
  $v.Visibility = "Collapsed"
  $sloth[$st] = $parts
}

# ---------- settings ----------
$script:cfg = @{ left = $null; top = $null; mini = $false; lang = $null }
try {
  $j = [System.IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
  $script:cfg.left = $j.left; $script:cfg.top = $j.top; $script:cfg.mini = [bool]$j.mini; $script:cfg.lang = $j.lang
} catch {}
function Save-Settings {
  # Keep keys the panel does not own (askMarker, allowInBypass, ...).
  $o = New-Object PSObject
  try { $o = [System.IO.File]::ReadAllText($settingsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
  $mine = @{ left = [math]::Round($win.Left); top = [math]::Round($win.Top); mini = $script:cfg.mini; lang = $script:cfg.lang }
  foreach ($k in $mine.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $mine[$k] -Force }
  try { [System.IO.File]::WriteAllText($settingsFile, ($o | ConvertTo-Json -Compress)) } catch {}
}

# ---------- mascot window ----------
$big = 104; $small = 56
$win = New-Object System.Windows.Window
$win.WindowStyle = "None"; $win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true; $win.ShowInTaskbar = $false; $win.ResizeMode = "NoResize"
$win.Title = "Sloth panel"

$stage = New-Object System.Windows.Controls.Grid
$stage.Background = Brush "#01000000"   # nearly transparent but hit-testable, so the whole square drags
$stage.Cursor = "Hand"
$win.Content = $stage
foreach ($st in @("sleep", "work", "call")) { $stage.Children.Add($sloth[$st].root) | Out-Null }

# badge: number of tabs waiting for you
$badge = New-Object System.Windows.Controls.Border
$badge.Background = Brush "#FFB347"; $badge.CornerRadius = 9; $badge.MinWidth = 18; $badge.Height = 18
$badge.HorizontalAlignment = "Left"; $badge.VerticalAlignment = "Top"; $badge.Margin = "2,2,0,0"; $badge.Padding = "4,0,4,0"
$badgeText = New-Object System.Windows.Controls.TextBlock
$badgeText.FontSize = 11; $badgeText.FontWeight = "Bold"; $badgeText.Foreground = Brush "#1B1B1B"
$badgeText.HorizontalAlignment = "Center"; $badgeText.VerticalAlignment = "Center"
$badge.Child = $badgeText; $badge.Visibility = "Collapsed"
$stage.Children.Add($badge) | Out-Null

function Round-Button($glyph, $tip) {
  $b = New-Object System.Windows.Controls.Border
  $b.Width = 18; $b.Height = 18; $b.CornerRadius = 9; $b.Margin = "2,0,0,0"
  $b.Background = Brush "#E61D2027"; $b.BorderBrush = Brush "#55FFFFFF"; $b.BorderThickness = 1
  $b.Cursor = "Hand"; $b.ToolTip = $tip
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $glyph; $t.FontSize = 10; $t.Foreground = Brush "#EEFFFFFF"
  $t.HorizontalAlignment = "Center"; $t.VerticalAlignment = "Center"; $t.Margin = "0,-1,0,0"
  $b.Child = $t
  return $b
}
$tools = New-Object System.Windows.Controls.StackPanel
$tools.Orientation = "Horizontal"; $tools.HorizontalAlignment = "Right"; $tools.VerticalAlignment = "Top"; $tools.Margin = "0,2,2,0"
$btnMin = Round-Button ([string][char]0x2013) $T.minimize
$btnClose = Round-Button ([string][char]0x2715) $T.close
$tools.Children.Add($btnMin) | Out-Null; $tools.Children.Add($btnClose) | Out-Null
$tools.Visibility = "Hidden"
$stage.Children.Add($tools) | Out-Null
$win.Add_MouseEnter({ $tools.Visibility = "Visible" })
$win.Add_MouseLeave({ $tools.Visibility = "Hidden" })

function Apply-Size {
  $s = $(if ($script:cfg.mini) { $small } else { $big })
  $bottom = $win.Top + $win.Height
  $win.Width = $s; $win.Height = $s
  if (-not [double]::IsNaN($bottom)) { $win.Top = $bottom - $s }
  $btnMin.ToolTip = $(if ($script:cfg.mini) { $T.restore } else { $T.minimize })
  $btnMin.Child.Text = $(if ($script:cfg.mini) { [string][char]0x25A1 } else { [string][char]0x2013 })
  $tools.Margin = $(if ($script:cfg.mini) { "0,-2,-2,0" } else { "0,2,2,0" })
}
function Toggle-Mini { $script:cfg.mini = -not $script:cfg.mini; Apply-Size; Clamp-Win; Save-Settings; Place-Pop }

# ---------- screen helpers (WPF units) ----------
function Dpi {
  $src = [System.Windows.PresentationSource]::FromVisual($win)
  if ($src) { return $src.CompositionTarget.TransformToDevice.M11 }
  return 1.0
}
function WorkArea-At($x, $y) {
  $k = Dpi
  $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point([int]($x * $k), [int]($y * $k))))
  $w = $scr.WorkingArea
  return @{ L = $w.Left / $k; T = $w.Top / $k; R = $w.Right / $k; B = $w.Bottom / $k }
}
function Clamp-Win {
  $wa = WorkArea-At ($win.Left + $win.Width / 2) ($win.Top + $win.Height / 2)
  $win.Left = [math]::Max($wa.L, [math]::Min($win.Left, $wa.R - $win.Width))
  $win.Top = [math]::Max($wa.T, [math]::Min($win.Top, $wa.B - $win.Height))
}
function Place-Default {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $win.Left = $wa.Left + 8
  $win.Top = $wa.Bottom - $win.Height - 8
}

# ---------- popup window (speech bubble or tab list + permission cards) ----------
$pop = New-Object System.Windows.Window
$pop.WindowStyle = "None"; $pop.AllowsTransparency = $true
$pop.Background = [System.Windows.Media.Brushes]::Transparent
$pop.Topmost = $true; $pop.ShowInTaskbar = $false; $pop.ResizeMode = "NoResize"
$pop.SizeToContent = "WidthAndHeight"; $pop.ShowActivated = $false

$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 18; $shadow.ShadowDepth = 3; $shadow.Opacity = 0.45

# speech bubble
$bubble = New-Object System.Windows.Controls.Border
$bubble.Background = Brush "#FFFBFAF7"; $bubble.CornerRadius = 14; $bubble.Padding = "11,7,11,8"; $bubble.Margin = 10
$bubble.Effect = $shadow; $bubble.MaxWidth = 300; $bubble.MinWidth = 170
$bubbleRow = New-Object System.Windows.Controls.DockPanel
$bubbleAvatarSlot = New-Object System.Windows.Controls.ContentControl
$bubbleAvatarSlot.Margin = "0,1,9,0"; $bubbleAvatarSlot.VerticalAlignment = "Top"
[System.Windows.Controls.DockPanel]::SetDock($bubbleAvatarSlot, "Left")
$bubbleTexts = New-Object System.Windows.Controls.StackPanel
$bubbleTab = New-Object System.Windows.Controls.TextBlock
$bubbleTab.FontSize = 11.5; $bubbleTab.FontWeight = "Bold"; $bubbleTab.TextTrimming = "CharacterEllipsis"
$bubbleText = New-Object System.Windows.Controls.TextBlock
$bubbleText.FontSize = 13; $bubbleText.FontWeight = "SemiBold"; $bubbleText.Foreground = Brush "#1B1B1B"; $bubbleText.TextWrapping = "Wrap"
$bubbleTexts.Children.Add($bubbleTab) | Out-Null; $bubbleTexts.Children.Add($bubbleText) | Out-Null
$bubbleRow.Children.Add($bubbleAvatarSlot) | Out-Null; $bubbleRow.Children.Add($bubbleTexts) | Out-Null
$bubble.Child = $bubbleRow
$bubble.Cursor = "Hand"

# list panel
$panel = New-Object System.Windows.Controls.Border
$panel.Background = Brush "#F70E1116"; $panel.BorderBrush = Brush "#2A323C"; $panel.BorderThickness = 1
$panel.CornerRadius = 16; $panel.Padding = "12,10,12,10"; $panel.Margin = 10; $panel.Width = 380
$panel.Effect = $shadow
$panelRoot = New-Object System.Windows.Controls.StackPanel
$panel.Child = $panelRoot
$head = New-Object System.Windows.Controls.DockPanel
$head.Margin = "2,0,0,6"
$hide = New-Object System.Windows.Controls.TextBlock
$hide.Text = [string][char]0x2013; $hide.Foreground = Brush "#99FFFFFF"; $hide.FontSize = 14; $hide.Padding = "8,0,4,0"
$hide.Cursor = "Hand"; $hide.ToolTip = $T.hideList; $hide.Background = [System.Windows.Media.Brushes]::Transparent
[System.Windows.Controls.DockPanel]::SetDock($hide, "Right")
$headTitle = New-Object System.Windows.Controls.TextBlock
$headTitle.Text = Up $T.board; $headTitle.Foreground = Brush "#8A94A3"; $headTitle.FontSize = 12; $headTitle.FontWeight = "SemiBold"
$headTitle.FontFamily = $ui; $headTitle.VerticalAlignment = "Center"
$boardClock = New-Object System.Windows.Controls.TextBlock
$boardClock.Foreground = Brush "#8A94A3"; $boardClock.FontSize = 12; $boardClock.FontFamily = $ui; $boardClock.VerticalAlignment = "Center"; $boardClock.Margin = "0,0,6,0"
[System.Windows.Controls.DockPanel]::SetDock($boardClock, "Right")
$head.Children.Add($hide) | Out-Null; $head.Children.Add($boardClock) | Out-Null; $head.Children.Add($headTitle) | Out-Null
$cards = New-Object System.Windows.Controls.StackPanel
$list = New-Object System.Windows.Controls.StackPanel
$panelRoot.Children.Add($head) | Out-Null
$panelRoot.Children.Add($cards) | Out-Null
$panelRoot.Children.Add($list) | Out-Null

$script:popMode = ""   # "", "bubble", "panel"
function Show-Pop($mode) {
  $script:popMode = $mode
  $pop.Content = $(if ($mode -eq "panel") { $panel } else { $bubble })
  if (-not $pop.IsVisible) { $pop.Show() }
  $pop.UpdateLayout()
  Place-Pop
}
function Hide-Pop { $script:popMode = ""; $pop.Hide() }

# The popup opens toward the middle of the screen the sloth is on.
function Place-Pop {
  if (-not $pop.IsVisible) { return }
  $w = $pop.ActualWidth; $h = $pop.ActualHeight
  $cx = $win.Left + $win.Width / 2; $cy = $win.Top + $win.Height / 2
  $wa = WorkArea-At $cx $cy
  if ($cx -lt ($wa.L + $wa.R) / 2) { $x = $win.Left + $win.Width - 6 } else { $x = $win.Left - $w + 6 }
  if ($cy -gt ($wa.T + $wa.B) / 2) { $y = $win.Top + $win.Height - $h } else { $y = $win.Top }
  $pop.Left = [math]::Max($wa.L, [math]::Min($x, $wa.R - $w))
  $pop.Top = [math]::Max($wa.T, [math]::Min($y, $wa.B - $h))
}
$pop.Add_SizeChanged({ Place-Pop })

# ---------- data ----------
$script:sessions = @()
$script:prev = @{}      # sid -> "status|updated"
$script:seen = @{}      # sid -> updated value the user has seen
$script:reqs = @()
$script:firstLoad = $true
$script:bubbleQueue = New-Object System.Collections.Queue

# Claude Code keeps <claude home>\sessions\<pid>.json for every running process, holding the session it
# runs right now (it changes on /clear). A tab whose process is gone was closed: drop it from the panel.
$ccHome = $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" })
$ccSessions = Join-Path $ccHome "sessions"
function Live-Sessions {
  if (-not (Test-Path $ccSessions)) { return $null }
  $live = @{}
  foreach ($f in Get-ChildItem $ccSessions -Filter *.json -File -ErrorAction SilentlyContinue) {
    try { $j = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
    if (-not $j.pid -or -not $j.sessionId) { continue }
    $proc = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq "claude") { $live[[string]$j.sessionId] = [string]$j.pid }
  }
  return $live
}
function Load-Sessions {
  $items = @()
  $cutoff = (Get-Date).AddHours(-$maxAgeHours)
  $live = Live-Sessions
  $script:sidPid = $(if ($null -ne $live) { $live } else { @{} })
  # Queue numbers come from hooks\numbers.js: { "<pid or session id>": n }
  $script:numbers = @{}
  try {
    $nj = [System.IO.File]::ReadAllText((Join-Path $dataDir "numbers.json")) | ConvertFrom-Json
    foreach ($p in $nj.PSObject.Properties) { $script:numbers[[string]$p.Name] = [int]$p.Value }
  } catch {}
  # An open tab without a number (it has not done anything since the sloth started): hand out numbers.
  $missing = @($script:sidPid.Keys | Where-Object { -not $script:numbers.ContainsKey([string]$script:sidPid[$_]) }).Count
  if ($missing -gt 0 -and ((Get-Date) - $script:lastSync).TotalSeconds -gt 10) {
    $script:lastSync = Get-Date
    try { Start-Process node -ArgumentList ('"' + (Join-Path $dir "hooks\numbers.js") + '" --sync') -WindowStyle Hidden } catch { Log "sync: $_" }
  }
  foreach ($f in Get-ChildItem $stateDir -Filter *.json -File -ErrorAction SilentlyContinue) {
    if ($f.LastWriteTime -lt $cutoff) { continue }
    try { $s = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    $fresh = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$s.updated) -lt 15000
    if ($null -ne $live -and -not $live.ContainsKey([string]$s.sessionId) -and -not $fresh) {
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue
    }
    $items += $s
  }
  return @($items | Sort-Object @{ e = { $o = $statusOrder[$_.status]; if ($null -eq $o) { 9 } else { $o } } }, @{ e = { -[double]$_.updated } })
}
function Load-Requests {
  $items = @()
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  foreach ($f in Get-ChildItem $reqDir -Filter *.json -File -ErrorAction SilentlyContinue) {
    try { $r = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    if ([double]$r.expires -lt $now) { continue }
    if (Test-Path (Join-Path $ansDir "$($r.id).json")) { continue }
    # The tab answered first and Claude Code killed the hook: drop the card.
    if ($r.pid -and -not (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)) {
      Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; continue
    }
    $items += $r
  }
  return @($items | Sort-Object { [double]$_.created })
}

function Short($s, $max) { $s = [string]$s; if ($s.Length -gt $max) { return $s.Substring(0, $max - 1).TrimEnd() + [char]0x2026 }; return $s }
function Ago($ms) {
  $min = [int]([DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms)).TotalMinutes
  if ($min -lt 1) { return $T.now }
  if ($min -lt 60) { return (Fmt $T.minutes @{ n = $min }) }
  return (Fmt $T.hours @{ n = [int]($min / 60) })
}
function Is-Attention($s) {
  if ($attention -notcontains $s.status) { return $false }
  $seenAt = $script:seen[$s.sessionId]
  return ($null -eq $seenAt) -or ([double]$s.updated -gt [double]$seenAt)
}
function Mark-Seen { foreach ($s in $script:sessions) { $script:seen[$s.sessionId] = [double]$s.updated } }

function Open-Tab($sid) { Start-Process ("vscode://anthropic.claude-code/open?session=" + $sid) }

function Answer($id, $behavior) {
  try { [System.IO.File]::WriteAllText((Join-Path $ansDir "$id.json"), "{""behavior"":""$behavior""}") } catch {}
  $script:reqs = @($script:reqs | Where-Object { $_.id -ne $id })
  Log "answer $id $behavior"
  Render-Cards
  if ($script:reqs.Count -eq 0 -and $script:autoOpened) { $script:autoOpened = $false; Hide-Pop }
}

function Small-Button($text, $bg, $fg, $tag) {
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = 8; $b.Padding = "12,7,12,7"; $b.Margin = "0,0,8,0"; $b.Cursor = "Hand"
  $b.Background = Brush $bg
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text; $t.Foreground = Brush $fg; $t.FontSize = 13; $t.FontWeight = "SemiBold"; $t.HorizontalAlignment = "Center"
  $t.FontFamily = $ui
  $b.Child = $t
  $b.Tag = $tag
  # Handled: the row under the button must not also open the tab.
  $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; $t = $this.Tag; Answer $t.id $t.behavior; if ($t.sid) { Open-Tab $t.sid } })
  return $b
}

# ---------- queue board (hospital style: "3 -> NEEDS PERMISSION") ----------
$arrow = [string][char]0x2192
$tileColor = @{ permission = "#F4A3A9"; waiting = "#FFD08A"; question = "#DDBBFD" }
function Num-Of($sid) {
  $k = $script:sidPid[[string]$sid]
  if ($k -and $script:numbers.ContainsKey([string]$k)) { return $script:numbers[[string]$k] }
  if ($script:numbers.ContainsKey([string]$sid)) { return $script:numbers[[string]$sid] }
  return $null
}
function Title-Of($sid, $fallback) {
  $known = $script:sessions | Where-Object { $_.sessionId -eq $sid } | Select-Object -First 1
  if ($known -and $known.title) { return [string]$known.title }
  return [string]$fallback
}
function TB($text, $size, $color, $weight = "Normal") {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = [string]$text; $t.FontSize = $size; $t.Foreground = Brush $color; $t.FontWeight = $weight
  $t.FontFamily = $ui; $t.TextTrimming = "CharacterEllipsis"
  return $t
}
function Num-Tile($n, $bg, $fg, $size, $w) {
  $b = New-Object System.Windows.Controls.Border
  $b.Background = Brush $bg; $b.CornerRadius = [math]::Max(6, [math]::Round($size / 4)); $b.Width = $w
  $b.Padding = "0,4,0,4"; $b.VerticalAlignment = "Center"
  $t = TB $(if ($n) { [string]$n } else { "-" }) $size $fg "Bold"
  $t.HorizontalAlignment = "Center"; $t.TextTrimming = "None"
  $b.Child = $t
  return $b
}
function Section($text, $color = "#8A94A3") {
  $t = TB (Up $text) 11 $color "SemiBold"
  $t.Margin = "4,12,0,6"
  return $t
}
function Status-Text($st) { $l = $T.status.$st; if (-not $l) { $l = $st }; return [string]$l }
function Hover-Row($row, $sid) {
  $row.Cursor = "Hand"; $row.Tag = $sid
  $row.Background = [System.Windows.Media.Brushes]::Transparent
  $row.Add_MouseEnter({ $this.Background = Brush "#1AFFFFFF" })
  $row.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
  $row.Add_MouseLeftButtonUp({ $script:seen[$this.Tag] = [double]::MaxValue; Open-Tab $this.Tag; Hide-Pop; Refresh-Mood })
}
function Ask-Box($r) {
  $box = New-Object System.Windows.Controls.Border
  $box.Background = Brush "#0A0D11"; $box.BorderBrush = Brush "#2A323C"; $box.BorderThickness = 1
  $box.CornerRadius = 10; $box.Padding = "12,10,12,12"; $box.Margin = "0,12,0,0"
  $sp = New-Object System.Windows.Controls.StackPanel
  $w = TB (Fmt $T.permWants @{ tool = $r.tool }) 12 "#8A94A3"
  $code = New-Object System.Windows.Controls.TextBlock
  $code.Text = Short $r.detail 220; $code.FontFamily = "Consolas"; $code.FontSize = 12; $code.Foreground = Brush "#D6DBE3"
  $code.TextWrapping = "Wrap"; $code.Margin = "0,5,0,10"
  $btns = New-Object System.Windows.Controls.StackPanel
  $btns.Orientation = "Horizontal"
  $btns.Children.Add((Small-Button $T.allow "#2F9E5B" "#FFFFFF" @{ id = $r.id; behavior = "allow" })) | Out-Null
  $btns.Children.Add((Small-Button $T.deny "#2A313B" "#F2F4F7" @{ id = $r.id; behavior = "deny" })) | Out-Null
  $btns.Children.Add((Small-Button $T.inTab "Transparent" "#8A94A3" @{ id = $r.id; behavior = "pass"; sid = $r.sessionId })) | Out-Null
  foreach ($x in @($w, $code, $btns)) { $sp.Children.Add($x) | Out-Null }
  $box.Child = $sp
  return $box
}
# Queue item: @{ kind = "req" | "ses"; sid; st; title; t; r }
function Big-Call($q) {
  $wrap = New-Object System.Windows.Controls.Border
  $wrap.CornerRadius = 12; $wrap.Padding = "12,10,12,12"
  $wrap.Background = Brush "#1C1417"; $wrap.BorderBrush = Brush "#3A2328"; $wrap.BorderThickness = 1
  $sp = New-Object System.Windows.Controls.StackPanel
  $lbl = TB ([string][char]0x25CF + "  " + (Up $T.nowCalling)) 11 "#F4505E" "Bold"
  $call = New-Object System.Windows.Controls.DockPanel
  $call.Margin = "0,8,0,0"
  $c = $statusColor[$q.st]; if (-not $c) { $c = "#F2F4F7" }
  $tile = Num-Tile (Num-Of $q.sid) $tileColor[$q.st] "#0E1116" 46 84
  [System.Windows.Controls.DockPanel]::SetDock($tile, "Left")
  $ar = TB $arrow 28 "#8A94A3"; $ar.Margin = "12,0,12,0"; $ar.VerticalAlignment = "Center"
  [System.Windows.Controls.DockPanel]::SetDock($ar, "Left")
  $texts = New-Object System.Windows.Controls.StackPanel
  $texts.VerticalAlignment = "Center"
  $st = TB (Up (Status-Text $q.st)) 22 $c "Bold"
  $tt = TB $q.title 13 "#A7B0BD"; $tt.Margin = "0,3,0,0"
  $ago = TB (Ago $q.t) 11.5 "#8A94A3"; $ago.Margin = "0,2,0,0"
  foreach ($x in @($st, $tt, $ago)) { $texts.Children.Add($x) | Out-Null }
  foreach ($x in @($tile, $ar, $texts)) { $call.Children.Add($x) | Out-Null }
  $sp.Children.Add($lbl) | Out-Null; $sp.Children.Add($call) | Out-Null
  if ($q.kind -eq "req") { $sp.Children.Add((Ask-Box $q.r)) | Out-Null }
  $wrap.Child = $sp
  if ($q.kind -ne "req") { Hover-Row $wrap $q.sid }
  return $wrap
}
function Queue-Row($q, $working) {
  $row = New-Object System.Windows.Controls.Border
  $row.CornerRadius = 10; $row.Padding = "6,7,8,7"; $row.Margin = "0,0,0,2"
  $sp = New-Object System.Windows.Controls.StackPanel
  $dp = New-Object System.Windows.Controls.DockPanel
  if ($working) { $tile = Num-Tile (Num-Of $q.sid) "#26303B" "#F2F4F7" 22 48 }
  else { $tile = Num-Tile (Num-Of $q.sid) $tileColor[$q.st] "#0E1116" 22 48 }
  [System.Windows.Controls.DockPanel]::SetDock($tile, "Left")
  $ar = TB $arrow 18 "#5C6673"; $ar.Margin = "10,0,10,0"; $ar.VerticalAlignment = "Center"
  [System.Windows.Controls.DockPanel]::SetDock($ar, "Left")
  $ago = TB (Ago $q.t) 11.5 "#8A94A3"; $ago.VerticalAlignment = "Center"; $ago.Margin = "8,0,0,0"
  [System.Windows.Controls.DockPanel]::SetDock($ago, "Right")
  $texts = New-Object System.Windows.Controls.StackPanel
  $texts.VerticalAlignment = "Center"
  $c = $statusColor[$q.st]; if (-not $c) { $c = "#F2F4F7" }
  if ($working) { $st = TB (Status-Text $q.st) 14 $c "SemiBold" } else { $st = TB (Up (Status-Text $q.st)) 15 $c "Bold" }
  $tt = TB $q.title 12 "#8A94A3"; $tt.Margin = "0,1,0,0"
  $texts.Children.Add($st) | Out-Null; $texts.Children.Add($tt) | Out-Null
  foreach ($x in @($tile, $ar, $ago, $texts)) { $dp.Children.Add($x) | Out-Null }
  $sp.Children.Add($dp) | Out-Null
  if ($q.kind -eq "req") { $box = Ask-Box $q.r; $box.Margin = "58,8,0,4"; $sp.Children.Add($box) | Out-Null }
  $row.Child = $sp
  Hover-Row $row $q.sid
  return $row
}
$script:boardSig = ""
$script:lastSync = [datetime]::MinValue
function Render-Board([switch]$force) {
  $boardClock.Text = (Get-Date).ToString("HH:mm")
  $reqSids = @{}
  foreach ($r in $script:reqs) { $reqSids[[string]$r.sessionId] = $true }
  $queue = @()
  foreach ($r in $script:reqs) {
    $queue += @{ kind = "req"; sid = [string]$r.sessionId; st = "permission"; title = (Title-Of $r.sessionId $r.title); t = [double]$r.created; r = $r }
  }
  $att = @($script:sessions | Where-Object { $attention -contains $_.status -and -not $reqSids.ContainsKey([string]$_.sessionId) } |
    Sort-Object @{ e = { $o = $statusOrder[$_.status]; if ($null -eq $o) { 9 } else { $o } } }, @{ e = { [double]$_.updated } })
  foreach ($s in $att) { $queue += @{ kind = "ses"; sid = [string]$s.sessionId; st = [string]$s.status; title = [string]$s.title; t = [double]$s.updated } }
  $work = @($script:sessions | Where-Object { $_.status -eq "working" -and -not $reqSids.ContainsKey([string]$_.sessionId) } |
    Sort-Object @{ e = { $n = Num-Of $_.sessionId; if ($n) { [int]$n } else { 999 } } })
  # Re-draw only when something visible changed, so hover and clicks are not interrupted.
  $sig = (($queue | ForEach-Object { "$($_.sid)|$($_.st)|$(Num-Of $_.sid)|$(Ago $_.t)|$($_.title)" }) -join ";") + "#" +
         (($work | ForEach-Object { "$($_.sessionId)|$(Num-Of $_.sessionId)|$(Ago $_.updated)|$($_.title)" }) -join ";") + "#" + $boardClock.Text
  if (-not $force -and $sig -eq $script:boardSig) { return }
  $script:boardSig = $sig
  $cards.Children.Clear(); $list.Children.Clear()
  if ($queue.Count -gt 0) {
    $cards.Children.Add((Big-Call $queue[0])) | Out-Null
    if ($queue.Count -gt 1) {
      $list.Children.Add((Section $T.inLine)) | Out-Null
      for ($i = 1; $i -lt $queue.Count; $i++) { $list.Children.Add((Queue-Row $queue[$i] $false)) | Out-Null }
    }
  } else {
    $e = TB $T.empty 13 "#8A94A3"; $e.Margin = "4,6,4,2"
    $cards.Children.Add($e) | Out-Null
  }
  if ($work.Count -gt 0) {
    $list.Children.Add((Section $T.workingNow)) | Out-Null
    foreach ($s in $work) {
      $list.Children.Add((Queue-Row @{ kind = "ses"; sid = [string]$s.sessionId; st = "working"; title = [string]$s.title; t = [double]$s.updated } $true)) | Out-Null
    }
  }
  $foot = TB $T.footer 11 "#5C6673"; $foot.Margin = "4,10,4,0"; $foot.TextWrapping = "Wrap"
  $list.Children.Add($foot) | Out-Null
}
function Render-Cards { Render-Board -force }
function Render-List { Render-Board }
function Update-Countdowns { if ($script:popMode -eq "panel") { Render-Board } }

# ---------- mood ----------
$script:mood = ""
function Set-Mood($m) {
  if ($m -eq $script:mood) { return }
  $script:mood = $m
  foreach ($st in $sloth.Keys) { $sloth[$st].root.Visibility = $(if ($st -eq $m) { "Visible" } else { "Collapsed" }) }
}
function Refresh-Mood {
  $waiting = @($script:sessions | Where-Object { Is-Attention $_ }).Count + $script:reqs.Count
  $cut = [DateTimeOffset]::UtcNow.AddMinutes(-$workStaleMinutes).ToUnixTimeMilliseconds()
  $busy = @($script:sessions | Where-Object { $_.status -eq "working" -and [double]$_.updated -gt $cut }).Count
  if ($waiting -gt 0) { Set-Mood "call" } elseif ($busy -gt 0) { Set-Mood "work" } else { Set-Mood "sleep" }
  if ($waiting -gt 0) { $badgeText.Text = [string]$waiting; $badge.Visibility = "Visible" } else { $badge.Visibility = "Collapsed" }
}

# ---------- speech ----------
$script:say = ""; $script:sayShown = 0; $script:sayUntil = [datetime]::MinValue
function Say($msg) {
  if ($script:popMode -eq "panel") { return }
  if ($script:popMode -eq "bubble") { $script:bubbleQueue.Enqueue($msg); return }
  # Announced like a hospital call: "3 numara... izin... istiyor..."
  $n = Num-Of $msg.sid
  $text = $(if ($n) { Fmt $T.call @{ n = $n; say = $msg.text } } else { $msg.text })
  $bg = $tileColor[[string]$msg.st]; $fg = "#0E1116"
  if (-not $bg) { $bg = "#26303B"; $fg = "#F2F4F7" }
  $bubbleAvatarSlot.Content = Num-Tile $n $bg $fg 20 40
  $bubbleTab.Text = $msg.title; $bubbleTab.Foreground = Brush "#6B7480"; $bubbleTab.FontFamily = $ui
  $bubbleText.FontFamily = $ui; $bubbleText.FontSize = 14
  $script:say = $text; $script:sayShown = 0; $bubbleText.Text = ""
  $script:sayUntil = (Get-Date).AddSeconds(5 + $text.Length * 0.07)
  Show-Pop "bubble"
}
$bubble.Add_MouseLeftButtonUp({ $script:bubbleQueue.Clear(); Hide-Pop; Open-Panel })

# ---------- refresh loops ----------
function Refresh-Sessions {
  $script:sessions = @(Load-Sessions)
  foreach ($s in $script:sessions) {
    $key = "$($s.status)|$($s.updated)"
    $old = $script:prev[$s.sessionId]
    if ($script:firstLoad) {
      $ageMin = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$s.updated) / 60000
      if ($ageMin -gt 10) { $script:seen[$s.sessionId] = [double]$s.updated }
    } elseif ($old -ne $key -and $T.say.($s.status)) {
      if (($old -split "\|")[0] -ne $s.status -or $attention -contains $s.status) {
        Say @{ sid = $s.sessionId; st = $s.status; title = (Short $s.title 36); text = $T.say.($s.status) }
      }
    }
    $script:prev[$s.sessionId] = $key
  }
  $script:firstLoad = $false
  if ($script:popMode -eq "panel") { Render-List; Mark-Seen }
  Refresh-Mood
}

$script:autoOpened = $false
function Refresh-Requests {
  $new = @(Load-Requests)
  $sigOld = ($script:reqs | ForEach-Object { $_.id }) -join ","
  $sigNew = ($new | ForEach-Object { $_.id }) -join ","
  if ($sigOld -ne $sigNew) {
    $grew = @($new).Count -gt @($script:reqs).Count
    $script:reqs = $new
    Render-Cards
    if ($grew -and $script:popMode -ne "panel") { $script:autoOpened = $true; Open-Panel }
    if ($script:reqs.Count -eq 0 -and $script:autoOpened) { $script:autoOpened = $false; Hide-Pop }
    Refresh-Mood
  } else {
    Update-Countdowns
  }
}

function Open-Panel {
  Render-List; Render-Cards; Mark-Seen
  Show-Pop "panel"
  Refresh-Mood
}
$hide.Add_MouseLeftButtonUp({ $script:autoOpened = $false; Hide-Pop })

# ---------- mascot interaction ----------
$stage.Add_MouseLeftButtonDown({
  param($s, $e)
  $x0 = $win.Left; $y0 = $win.Top
  try { $win.DragMove() } catch {}
  if ([math]::Abs($win.Left - $x0) -lt 3 -and [math]::Abs($win.Top - $y0) -lt 3) {
    if ($script:popMode -eq "panel") { $script:autoOpened = $false; Hide-Pop } else { Open-Panel }
  } else {
    Clamp-Win; Save-Settings; Place-Pop
  }
})
$btnMin.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Toggle-Mini })
$btnClose.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $win.Close() })

$menu = New-Object System.Windows.Controls.ContextMenu
function Menu-Item($text, $action) { $m = New-Object System.Windows.Controls.MenuItem; $m.Header = $text; $m.Add_Click($action); $menu.Items.Add($m) | Out-Null; return $m }
$miMini = Menu-Item $T.minimize { Toggle-Mini }
Menu-Item $T.resetPos { Place-Default; Save-Settings; Place-Pop } | Out-Null
Menu-Item $T.close { $win.Close() } | Out-Null
$menu.Add_Opened({ $miMini.Header = $(if ($script:cfg.mini) { $T.restore } else { $T.minimize }) })
$stage.ContextMenu = $menu

# ---------- animation ----------
$clock = [System.Diagnostics.Stopwatch]::StartNew()
function Wave01($t, $period) { 0.5 - 0.5 * [math]::Cos(2 * [math]::PI * $t / $period) }
function Animate {
  $t = $clock.Elapsed.TotalSeconds
  $p = $sloth[$script:mood]
  if ($script:mood -eq "sleep") {
    $p.headMove.Y = 1.2 * (Wave01 $t 4)
    $i = 0
    foreach ($z in @("z1", "z2")) {
      $ph = (($t / 3.2) + $i * 0.5) % 1
      $p[$z].Opacity = $(if ($ph -lt 0.3) { $ph / 0.3 } else { 1 - ($ph - 0.3) / 0.7 })
      $p[$z].RenderTransform.X = 10 * $ph; $p[$z].RenderTransform.Y = -18 * $ph
      $i++
    }
  } elseif ($script:mood -eq "work") {
    $p.headRot.Angle = -2.5 * (Wave01 $t 6)
    $b = ($t % 5) / 5
    $p.lidScale.ScaleY = $(if ($b -gt 0.88 -and $b -lt 0.94) { 2.1 } else { 1 })
    $h = ($t % 1.6) / 1.6
    $p.handMove.Y = $(if ($h -lt 0.6) { 0 } elseif ($h -lt 0.75) { -2.2 * ($h - 0.6) / 0.15 } else { -2.2 * (1 - ($h - 0.75) / 0.25) })
  } elseif ($script:mood -eq "call") {
    $p.armRot.Angle = -16 * (Wave01 $t 2.4)
    $p.headMove.Y = -1 * (Wave01 $t 2.4)
  }
  # slow speech: one character every 70 ms, then hold, then next queued line
  if ($script:popMode -eq "bubble") {
    if ($script:sayShown -lt $script:say.Length) { $script:sayShown++; $bubbleText.Text = $script:say.Substring(0, $script:sayShown) }
    if ((Get-Date) -gt $script:sayUntil) {
      Hide-Pop
      if ($script:bubbleQueue.Count -gt 0) { Say $script:bubbleQueue.Dequeue() }
    }
  }
}

$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$animTimer.Add_Tick({ try { Animate } catch { Log "anim: $_ @ $($_.InvocationInfo.ScriptLineNumber)" } })

$reqTimer = New-Object System.Windows.Threading.DispatcherTimer
$reqTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$reqTimer.Add_Tick({ try { Refresh-Requests } catch { Log "req: $_ @ $($_.InvocationInfo.ScriptLineNumber)" } })

$slowTimer = New-Object System.Windows.Threading.DispatcherTimer
$slowTimer.Interval = [TimeSpan]::FromSeconds(2)
$slowTimer.Add_Tick({
  try { [System.IO.File]::WriteAllText($aliveFile, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) } catch {}
  try { Refresh-Sessions } catch { Log "ses: $_ @ $($_.InvocationInfo.ScriptLineNumber)" }
})

$win.Add_SourceInitialized({
  Apply-Size
  if ($null -ne $script:cfg.left -and $null -ne $script:cfg.top) { $win.Left = [double]$script:cfg.left; $win.Top = [double]$script:cfg.top } else { Place-Default }
})
$win.Add_Loaded({
  Clamp-Win
  $pop.Owner = $win
  try { [System.IO.File]::WriteAllText($aliveFile, [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) } catch {}
  Refresh-Sessions; Refresh-Requests
  if (-not $script:mood) { Set-Mood "sleep" }
  $animTimer.Start(); $reqTimer.Start(); $slowTimer.Start()
})
$win.Add_Closed({
  $animTimer.Stop(); $reqTimer.Stop(); $slowTimer.Stop()
  try { Remove-Item $aliveFile -ErrorAction SilentlyContinue } catch {}
  $mutex.ReleaseMutex()
})

$app = New-Object System.Windows.Application
$app.ShutdownMode = "OnMainWindowClose"
[void]$app.Run($win)
