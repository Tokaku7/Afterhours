Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ActivityNative {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
 [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
 public static bool DesktopAvailable() {
  IntPtr h = OpenInputDesktop(0, false, 1);
  if(h == IntPtr.Zero) return false;
  CloseDesktop(h); return true;
 }
}
'@
function Get-SteamRules([string]$SteamPathOverride='') {
 $steam = if($SteamPathOverride){$SteamPathOverride}else{(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath}
 if (-not $steam -or -not (Test-Path -LiteralPath $steam -PathType Container -ErrorAction SilentlyContinue)) { return }
 $libraries = @($steam)
 $libraryFile = try { Join-Path $steam 'steamapps\libraryfolders.vdf' } catch { $null }
 if (Test-Path -LiteralPath $libraryFile) {
  $content = Get-Content -LiteralPath $libraryFile -Raw
  foreach ($match in [regex]::Matches($content,'"path"\s+"([^"]+)"')) { $libraries += $match.Groups[1].Value.Replace('\\','\') }
 }
 foreach ($library in @($libraries | Select-Object -Unique)) {
  if(-not $library -or -not (Test-Path -LiteralPath $library -PathType Container -ErrorAction SilentlyContinue)){continue}
  $appsPath=try{Join-Path $library 'steamapps'}catch{continue}
  foreach ($manifest in @(Get-ChildItem -LiteralPath $appsPath -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
   $content = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8
   $appId = [regex]::Match($content,'"appid"\s+"([^"]+)"').Groups[1].Value
   $name = [regex]::Match($content,'"name"\s+"([^"]+)"').Groups[1].Value
   $dir = [regex]::Match($content,'"installdir"\s+"([^"]+)"').Groups[1].Value
   if ($appId -and $dir -and $appId -ne '228980') {
    try{$root=[IO.Path]::GetFullPath((Join-Path $library "steamapps\common\$dir"));if(Test-Path -LiteralPath $root -PathType Container){[pscustomobject]@{Name=$name; Process="steam-$appId"; Root=$root.TrimEnd('\')+'\'}}}catch{}
   }
  }
 }
}
$script:pathCache=@{}
$script:matchCache=@{}
$script:matchRuleKey=''
function Read-Snapshot($Rules=@()) {
 $sameSession = (Get-Process -Id $PID).SessionId
 $names = @{}
 $paths = @{}
 foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
  if ($process.SessionId -eq $sameSession) {
   $names[$process.ProcessName.ToLowerInvariant()] = $true
   $cached=$script:pathCache[$process.Id]
   if(-not $cached -or $cached.Name -ne $process.ProcessName -or $cached.Expires -lt [datetime]::UtcNow){
    $path='';try{$path=$process.Path}catch{}
    $cached=[pscustomobject]@{Name=$process.ProcessName;Path=$path;Expires=[datetime]::UtcNow.AddSeconds(30)}
    $script:pathCache[$process.Id]=$cached
   }
   if($cached.Path){$paths[$process.Id]=$cached.Path}
  }
  $process.Dispose()
 }
 [uint32]$owner = 0
 $handle = [ActivityNative]::GetForegroundWindow()
 [void][ActivityNative]::GetWindowThreadProcessId($handle,[ref]$owner)
 $front = ''
 if ($owner -gt 0) {
  $process = Get-Process -Id $owner -ErrorAction SilentlyContinue
  if ($process) { $front = $process.ProcessName.ToLowerInvariant() }
 }
 $frontLabel=$front
 $ruleKey=($Rules.Root -join '|')
 if($script:matchRuleKey -ne $ruleKey){$script:matchCache=@{};$script:matchRuleKey=$ruleKey}
 foreach ($entry in $paths.GetEnumerator()) {
  if(-not $script:matchCache.ContainsKey($entry.Value)){
   $matchName=''
   foreach($rule in $Rules){
    if ($rule.Root -and $entry.Value.StartsWith($rule.Root,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileNameWithoutExtension($entry.Value) -notmatch 'crash|report|launcher|unins|setup|helper|anticheat|bootstrap') {$matchName=$rule.Process;break}
   }
   $script:matchCache[$entry.Value]=$matchName
  }
  $matchName=$script:matchCache[$entry.Value]
  if($matchName){$names[$matchName]=$true;if($entry.Key -eq $owner){$front=$matchName}}
 }
 [pscustomobject]@{ Time=[datetime]::Now; Names=$names; Front=$front; FrontLabel=$frontLabel; Readable=($front -ne '' -and [ActivityNative]::DesktopAvailable()) }
}
function Add-Interval($Records, $Rules, $Before, $After, [double]$Seconds) {
 # Conservative boundary sampling; never fill sleep/stall/closed-app gaps.
 if ($Seconds -le 0 -or $Seconds -gt 5 -or -not $Before.Readable -or -not $After.Readable) { return }
 $cursor = $Before.Time
 $remaining = $Seconds
 while ($remaining -gt 0.00001) {
  $part = [math]::Min($remaining, ($cursor.Date.AddDays(1)-$cursor).TotalSeconds)
  $date = $cursor.ToString('yyyy-MM-dd')
  foreach ($rule in $Rules) {
   $processName = $rule.Process.ToLowerInvariant()
   if (-not ($Before.Names.ContainsKey($processName) -and $After.Names.ContainsKey($processName))) { continue }
   $key = "$date|$processName"
   if (-not $Records.ContainsKey($key)) { $Records[$key] = [pscustomobject]@{ Date=$date; Process=$processName; Name=$rule.Name; Running=0.0; Foreground=0.0 } }
   $Records[$key].Running += $part
   if ($Before.Front -eq $processName -and $After.Front -eq $processName) { $Records[$key].Foreground += $part }
  }
  $remaining -= $part
  $cursor = $cursor.AddSeconds($part)
 }
}
function Save-JsonAtomic($Value, $Path) {
 $json = ConvertTo-Json -InputObject $Value -Depth 8
 [IO.File]::WriteAllText("$Path.tmp",$json,[Text.UTF8Encoding]::new($true))
 if ([IO.File]::Exists($Path)) { [IO.File]::Replace("$Path.tmp",$Path,"$Path.bak") }
 else { [IO.File]::Move("$Path.tmp",$Path) }
}
function Format-Duration([double]$Seconds) {
 $span = [timespan]::FromSeconds([math]::Max(0,[math]::Floor($Seconds)))
 if ($span.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds) }
 if ($span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f [math]::Floor($span.TotalMinutes),$span.Seconds) }
 return "$($span.Seconds)s"
}
