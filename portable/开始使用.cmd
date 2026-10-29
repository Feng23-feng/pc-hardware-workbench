@echo off
chcp 65001 >nul
title 电脑硬件便携工具包
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 (
  echo.
  echo 工具异常退出，请查看上面的错误信息。
  pause
)
