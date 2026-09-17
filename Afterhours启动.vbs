Option Explicit
Dim shell, fso, basePath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
basePath = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & fso.BuildPath(basePath, "Launcher.ps1") & """"
If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "demomode" Then command = command & " -DemoMode"
End If
shell.Run command, 0, False
