param([switch]$DemoMode)
$ErrorActionPreference='Stop'
$dataDirectory=Join-Path $PSScriptRoot 'data'
[void][IO.Directory]::CreateDirectory($dataDirectory)
try {
 $arguments=@{}
 if($DemoMode){$arguments['DemoMode']=$true}
 & (Join-Path $PSScriptRoot 'Live.ps1') @arguments
} catch {
 $message=$_|Out-String
 $log=Join-Path $dataDirectory 'startup-error.log'
 [IO.File]::WriteAllText($log,$message,[Text.UTF8Encoding]::new($true))
 try {
  Add-Type -AssemblyName PresentationFramework
  [Windows.MessageBox]::Show("Afterhours 启动失败。`n`n错误已保存到：`n$log`n`n$($_.Exception.Message)",'Afterhours')|Out-Null
 } catch {}
 exit 1
}
