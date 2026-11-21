@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp004-Package-Evidence.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Evidence packaging failed. Review the error and evidence directory.
) else (
  echo Evidence packaging completed.
)
pause
exit /b %RC%
