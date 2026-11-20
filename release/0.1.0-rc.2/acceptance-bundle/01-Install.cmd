@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp001-Install.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Installation failed. Keep the evidence directory and report the error.
) else (
  echo Installation completed.
)
pause
exit /b %RC%
