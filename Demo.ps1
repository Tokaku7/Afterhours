# Explicitly synthetic sample history. Never merged into data/activity.json.
function New-DemoHistory {
 $result=@{}
 $random=[Random]::new(915)
 $games=@(@{Name='剑网三';Process='demo-jx3'},@{Name='守望先锋';Process='demo-overwatch'},@{Name='DJMAX RESPECT V';Process='demo-djmax'},@{Name='A Dance of Fire and Ice';Process='demo-adofai'})
 for($ago=55;$ago -ge 0;$ago--){
  if($ago -gt 0 -and $random.NextDouble() -lt 0.25){continue}
  $date=[datetime]::Today.AddDays(-$ago).ToString('yyyy-MM-dd')
  $count=if($ago -eq 0){3}else{$random.Next(1,4)}
  for($index=0;$index -lt $count;$index++){
   $game=$games[($ago+$index)%$games.Count]
   $seconds=$random.Next(12,145)*60
   $result["$date|$($game.Process)"]=[pscustomobject]@{Date=$date;Name=$game.Name;Process=$game.Process;Foreground=[double]$seconds;Running=[double]($seconds+$random.Next(2,28)*60);Source='示例数据'}
  }
 }
 return $result
}
function New-DemoSessions($history){
 $random=[Random]::new(917);$result=@()
 foreach($record in @($history.Values|Sort-Object Date)){
  $date=[datetime]$record.Date;$roll=$random.NextDouble()
  $hour=if($roll -lt 0.62){$random.Next(19,23)}elseif($roll -lt 0.85){$random.Next(13,18)}else{$random.Next(9,13)}
  $start=$date.AddHours($hour).AddMinutes($random.Next(0,50));$end=$start.AddSeconds($record.Foreground)
  $result+=[pscustomobject]@{Name=$record.Name;Process=$record.Process;Start=$start.ToString('o');End=$end.ToString('o');Seconds=[double]$record.Foreground}
 }
 return $result
}
