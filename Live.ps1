param([switch]$Preview, [switch]$DemoMode, [switch]$VerifyUI, [string]$Screenshots='', [int]$ProbeSeconds=0, [string]$DataDirectory='')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopLayer.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Interop.HwndSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
. (Join-Path $PSScriptRoot 'Tracker.ps1')
. (Join-Path $PSScriptRoot 'Demo.ps1')
. (Join-Path $PSScriptRoot 'DayCard.ps1')
$script:isDemo=[bool]$DemoMode
$demoRecords=New-DemoHistory
$demoSessions=New-DemoSessions $demoRecords
if (!$DataDirectory) { $DataDirectory = Join-Path $PSScriptRoot 'data' }
[void][IO.Directory]::CreateDirectory($DataDirectory)
$mutexId = 'Local\Afterhours-' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DataDirectory.ToLowerInvariant())) -replace '[^a-zA-Z0-9]','')
$mutex = [Threading.Mutex]::new($false,$mutexId)
if (-not $mutex.WaitOne(0)) { [Windows.MessageBox]::Show('看板已经运行，请使用已打开的窗口。') | Out-Null; exit }
try {
$configPath = Join-Path $DataDirectory 'games.json'
$recordsPath = Join-Path $DataDirectory 'activity.json'
$preferencesPath = Join-Path $DataDirectory 'preferences.json'
$sessionsPath = Join-Path $DataDirectory 'sessions.json'
$preferences=[pscustomobject]@{Theme='极光薄荷';Dark=$false}
if(Test-Path -LiteralPath $preferencesPath){
 try{$saved=Get-Content -LiteralPath $preferencesPath -Raw|ConvertFrom-Json;if($saved.Theme){$preferences.Theme=$saved.Theme};$preferences.Dark=[bool]$saved.Dark}catch{}
}
$builtInRules = @(
 [pscustomobject]@{Name='剑网 3'; Process='jx3clientx64'},
 [pscustomobject]@{Name='剑网 3'; Process='jx3client'},
 [pscustomobject]@{Name='三角洲行动'; Process='dfgame'},
 [pscustomobject]@{Name='守望先锋'; Process='overwatch'},
 [pscustomobject]@{Name='Apex Legends'; Process='r5apex'},
 [pscustomobject]@{Name='Apex Legends'; Process='r5apex_dx12'},
 [pscustomobject]@{Name='无限暖暖'; Process='x6game-win64-shipping'},
 [pscustomobject]@{Name='无限暖暖'; Process='infinitynikki'}
)
$manualRules=@()
if (Test-Path -LiteralPath $configPath) { try{$loaded=@((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json));$manualRules=@($loaded|Where-Object{$_.Process -notlike 'steam-*' -and $_.Process -notin $builtInRules.Process})}catch{} }
else { Save-JsonAtomic @() $configPath }
$steamRules=@(Get-SteamRules | Sort-Object Process -Unique)
$script:rules=@($builtInRules)+@($manualRules)+@($steamRules)
foreach($rule in $script:rules){$rule.Name=$rule.Name -replace '^剑网\s*3$','剑网三'}
$records = @{}
if (Test-Path -LiteralPath $recordsPath) {
 foreach ($row in @((Get-Content -LiteralPath $recordsPath -Raw | ConvertFrom-Json))) { if ($null -ne $row) { $row.Name=$row.Name -replace '^剑网\s*3$','剑网三'; $records["$($row.Date)|$($row.Process)"] = $row } }
}
$sessions=[Collections.ArrayList]::new()
if(Test-Path -LiteralPath $sessionsPath){try{foreach($item in @((Get-Content -LiteralPath $sessionsPath -Raw|ConvertFrom-Json))){if($item){[void]$sessions.Add($item)}}}catch{}}
$script:currentSession=$null
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'Silver.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
$ui['GameScroll']=$window.FindName('GameScroll')
$ui['SettingsButton']=$window.FindName('SettingsButton')
$ui['RootGlass']=$window.FindName('RootGlass')
$ui['HeatPanel']=$window.FindName('HeatPanel')
'DragHandle','TopHeader','HeaderActions','Subtitle','Compact','CloseButton','FullPanel','MiniPanel','StatsPanel','StatsButton','StatsBack','StatsTotal','StatsGames','StatsTimeline','StatsPlayWindow','StatsRangeLabel','StatsRange7','StatsRange30','StatsRangeAll','StatsRangeBox','StatsHeaderActions','StatsShareHint','StatsDateSpan','StatsAverage','StatsDays','StatsHours','StatsHourHint','StatsTile1','StatsTile2','StatsTile3','StatsDonut','StatsShareCard','StatsTimelineCard','ResizeGrip','Heatmap','Play','Total','Session','MiniTime','Runtime','CurrentGame','DateRange','Ranking','WeekTotal','Health','GameCount','PrevMonth','NextMonth','MonthLabel','CalendarScope','ClearFilter','HeatLegend' | ForEach-Object { $ui[$_]=$window.FindName($_) }
$window.Height=[math]::Min(610,[Windows.SystemParameters]::WorkArea.Height-24)
$window.Left=[Windows.SystemParameters]::WorkArea.Right-$window.Width-20
$window.Top=[Windows.SystemParameters]::WorkArea.Top+12
$script:month=[datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))
$script:heatKey=''
$script:rankKey=''
$script:rankControls=@{}
$script:selectedGame=''
$script:statsRange=7
$script:desktop=$null
$script:lastRenderSignature=''
$startupRegistry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupName='AfterhoursGameTime'
$startupCommand='wscript.exe "'+(Join-Path $PSScriptRoot 'Afterhours启动.vbs')+'"'
$legacyStartupCommand='wscript.exe "'+(Join-Path $PSScriptRoot 'Afterhours.vbs')+'"'
function Test-StartupEnabled {
 $value=(Get-ItemProperty -LiteralPath $startupRegistry -Name $startupName -ErrorAction SilentlyContinue).$startupName
 return $value -eq $startupCommand -or $value -eq $legacyStartupCommand
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
 if($root -is [Windows.Controls.Button]){$root.Foreground=$script:themeText;$root.BorderBrush=$script:glassBorder;if($root.Name -in @('StatsBack','StatsButton','SettingsButton','Play','Compact','CloseButton','CalendarScope','ClearFilter','PrevMonth','NextMonth')){$root.Background=$script:buttonBackground}}
 $count=[Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
 for($i=0;$i -lt $count;$i++){Set-ThemeText ([Windows.Media.VisualTreeHelper]::GetChild($root,$i))}
}
function Apply-Theme {
 # 主题色板：玻璃底色 / 选中控件 / 主图表色 / 次图表色 / 三级图表色 / 文字
 $themes=@{
  '极地雾'=@{Glass='#E8F2F8';Selected='#6B8FA7';Primary='#7FA6C1';Secondary='#B7CBD9';Tertiary='#D7E2EA';Text='#1F2933'}
  '极光薄荷'=@{Glass='#E6F5EE';Selected='#3F7F72';Primary='#6FB7A7';Secondary='#A7D4C5';Tertiary='#D9EFE6';Text='#1E2F2B'}
  '烟粉'=@{Glass='#F8EDEF';Selected='#B36B7A';Primary='#D58D9B';Secondary='#E6B7C1';Tertiary='#F4DDE2';Text='#3B2A2E'}
 }
 if(-not $themes.ContainsKey($preferences.Theme)){$preferences.Theme='极光薄荷'}
 $theme=$themes[$preferences.Theme];$script:isDark=[bool]$preferences.Dark
 if($script:isDark){
  # 深色底上：越亮 = 越多，最亮一档停在次色，避免出现近白方块
  $script:heatPalette=@('#22FFFFFF',('#8C'+$theme.Selected.Substring(1)),$theme.Selected,$theme.Primary,$theme.Secondary)
  $tone=@(('#3C'+$theme.Primary.Substring(1)),('#80'+$theme.Primary.Substring(1)),$theme.Tertiary);$script:gameTones=@($tone,$tone,$tone)
  $script:chartColors=@($theme.Secondary,$theme.Primary,$theme.Selected,('#8C'+$theme.Secondary.Substring(1)))
 }else{
  $script:heatPalette=@(('#3A'+$theme.Secondary.Substring(1)),$theme.Tertiary,$theme.Secondary,$theme.Primary,$theme.Selected)
  $tone=@($theme.Tertiary,$theme.Secondary,$theme.Selected);$script:gameTones=@($tone,$tone,$tone)
  $script:chartColors=@($theme.Selected,$theme.Primary,$theme.Secondary,$theme.Tertiary)
 }
 $script:barLight=$theme.Secondary;$script:barDark=$theme.Primary;$script:barDeep=$theme.Selected
 if($script:isDark){$tint='#1F2B3A';$script:themeText=[Windows.Media.BrushConverter]::new().ConvertFromString('#E8EEF6');$glass=New-ThemeGradient ('#DC'+$tint.Substring(1)) ('#D8'+$tint.Substring(1)) ('#D8243247');$panel='#2EFFFFFF';$script:glassBorder='#4AFFFFFF';$script:buttonBackground='#28FFFFFF'}
 else{$tint=$theme.Glass;$script:themeText=[Windows.Media.BrushConverter]::new().ConvertFromString($theme.Text);$glass=New-ThemeGradient '#DEFFFFFF' ('#D6'+$tint.Substring(1)) ('#D6'+$tint.Substring(1));$panel='#78FFFFFF';$script:glassBorder='#A8FFFFFF';$script:buttonBackground='#6EFFFFFF'}
 $script:cardBackground=$glass
 $ui.RootGlass.Background=$glass;$ui.RootGlass.BorderBrush=$script:glassBorder;$ui.RootGlass.BorderThickness=1
 $ui.HeatPanel.Background=$panel;$ui.HeatPanel.BorderBrush=$script:glassBorder
 $swatch=0;foreach($child in $ui.HeatLegend.Children){if($child -is [Windows.Controls.Border]){$child.Background=$script:heatPalette[$swatch];$swatch++}}
 $ui.StatsRangeBox.Background=if($script:isDark){'#26FFFFFF'}else{'#4AFFFFFF'}
 foreach($tile in @($ui.StatsTile1,$ui.StatsTile2,$ui.StatsTile3,$ui.StatsShareCard,$ui.StatsTimelineCard)){$tile.Background=$panel;$tile.BorderBrush=$script:glassBorder}
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
 try { Save-JsonAtomic @($records.Values) $recordsPath; Save-JsonAtomic @($sessions) $sessionsPath; $script:saveError='' }
 catch { $script:saveError='保存失败：' + $_.Exception.Message }
}
function Update-Session($snapshot,[double]$seconds){
 $rule=@($script:rules|Where-Object Process -eq $snapshot.Front|Select-Object -First 1)
 $valid=$snapshot.Readable -and $seconds -gt 0 -and $seconds -le 5 -and $rule.Count
 if($valid -and $script:currentSession -and $script:currentSession.Process -eq $snapshot.Front){$script:currentSession.End=$snapshot.Time.ToString('o');$script:currentSession.Seconds=[double]$script:currentSession.Seconds+$seconds;return}
 if($script:currentSession){$script:currentSession.End=$snapshot.Time.ToString('o');$script:currentSession=$null}
 if($valid){$item=[pscustomobject]@{Process=$snapshot.Front;Name=$rule[0].Name;Start=$snapshot.Time.AddSeconds(-$seconds).ToString('o');End=$snapshot.Time.ToString('o');Seconds=$seconds};[void]$sessions.Add($item);$script:currentSession=$item}
}
function Format-CompactDuration([double]$Seconds){
 if($Seconds -lt 60){return Format-Duration $Seconds}
 $value=[timespan]::FromSeconds($Seconds)
 if($value.TotalHours -ge 1){return ('{0}h {1:00}m' -f [math]::Floor($value.TotalHours),$value.Minutes)}
 return "$([math]::Floor($value.TotalMinutes))m"
}
function Render-State {
 $displayRecords=if($script:isDemo){$demoRecords}else{$records}
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
 if($ui.FullPanel.Visibility -eq 'Visible' -and -not $script:userResized){$window.Height=[math]::Min($script:expandedHeight,[Windows.SystemParameters]::WorkArea.Height-24)}
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
  $row.Background=if($script:isDark){'#20FFFFFF'}else{'#72FFFFFF'}
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
  $light=[Windows.Media.Color]::FromArgb($shade.A,[byte][math]::Min(255,$shade.R+15),[byte][math]::Min(255,$shade.G+15),[byte][math]::Min(255,$shade.B+15))
  $cell.Background=[Windows.Media.LinearGradientBrush]::new($light,$shade,90)
  $cell.BorderBrush=if($script:isDark){'#28FFFFFF'}else{'#72FFFFFF'};$cell.BorderThickness=0.5
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
 if($ui.StatsPanel.Visibility -eq 'Visible'){Render-Stats}
}
function New-VerticalGradient($topColor,$bottomColor){
 $brush=[Windows.Media.LinearGradientBrush]::new();$brush.StartPoint='0,0';$brush.EndPoint='0,1'
 [void]$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($topColor),0))
 [void]$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($bottomColor),1))
 return $brush
}
function Get-StatsSessions([datetime]$cutoff){
 $pool=if($script:isDemo){$demoSessions}else{$sessions}
 return @($pool|Where-Object{try{[datetime]$_.Start -ge $cutoff}catch{$false}})
}
function Add-RingSegment($canvas,[double]$start,[double]$sweep,$brush){
 if($sweep -le 0.2){return $null}
 $center=44.0;$radius=36.0;$end=$start+$sweep;$startRad=($start-90)*[math]::PI/180;$endRad=($end-90)*[math]::PI/180
 $figure=[Windows.Media.PathFigure]::new();$figure.StartPoint=[Windows.Point]::new($center+$radius*[math]::Cos($startRad),$center+$radius*[math]::Sin($startRad))
 $arc=[Windows.Media.ArcSegment]::new();$arc.Point=[Windows.Point]::new($center+$radius*[math]::Cos($endRad),$center+$radius*[math]::Sin($endRad));$arc.Size=[Windows.Size]::new($radius,$radius);$arc.IsLargeArc=$sweep -gt 180;$arc.SweepDirection='Clockwise';[void]$figure.Segments.Add($arc)
 $geometry=[Windows.Media.PathGeometry]::new();[void]$geometry.Figures.Add($figure);$path=[Windows.Shapes.Path]::new();$path.Data=$geometry;$path.Stroke=$brush;$path.StrokeThickness=14;[void]$canvas.Children.Add($path);return $path
}
function Set-StatsHighlight($index){
 foreach($segment in $script:statsSegments){$segment.Opacity=if($index -lt 0 -or [int]$segment.Tag -eq $index){1.0}else{0.3}}
 foreach($row in $ui.StatsGames.Children){if($row -is [Windows.Controls.Border]){$row.Background=if([int]$row.Tag -eq $index){$script:statsRowHover}else{'Transparent'}}}
}
function New-StatsGameRow($game,[double]$total,[int]$index){
 $share=if($total -gt 0){$game.Seconds/$total}else{0}
 $row=[Windows.Controls.Border]::new();$row.CornerRadius=8;$row.Padding='6,4';$row.Margin='-6,0';$row.Background='Transparent';$row.Tag=$index;$row.ToolTip=$game.Name+' · '+(Format-CompactDuration $game.Seconds)
 $grid=[Windows.Controls.Grid]::new();foreach($w in @('Auto','*','Auto','Auto')){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width=$w;$grid.ColumnDefinitions.Add($c)}
 $dot=[Windows.Controls.Border]::new();$dot.Width=9;$dot.Height=9;$dot.CornerRadius=4.5;$dot.Background=$game.ChartBrush;$dot.Margin='0,0,7,0';$dot.VerticalAlignment='Center';[void]$grid.Children.Add($dot)
 $name=[Windows.Controls.TextBlock]::new();$name.Text=$game.Name;$name.FontSize=12;$name.TextTrimming='CharacterEllipsis';$name.VerticalAlignment='Center';$name.Margin='0,0,6,0';[Windows.Controls.Grid]::SetColumn($name,1);[void]$grid.Children.Add($name)
 $value=[Windows.Controls.TextBlock]::new();$value.Text=Format-CompactDuration $game.Seconds;$value.FontSize=12;$value.FontWeight='SemiBold';$value.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($value,2);[void]$grid.Children.Add($value)
 $percent=[Windows.Controls.TextBlock]::new();$percent.Text=[math]::Round(100*$share).ToString()+'%';$percent.FontSize=10.5;$percent.Opacity=.55;$percent.Width=30;$percent.TextAlignment='Right';$percent.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($percent,3);[void]$grid.Children.Add($percent)
 $row.Child=$grid
 $row.Add_MouseEnter({param($sender,$eventArgs)Set-StatsHighlight ([int]$sender.Tag)});$row.Add_MouseLeave({param($sender,$eventArgs)Set-StatsHighlight -1})
 return $row
}
function Render-StatsDonut($items,[double]$total){
 $ui.StatsDonut.Children.Clear();$script:statsSegments=@()
 $track=[Windows.Shapes.Ellipse]::new();$track.Width=72;$track.Height=72;$track.Stroke=$script:statsTrack;$track.StrokeThickness=14;[Windows.Controls.Canvas]::SetLeft($track,8);[Windows.Controls.Canvas]::SetTop($track,8);[void]$ui.StatsDonut.Children.Add($track)
 $angle=0.0;$gap=if($items.Count -gt 1){2.0}else{0.0}
 for($i=0;$i -lt $items.Count;$i++){$sweep=if($total -gt 0){360*$items[$i].Seconds/$total}else{0};$segment=Add-RingSegment $ui.StatsDonut ($angle+$gap/2) ([math]::Max(.2,$sweep-$gap)) $items[$i].ChartBrush;if($segment){$segment.Tag=$i;$segment.ToolTip=$items[$i].Name+' · '+(Format-CompactDuration $items[$i].Seconds);$segment.Cursor='Hand';$segment.Add_MouseEnter({param($sender,$eventArgs)Set-StatsHighlight ([int]$sender.Tag)});$segment.Add_MouseLeave({param($sender,$eventArgs)Set-StatsHighlight -1});$script:statsSegments+=$segment};$angle+=$sweep}
 $centerValue=[Windows.Controls.TextBlock]::new();$centerValue.Text=Format-CompactDuration $total;$centerValue.TextAlignment='Center';$centerValue.FontSize=11.5;$centerValue.FontFamily='Segoe UI';$centerValue.FontWeight='SemiBold';$centerValue.Width=56;[Windows.Controls.Canvas]::SetLeft($centerValue,16);[Windows.Controls.Canvas]::SetTop($centerValue,30);[void]$ui.StatsDonut.Children.Add($centerValue)
 $centerLabel=[Windows.Controls.TextBlock]::new();$centerLabel.Text='总时长';$centerLabel.TextAlignment='Center';$centerLabel.FontSize=9;$centerLabel.Opacity=.6;$centerLabel.Width=56;[Windows.Controls.Canvas]::SetLeft($centerLabel,16);[Windows.Controls.Canvas]::SetTop($centerLabel,47);[void]$ui.StatsDonut.Children.Add($centerLabel)
}
function Render-StatsHours($rangeSessions){
 $ui.StatsHours.Children.Clear()
 $minutes=[double[]]::new(24)
 foreach($s in $rangeSessions){try{$cursor=[datetime]$s.Start;$end=[datetime]$s.End;if($end -le $cursor){continue};while($cursor -lt $end){$next=$cursor.Date.AddHours($cursor.Hour+1);if($next -gt $end){$next=$end};$minutes[$cursor.Hour]+=($next-$cursor).TotalMinutes;$cursor=$next}}catch{}}
 $sum=[double]($minutes|Measure-Object -Sum).Sum
 $width=[double]$ui.StatsHours.ActualWidth;if($width -lt 120){$width=[double]([math]::Max(240,$window.Width-34))}
 $top=24.0;$plotHeight=58.0;$baseY=$top+$plotHeight;$slot=$width/24;$barWidth=[math]::Max(5,[math]::Min(10,$slot*0.62))
 $max=[math]::Max(1,[double]($minutes|Measure-Object -Maximum).Maximum)
 $bestStart=-1;$bestSum=0;if($sum -gt 0){for($h=0;$h -le 21;$h++){$window3=$minutes[$h]+$minutes[$h+1]+$minutes[$h+2];if($window3 -gt $bestSum){$bestSum=$window3;$bestStart=$h}}}
 if($bestStart -ge 0){
  $band=[Windows.Controls.Border]::new();$band.Width=$slot*3;$band.Height=$plotHeight+$top-4;$band.CornerRadius=10;$band.Background=$script:statsTrack;[Windows.Controls.Canvas]::SetLeft($band,$slot*$bestStart);[Windows.Controls.Canvas]::SetTop($band,2);[void]$ui.StatsHours.Children.Add($band)
  $bandLabel=[Windows.Controls.TextBlock]::new();$bandLabel.Text=('{0:00}:00 – {1:00}:00' -f $bestStart,($bestStart+3));$bandLabel.FontSize=10;$bandLabel.FontWeight='SemiBold';$bandLabel.Opacity=.85;$bandLabel.Width=$slot*3+40;$bandLabel.TextAlignment='Center';$bandLeft=[math]::Max(0,[math]::Min($width-$bandLabel.Width,$slot*$bestStart-20));[Windows.Controls.Canvas]::SetLeft($bandLabel,$bandLeft);[Windows.Controls.Canvas]::SetTop($bandLabel,4);[void]$ui.StatsHours.Children.Add($bandLabel)
  $period=if($bestStart -ge 5 -and $bestStart -lt 11){'早上'}elseif($bestStart -lt 14){'中午'}elseif($bestStart -lt 18){'下午'}elseif($bestStart -lt 23){'晚上'}else{'深夜'}
  $ui.StatsHourHint.Text='你通常在'+$period+'玩得更多';$ui.StatsPlayWindow.Text=('常玩 {0:00}:00–{1:00}:00' -f $bestStart,($bestStart+3))
 }else{$ui.StatsHourHint.Text='还没有时段数据';$ui.StatsPlayWindow.Text=''}
 for($h=0;$h -lt 24;$h++){
  $value=$minutes[$h];$height=if($value -gt 0){[math]::Max(4,$plotHeight*$value/$max)}else{4};$x=$slot*$h+($slot-$barWidth)/2
  $bar=[Windows.Shapes.Rectangle]::new();$bar.Width=$barWidth;$bar.Height=$height;$bar.RadiusX=$barWidth/2;$bar.RadiusY=$barWidth/2
  $inBand=$bestStart -ge 0 -and $h -ge $bestStart -and $h -lt $bestStart+3
  $bar.Fill=if($value -le 0){$script:statsTrack}elseif($inBand){New-VerticalGradient $script:barDeep $script:barDark}else{New-VerticalGradient $script:barDark $script:barLight}
  if($value -gt 0 -and -not $inBand){$bar.Opacity=.75}
  [Windows.Controls.Canvas]::SetLeft($bar,$x);[Windows.Controls.Canvas]::SetTop($bar,$baseY-$height);$bar.ToolTip=('{0:00}:00 – {1:00}:00 · ' -f $h,($h+1))+(Format-CompactDuration ($value*60));[void]$ui.StatsHours.Children.Add($bar)
  if($h%3 -eq 0){$label=[Windows.Controls.TextBlock]::new();$label.Text=('{0:00}' -f $h);$label.FontSize=9.5;$label.Opacity=.6;$label.Width=$slot;$label.TextAlignment='Center';[Windows.Controls.Canvas]::SetLeft($label,$slot*$h);[Windows.Controls.Canvas]::SetTop($label,$baseY+5);[void]$ui.StatsHours.Children.Add($label)}
 }
 Set-ThemeText $ui.StatsHours
}
function Render-Stats {
 $source=if($script:isDemo){$demoRecords}else{$records};$allRows=@($source.Values);$cutoff=if($script:statsRange -eq 7){[datetime]::Today.AddDays(-6)}elseif($script:statsRange -eq 30){[datetime]::Today.AddDays(-29)}else{[datetime]::MinValue};$rows=@($allRows|Where-Object{try{[datetime]$_.Date -ge $cutoff}catch{$false}})
 $total=[double](($rows|Measure-Object Foreground -Sum).Sum);$days=@($rows|Where-Object Foreground -gt 0|Select-Object -ExpandProperty Date -Unique);$average=if($days.Count){$total/$days.Count}else{0}
 $script:statsTrack=if($script:isDark){'#24FFFFFF'}else{'#16303633'};$script:statsRowBackground='Transparent';$script:statsRowHover=if($script:isDark){'#26FFFFFF'}else{'#66FFFFFF'}
 $ui.StatsRangeLabel.Text=if($script:statsRange -eq 7){'最近 7 天'}elseif($script:statsRange -eq 30){'最近 30 天'}else{'全部记录'}
 $firstDate=if($script:statsRange -eq 0){$sortedDates=@($days|Sort-Object);if($sortedDates.Count){[datetime]$sortedDates[0]}else{[datetime]::Today}}else{$cutoff}
 $ui.StatsDateSpan.Text=$firstDate.ToString('M月d日')+' — '+[datetime]::Today.ToString('M月d日')
 $ui.StatsTotal.Text=Format-CompactDuration $total;$ui.StatsAverage.Text=Format-CompactDuration $average;$ui.StatsDays.Text=$days.Count.ToString()+' 天'
 foreach($button in @($ui.StatsRange7,$ui.StatsRange30,$ui.StatsRangeAll)){$active=($button -eq $ui.StatsRange7 -and $script:statsRange -eq 7)-or($button -eq $ui.StatsRange30 -and $script:statsRange -eq 30)-or($button -eq $ui.StatsRangeAll -and $script:statsRange -eq 0);$button.Background=if($active){$script:barDeep}else{'Transparent'};$button.FontWeight=if($active){'SemiBold'}else{'Normal'};$button.Tag=if($active){'active'}else{''}}
 $games=@($rows|Group-Object Name|ForEach-Object{[pscustomobject]@{Name=$_.Name;Seconds=[double](($_.Group|Measure-Object Foreground -Sum).Sum)}}|Where-Object Seconds -gt 0|Sort-Object Seconds -Descending)
 $ui.StatsGames.Children.Clear();$script:statsGameBrush=@{}
 for($gameIndex=0;$gameIndex -lt $games.Count;$gameIndex++){$game=$games[$gameIndex];$chartBrush=$script:chartColors[$gameIndex%$script:chartColors.Count];$game|Add-Member -NotePropertyName ChartBrush -NotePropertyValue $chartBrush -Force;$script:statsGameBrush[$game.Name]=$chartBrush}
 $items=@($games|Select-Object -First 4);$otherSeconds=[double](($games|Select-Object -Skip 4|Measure-Object Seconds -Sum).Sum)
 if($otherSeconds -gt 0){$otherBrush=if($script:isDark){'#5AFFFFFF'}else{'#4A303633'};$items+=[pscustomobject]@{Name='其他 '+($games.Count-4)+' 款';Seconds=$otherSeconds;ChartBrush=$otherBrush}}
 Render-StatsDonut $items $total
 for($i=0;$i -lt $items.Count;$i++){[void]$ui.StatsGames.Children.Add((New-StatsGameRow $items[$i] $total $i))}
 $ui.StatsShareHint.Text=if($games.Count){'共 '+$games.Count+' 款 · 悬停查看'}else{''}
 if(-not $games.Count){$empty=[Windows.Controls.TextBlock]::new();$empty.Text='这段时间还没有游戏记录';$empty.Opacity=.6;$empty.FontSize=12;$empty.TextWrapping='Wrap';[void]$ui.StatsGames.Children.Add($empty)}
 $rangeSessions=Get-StatsSessions $cutoff
 Render-StatsHours $rangeSessions
 $ui.StatsTimeline.Children.Clear();$latest=@($rangeSessions|Sort-Object{[datetime]$_.Start}-Descending|Select-Object -First 3);$divider=if($script:isDark){'#1EFFFFFF'}else{'#1E303633'}
 for($i=0;$i -lt $latest.Count;$i++){$s=$latest[$i];try{$start=[datetime]$s.Start;$end=[datetime]$s.End
  if($i -gt 0){$line=[Windows.Controls.Border]::new();$line.Height=1;$line.Background=$divider;[void]$ui.StatsTimeline.Children.Add($line)}
  $row=[Windows.Controls.Grid]::new();$row.Margin='0,9';foreach($w in @('Auto','*','Auto')){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width=$w;$row.ColumnDefinitions.Add($c)}
  $accent=[Windows.Controls.Border]::new();$accent.Width=5;$accent.Height=30;$accent.CornerRadius=2.5;$accent.Margin='0,0,12,0';$accent.VerticalAlignment='Center';$accent.Background=if($script:statsGameBrush.ContainsKey($s.Name)){$script:statsGameBrush[$s.Name]}else{$script:barDark};[void]$row.Children.Add($accent)
  $left=[Windows.Controls.StackPanel]::new();$left.VerticalAlignment='Center';$name=[Windows.Controls.TextBlock]::new();$name.Text=$s.Name;$name.FontSize=13;$name.FontWeight='SemiBold';$name.TextTrimming='CharacterEllipsis';$dateLabel=if($start.Date -eq [datetime]::Today){'今天'}elseif($start.Date -eq [datetime]::Today.AddDays(-1)){'昨天'}else{$start.ToString('M月d日')};$time=[Windows.Controls.TextBlock]::new();$time.Text=$dateLabel+' '+$start.ToString('HH:mm')+' – '+$end.ToString('HH:mm');$time.FontSize=11;$time.Opacity=.62;$time.Margin='0,2,0,0';[void]$left.Children.Add($name);[void]$left.Children.Add($time);[Windows.Controls.Grid]::SetColumn($left,1);[void]$row.Children.Add($left)
  $duration=[Windows.Controls.TextBlock]::new();$duration.Text=Format-CompactDuration ([double]$s.Seconds);$duration.FontSize=14;$duration.FontFamily='Segoe UI';$duration.FontWeight='SemiBold';$duration.VerticalAlignment='Center';$duration.Margin='10,0,0,0';[Windows.Controls.Grid]::SetColumn($duration,2);[void]$row.Children.Add($duration)
  [void]$ui.StatsTimeline.Children.Add($row)}catch{}}
 if(-not $ui.StatsTimeline.Children.Count){$empty=[Windows.Controls.TextBlock]::new();$empty.Text='还没有会话记录 · 2.0 起会记录每次游戏的起止时间';$empty.Opacity=.6;$empty.FontSize=12;$empty.Margin='0,8';[void]$ui.StatsTimeline.Children.Add($empty)}
 Set-ThemeText $ui.StatsPanel;Set-ThemeText $ui.StatsHeaderActions
 foreach($button in @($ui.StatsRange7,$ui.StatsRange30,$ui.StatsRangeAll)){if($button.Tag -eq 'active'){$button.Foreground='#FFFFFFFF'}}
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
   $newRule=[pscustomobject]@{Name=$nameBox.Text.Trim(); Process=$processName}
   $script:manualRules=@($script:manualRules|Where-Object Process -ne $processName)+@($newRule)
   $script:rules=@($builtInRules)+@($script:manualRules)+@($steamRules)
   Save-JsonAtomic @($script:manualRules) $configPath
   $picker.Close()
  }
 })
 [void]$panel.Children.Add($add); $picker.Content=$panel
 [void]$picker.ShowDialog()
}
$script:manualRules=@($manualRules)
function Manage-Games {
 $picker=[Windows.Window]::new();$picker.Title='管理手动添加的游戏';$picker.Width=420;$picker.Height=420;$picker.Owner=$window;$picker.WindowStartupLocation='CenterOwner';$picker.Background='#EDF5FA'
 $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=20;$hint=[Windows.Controls.TextBlock]::new();$hint.Text='这里只显示手动添加的规则；内置与 Steam 自动规则不会被删除。';$hint.TextWrapping='Wrap';$hint.Margin='0,0,0,12';[void]$panel.Children.Add($hint)
 $list=[Windows.Controls.ListBox]::new();$list.Height=260;foreach($r in $script:manualRules){[void]$list.Items.Add("$($r.Name)  ·  $($r.Process)")};[void]$panel.Children.Add($list)
 $delete=[Windows.Controls.Button]::new();$delete.Content='删除选中规则';$delete.Margin='0,12,0,0';$delete.Add_Click({if($list.SelectedIndex -ge 0){$script:manualRules=@($script:manualRules|Where-Object Process -ne $script:manualRules[$list.SelectedIndex].Process);$script:rules=@($builtInRules)+@($script:manualRules)+@($steamRules);Save-JsonAtomic @($script:manualRules) $configPath;$picker.Close();Render-State}});[void]$panel.Children.Add($delete);$picker.Content=$panel;[void]$picker.ShowDialog()
}
$ui.DragHandle.Add_MouseLeftButtonDown({ $window.DragMove() })
$ui.PrevMonth.Add_Click({$script:month=$script:month.AddDays(-56);Render-State})
$ui.ClearFilter.Add_Click({$script:selectedGame='';Render-State})
function New-SettingsMenu {
 $menu=[Windows.Controls.ContextMenu]::new();$menu.Style=$window.FindResource('GameMenuStyle');$menu.Placement='Bottom';$menu.VerticalOffset=5
 $menu.Add_Loaded({param($sender,$eventArgs)$source=[Windows.Interop.HwndSource]::FromVisual($sender);if($source){[DesktopLayer]::BlurPopup($source.Handle)}})
 foreach($theme in @('极地雾','极光薄荷','烟粉')){
  $item=[Windows.Controls.MenuItem]::new();$item.Header='主题 · '+$theme;$item.Tag='theme|'+$theme;$item.IsCheckable=$true;$item.IsChecked=$preferences.Theme -eq $theme;$item.Style=$window.FindResource('GameMenuItemStyle')
  $item.Add_Click({param($sender,$eventArgs)$preferences.Theme=([string]$sender.Tag).Split('|')[1];Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($item)
 }
 $dark=[Windows.Controls.MenuItem]::new();$dark.Header='深色模式';$dark.IsCheckable=$true;$dark.IsChecked=$preferences.Dark;$dark.Style=$window.FindResource('GameMenuItemStyle')
 $dark.Add_Click({$preferences.Dark=-not $preferences.Dark;Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($dark)
 $demo=[Windows.Controls.MenuItem]::new();$demo.Header=if($script:isDemo){'返回实测'}else{'查看演示数据'};$demo.IsCheckable=$true;$demo.IsChecked=$script:isDemo;$demo.Style=$window.FindResource('GameMenuItemStyle');$demo.Add_Click({$script:isDemo=-not $script:isDemo;$script:selectedGame='';$script:heatKey='';Render-State});[void]$menu.Items.Add($demo)
 $manage=[Windows.Controls.MenuItem]::new();$manage.Header='管理手动游戏';$manage.Style=$window.FindResource('GameMenuItemStyle');$manage.Add_Click({Manage-Games});[void]$menu.Items.Add($manage)
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
$ui.StatsButton.Add_Click({$script:preStatsHeight=$window.Height;$ui.FullPanel.Visibility='Collapsed';$ui.MiniPanel.Visibility='Collapsed';$ui.HeaderActions.Visibility='Collapsed';$ui.StatsHeaderActions.Visibility='Visible';$ui.TopHeader.Margin='0,0,0,18';$ui.StatsPanel.Visibility='Visible';if(-not $script:userResized){$window.Height=[math]::Min(750,[Windows.SystemParameters]::WorkArea.Height-24)};Render-Stats;if(-not $Preview){$ui.StatsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty,[Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([timespan]::FromMilliseconds(220))))}})
$ui.StatsBack.Add_Click({$ui.StatsPanel.Visibility='Collapsed';$ui.FullPanel.Visibility='Visible';$ui.HeaderActions.Visibility='Visible';$ui.StatsHeaderActions.Visibility='Collapsed';$ui.TopHeader.Margin='0,0,0,16';$ui.Compact.Visibility='Visible';if(-not $script:userResized -and $script:preStatsHeight){$window.Height=$script:preStatsHeight};Render-State})
$ui.StatsHours.Add_SizeChanged({param($sender,$eventArgs)if($ui.StatsPanel.Visibility -eq 'Visible' -and $eventArgs.WidthChanged){Render-Stats}})
$ui.StatsRange7.Add_Click({$script:statsRange=7;Render-Stats})
$ui.StatsRange30.Add_Click({$script:statsRange=30;Render-Stats})
$ui.StatsRangeAll.Add_Click({$script:statsRange=0;Render-Stats})
$ui.ResizeGrip.Add_MouseLeftButtonDown({$script:userResized=$true;if($script:desktop){$script:desktop.BeginResize()}})
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
  Update-Session $next ($tick-$script:lastTick)
  $script:last=$next; $script:lastTick=$tick
  if($tick-$script:lastSaved -ge 5){Save-Activity; $script:lastSaved=$tick}
  $signature=$script:last.Front+'|'+$script:last.Readable+'|'+($records.Values | ForEach-Object { [math]::Floor($_.Foreground).ToString()+','+[math]::Floor($_.Running).ToString() })+'|'+$script:saveError
  if($signature -ne $script:lastRenderSignature -and (-not $script:desktop -or -not $script:desktop.IsCovered())){Render-State;$script:lastRenderSignature=$signature}
  if($ProbeSeconds -gt 0 -and $tick -ge $ProbeSeconds){$window.Close()}
 } catch { $ui.Health.Text='采集错误：'+$_.Exception.Message; $script:last=Read-Snapshot $script:rules; $script:lastTick=$clock.Elapsed.TotalSeconds }
})
$script:tray=$null
if(-not $Preview){
 $script:tray=[Windows.Forms.NotifyIcon]::new();$iconPath=Join-Path $PSScriptRoot 'Afterhours.ico';if(Test-Path -LiteralPath $iconPath){$script:trayIcon=[Drawing.Icon]::new($iconPath);$script:tray.Icon=$script:trayIcon}else{$script:tray.Icon=[Drawing.SystemIcons]::Application};$script:tray.Text='Afterhours 2.0.1 · 游戏时间';$script:tray.Visible=$true
 $trayMenu=[Windows.Forms.ContextMenuStrip]::new();[void]$trayMenu.Items.Add('显示 / 隐藏看板');[void]$trayMenu.Items.Add('退出 Afterhours')
 $trayMenu.Items[0].Add_Click({if($window.Visibility -eq 'Visible'){$window.Hide()}else{$window.Show();$window.UpdateLayout();if($script:desktop){$script:desktop.Lower()}}})
 $trayMenu.Items[1].Add_Click({$window.Close()});$script:tray.ContextMenuStrip=$trayMenu;$script:tray.Add_DoubleClick({if($window.Visibility -ne 'Visible'){$window.Show()};if($script:desktop){$script:desktop.Lower()}})
}
$window.Add_Closed({$timer.Stop();if($script:currentSession){$script:currentSession.End=[datetime]::Now.ToString('o')};Save-Activity;if($script:tray){$script:tray.Visible=$false;$script:tray.Dispose()};if($script:trayIcon){$script:trayIcon.Dispose()}})
Apply-Theme
Render-State
if($Preview){
 $window.Show(); $window.UpdateLayout()
 Render-State
 if($VerifyUI){
  $realBefore=ConvertTo-Json -InputObject @($records.Values) -Depth 6
  $modeBefore=$script:isDemo
  $script:isDemo=-not $script:isDemo;Render-State;$script:isDemo=-not $script:isDemo;Render-State
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
  if($settings.Items.Count -ne 7){throw 'Settings menu item count failed'}
  $settings.Items[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  if($preferences.Theme -ne '烟粉'){throw 'Theme selection failed'}
  $preferences.Dark=$false;$settings=New-SettingsMenu;$settings.Items[3].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  if(-not $preferences.Dark){throw 'Dark mode failed'}
  $preferences.Dark=$false;Apply-Theme;$ui.StatsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));if($ui.StatsPanel.Visibility -ne 'Visible' -or -not $ui.StatsTotal.Text){throw 'Stats page failed'};$ui.StatsRange30.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));if($script:statsRange -ne 30){throw 'Stats 30-day range failed'};$ui.StatsRangeAll.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));if($script:statsRange -ne 0){throw 'Stats all range failed'};$ui.StatsRange7.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));if($script:statsRange -ne 7){throw 'Stats 7-day range failed'};$window.UpdateLayout();$statsBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Width,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$statsBitmap.Render($window);$statsEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$statsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($statsBitmap));$statsStream=[IO.File]::Create((Join-Path $PSScriptRoot 'stats-preview.png'));$statsEncoder.Save($statsStream);$statsStream.Dispose();$ui.StatsBack.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  $preferences.Dark=$true;Apply-Theme;Render-State;$window.UpdateLayout();[void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  $darkBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(400,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$darkBitmap.Render($window)
  $darkEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$darkEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($darkBitmap))
  $darkStream=[IO.File]::Create((Join-Path $PSScriptRoot 'dark-preview.png'));$darkEncoder.Save($darkStream);$darkStream.Dispose()
  $ui.StatsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$window.UpdateLayout();[void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);$darkStatsBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Width,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$darkStatsBitmap.Render($window);$darkStatsEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$darkStatsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($darkStatsBitmap));$darkStatsStream=[IO.File]::Create((Join-Path $PSScriptRoot 'stats-dark-preview.png'));$darkStatsEncoder.Save($darkStatsStream);$darkStatsStream.Dispose();$ui.StatsBack.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  $preferences.Theme=$savedTheme;$preferences.Dark=$savedDark;Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State
  Write-Output 'UI_PASS: themes, dark mode, settings menu, stats page, square cells, game filter, history, hover, daily tooltip, demo isolation'
 }
 if($Screenshots){
  [void][IO.Directory]::CreateDirectory($Screenshots)
  function Save-Shot([string]$name){$window.UpdateLayout();[void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);$shot=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Width,[int]$window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$shot.Render($window);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($shot));$fs=[IO.File]::Create((Join-Path $Screenshots ($name+'.png')));$enc.Save($fs);$fs.Dispose()}
  $savedTheme=$preferences.Theme;$savedDark=$preferences.Dark
  foreach($shotTheme in @('极光薄荷','极地雾','烟粉')){foreach($shotDark in @($false,$true)){
   $preferences.Theme=$shotTheme;$preferences.Dark=$shotDark;Apply-Theme;$window.Height=$script:expandedHeight;Render-State
   $mode=if($shotDark){'dark'}else{'light'}
   Save-Shot ($shotTheme+'-'+$mode+'-home')
   $ui.StatsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Save-Shot ($shotTheme+'-'+$mode+'-stats')
   $ui.StatsBack.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  }}
  $preferences.Theme='极光薄荷';$preferences.Dark=$false;Apply-Theme;Render-State
  $ui.Compact.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Save-Shot 'mini';$ui.Compact.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  $preferences.Theme=$savedTheme;$preferences.Dark=$savedDark;Apply-Theme;Render-State
  Write-Output ('SHOTS_OK '+$Screenshots)
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
