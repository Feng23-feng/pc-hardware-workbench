@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp003-Uninstall.ps1" -AcceptDedicatedProfileCleanup
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Uninstall or residue verification failed. Keep the evidence directory.
) else (
  echo Uninstall and residue verification completed.
)
pause
exit /b %RC%
