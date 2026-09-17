@echo off
chcp 65001 >nul
title Afterhours 诊断启动
cd /d "%~dp0"
echo 正在以前台诊断模式启动 Afterhours...
echo 如果启动失败，请保留本窗口内容和 data\startup-error.log。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Launcher.ps1"
set "exitCode=%errorlevel%"
if not "%exitCode%"=="0" (
  echo.
  echo Afterhours 启动失败，退出代码：%exitCode%
  echo 错误日志：%~dp0data\startup-error.log
  pause
)
exit /b %exitCode%
