param([switch]$Preview, [switch]$DemoMode, [switch]$VerifyUI, [int]$ProbeSeconds=0, [string]$DataDirectory='')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopLayer.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Interop.HwndSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
. (Join-Path $PSScriptRoot 'Tracker.ps1')
. (Join-Path $PSScriptRoot 'Demo.ps1')
. (Join-Path $PSScriptRoot 'DayCard.ps1')
$script:isDemo=[bool]$DemoMode
$demoRecords=New-DemoHistory
if (!$DataDirectory) { $DataDirectory = Join-Path $PSScriptRoot 'data' }
[void][IO.Directory]::CreateDirectory($DataDirectory)
$mutexId = 'Local\Afterhours-' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DataDirectory.ToLowerInvariant())) -replace '[^a-zA-Z0-9]','')
$mutex = [Threading.Mutex]::new($false,$mutexId)
if (-not $mutex.WaitOne(0)) { [Windows.MessageBox]::Show('看板已经运行，请使用已打开的窗口。') | Out-Null; exit }
try {
$configPath = Join-Path $DataDirectory 'games.json'
$recordsPath = Join-Path $DataDirectory 'activity.json'
$preferencesPath = Join-Path $DataDirectory 'preferences.json'
$preferences=[pscustomobject]@{Theme='灰绿';Dark=$false}
if(Test-Path -LiteralPath $preferencesPath){
 try{$saved=Get-Content -LiteralPath $preferencesPath -Raw|ConvertFrom-Json;if($saved.Theme){$preferences.Theme=$saved.Theme};$preferences.Dark=[bool]$saved.Dark}catch{}
}
$script:rules = @(
 [pscustomobject]@{Name='剑网 3'; Process='jx3clientx64'},
 [pscustomobject]@{Name='剑网 3'; Process='jx3client'},
 [pscustomobject]@{Name='三角洲行动'; Process='dfgame'},
 [pscustomobject]@{Name='守望先锋'; Process='overwatch'}
)
if (Test-Path -LiteralPath $configPath) { $script:rules = @((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)) }
else { Save-JsonAtomic $script:rules $configPath }
$steamRules=@(Get-SteamRules | Sort-Object Process -Unique)
$script:rules=@($script:rules | Where-Object { $_.Process -notlike 'steam-*' }) + $steamRules
foreach($rule in $script:rules){$rule.Name=$rule.Name -replace '^剑网\s*3$','剑网三'}
$records = @{}
if (Test-Path -LiteralPath $recordsPath) {
 foreach ($row in @((Get-Content -LiteralPath $recordsPath -Raw | ConvertFrom-Json))) { if ($null -ne $row) { $row.Name=$row.Name -replace '^剑网\s*3$','剑网三'; $records["$($row.Date)|$($row.Process)"] = $row } }
}
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'Silver.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
$ui['DemoToggle']=$window.FindName('DemoToggle')
$ui['GameScroll']=$window.FindName('GameScroll')
$ui['SettingsButton']=$window.FindName('SettingsButton')
$ui['RootGlass']=$window.FindName('RootGlass')
$ui['HeatPanel']=$window.FindName('HeatPanel')
'DragHandle','Subtitle','Compact','CloseButton','FullPanel','MiniPanel','Heatmap','Play','Total','Session','MiniTime','Runtime','CurrentGame','DateRange','Ranking','WeekTotal','Health','GameCount','PrevMonth','NextMonth','MonthLabel','CalendarScope','ClearFilter' | ForEach-Object { $ui[$_]=$window.FindName($_) }
$window.Height=[math]::Min(660,[Windows.SystemParameters]::WorkArea.Height-24)
$window.Left=[Windows.SystemParameters]::WorkArea.Right-$window.Width-20
$window.Top=[Windows.SystemParameters]::WorkArea.Top+12
$script:month=[datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))
$script:heatKey=''
$script:rankKey=''
$script:rankControls=@{}
$script:selectedGame=''
$script:desktop=$null
$script:lastRenderSignature=''
$startupRegistry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupName='AfterhoursGameTime'
$startupCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "'+(Join-Path $PSScriptRoot 'Launcher.ps1')+'"'
function Test-StartupEnabled {
 $value=(Get-ItemProperty -LiteralPath $startupRegistry -Name $startupName -ErrorAction SilentlyContinue).$startupName
 return $value -eq $startupCommand
}
function New-ThemeGradient($a,$b,$c){
 $brush=[Windows.Media.LinearGradientBrush]::new();$brush.StartPoint='0,0';$brush.EndPoint='1,1'
 [void]$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($a),0))
 [void]$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($b),0.55))
 [void]$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($c),1))
 return $brush
}
function Set-ThemeText($root){
 if($root -is [Windows.Controls.TextBlock] -and $root.Name -notin @('Name','Game')){$root.Foreground=$script:themeText}
 if($root -is [Windows.Controls.Button]){$root.Foreground=$script:themeText;$root.BorderBrush=$script:glassBorder}
 $count=[Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
 for($i=0;$i -lt $count;$i++){Set-ThemeText ([Windows.Media.VisualTreeHelper]::GetChild($root,$i))}
}
function Apply-Theme {
 switch($preferences.Theme){
  '雾蓝' {$script:heatPalette=@('#E1E8EB','#C4D2D9','#9EB4BF','#7898A8','#567888');$script:gameTones=@(@('#DDE7EC','#AFC2CB','#405A66'),@('#E6EBEE','#BBC8CE','#4A5C64'),@('#D6E2E7','#A3BBC5','#385867'));$script:barLight='#B8CBD4';$script:barDark='#718E9C'}
  '淡紫' {$script:heatPalette=@('#E8E4EA','#D6CDD9','#BDAFC2','#9E8BA7','#796982');$script:gameTones=@(@('#E9E2EC','#CDBFD2','#594D60'),@('#E2DCE8','#C1B4CA','#53485B'),@('#EEE8EF','#D5C9D8','#625667'));$script:barLight='#CBBFD0';$script:barDark='#8D7B95'}
  '暖杏' {$script:heatPalette=@('#EEE8E0','#DFD1C2','#C9B39E','#AE9278','#876F5A');$script:gameTones=@(@('#EFE5D9','#D3C0AA','#635443'),@('#E8DED2','#C9B8A5','#5D5042'),@('#F1E9E0','#DACABA','#6A5848'));$script:barLight='#D3C2AF';$script:barDark='#9B8168'}
  default {$preferences.Theme='灰绿';$script:heatPalette=@('#E3E7E4','#C9D5CE','#A8BCB0','#819C8C','#5E796A');$script:gameTones=@(@('#DDE7E1','#AEBFB5','#42574B'),@('#E5EAE7','#B9C7BF','#4A5C52'),@('#D5E1DA','#A4B8AD','#3F574A'));$script:barLight='#AFC2B7';$script:barDark='#728D7D'}
 }
 if($preferences.Dark){$script:themeText=[Windows.Media.BrushConverter]::new().ConvertFromString('#F1F4F2');$glass=New-ThemeGradient '#80252A28' '#802D322F' '#80332F2B';$panel='#523A403D';$script:glassBorder='#70FFFFFF'}
 else{$script:themeText=[Windows.Media.BrushConverter]::new().ConvertFromString('#303633');$glass=New-ThemeGradient '#80FFFFFF' '#80E7E9E5' '#80F0ECE7';$panel='#62FFFFFF';$script:glassBorder='#A8FFFFFF'}
 $script:cardBackground=$glass
 $ui.RootGlass.Background=$glass;$ui.RootGlass.BorderBrush=$script:glassBorder;$ui.RootGlass.BorderThickness=1
 $ui.HeatPanel.Background=$panel;$ui.HeatPanel.BorderBrush=$script:glassBorder
 Set-ThemeText $window
 $script:heatKey='';$script:rankKey=''
}
if(-not $Preview){$window.Add_SourceInitialized({
 $script:desktop=[DesktopLayer]::new($window)
 Save-JsonAtomic ([pscustomobject]@{Pid=$PID;Handle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle.ToInt64();BlurEnabled=$script:desktop.BlurEnabled;Mode='Desktop';Started=[datetime]::Now.ToString('o')}) (Join-Path $DataDirectory 'runtime.json')
})}
if(-not $Preview){$window.Add_ContentRendered({$script:desktop.Lower()})}
$script:last = Read-Snapshot $script:rules
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:lastTick = $clock.Elapsed.TotalSeconds
$script:lastSaved = 0.0
$script:saveError = ''
function Save-Activity {
 try { Save-JsonAtomic @($records.Values) $recordsPath; $script:saveError='' }
 catch { $script:saveError='保存失败：' + $_.Exception.Message }
}
function Format-CompactDuration([double]$Seconds){
 if($Seconds -lt 60){return Format-Duration $Seconds}
 $value=[timespan]::FromSeconds($Seconds)
 if($value.TotalHours -ge 1){return ('{0}h {1:00}m' -f [math]::Floor($value.TotalHours),$value.Minutes)}
 return "$([math]::Floor($value.TotalMinutes))m"
}
function Render-State {
 $displayRecords=if($script:isDemo){$demoRecords}else{$records}
 $ui.DemoToggle.Content=if($script:isDemo){'返回实测'}else{'演示'}
 $ui.DemoToggle.Background=if($script:isDemo){'#D8CDEC'}else{'#72FFFFFF'}
 $ui.CalendarScope.Content=if($script:selectedGame){$script:selectedGame+' ▾'}else{'全部游戏 ▾'}
 $ui.ClearFilter.Visibility=if($script:selectedGame){'Visible'}else{'Collapsed'}
 $today = [datetime]::Today.ToString('yyyy-MM-dd')
 $todayRows = @($displayRecords.Values | Where-Object Date -eq $today)
 $fg = [double](($todayRows | Measure-Object Foreground -Sum).Sum)
 $run = [double](($todayRows | Measure-Object Running -Sum).Sum)
 $ui.Total.Text = Format-CompactDuration $fg
 $ui.MiniTime.Text = Format-CompactDuration $fg
 $ui.Total.ToolTip = '运行累计 ' + (Format-Duration $run) + ' · 后台 ' + (Format-Duration ($run-$fg))
 $active = @($script:rules | Where-Object { $script:last.Names.ContainsKey($_.Process.ToLowerInvariant()) })
 $frontGame = @($active | Where-Object { $_.Process -eq $script:last.Front })
 $ui.CurrentGame.Text = if ($frontGame.Count) { $frontGame[0].Name + ' · 前台' } elseif ($active.Count) { $active[0].Name + ' · 后台' } else { '等待游戏' }
 if($script:isDemo){$ui.CurrentGame.Text='演示模式 · 示例数据'}
 $ui.CurrentGame.ToolTip = if ($script:last.Readable) { '当前前台：' + $script:last.FrontLabel + "`n已识别 $($steamRules.Count) 款 Steam 游戏；每 5 秒本地保存。" } else { '前台不可读或桌面锁定，暂停累计。' }
 $ui.Health.Text = if ($script:saveError) { $script:saveError } elseif (-not $script:last.Readable) { '无法读取交互桌面。请在桌面双击启动；锁屏期间不计时。' } else { "已识别 $($steamRules.Count) 款 Steam 游戏 · 每 5 秒保存 · 从现在起统计" }
 $ui.Health.Visibility=if($script:saveError -or (-not $script:last.Readable -and -not $Preview)){'Visible'}else{'Collapsed'}
 $games=@($todayRows | Group-Object Name | ForEach-Object {
  [pscustomobject]@{Name=$_.Name;Foreground=[double](($_.Group|Measure-Object Foreground -Sum).Sum);Running=[double](($_.Group|Measure-Object Running -Sum).Sum)}
 } | Sort-Object Foreground -Descending)
 $script:expandedHeight=[math]::Min(750,610+[math]::Max(0,$games.Count-1)*70)
 $ui.GameScroll.Height=[math]::Min(216,76*[math]::Max(1,$games.Count))
 if($ui.FullPanel.Visibility -eq 'Visible'){$window.Height=[math]::Min($script:expandedHeight,[Windows.SystemParameters]::WorkArea.Height-24)}
 $rankKey=($games.Name -join '|')
 if($script:rankKey -ne $rankKey -or $ui.Ranking.Children.Count -eq 0){
  $script:rankKey=$rankKey; $ui.Ranking.Children.Clear(); $script:rankControls=@{}
  if(-not $games.Count){
   $empty=[Windows.Controls.TextBlock]::new();$empty.Text="今天还没玩游戏`n启动游戏后自动记录。";$empty.FontSize=11;$empty.Foreground='#496C81';$empty.LineHeight=24;$empty.Margin='0,12,0,0';[void]$ui.Ranking.Children.Add($empty)
  }
  foreach($game in $games){
   [xml]$rowXaml=@'
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Style="{DynamicResource GameRowStyle}">
 <StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Border Name="GameChip" CornerRadius="6" BorderThickness="1" Padding="8,4" HorizontalAlignment="Left" Margin="0,0,12,0"><TextBlock Name="Name" FontSize="13" TextTrimming="CharacterEllipsis"/></Border><TextBlock Name="Front" Grid.Column="1" FontFamily="Segoe UI" FontSize="14" FontWeight="SemiBold" Foreground="#354942" VerticalAlignment="Center"/></Grid>
 <Grid Name="BarTrack" Height="6" Margin="0,9,0,0"><Border Background="#E2E7E4" CornerRadius="3"/><Border Name="RunBar" Background="#C8D4CD" CornerRadius="3" HorizontalAlignment="Left"/><Border Name="FrontBar" CornerRadius="3" HorizontalAlignment="Left"><Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#AFC2B7" Offset="0"/><GradientStop Color="#728D7D" Offset="1"/></LinearGradientBrush></Border.Background></Border></Grid>
 </StackPanel>
</Button>
'@
   $row=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($rowXaml))
   $row.FindName('Name').Text=$game.Name;$row.FindName('Name').ToolTip=$game.Name
   $tone=Get-GameTint $game.Name;$row.FindName('GameChip').Background=$tone[0];$row.FindName('GameChip').BorderBrush=$tone[1]
   $row.FindName('RunBar').Background=$script:barLight
   $row.FindName('FrontBar').Background=(New-ThemeGradient $script:barLight $script:barDark $script:barDark)
   $row.Uid=$game.Name
   $track=$row.FindName('BarTrack');$track.Tag=$row
   $track.Add_SizeChanged({param($sender,$eventArgs)
    $owner=$sender.Tag
    $owner.FindName('RunBar').Width=$sender.ActualWidth*[double]$owner.Resources['runFraction']
    $owner.FindName('FrontBar').Width=$sender.ActualWidth*[double]$owner.Resources['frontFraction']
   })
   $row.Add_Click({param($sender,$eventArgs) if($script:selectedGame -eq $sender.Uid){$script:selectedGame=''}else{$script:selectedGame=[string]$sender.Uid};Render-State})
   $script:rankControls[$game.Name]=$row
   [void]$ui.Ranking.Children.Add($row)
  }
 }
 $maximum=[math]::Max(1,[double](($games|Measure-Object Running -Maximum).Maximum))
 foreach($game in $games){
  $row=$script:rankControls[$game.Name]
  $row.Tag=if($script:selectedGame -eq $game.Name){'selected'}else{''}
  $row.BorderBrush=if($script:selectedGame -eq $game.Name){$script:barDark}else{$script:glassBorder}
  $row.Background=if($preferences.Dark){'#34FFFFFF'}else{'#72FFFFFF'}
  $row.FindName('Name').Foreground=(Get-GameTint $game.Name)[2]
  $row.FindName('Front').Text=Format-CompactDuration $game.Foreground
  $barWidth=[math]::Max(100,$row.FindName('BarTrack').ActualWidth)
  $row.Resources['runFraction']=$game.Running/$maximum
  $row.Resources['frontFraction']=$game.Foreground/$maximum
  $row.FindName('RunBar').Width=$barWidth*$game.Running/$maximum
  $row.FindName('FrontBar').Width=$barWidth*$game.Foreground/$maximum
  $state=if($frontGame.Name -contains $game.Name){'前台游玩'}elseif($active.Name -contains $game.Name){'后台运行'}else{'已结束'}
  $row.ToolTip="点击筛选热力图，再次点击恢复全部`n"+$state+' · 运行 '+(Format-Duration $game.Running)+' · 后台 '+(Format-Duration ($game.Running-$game.Foreground))+"`n深色为前台，浅色为后台；各条按运行时间同比例显示。"
 }
 $monday = [datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))
 $start = $script:month.AddDays(-49)
 $palette = $script:heatPalette
 $totals = @{}
 foreach ($row in $displayRecords.Values) { if(-not $script:selectedGame -or $row.Name -eq $script:selectedGame){$totals[$row.Date] += $row.Foreground} }
 $heatKey=$script:month.ToString('yyyy-MM-dd')+'|'+$today+'|'+[math]::Floor($fg/60)+'|'+$displayRecords.Count+'|'+$script:selectedGame+'|'+$script:isDemo
 if($script:heatKey -ne $heatKey){
 $script:heatKey=$heatKey
 $ui.Heatmap.Children.Clear()
 for ($index=0; $index -lt 56; $index++) {
  $date = $start.AddDays(($index%8)*7+[math]::Floor($index/8))
  $seconds = [double]$totals[$date.ToString('yyyy-MM-dd')]
  $level = if ($seconds -le 0) {0} elseif ($seconds -lt 3600) {1} elseif ($seconds -lt 7200) {2} elseif ($seconds -lt 14400) {3} else {4}
  $cell = [Windows.Controls.Border]::new()
  $shade=[Windows.Media.ColorConverter]::ConvertFromString($palette[$level])
  $light=[Windows.Media.Color]::FromRgb([byte][math]::Min(255,$shade.R+15),[byte][math]::Min(255,$shade.G+15),[byte][math]::Min(255,$shade.B+15))
  $cell.Background=[Windows.Media.LinearGradientBrush]::new($light,$shade,90)
  $cell.BorderBrush='#72FFFFFF';$cell.BorderThickness=0.5
  $cell.CornerRadius=4; $cell.Margin=3
  if ($date -gt [datetime]::Today) { $cell.Opacity=0.25 }
  if ($date -eq [datetime]::Today) { $cell.BorderBrush='#537FA4'; $cell.BorderThickness=1.5 }
  $cell.Tag=$date.ToString('yyyy-MM-dd')
  $cell.Add_MouseEnter({param($sender,$eventArgs)
   $sender.Resources['previousBorder']=@($sender.BorderBrush,$sender.BorderThickness)
   $sender.BorderBrush='#6097BD';$sender.BorderThickness=2
   $sender.ToolTip=New-DayTooltip ([string]$sender.Tag)
  })
  $cell.Add_MouseLeave({param($sender,$eventArgs) $previous=$sender.Resources['previousBorder'];if($previous){$sender.BorderBrush=$previous[0];$sender.BorderThickness=$previous[1]}})
  $cell.ToolTip = '查看当日明细'
  [Windows.Controls.ToolTipService]::SetInitialShowDelay($cell,120)
  [Windows.Controls.ToolTipService]::SetShowDuration($cell,20000)
  [void]$ui.Heatmap.Children.Add($cell)
 }
 $ui.MonthLabel.Text=$start.ToString('MM.dd')+' — '+$script:month.AddDays(6).ToString('MM.dd')
 $ui.Heatmap.ToolTip='每格一天，深色表示更长的前台时间；描边为今天。'
 $ui.NextMonth.IsEnabled=$script:month -lt $monday
 }
 $weekSum = [double](($displayRecords.Values | Where-Object { $_.Date -ge $monday.ToString('yyyy-MM-dd') -and $_.Date -le $today } | Measure-Object Foreground -Sum).Sum)
 $ui.WeekTotal.Text='本周 ' + (Format-CompactDuration $weekSum)
 Set-ThemeText $window
 foreach($game in $games){$row=$script:rankControls[$game.Name];$row.FindName('Name').Foreground=(Get-GameTint $game.Name)[2];$row.FindName('Front').Foreground=$script:themeText}
}
function Get-DayTooltip([string]$Date){
 $source=if($script:isDemo){$demoRecords}else{$records}
 $rows=@($source.Values|Where-Object { $_.Date -eq $Date -and (-not $script:selectedGame -or $_.Name -eq $script:selectedGame) })
 $front=[double](($rows|Measure-Object Foreground -Sum).Sum)
 $running=[double](($rows|Measure-Object Running -Sum).Sum)
 $label=if($script:isDemo){' · 示例数据'}else{''}
 $text="$Date$label`n前台 $(Format-Duration $front) · 运行 $(Format-Duration $running)"
 foreach($group in @($rows|Group-Object Name)){
  $f=[double](($group.Group|Measure-Object Foreground -Sum).Sum)
  $r=[double](($group.Group|Measure-Object Running -Sum).Sum)
  $text+="`n$($group.Name)：前台 $(Format-Duration $f) / 运行 $(Format-Duration $r)"
 }
 if(-not $rows.Count){$text+="`n暂无记录"}
 return $text
}
function Select-Game {
 $picker = [Windows.Window]::new()
 $picker.Title='添加要统计的程序'; $picker.Width=460; $picker.Height=500; $picker.Owner=$window; $picker.WindowStartupLocation='CenterOwner'; $picker.Background='#EDF5FA'
 $picker.Resources.MergedDictionaries.Add($window.Resources)
 $panel=[Windows.Controls.StackPanel]::new(); $panel.Margin=20
 $hint=[Windows.Controls.TextBlock]::new(); $hint.Text='先打开游戏，再选择对应进程（不选启动器）。'; $hint.Foreground='#365367'; $hint.Margin='0,0,0,12'; [void]$panel.Children.Add($hint)
 $list=[Windows.Controls.ListBox]::new(); $list.Height=290
 $sessionId=(Get-Process -Id $PID).SessionId
 foreach($name in @(Get-Process | Where-Object SessionId -eq $sessionId | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object)) { [void]$list.Items.Add($name) }
 [void]$panel.Children.Add($list)
 $label=[Windows.Controls.TextBlock]::new(); $label.Text='显示名称（可改为游戏名）'; $label.Foreground='#365367'; $label.Margin='0,12,0,6'; [void]$panel.Children.Add($label)
 $nameBox=[Windows.Controls.TextBox]::new(); $nameBox.Height=28; [void]$panel.Children.Add($nameBox)
 $list.Add_SelectionChanged({$nameBox.Text=[string]$list.SelectedItem})
 $add=[Windows.Controls.Button]::new(); $add.Content='添加并立即统计'; $add.Margin='0,12,0,0'; $add.Height=30
 $add.Add_Click({
  if ($list.SelectedItem -and $nameBox.Text.Trim()) {
   $processName=([string]$list.SelectedItem).ToLowerInvariant()
   if($processName -match '^(steam|steamwebhelper|battle[.]net)$'){[void][Windows.MessageBox]::Show('请选择游戏进程，而不是平台客户端。');return}
   $script:rules=@($script:rules | Where-Object Process -ne $processName) + @([pscustomobject]@{Name=$nameBox.Text.Trim(); Process=$processName})
   Save-JsonAtomic $script:rules $configPath
   $picker.Close()
  }
 })
 [void]$panel.Children.Add($add); $picker.Content=$panel
 [void]$picker.ShowDialog()
}
$ui.DragHandle.Add_MouseLeftButtonDown({ $window.DragMove() })
$ui.PrevMonth.Add_Click({$script:month=$script:month.AddDays(-56);Render-State})
$ui.ClearFilter.Add_Click({$script:selectedGame='';Render-State})
$ui.DemoToggle.Add_Click({$script:isDemo=-not $script:isDemo;$script:selectedGame='';$script:heatKey='';Render-State})
function New-SettingsMenu {
 $menu=[Windows.Controls.ContextMenu]::new();$menu.Style=$window.FindResource('GameMenuStyle');$menu.Placement='Bottom';$menu.VerticalOffset=5
 $menu.Add_Loaded({param($sender,$eventArgs)$source=[Windows.Interop.HwndSource]::FromVisual($sender);if($source){[DesktopLayer]::BlurPopup($source.Handle)}})
 foreach($theme in @('灰绿','雾蓝','淡紫','暖杏')){
  $item=[Windows.Controls.MenuItem]::new();$item.Header='主题 · '+$theme;$item.Tag='theme|'+$theme;$item.IsCheckable=$true;$item.IsChecked=$preferences.Theme -eq $theme;$item.Style=$window.FindResource('GameMenuItemStyle')
  $item.Add_Click({param($sender,$eventArgs)$preferences.Theme=([string]$sender.Tag).Split('|')[1];Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($item)
 }
 $dark=[Windows.Controls.MenuItem]::new();$dark.Header='深色模式';$dark.IsCheckable=$true;$dark.IsChecked=$preferences.Dark;$dark.Style=$window.FindResource('GameMenuItemStyle')
 $dark.Add_Click({$preferences.Dark=-not $preferences.Dark;Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($dark)
 $startup=[Windows.Controls.MenuItem]::new();$startup.Header='开机启动';$startup.IsCheckable=$true;$startup.IsChecked=Test-StartupEnabled;$startup.Style=$window.FindResource('GameMenuItemStyle')
 $startup.Add_Click({try{if(Test-StartupEnabled){Remove-ItemProperty -LiteralPath $startupRegistry -Name $startupName -ErrorAction SilentlyContinue}else{Set-ItemProperty -LiteralPath $startupRegistry -Name $startupName -Value $startupCommand -Type String}}catch{[Windows.MessageBox]::Show('无法修改开机启动：'+$_.Exception.Message,'Afterhours')|Out-Null}});[void]$menu.Items.Add($startup)
 return $menu
}
$ui.SettingsButton.Add_Click({$menu=New-SettingsMenu;$menu.PlacementTarget=$ui.SettingsButton;$menu.IsOpen=$true})
function New-GameMenu {
 $menu=[Windows.Controls.ContextMenu]::new()
 $menu.Style=$window.FindResource('GameMenuStyle')
 $menu.Placement='Bottom';$menu.VerticalOffset=5
 $menu.Add_Loaded({param($sender,$eventArgs) $source=[Windows.Interop.HwndSource]::FromVisual($sender);if($source){[DesktopLayer]::BlurPopup($source.Handle)}})
 $source=if($script:isDemo){$demoRecords}else{$records}
 foreach($name in @('全部游戏')+@(@($script:rules.Name)+@($source.Values.Name)|Sort-Object -Unique)){
 $item=[Windows.Controls.MenuItem]::new();$item.Header=$name;$item.Tag=$name
  $item.Foreground=$script:themeText
  $item.Style=$window.FindResource('GameMenuItemStyle');$item.IsCheckable=$true
  $item.IsChecked=($name -eq $script:selectedGame -or (-not $script:selectedGame -and $name -eq '全部游戏'))
  $item.ToolTip=$name
  $item.Add_Click({param($sender,$eventArgs) $script:selectedGame=if($sender.Tag -eq '全部游戏'){''}else{[string]$sender.Tag};Render-State})
  [void]$menu.Items.Add($item)
 }
 return $menu
}
$ui.CalendarScope.Add_Click({
 $menu=New-GameMenu
 $menu.PlacementTarget=$ui.CalendarScope;$menu.IsOpen=$true
})
$ui.NextMonth.Add_Click({if($script:month -lt [datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))){$script:month=$script:month.AddDays(56);Render-State}})
$ui.CloseButton.Add_Click({$window.Close()})
$ui.Compact.Add_Click({
 if($ui.FullPanel.Visibility -eq 'Visible'){$ui.FullPanel.Visibility='Collapsed';$ui.MiniPanel.Visibility='Visible';$window.Height=160;$ui.Compact.Content='+'}
 else{$ui.FullPanel.Visibility='Visible';$ui.MiniPanel.Visibility='Collapsed';$window.Height=[math]::Min($script:expandedHeight,[Windows.SystemParameters]::WorkArea.Height-24);$ui.Compact.Content='−'}
})
$ui.Play.Add_Click({Select-Game})
$timer=[Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[timespan]::FromSeconds(1)
$timer.Add_Tick({
 try {
  $next=Read-Snapshot $script:rules
  $tick=$clock.Elapsed.TotalSeconds
  Add-Interval $records $script:rules $script:last $next ($tick-$script:lastTick)
  $script:last=$next; $script:lastTick=$tick
  if($tick-$script:lastSaved -ge 5){Save-Activity; $script:lastSaved=$tick}
  $signature=$script:last.Front+'|'+$script:last.Readable+'|'+($records.Values | ForEach-Object { [math]::Floor($_.Foreground).ToString()+','+[math]::Floor($_.Running).ToString() })+'|'+$script:saveError
  if($signature -ne $script:lastRenderSignature -and (-not $script:desktop -or -not $script:desktop.IsCovered())){Render-State;$script:lastRenderSignature=$signature}
  if($ProbeSeconds -gt 0 -and $tick -ge $ProbeSeconds){$window.Close()}
 } catch { $ui.Health.Text='采集错误：'+$_.Exception.Message; $script:last=Read-Snapshot $script:rules; $script:lastTick=$clock.Elapsed.TotalSeconds }
})
$window.Add_Closed({$timer.Stop(); Save-Activity})
Apply-Theme
Render-State
if($Preview){
 $window.Show(); $window.UpdateLayout()
 Render-State
 if($VerifyUI){
  $realBefore=ConvertTo-Json -InputObject @($records.Values) -Depth 6
  $modeBefore=$script:isDemo
  $ui.DemoToggle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  $ui.DemoToggle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($script:isDemo -ne $modeBefore -or (ConvertTo-Json -InputObject @($records.Values) -Depth 6) -ne $realBefore){throw 'Demo isolation failed'}
  $tip=Get-DayTooltip ([datetime]::Today.ToString('yyyy-MM-dd'))
  if($tip -notmatch '前台' -or $tip -notmatch '运行'){throw 'Daily tooltip failed'}
  $dayTip=New-DayTooltip ([datetime]::Today.ToString('yyyy-MM-dd'))
  $dayTip.PlacementTarget=$ui.Heatmap;$dayTip.IsOpen=$true
  [void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  $dayTip.UpdateLayout()
  if($dayTip.ActualWidth -lt 370 -or $dayTip.Content.FindName('Rows').Children.Count -lt 1){throw 'Structured tooltip popup failed'}
  $hoverBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($dayTip.ActualWidth),[int][math]::Ceiling($dayTip.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32);$hoverBitmap.Render($dayTip)
  $hoverEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$hoverEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($hoverBitmap))
  $hoverStream=[IO.File]::Create((Join-Path $PSScriptRoot 'hover-detail.png'));$hoverEncoder.Save($hoverStream);$hoverStream.Dispose()
  $dayTip.IsOpen=$false
  $testMenu=New-GameMenu;$testMenu.PlacementTarget=$ui.CalendarScope;$testMenu.IsOpen=$true
  [void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  $testMenu.UpdateLayout()
  if(-not $testMenu.Items[0].IsChecked -or $testMenu.ActualWidth -lt 260){throw 'Styled menu failed'}
  $menuBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($testMenu.ActualWidth),[int][math]::Ceiling($testMenu.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32);$menuBitmap.Render($testMenu)
  $menuEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$menuEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($menuBitmap))
  $menuStream=[IO.File]::Create((Join-Path $PSScriptRoot 'game-menu.png'));$menuEncoder.Save($menuStream);$menuStream.Dispose()
  $testMenu.IsOpen=$false
  if($ui.Heatmap.Children.Count -ne 56){throw 'Heatmap count failed'}
  $cell=$ui.Heatmap.Children[0]
  if([math]::Abs($cell.ActualWidth-$cell.ActualHeight) -gt 0.1){throw 'Heatmap squares failed'}
  if($script:rankControls.Count){
   $row=@($script:rankControls.Values)[0]
   $row.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   if($script:selectedGame -ne $row.Uid -or $row.Tag -ne 'selected'){throw 'Game click filter failed'}
   if(-not @($row.Template.Triggers|Where-Object {$_.Property.Name -eq 'IsMouseOver'}).Count){throw 'Row hover affordance missing'}
   $window.UpdateLayout()
   [void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
   $selectedBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(400,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$selectedBitmap.Render($window)
   $selectedEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$selectedEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($selectedBitmap))
   $selectedStream=[IO.File]::Create((Join-Path $PSScriptRoot 'selected-game.png'));$selectedEncoder.Save($selectedStream);$selectedStream.Dispose()
   $ui.ClearFilter.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
   if($script:selectedGame){throw 'Clear filter failed'}
  }
  $previous=$script:month
  $ui.PrevMonth.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($script:month -ne $previous.AddDays(-56)){throw 'History paging failed'}
  $ui.NextMonth.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  if($script:month -ne $previous){throw 'Forward paging failed'}
  $savedTheme=$preferences.Theme;$savedDark=$preferences.Dark
  $settings=New-SettingsMenu
  if($settings.Items.Count -ne 6){throw 'Settings menu item count failed'}
  $settings.Items[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  if($preferences.Theme -ne '淡紫'){throw 'Theme selection failed'}
  $settings=New-SettingsMenu;$settings.Items[4].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  if(-not $preferences.Dark){throw 'Dark mode failed'}
  $window.UpdateLayout();[void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  $darkBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(400,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$darkBitmap.Render($window)
  $darkEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$darkEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($darkBitmap))
  $darkStream=[IO.File]::Create((Join-Path $PSScriptRoot 'dark-preview.png'));$darkEncoder.Save($darkStream);$darkStream.Dispose()
  $preferences.Theme=$savedTheme;$preferences.Dark=$savedDark;Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State
  Write-Output 'UI_PASS: themes, dark mode, settings menu, square cells, game filter, history, hover, daily tooltip, demo isolation'
 }
 $window.Height=$script:expandedHeight; $window.UpdateLayout()
 Render-State; $window.UpdateLayout()
 [void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(400,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32); $bitmap.Render($window)
 $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create((Join-Path $PSScriptRoot 'preview.png')); $encoder.Save($stream); $stream.Dispose(); $window.Close()
 $card=New-DayCard ([datetime]::Today.ToString('yyyy-MM-dd'))
 $card.Measure([Windows.Size]::new(376,[double]::PositiveInfinity));$card.Arrange([Windows.Rect]::new(0,0,376,$card.DesiredSize.Height));$card.UpdateLayout()
 $cardBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(376,[int][math]::Ceiling($card.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32);$cardBitmap.Render($card)
 $cardEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$cardEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($cardBitmap))
 $cardStream=[IO.File]::Create((Join-Path $PSScriptRoot 'day-detail.png'));$cardEncoder.Save($cardStream);$cardStream.Dispose()
 Write-Output 'PREVIEW_OK'
} else { $timer.Start(); [void]$window.ShowDialog() }
if($ProbeSeconds -gt 0){[pscustomobject]@{Readable=$script:last.Readable; Foreground=$script:last.Front; Rows=@($records.Values)} | ConvertTo-Json -Depth 5}
} catch {
 $_ | Out-String | Set-Content (Join-Path $DataDirectory 'error.log')
 throw
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
