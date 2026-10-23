Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
public sealed class SnapshotResult {
 public Dictionary<string,bool> Names;
 public string Front;
 public string FrontLabel;
}
public static class ActivityNative {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
 [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
 [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static bool DesktopAvailable() {
  IntPtr h = OpenInputDesktop(0, false, 1);
  if(h == IntPtr.Zero) return false;
  CloseDesktop(h); return true;
 }

 // 2.1: the per-second process scan moved here from PowerShell (it was the main
 // CPU cost). Same rules as 2.0.3: names of all processes in the session, plus the
 // Steam rule whose install folder contains the exe (helpers/launchers excluded).
 sealed class Entry { public string Name; public string Path; public DateTime Retry; }
 static readonly Dictionary<int,Entry> pathCache = new Dictionary<int,Entry>();
 static readonly Dictionary<string,string> matchCache = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
 static string matchKey = "";
 static readonly Regex helperExe = new Regex("crash|report|launcher|unins|setup|helper|anticheat|bootstrap", RegexOptions.IgnoreCase);

 static string ImagePath(int pid) {
  // PROCESS_QUERY_LIMITED_INFORMATION also works for many elevated/protected processes.
  IntPtr h = OpenProcess(0x1000, false, pid);
  if (h == IntPtr.Zero) return "";
  try { var sb = new StringBuilder(1024); int size = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : ""; }
  finally { CloseHandle(h); }
 }

 // nameRules: process names already covered by built-in/manual rules. Those processes
 // skip Steam path matching so one game is never counted under two rules.
 public static SnapshotResult Read(int session, string[] roots, string[] ruleProcesses, string[] nameRules) {
  var named = new HashSet<string>(nameRules, StringComparer.OrdinalIgnoreCase);
  DateTime now = DateTime.UtcNow;
  var names = new Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase);
  var byId = new Dictionary<int,string>();
  uint owner = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), out owner);
  string key = string.Join("|", roots);
  if (key != matchKey) { matchCache.Clear(); matchKey = key; }
  string front = "", frontMatch = "";
  foreach (Process p in Process.GetProcesses()) {
   try {
    if (p.SessionId != session) continue;
    int id = p.Id; string name = p.ProcessName;
    byId[id] = name;
    names[name.ToLowerInvariant()] = true;
    if (id == (int)owner) front = name.ToLowerInvariant();
    if (roots.Length == 0 || named.Contains(name)) continue;
    Entry e;
    if (!pathCache.TryGetValue(id, out e) || e.Name != name || (e.Path.Length == 0 && e.Retry < now)) {
     e = new Entry { Name = name, Path = ImagePath(id), Retry = now.AddSeconds(60) };
     pathCache[id] = e;
    }
    if (e.Path.Length == 0) continue;
    string match;
    if (!matchCache.TryGetValue(e.Path, out match)) {
     match = "";
     string file = System.IO.Path.GetFileNameWithoutExtension(e.Path);
     for (int i = 0; i < roots.Length; i++) {
      if (!string.IsNullOrEmpty(roots[i]) && e.Path.StartsWith(roots[i], StringComparison.OrdinalIgnoreCase) && !helperExe.IsMatch(file)) { match = ruleProcesses[i]; break; }
     }
     matchCache[e.Path] = match;
    }
    if (match.Length > 0) { names[match] = true; if (id == (int)owner) frontMatch = match; }
   } catch { } finally { p.Dispose(); }
  }
  var dead = new List<int>();
  foreach (int id in pathCache.Keys) if (!byId.ContainsKey(id)) dead.Add(id);
  foreach (int id in dead) pathCache.Remove(id);
  return new SnapshotResult { Names = names, Front = frontMatch.Length > 0 ? frontMatch : front, FrontLabel = front };
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
$script:sameSession=(Get-Process -Id $PID).SessionId
$script:snapshotRules=$null
function Read-Snapshot($Rules=@()) {
 # 2.1: the scan itself runs in [ActivityNative]::Read (C#); only path-based rules are passed.
 if(-not [object]::ReferenceEquals($Rules,$script:snapshotRules)){
  $script:snapshotRules=$Rules
  $withRoot=@($Rules|Where-Object{$_.Root})
  $script:snapshotRoots=[string[]]@($withRoot|ForEach-Object{[string]$_.Root})
  $script:snapshotProcesses=[string[]]@($withRoot|ForEach-Object{[string]$_.Process})
  $script:snapshotNamed=[string[]]@($Rules|Where-Object{-not $_.Root -and $_.Process}|ForEach-Object{[string]$_.Process})
 }
 $result=[ActivityNative]::Read($script:sameSession,$script:snapshotRoots,$script:snapshotProcesses,$script:snapshotNamed)
 [pscustomobject]@{ Time=[datetime]::Now; Names=$result.Names; Front=$result.Front; FrontLabel=$result.FrontLabel; Readable=($result.Front -ne '' -and [ActivityNative]::DesktopAvailable()) }
}
function Add-Interval($Records, $Rules, $Before, $After, [double]$Seconds) {
 # Conservative boundary sampling; never fill sleep/stall/closed-app gaps.
 # Returns $true when any record changed (2.1: lets the caller skip unnecessary saves).
 if ($Seconds -le 0 -or $Seconds -gt 5 -or -not $Before.Readable -or -not $After.Readable) { return $false }
 $changed = $false
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
   $changed = $true
  }
  $remaining -= $part
  $cursor = $cursor.AddSeconds($part)
 }
 return $changed
}
function Save-JsonAtomic($Value, $Path) {
 # 2.1: flush the temp file to disk before replacing, so a power loss cannot
 # leave a zero-filled activity.json (likely cause of "无效的 JSON 基元" reports).
 $json = ConvertTo-Json -InputObject $Value -Depth 8
 $bytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.UTF8Encoding]::new($false).GetBytes($json)
 $stream = [IO.FileStream]::new("$Path.tmp",[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
 if ([IO.File]::Exists($Path)) { [IO.File]::Replace("$Path.tmp",$Path,"$Path.bak") }
 else { [IO.File]::Move("$Path.tmp",$Path) }
}
function Read-JsonArraySafe([string]$Path) {
 # 2.1: never treat an unreadable file as empty. Try the file, then its .bak;
 # if the .bak was used, keep the broken file as *.corrupt-<time> for inspection.
 # Ok=$false means both failed: the caller must stop saving that file.
 if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{Ok=$true;Rows=@();Note=''} }
 foreach ($candidate in @($Path,"$Path.bak")) {
  try {
   if (-not [IO.File]::Exists($candidate)) { continue }
   $raw = [IO.File]::ReadAllText($candidate,[Text.Encoding]::UTF8)
   if (-not $raw.Trim()) { throw 'empty file' }
   $rows = @(($raw | ConvertFrom-Json -ErrorAction Stop) | Where-Object { $null -ne $_ })
   $note = ''
   if ($candidate -ne $Path) {
    [IO.File]::Copy($Path,"$Path.corrupt-$([datetime]::Now.ToString('yyyyMMdd-HHmmss'))",$true)
    $note = "$([IO.Path]::GetFileName($Path)) 损坏，已从自动备份恢复"
   }
   return [pscustomobject]@{Ok=$true;Rows=$rows;Note=$note}
  } catch {}
 }
 return [pscustomobject]@{Ok=$false;Rows=@();Note="$([IO.Path]::GetFileName($Path)) 及其备份都无法读取，已暂停写入该文件以保护原数据"}
}
function Merge-Sessions($Items, [double]$GapSeconds=120) {
 # 2.1: join consecutive sessions of the same game separated by <= GapSeconds.
 # Seconds stays the sum of counted foreground time; Start/End span the whole block.
 $result = [Collections.ArrayList]::new()
 $sorted = @($Items | Where-Object { $_ -and $_.Start -and $_.End } | Sort-Object { try { [datetime]$_.Start } catch { [datetime]::MinValue } })
 foreach ($item in $sorted) {
  $last = if ($result.Count) { $result[$result.Count-1] } else { $null }
  $gap = if ($last) { try { ([datetime]$item.Start - [datetime]$last.End).TotalSeconds } catch { [double]::MaxValue } } else { [double]::MaxValue }
  if ($last -and $last.Process -eq $item.Process -and $gap -le $GapSeconds) {
   try { if ([datetime]$item.End -gt [datetime]$last.End) { $last.End = $item.End } } catch {}
   $last.Seconds = [double]$last.Seconds + [double]$item.Seconds
  } else {
   [void]$result.Add([pscustomobject]@{Process=$item.Process;Name=$item.Name;Start=$item.Start;End=$item.End;Seconds=[double]$item.Seconds})
  }
 }
 return ,$result
}
function Format-Duration([double]$Seconds) {
 $span = [timespan]::FromSeconds([math]::Max(0,[math]::Floor($Seconds)))
 if ($span.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds) }
 if ($span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f [math]::Floor($span.TotalMinutes),$span.Seconds) }
 return "$($span.Seconds)s"
}
