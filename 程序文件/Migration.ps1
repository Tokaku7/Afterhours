function Read-MigrationRows([string]$Directory,[string]$File) {
 $path=Join-Path $Directory $File
 if(-not [IO.File]::Exists($path)){return}
 $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 if(-not $raw.Trim().StartsWith('[')){throw "$File 必须是有效的 JSON 数组，未修改任何数据。"}
 $rows=@($raw|ConvertFrom-Json -ErrorAction Stop)
 foreach($r in $rows){
  if(-not $r -or -not $r.Process -or -not $r.Name){throw "$File 缺少游戏名称或进程名。"}
  if($File -eq 'activity.json'){
   $date=[datetime]::MinValue
   if(-not [datetime]::TryParseExact([string]$r.Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){throw '历史日期格式不正确。'}
   foreach($key in @('Foreground','Running')){if($null -eq $r.$key -or [double]::IsNaN([double]$r.$key) -or [double]::IsInfinity([double]$r.$key) -or [double]$r.$key -lt 0){throw '历史时长格式不正确。'}}
  }
  if($File -eq 'sessions.json'){
   if(-not $r.Start -or -not $r.End -or $null -eq $r.Seconds -or [double]$r.Seconds -lt 0 -or [double]::IsNaN([double]$r.Seconds) -or [double]::IsInfinity([double]$r.Seconds) -or [datetime]$r.End -lt [datetime]$r.Start){throw '会话格式不正确。'}
  }
  $r
 }
}
function New-MigrationPlan([string]$Source,[string]$Target) {
 $sourceData=if(Test-Path -LiteralPath (Join-Path $Source 'activity.json')){$Source}else{Join-Path $Source 'data'}
 $sourceData=[IO.Path]::GetFullPath($sourceData).TrimEnd('\')
 $targetData=[IO.Path]::GetFullPath($Target).TrimEnd('\')
 if($sourceData -eq $targetData){throw '所选文件夹就是当前数据目录，无需迁移。'}
 if(-not (Test-Path -LiteralPath (Join-Path $sourceData 'activity.json'))){throw '未找到旧版 data/activity.json，请选择实际使用过的旧版文件夹。'}
 $mutexId='Local\Afterhours-'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sourceData.ToLowerInvariant())) -replace '[^a-zA-Z0-9]','')
 $m=[Threading.Mutex]::new($false,$mutexId);$held=$false
 try{$held=$m.WaitOne(0);if(-not $held){throw '旧版程序仍在运行，请先退出旧版。'}}finally{if($held){$m.ReleaseMutex()};$m.Dispose()}
 $sourceRows=@(Read-MigrationRows $sourceData 'activity.json');$targetRows=@(Read-MigrationRows $targetData 'activity.json')
 if(-not $sourceRows.Count){throw '所选旧版没有历史记录，请检查是否选中了空的发布副本。'}
 $records=@{};foreach($r in $targetRows){$records["$($r.Date)|$($r.Process.ToLowerInvariant())"]=$r}
 $conflicts=0
 foreach($r in $sourceRows){$key="$($r.Date)|$($r.Process.ToLowerInvariant())";if($records.ContainsKey($key)){$old=$records[$key];if([double]$old.Foreground -ne [double]$r.Foreground -or [double]$old.Running -ne [double]$r.Running){$conflicts++}}}
 $sessions=@{};foreach($d in @($targetData,$sourceData)){foreach($r in @(Read-MigrationRows $d 'sessions.json')){$key="$($r.Process.ToLowerInvariant())|$($r.Start)";if(-not $sessions.ContainsKey($key) -or [double]$r.Seconds -gt [double]$sessions[$key].Seconds){$sessions[$key]=$r}}}
 $games=@{};foreach($d in @($sourceData,$targetData)){foreach($r in @(Read-MigrationRows $d 'games.json')){$games[$r.Process.ToLowerInvariant()]=$r}}
 $dates=@($sourceRows.Date|Sort-Object -Unique)
 [pscustomobject]@{Source=$sourceData;Target=$targetData;Rows=$sourceRows;TargetRecords=$records;Conflicts=$conflicts;Sessions=@($sessions.Values);Games=@($games.Values);Days=$dates.Count;From=$dates[0];To=$dates[-1];Seconds=[double](($sourceRows|Measure-Object Foreground -Sum).Sum)}
}
function Invoke-MigrationPlan($Plan,[switch]$PreferSource) {
 if($Plan.Conflicts -gt 0 -and -not $PreferSource){throw '发现重叠记录冲突，尚未导入。'}
 foreach($r in $Plan.Rows){$Plan.TargetRecords["$($r.Date)|$($r.Process.ToLowerInvariant())"]=$r}
 $backup=Join-Path $Plan.Target ('migration-backups\'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
 [void][IO.Directory]::CreateDirectory($backup)
 $files=@('activity.json','games.json','sessions.json');$existed=@{}
 foreach($f in $files){$path=Join-Path $Plan.Target $f;$existed[$f]=[IO.File]::Exists($path);if($existed[$f]){[IO.File]::Copy($path,(Join-Path $backup $f),$false)}}
 try{
  $values=@{ 'activity.json'=@($Plan.TargetRecords.Values|Sort-Object Date,Process);'games.json'=@($Plan.Games);'sessions.json'=@($Plan.Sessions|Sort-Object Start) }
  foreach($f in $files){$path=Join-Path $Plan.Target $f;$temp=$path+'.migration.tmp';[IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $values[$f] -Depth 8),[Text.UTF8Encoding]::new($true));if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,($path+'.migration.bak'))}else{[IO.File]::Move($temp,$path)}}
 }catch{foreach($f in $files){$path=Join-Path $Plan.Target $f;if($existed[$f]){[IO.File]::Copy((Join-Path $backup $f),$path,$true)}elseif([IO.File]::Exists($path)){[IO.File]::Delete($path)}};throw}
 $backup
}
