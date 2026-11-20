@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp002-Collect-Evidence.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Evidence collection failed.
) else (
  echo Evidence collection completed.
)
pause
exit /b %RC%
