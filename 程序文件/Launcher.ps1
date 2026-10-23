param([switch]$DemoMode)
$ErrorActionPreference='Stop'
$dataDirectory=Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
[void][IO.Directory]::CreateDirectory($dataDirectory)
try {
 $arguments=@{DataDirectory=$dataDirectory}
 if($DemoMode){$arguments['DemoMode']=$true}
 & (Join-Path $PSScriptRoot 'Live.ps1') @arguments
} catch {
 $message=$_|Out-String
 # 2.1: distinguish a crash while running from a failure to start.
 $started=[bool]$global:AfterhoursStarted
 $log=Join-Path $dataDirectory $(if($started){'runtime-error.log'}else{'startup-error.log'})
 if($started){[IO.File]::AppendAllText($log,$message,[Text.UTF8Encoding]::new($false))}else{[IO.File]::WriteAllText($log,$message,[Text.UTF8Encoding]::new($true))}
 try {
  Add-Type -AssemblyName PresentationFramework
  $title=if($started){'Afterhours 运行中意外退出。'}else{'Afterhours 启动失败。'}
  [Windows.MessageBox]::Show("$title`n`n错误已保存到：`n$log`n`n$($_.Exception.Message)",'Afterhours')|Out-Null
 } catch {}
 exit 1
}
