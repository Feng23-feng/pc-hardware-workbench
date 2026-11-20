@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp000-Preflight.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Preflight failed. Do not continue.
) else (
  echo Preflight passed.
)
pause
exit /b %RC%
