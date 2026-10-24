param([switch]$Preview, [switch]$DemoMode, [switch]$VerifyUI, [string]$Screenshots='', [int]$ProbeSeconds=0, [string]$DataDirectory='')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopLayer.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Interop.HwndSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
. (Join-Path $PSScriptRoot 'Tracker.ps1')
. (Join-Path $PSScriptRoot 'Migration.ps1')
. (Join-Path $PSScriptRoot 'Demo.ps1')
. (Join-Path $PSScriptRoot 'DayCard.ps1')
$script:isDemo=[bool]$DemoMode
$script:demoRecords=$null
$script:demoSessions=$null
function Initialize-DemoData {
 if($null -eq $script:demoRecords){
  $history=New-DemoHistory
  $historySessions=New-DemoSessions $history
  $script:demoRecords=$history
  $script:demoSessions=$historySessions
 }
}
if (!$DataDirectory) { $DataDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'data' }
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
# 2.1 data safety: an unreadable file is never replaced with empty data.
# blockSave[<file>] stays $true until a migration rewrites that file successfully.
$script:blockSave=@{games=$false;activity=$false;sessions=$false}
$script:dataNotes=[Collections.ArrayList]::new()
$script:recovered=@{games=$false;activity=$false;sessions=$false}
function Use-SafeLoad([string]$Path,[string]$Key){
 $result=Read-JsonArraySafe $Path
 if($result.Note){[void]$script:dataNotes.Add($result.Note)}
 if(-not $result.Ok){$script:blockSave[$Key]=$true}elseif($result.Note){$script:recovered[$Key]=$true}
 return $result.Rows
}
$manualRules=@()
if (Test-Path -LiteralPath $configPath) { $loaded=@(Use-SafeLoad $configPath 'games');$manualRules=@($loaded|Where-Object{$_.Process -and $_.Process -notlike 'steam-*' -and $_.Process -notin $builtInRules.Process}) }
else { Save-JsonAtomic @() $configPath }
$steamRules=@(Get-SteamRules | Sort-Object Process -Unique)
$script:rules=@($builtInRules)+@($manualRules)+@($steamRules)
foreach($rule in $script:rules){$rule.Name=$rule.Name -replace '^剑网\s*3$','剑网三'}
$records = @{}
foreach ($row in @(Use-SafeLoad $recordsPath 'activity')) { if ($null -ne $row -and $row.Process) { $row.Name=$row.Name -replace '^剑网\s*3$','剑网三'; $records["$($row.Date)|$($row.Process)"] = $row } }
$rawSessions=@(Use-SafeLoad $sessionsPath 'sessions')
$sessions=Merge-Sessions $rawSessions 120
# A file restored from .bak is rewritten on the first save so the broken copy is replaced.
$script:activityDirty=$script:recovered.activity
$script:sessionsDirty=($sessions.Count -ne $rawSessions.Count) -or $script:recovered.sessions
if($script:recovered.games){try{Save-JsonAtomic @($manualRules) $configPath}catch{}}
Remove-Variable rawSessions;[GC]::Collect()  # the unmerged list is only needed for the comparison above
$script:currentSession=$null
$backupRoot=Join-Path $DataDirectory 'backups'
function Save-DailyBackup {
 # 2.1: once per day keep a copy of the three data files; the newest 7 days are kept.
 try{
  $folder=Join-Path $backupRoot ([datetime]::Today.ToString('yyyy-MM-dd'))
  if([IO.Directory]::Exists($folder)){return}
  [void][IO.Directory]::CreateDirectory($folder)
  foreach($file in @('activity.json','sessions.json','games.json')){
   $path=Join-Path $DataDirectory $file
   if(-not [IO.File]::Exists($path)){continue}
   try{$null=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop}catch{continue}  # never back up a broken file
   [IO.File]::Copy($path,(Join-Path $folder $file),$true)
  }
  @(Get-ChildItem -LiteralPath $backupRoot -Directory|Sort-Object Name -Descending|Select-Object -Skip 7)|ForEach-Object{Remove-Item -LiteralPath $_.FullName -Recurse -Force}
 }catch{}
}
Save-DailyBackup
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'Silver.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
$ui['GameScroll']=$window.FindName('GameScroll')
$ui['SettingsButton']=$window.FindName('SettingsButton')
$ui['RootGlass']=$window.FindName('RootGlass')
$ui['HeatPanel']=$window.FindName('HeatPanel')
'MiniDrag','MiniExpand','MiniClose','MiniDot','MiniStatus','MiniActions','MainScroll','MainContent','DragHandle','TopHeader','HeaderActions','Subtitle','Compact','CloseButton','FullPanel','MiniPanel','StatsPanel','StatsButton','StatsBack','StatsTotal','StatsGames','StatsTimeline','StatsPlayWindow','StatsRangeLabel','StatsRange7','StatsRange30','StatsRangeAll','StatsRangeBox','StatsHeaderActions','StatsShareHint','StatsDateSpan','StatsAverage','StatsDays','StatsHours','StatsHourHint','StatsTile1','StatsTile2','StatsTile3','StatsDonut','StatsShareCard','StatsTimelineCard','ResizeGrip','Heatmap','Play','Total','Session','MiniTime','Runtime','CurrentGame','DateRange','Ranking','WeekTotal','Health','GameCount','PrevMonth','NextMonth','MonthLabel','CalendarScope','ClearFilter','HeatLegend' | ForEach-Object { $ui[$_]=$window.FindName($_) }
$window.Height=[math]::Min(610,[Windows.SystemParameters]::WorkArea.Height-24)
$window.Left=[Windows.SystemParameters]::WorkArea.Right-$window.Width-20
$window.Top=[Windows.SystemParameters]::WorkArea.Top+12
$script:month=[datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))
$script:anchorMonday=$script:month
$script:lastStatsRender=-100.0
$script:heatKey=''
$script:rankKey=''
$script:rankControls=@{}
$script:selectedGame=''
$script:statsRange=7
$script:desktop=$null
$script:lastRenderSignature=''
$script:userResized=$false
$script:isCompact=$false
$script:expandedSize=[pscustomobject]@{Width=$window.Width;Height=$window.Height}
$startupRegistry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupName='AfterhoursGameTime'
$startupCommand='wscript.exe "'+(Join-Path (Split-Path $PSScriptRoot -Parent) 'Afterhours启动.vbs')+'"'
$legacyStartupCommand='wscript.exe "'+(Join-Path (Split-Path $PSScriptRoot -Parent) 'Afterhours.vbs')+'"'
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
 if($root -is [Windows.Controls.TextBlock] -and $root.Name -notin @('Name','Game','MiniStatus')){$root.Foreground=$script:themeText}
 if($root -is [Windows.Controls.Button]){$root.Foreground=$script:themeText;$root.BorderBrush=$script:glassBorder;if($root.Name -in @('StatsBack','StatsButton','SettingsButton','Play','Compact','CloseButton','CalendarScope','ClearFilter','PrevMonth','NextMonth')){$root.Background=$script:buttonBackground}}
 $count=[Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
 for($i=0;$i -lt $count;$i++){Set-ThemeText ([Windows.Media.VisualTreeHelper]::GetChild($root,$i))}
}
function Update-ContentScale {
 if(-not $ui.MainContent -or -not $ui.MainScroll){return}
 if($script:isCompact){
  $ui.MainContent.LayoutTransform=[Windows.Media.ScaleTransform]::new(1,1)
  $ui.MainContent.Width=[double]::NaN
  return
 }
 $width=if($window.ActualWidth -gt 0){$window.ActualWidth}else{$window.Width}
 $height=if($window.ActualHeight -gt 0){$window.ActualHeight}else{$window.Height}
 $scale=[math]::Max(0.78,[math]::Min(1.40,[math]::Min($width/370.0,$height/610.0)))
 $ui.MainContent.LayoutTransform=[Windows.Media.ScaleTransform]::new($scale,$scale)
 if($ui.MainScroll.ViewportWidth -gt 0){$ui.MainContent.Width=[math]::Max(260,$ui.MainScroll.ViewportWidth/$scale)}
}
function Apply-Theme {
 # 主题色板：玻璃底色 / 选中控件 / 主图表色 / 次图表色 / 三级图表色 / 文字
 $themes=@{
  '极地雾'=@{Glass='#E8F2F8';Selected='#6B8FA7';Primary='#7FA6C1';Secondary='#B7CBD9';Tertiary='#D7E2EA';Text='#1F2933'}
  '极光薄荷'=@{Glass='#E6F5EE';Selected='#3F7F72';Primary='#6FB7A7';Secondary='#A7D4C5';Tertiary='#D9EFE6';Text='#1E2F2B'}
  '烟粉'=@{Glass='#F8EDEF';Selected='#B36B7A';Primary='#D58D9B';Secondary='#E6B7C1';Tertiary='#F4DDE2';Text='#3B2A2E'}
  '暮光紫'=@{Glass='#F1ECF5';Selected='#796982';Primary='#9E8BA7';Secondary='#BDAFC2';Tertiary='#E8E4EA';Text='#302A34'}
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
 # 2.1: DesktopLayer raises SaveRequested on logoff/shutdown and before sleep.
 $script:desktop.add_SaveRequested({try{Save-Activity -Force}catch{}})
 Save-JsonAtomic ([pscustomobject]@{Pid=$PID;Handle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle.ToInt64();BlurEnabled=$script:desktop.BlurEnabled;Mode='Desktop';Started=[datetime]::Now.ToString('o')}) (Join-Path $DataDirectory 'runtime.json')
})}
if(-not $Preview){$window.Add_ContentRendered({$script:desktop.Lower();$global:AfterhoursStarted=$true;Keep-OnScreen})}
# 2.1: an exception in any UI handler used to end the whole process without saving
# (one plausible cause of "游戏闪退后看板也一起退出"). Log it, save, keep running.
$window.Dispatcher.Add_UnhandledException({param($sender,$eventArgs)
 Write-RuntimeLog $eventArgs.Exception
 $script:runtimeWarning='界面出现错误，已记录到 data/runtime-error.log，计时继续。'
 try{Save-Activity -Force}catch{}
 $eventArgs.Handled=$true
})
$script:last = Read-Snapshot $script:rules
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:lastTick = $clock.Elapsed.TotalSeconds
$script:lastActivitySave = 0.0
$script:lastSessionsSave = 0.0
$script:saveError = ''
$script:runtimeWarning = ''
# 2.1: save only when something changed: activity every 30 s, sessions every 60 s
# (sessions.json is ~1 MB; 2.0.3 rewrote both files every 5 s even when idle).
# -Force is used on exit, lock, sleep, shutdown and before migration.
function Save-Activity([switch]$Force){
 $now=$clock.Elapsed.TotalSeconds
 try {
  if($script:activityDirty -and -not $script:blockSave.activity -and ($Force -or $now-$script:lastActivitySave -ge 30)){Save-JsonAtomic @($records.Values) $recordsPath;$script:activityDirty=$false;$script:lastActivitySave=$now}
  if($script:sessionsDirty -and -not $script:blockSave.sessions -and ($Force -or $now-$script:lastSessionsSave -ge 60)){Save-JsonAtomic @($sessions) $sessionsPath;$script:sessionsDirty=$false;$script:lastSessionsSave=$now}
  $script:saveError=''
 }
 catch { $script:saveError='保存失败：' + $_.Exception.Message }
}
function Write-RuntimeLog($ErrorRecord){
 # 2.1: errors after startup go to runtime-error.log (startup-error.log is only for launch failures).
 try{[IO.File]::AppendAllText((Join-Path $DataDirectory 'runtime-error.log'),("[{0}] {1}`r`n" -f [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'),($ErrorRecord|Out-String)),[Text.UTF8Encoding]::new($false))}catch{}
}
function Save-Games {
 if($script:blockSave.games){[void][Windows.MessageBox]::Show('games.json 无法读取，为保护原文件，本次修改不会保存。请先检查 data 文件夹。','Afterhours');return}
 Save-JsonAtomic @($script:manualRules) $configPath
}
function Update-Session($snapshot,[double]$seconds){
 # 2.1: an invalid second (alt-tab, lock, unreadable foreground) no longer ends the
 # session; End simply stays at the last counted second. If the same game is back
 # in front within 120 s, the session continues, also across a restart.
 if(-not [object]::ReferenceEquals($script:rules,$script:ruleLookupSource)){
  $script:ruleLookupSource=$script:rules;$script:ruleLookup=@{}
  foreach($r in $script:rules){$k=$r.Process.ToLowerInvariant();if(-not $script:ruleLookup.ContainsKey($k)){$script:ruleLookup[$k]=$r}}
 }
 $rule=@($script:ruleLookup[$snapshot.Front]|Where-Object{$_})
 if(-not ($snapshot.Readable -and $seconds -gt 0 -and $seconds -le 5 -and $rule.Count)){return}
 $current=$script:currentSession
 if(-not $current -and $sessions.Count){$current=$sessions[$sessions.Count-1]}
 $gap=if($current){try{($snapshot.Time-[datetime]$current.End).TotalSeconds}catch{[double]::MaxValue}}else{[double]::MaxValue}
 if($current -and $current.Process -eq $snapshot.Front -and $gap -le 120){
  $current.End=$snapshot.Time.ToString('o');$current.Seconds=[double]$current.Seconds+$seconds;$script:currentSession=$current
 }else{
  $item=[pscustomobject]@{Process=$snapshot.Front;Name=$rule[0].Name;Start=$snapshot.Time.AddSeconds(-$seconds).ToString('o');End=$snapshot.Time.ToString('o');Seconds=$seconds};[void]$sessions.Add($item);$script:currentSession=$item
 }
 $script:sessionsDirty=$true
}
function Get-WorkAreaDip {
 # Work area of the monitor that holds the window, in WPF units (DPI aware).
 $handle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle
 $screen=if($handle -ne [IntPtr]::Zero){[Windows.Forms.Screen]::FromHandle($handle)}else{[Windows.Forms.Screen]::PrimaryScreen}
 $area=$screen.WorkingArea
 $source=[Windows.PresentationSource]::FromVisual($window)
 $matrix=if($source -and $source.CompositionTarget){$source.CompositionTarget.TransformFromDevice}else{[Windows.Media.Matrix]::Identity}
 $topLeft=$matrix.Transform([Windows.Point]::new($area.Left,$area.Top));$bottomRight=$matrix.Transform([Windows.Point]::new($area.Right,$area.Bottom))
 return [Windows.Rect]::new($topLeft,$bottomRight)
}
function Keep-OnScreen {
 # 2.1: keep the whole window inside the current monitor's work area.
 try{
  $area=Get-WorkAreaDip
  $width=if($window.ActualWidth -gt 0){$window.ActualWidth}else{$window.Width}
  $height=if($window.ActualHeight -gt 0){$window.ActualHeight}else{$window.Height}
  $window.Left=[math]::Max($area.Left,[math]::Min($window.Left,$area.Right-$width))
  $window.Top=[math]::Max($area.Top,[math]::Min($window.Top,$area.Bottom-$height))
 }catch{}
}
function Resize-Anchored([double]$NewWidth,[double]$NewHeight){
 # 2.1: grow/shrink toward the screen centre: a window in the right half keeps its
 # right edge, one in the lower half keeps its bottom edge. Then clamp to screen.
 $area=Get-WorkAreaDip
 $oldWidth=if($window.ActualWidth -gt 0){$window.ActualWidth}else{$window.Width}
 $oldHeight=if($window.ActualHeight -gt 0){$window.ActualHeight}else{$window.Height}
 $right=$window.Left+$oldWidth;$bottom=$window.Top+$oldHeight
 $keepRight=($window.Left+$oldWidth/2) -gt ($area.Left+$area.Width/2)
 $keepBottom=($window.Top+$oldHeight/2) -gt ($area.Top+$area.Height/2)
 $window.Width=$NewWidth;$window.Height=$NewHeight
 if($keepRight){$window.Left=$right-$NewWidth}
 if($keepBottom){$window.Top=$bottom-$NewHeight}
 $window.UpdateLayout()
 Keep-OnScreen
}
function Update-MiniStatus {
 # 2.1 mini bar: dot = theme colour while counting in front, light while only running
 # in background, grey when idle or paused; second line names the game and this session.
 $brushes=[Windows.Media.BrushConverter]::new()
 $frontRule=$null;$backRule=$null
 foreach($r in $script:rules){
  if(-not $frontRule -and $r.Process -eq $script:last.Front){$frontRule=$r}
  elseif(-not $backRule -and $script:last.Names.ContainsKey($r.Process)){$backRule=$r}
 }
 if($script:isDemo){$text='演示模式 · 示例数据';$dot=$script:barDark}
 elseif(-not $script:last.Readable -and -not $Preview){$text='已暂停 · 锁屏或桌面不可读';$dot=$null}
 elseif($frontRule){
  $session=$script:currentSession
  $text=if($session -and $session.Process -eq $frontRule.Process){$frontRule.Name+' · 本次 '+(Format-CompactDuration ([double]$session.Seconds))}else{$frontRule.Name+' · 计时中'}
  $dot=$script:barDeep
 }
 elseif($backRule){$text=$backRule.Name+' · 后台运行';$dot=$script:barLight}
 else{$text='等待游戏';$dot=$null}
 $ui.MiniStatus.Text=$text
 $ui.MiniStatus.Foreground=if($script:isDark){$brushes.ConvertFromString([string]$script:barLight)}else{$brushes.ConvertFromString([string]$script:barDeep)}
 $ui.MiniStatus.Opacity=if($dot){1.0}else{0.7}
 $ui.MiniDot.Fill=if($dot){$brushes.ConvertFromString([string]$dot)}else{$brushes.ConvertFromString($(if($script:isDark){'#59FFFFFF'}else{'#47303633'}))}
}
function Format-CompactDuration([double]$Seconds){
 if($Seconds -lt 60){return Format-Duration $Seconds}
 $value=[timespan]::FromSeconds($Seconds)
 if($value.TotalHours -ge 1){return ('{0}h {1:00}m' -f [math]::Floor($value.TotalHours),$value.Minutes)}
 return "$([math]::Floor($value.TotalMinutes))m"
}
function Render-State {
 # 2.1: when a new week starts while the app keeps running, move the heatmap page
 # along if the user was looking at the current page.
 $currentMonday=[datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7))
 if($script:anchorMonday -ne $currentMonday){if($script:month -eq $script:anchorMonday){$script:month=$currentMonday};$script:anchorMonday=$currentMonday;$script:heatKey=''}
 if($script:isDemo){Initialize-DemoData}
 $displayRecords=if($script:isDemo){$demoRecords}else{$records}
 $ui.CalendarScope.Content=if($script:selectedGame){$script:selectedGame+' ▾'}else{'全部游戏 ▾'}
 $ui.ClearFilter.Visibility=if($script:selectedGame){'Visible'}else{'Collapsed'}
 $today = [datetime]::Today.ToString('yyyy-MM-dd')
 $todayRows = @($displayRecords.Values | Where-Object Date -eq $today)
 $fg = [double](($todayRows | Measure-Object Foreground -Sum).Sum)
 $run = [double](($todayRows | Measure-Object Running -Sum).Sum)
 $ui.MiniTime.Text = Format-CompactDuration $fg
 Update-MiniStatus
 if($script:isCompact){return}
 $ui.Total.Text = Format-CompactDuration $fg
 $ui.Total.ToolTip = '运行累计 ' + (Format-Duration $run) + ' · 后台 ' + (Format-Duration ($run-$fg))
 $active = @($script:rules | Where-Object { $script:last.Names.ContainsKey($_.Process.ToLowerInvariant()) })
 $frontGame = @($active | Where-Object { $_.Process -eq $script:last.Front })
 $ui.CurrentGame.Text = if ($frontGame.Count) { $frontGame[0].Name + ' · 前台' } elseif ($active.Count) { $active[0].Name + ' · 后台' } else { '等待游戏' }
 if($script:isDemo){$ui.CurrentGame.Text='演示模式 · 示例数据'}
 $ui.CurrentGame.ToolTip = if ($script:last.Readable) { '当前前台：' + $script:last.FrontLabel + "`n已识别 $($steamRules.Count) 款 Steam 游戏；有变化时自动保存。" } else { '前台不可读或桌面锁定，暂停累计。' }
 $notes=@($script:dataNotes)+@($script:runtimeWarning|Where-Object{$_})
 $ui.Health.Text = if ($script:saveError) { $script:saveError } elseif ($notes.Count) { $notes -join "`n" } elseif (-not $script:last.Readable) { '无法读取交互桌面。请在桌面双击启动；锁屏期间不计时。' } else { "已识别 $($steamRules.Count) 款 Steam 游戏 · 自动保存 · 从现在起统计" }
 $ui.Health.Visibility=if($script:saveError -or $notes.Count -or (-not $script:last.Readable -and -not $Preview)){'Visible'}else{'Collapsed'}
 $games=@($todayRows | Group-Object Name | ForEach-Object {
  [pscustomobject]@{Name=$_.Name;Foreground=[double](($_.Group|Measure-Object Foreground -Sum).Sum);Running=[double](($_.Group|Measure-Object Running -Sum).Sum)}
 } | Sort-Object Foreground -Descending)
 $script:expandedHeight=[math]::Min(750,610+[math]::Max(0,$games.Count-1)*70)
 $ui.GameScroll.Height=[math]::Min(216,76*[math]::Max(1,$games.Count))
 if($ui.FullPanel.Visibility -eq 'Visible' -and -not $script:userResized){$autoHeight=[math]::Min($script:expandedHeight,[Windows.SystemParameters]::WorkArea.Height-24);if([math]::Abs($window.Height-$autoHeight) -gt 0.5){$window.Height=$autoHeight;$window.UpdateLayout();Keep-OnScreen}}
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
 # 2.1: the stats page is rebuilt at most every 10 s from the timer; clicks still render at once.
 if($ui.StatsPanel.Visibility -eq 'Visible' -and $clock.Elapsed.TotalSeconds-$script:lastStatsRender -ge 10){Render-Stats}
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
 $script:lastStatsRender=$clock.Elapsed.TotalSeconds
 if($script:isDemo){Initialize-DemoData}
 $source=if($script:isDemo){$demoRecords}else{$records};$allRows=@($source.Values);$cutoff=if($script:statsRange -eq 7){[datetime]::Today.AddDays(-6)}elseif($script:statsRange -eq 30){[datetime]::Today.AddDays(-29)}else{[datetime]::MinValue};$rows=@($allRows|Where-Object{try{[datetime]$_.Date -ge $cutoff}catch{$false}})
 $total=[double](($rows|Measure-Object Foreground -Sum).Sum);$days=@($rows|Where-Object Foreground -gt 0|Select-Object -ExpandProperty Date -Unique);$average=if($days.Count){$total/$days.Count}else{0}
 $script:statsTrack=if($script:isDark){'#24FFFFFF'}else{'#16303633'};$script:statsRowBackground='Transparent';$script:statsRowHover=if($script:isDark){'#26FFFFFF'}else{'#66FFFFFF'}
 $ui.StatsRangeLabel.Text=if($script:statsRange -eq 7){'最近 7 天'}elseif($script:statsRange -eq 30){'最近 30 天'}else{'全部记录'}
 $firstDate=if($script:statsRange -eq 0){$sortedDates=@($days|Sort-Object);if($sortedDates.Count){[datetime]$sortedDates[0]}else{[datetime]::Today}}else{$cutoff}
 $ui.StatsDateSpan.Text=$firstDate.ToString('M月d日')+' — '+[datetime]::Today.ToString('M月d日')
 $ui.StatsTotal.Text=Format-CompactDuration $total;$ui.StatsAverage.Text=Format-CompactDuration $average;$ui.StatsDays.Text=$days.Count.ToString()+' 天'
 foreach($button in @($ui.StatsRange7,$ui.StatsRange30,$ui.StatsRangeAll)){$active=($button -eq $ui.StatsRange7 -and $script:statsRange -eq 7)-or($button -eq $ui.StatsRange30 -and $script:statsRange -eq 30)-or($button -eq $ui.StatsRangeAll -and $script:statsRange -eq 0);$button.Background=if($active){('#24'+([string]$script:barDeep).Substring(1))}else{'Transparent'};$button.FontWeight=if($active){'SemiBold'}else{'Normal'};$button.Tag=if($active){'active'}else{''}}
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
  foreach($button in @($ui.StatsRange7,$ui.StatsRange30,$ui.StatsRangeAll)){
  $button.Foreground=$script:themeText
  $button.BorderThickness=1
  $button.BorderBrush=if($button.Tag -eq 'active'){('#60'+([string]$script:barDeep).Substring(1))}else{'Transparent'}
 }
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
   Save-Games
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
 $delete=[Windows.Controls.Button]::new();$delete.Content='删除选中规则';$delete.Margin='0,12,0,0';$delete.Add_Click({if($list.SelectedIndex -ge 0){$script:manualRules=@($script:manualRules|Where-Object Process -ne $script:manualRules[$list.SelectedIndex].Process);$script:rules=@($builtInRules)+@($script:manualRules)+@($steamRules);Save-Games;$picker.Close();Render-State}});[void]$panel.Children.Add($delete);$picker.Content=$panel;[void]$picker.ShowDialog()
}
$ui.DragHandle.Add_MouseLeftButtonDown({ $window.DragMove(); Keep-OnScreen })
$ui.PrevMonth.Add_Click({$script:month=$script:month.AddDays(-56);Render-State})
$ui.ClearFilter.Add_Click({$script:selectedGame='';Render-State})
function Show-Migration {
 $running=$timer.IsEnabled;$timer.Stop()
 try{
  $picker=[Windows.Forms.FolderBrowserDialog]::new();$picker.Description='选择实际使用过的旧版 Afterhours 文件夹（或其中的 data）'
  try{if($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){return};$source=$picker.SelectedPath}finally{$picker.Dispose()}
  Save-Activity -Force
  if($script:saveError){throw $script:saveError}
  $plan=New-MigrationPlan $source $DataDirectory
  $message="来源：$($plan.Source)`n日期：$($plan.From) 至 $($plan.To)`n共 $($plan.Days) 天，前台 $([math]::Round($plan.Seconds/3600,2)) 小时。`n`n"
  if($plan.Conflicts){$message+="有 $($plan.Conflicts) 条同日同游戏记录与当前不同。继续将以旧版这些记录为准，保留当前其他日期，不把冲突时长相加；可能舍弃新版在这些条目上的增量。`n`n"}
  $message+='将先备份当前数据再导入，主题设置保持当前选择。是否继续？'
  if([Windows.MessageBox]::Show($window,$message,'迁移旧版数据','YesNo','Question') -ne 'Yes'){return}
  $backup=Invoke-MigrationPlan $plan -PreferSource
  $records.Clear();foreach($r in @(Read-MigrationRows $DataDirectory 'activity.json')){$records["$($r.Date)|$($r.Process)"]=$r}
  $mergedSessions=Merge-Sessions @(Read-MigrationRows $DataDirectory 'sessions.json') 120;$sessions.Clear();foreach($r in $mergedSessions){[void]$sessions.Add($r)};$script:currentSession=$null
  # Migration rewrote all three files with validated data, so saving is safe again.
  $script:blockSave=@{games=$false;activity=$false;sessions=$false};$script:dataNotes.Clear();$script:activityDirty=$false;$script:sessionsDirty=$true
  $script:manualRules=@(Read-MigrationRows $DataDirectory 'games.json'|Where-Object{$_.Process -notlike 'steam-*' -and $_.Process -notin $builtInRules.Process});$script:rules=@($builtInRules)+@($script:manualRules)+@($steamRules)
  $script:heatKey='';$script:rankKey='';$script:month=[datetime]::Today.AddDays(-(([int][datetime]::Today.DayOfWeek+6)%7));$script:anchorMonday=$script:month;Render-State
  [void][Windows.MessageBox]::Show($window,"迁移完成。首页只显示今天，请在统计中选择全部查看历史。`n`n原数据备份：$backup",'Afterhours')
 }catch{[void][Windows.MessageBox]::Show($window,($_.Exception.Message),'迁移未完成','OK','Warning')}
 finally{$script:lastTick=$clock.Elapsed.TotalSeconds;if($running){$timer.Start()}}
}
function New-SettingsMenu {
 $menu=[Windows.Controls.ContextMenu]::new();$menu.Style=$window.FindResource('GameMenuStyle');$menu.Placement='Bottom';$menu.VerticalOffset=5
 $menu.Add_Loaded({param($sender,$eventArgs)$source=[Windows.Interop.HwndSource]::FromVisual($sender);if($source){[DesktopLayer]::BlurPopup($source.Handle)}})
 foreach($theme in @('极地雾','极光薄荷','烟粉','暮光紫')){
  $item=[Windows.Controls.MenuItem]::new();$item.Header='主题 · '+$theme;$item.Tag='theme|'+$theme;$item.IsCheckable=$true;$item.IsChecked=$preferences.Theme -eq $theme;$item.Style=$window.FindResource('GameMenuItemStyle')
  $item.Add_Click({param($sender,$eventArgs)$preferences.Theme=([string]$sender.Tag).Split('|')[1];Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($item)
 }
 $dark=[Windows.Controls.MenuItem]::new();$dark.Header='深色模式';$dark.IsCheckable=$true;$dark.IsChecked=$preferences.Dark;$dark.Style=$window.FindResource('GameMenuItemStyle')
 $dark.Add_Click({$preferences.Dark=-not $preferences.Dark;Save-JsonAtomic $preferences $preferencesPath;Apply-Theme;Render-State});[void]$menu.Items.Add($dark)
 $demo=[Windows.Controls.MenuItem]::new();$demo.Header=if($script:isDemo){'返回实测'}else{'查看演示数据'};$demo.IsCheckable=$true;$demo.IsChecked=$script:isDemo;$demo.Style=$window.FindResource('GameMenuItemStyle');$demo.Add_Click({$script:isDemo=-not $script:isDemo;$script:selectedGame='';$script:heatKey='';Render-State});[void]$menu.Items.Add($demo)
 $manage=[Windows.Controls.MenuItem]::new();$manage.Header='管理手动游戏';$manage.Style=$window.FindResource('GameMenuItemStyle');$manage.Add_Click({Manage-Games});[void]$menu.Items.Add($manage)
 $migration=[Windows.Controls.MenuItem]::new();$migration.Header='迁移旧版数据…';$migration.Style=$window.FindResource('GameMenuItemStyle');$migration.Add_Click({Show-Migration});[void]$menu.Items.Add($migration)
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
$ui.StatsButton.Add_Click({$script:preStatsHeight=$window.Height;$ui.FullPanel.Visibility='Collapsed';$ui.MiniPanel.Visibility='Collapsed';$ui.HeaderActions.Visibility='Collapsed';$ui.StatsHeaderActions.Visibility='Visible';$ui.TopHeader.Margin='0,0,0,18';$ui.StatsPanel.Visibility='Visible';if(-not $script:userResized){$window.Height=[math]::Min(750,(Get-WorkAreaDip).Height-24);$window.UpdateLayout();Keep-OnScreen};Render-Stats;if(-not $Preview){$ui.StatsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty,[Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([timespan]::FromMilliseconds(220))))}})
$ui.StatsBack.Add_Click({$ui.StatsPanel.Visibility='Collapsed';$ui.FullPanel.Visibility='Visible';$ui.HeaderActions.Visibility='Visible';$ui.StatsHeaderActions.Visibility='Collapsed';$ui.TopHeader.Margin='0,0,0,16';$ui.Compact.Visibility='Visible';if(-not $script:userResized -and $script:preStatsHeight){$window.Height=$script:preStatsHeight};Render-State;$window.UpdateLayout();Keep-OnScreen})
$ui.StatsHours.Add_SizeChanged({param($sender,$eventArgs)if($ui.StatsPanel.Visibility -eq 'Visible' -and $eventArgs.WidthChanged){Render-Stats}})
$window.Add_SizeChanged({Update-ContentScale})
$ui.StatsRange7.Add_Click({$script:statsRange=7;Render-Stats})
$ui.StatsRange30.Add_Click({$script:statsRange=30;Render-Stats})
$ui.StatsRangeAll.Add_Click({$script:statsRange=0;Render-Stats})
$ui.ResizeGrip.Add_MouseLeftButtonDown({
 if($script:isCompact){return}
 $script:userResized=$true
 if($script:desktop){$script:desktop.BeginResize()}
 Keep-OnScreen
})
$ui.Compact.Add_Click({
 if(-not $script:isCompact){
  $script:expandedSize=[pscustomobject]@{Width=$window.ActualWidth;Height=$window.ActualHeight}
  $script:isCompact=$true
  $ui.FullPanel.Visibility='Collapsed';$ui.MiniPanel.Visibility='Visible';$ui.ResizeGrip.Visibility='Collapsed'
  $ui.MainScroll.Visibility='Collapsed';$ui.RootGlass.Padding='14,10';$window.MinWidth=280;$window.MinHeight=64;$window.MaxHeight=64;Resize-Anchored 320 64;$ui.Compact.Content='+';$ui.Compact.ToolTip='展开看板'
  Update-ContentScale
 }else{
  $script:isCompact=$false
  $ui.MainScroll.Visibility='Visible';$ui.RootGlass.Padding='16,14';$window.MinWidth=300;$window.MaxHeight=860;$window.MinHeight=520
  $newWidth=[math]::Max($window.MinWidth,[math]::Min($window.MaxWidth,[double]$script:expandedSize.Width))
  $newHeight=[math]::Max($window.MinHeight,[math]::Min([math]::Min($window.MaxHeight,(Get-WorkAreaDip).Height-24),[double]$script:expandedSize.Height))
  Resize-Anchored $newWidth $newHeight
  $ui.FullPanel.Visibility='Visible';$ui.MiniPanel.Visibility='Collapsed';$ui.ResizeGrip.Visibility='Visible';$ui.Compact.Content='−';$ui.Compact.ToolTip='折叠为小窗'
  Update-ContentScale
  Render-State
 }
})
$ui.MiniExpand.Add_Click({$ui.Compact.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
$ui.MiniClose.Add_Click({$window.Close()})
$ui.MiniDrag.Add_MouseLeftButtonDown({$window.DragMove();Keep-OnScreen})
$ui.MainScroll.Add_ScrollChanged({param($sender,$e)if($e.ViewportWidthChange -ne 0){Update-ContentScale}})
$ui.Play.Add_Click({Select-Game})
$timer=[Windows.Threading.DispatcherTimer]::new(); $timer.Interval=[timespan]::FromSeconds(1)
$timer.Add_Tick({
 try {
  $next=Read-Snapshot $script:rules
  $tick=$clock.Elapsed.TotalSeconds
  if(Add-Interval $records $script:rules $script:last $next ($tick-$script:lastTick)){$script:activityDirty=$true}
  Update-Session $next ($tick-$script:lastTick)
  # Save at once when the desktop becomes unreadable (lock) or after a gap (sleep/resume).
  $force=($script:last.Readable -and -not $next.Readable) -or ($tick-$script:lastTick -gt 5)
  $script:last=$next; $script:lastTick=$tick
  if($force){Save-Activity -Force}else{Save-Activity}
  if($script:dailyBackupDate -ne [datetime]::Today){Save-DailyBackup;$script:dailyBackupDate=[datetime]::Today}
  # 2.1: the UI shows minutes, so only re-render when a visible value can change.
  $today=[datetime]::Today.ToString('yyyy-MM-dd');$fgToday=0.0;$runToday=0.0
  foreach($row in $records.Values){if($row.Date -eq $today){$fgToday+=[double]$row.Foreground;$runToday+=[double]$row.Running}}
  $activeKey='';foreach($r in $script:rules){if($script:last.Names.ContainsKey($r.Process)){$activeKey+=$r.Process+','}}
  $signature=$today+'|'+$script:last.Front+'|'+$script:last.Readable+'|'+$activeKey+'|'+[math]::Floor($fgToday/60)+'|'+[math]::Floor($runToday/60)+'|'+$script:saveError+'|'+$script:runtimeWarning
  if($signature -ne $script:lastRenderSignature -and (-not $script:desktop -or -not $script:desktop.IsCovered())){Render-State;$script:lastRenderSignature=$signature}
  if($ProbeSeconds -gt 0 -and $tick -ge $ProbeSeconds){$window.Close()}
 } catch {
  # 2.1: the recovery path itself must never throw (2.0.3 re-ran Read-Snapshot unguarded here).
  $script:runtimeWarning='采集错误（已自动继续）：'+$_.Exception.Message
  Write-RuntimeLog $_
  try{$script:last=Read-Snapshot $script:rules}catch{}
  $script:lastTick=$clock.Elapsed.TotalSeconds
 }
})
$script:dailyBackupDate=[datetime]::Today
$script:tray=$null
if(-not $Preview){
 $script:tray=[Windows.Forms.NotifyIcon]::new();$iconPath=Join-Path $PSScriptRoot 'Afterhours.ico';if(Test-Path -LiteralPath $iconPath){$script:trayIcon=[Drawing.Icon]::new($iconPath);$script:tray.Icon=$script:trayIcon}else{$script:tray.Icon=[Drawing.SystemIcons]::Application};$script:tray.Text='Afterhours 2.1.1 · 游戏时间';$script:tray.Visible=$true
 $trayMenu=[Windows.Forms.ContextMenuStrip]::new();[void]$trayMenu.Items.Add('退出 Afterhours')
 $trayMenu.Items[0].Add_Click({$window.Close()});$script:tray.ContextMenuStrip=$trayMenu
}
$window.Add_Closed({$timer.Stop();Save-Activity -Force;if($script:tray){$script:tray.Visible=$false;$script:tray.Dispose()};if($script:trayIcon){$script:trayIcon.Dispose()}})
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
  if($settings.Items.Count -ne 9){throw 'Settings menu item count failed'}
  $settings.Items[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
  if($preferences.Theme -ne '烟粉'){throw 'Theme selection failed'}
  $preferences.Dark=$false;$settings=New-SettingsMenu;$settings.Items[4].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
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
  foreach($shotTheme in @('极光薄荷','极地雾','烟粉','暮光紫')){foreach($shotDark in @($false,$true)){
   $preferences.Theme=$shotTheme;$preferences.Dark=$shotDark;Apply-Theme;$window.Height=$script:expandedHeight;Render-State
   $mode=if($shotDark){'dark'}else{'light'}
   Save-Shot ($shotTheme+'-'+$mode+'-home')
   $ui.StatsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Save-Shot ($shotTheme+'-'+$mode+'-stats')
   $ui.StatsBack.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
  }}
  $preferences.Theme='极光薄荷';$preferences.Dark=$false;Apply-Theme;Render-State
  if($window.ResizeMode -ne [Windows.ResizeMode]::CanResize){throw 'Window resize mode failed'}
  $script:userResized=$true;$window.Width=420;$window.Height=640;$window.UpdateLayout()
  $ui.Compact.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$window.UpdateLayout()
  if(-not $script:isCompact -or [math]::Abs($window.ActualHeight-64) -gt 1 -or $ui.MiniPanel.Visibility -ne 'Visible' -or $ui.ResizeGrip.Visibility -ne 'Collapsed'){throw 'Compact mode failed'}
  Save-Shot 'mini'
  $ui.Compact.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$window.UpdateLayout()
  if($script:isCompact -or [math]::Abs($window.ActualWidth-420) -gt 1 -or [math]::Abs($window.ActualHeight-640) -gt 1 -or $ui.ResizeGrip.Visibility -ne 'Visible'){throw 'Expanded size restore failed'}
  Update-ContentScale
  $mediumScale=[Windows.Media.ScaleTransform]$ui.MainContent.LayoutTransform
  if($mediumScale.ScaleX -le 1 -or [math]::Abs($mediumScale.ScaleX-$mediumScale.ScaleY) -gt 0.001){throw 'Proportional medium scaling failed'}
  Save-Shot 'scaled-medium'
  $window.Width=540;$window.Height=860;$window.UpdateLayout();Update-ContentScale
  $largeScale=[Windows.Media.ScaleTransform]$ui.MainContent.LayoutTransform
  if([math]::Abs($largeScale.ScaleX-1.4) -gt 0.01 -or [math]::Abs($largeScale.ScaleX-$largeScale.ScaleY) -gt 0.001){throw 'Proportional large scaling failed'}
  Save-Shot 'scaled-large'
  $window.Width=300;$window.Height=520;$window.UpdateLayout();Update-ContentScale
  $narrowScale=[Windows.Media.ScaleTransform]$ui.MainContent.LayoutTransform
  if([math]::Abs($window.ActualWidth-300) -gt 1 -or [math]::Abs($narrowScale.ScaleX-(300.0/370.0)) -gt 0.01 -or [math]::Abs($narrowScale.ScaleX-$narrowScale.ScaleY) -gt 0.001){throw 'Proportional narrow scaling failed'}
  Save-Shot 'scaled-narrow'
  $ui.StatsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$window.Height=520;$window.UpdateLayout();Update-ContentScale;$window.UpdateLayout()
  if($ui.MainContent.ActualWidth*$ui.MainContent.LayoutTransform.ScaleX -gt $ui.MainScroll.ViewportWidth+2){throw 'Stats content overlaps scrollbar'}
  Save-Shot 'stats-narrow'
  $ui.MainScroll.ScrollToEnd();$window.UpdateLayout()
  if($ui.MainScroll.ScrollableHeight -gt 0 -and $ui.MainScroll.VerticalOffset -le 0){throw 'Stats scrolling failed'}
  Save-Shot 'stats-narrow-bottom'
  $ui.MainScroll.ScrollToHome();$ui.StatsBack.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
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
