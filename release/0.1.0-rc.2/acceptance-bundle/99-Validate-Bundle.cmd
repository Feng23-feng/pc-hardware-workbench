@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp099-Validate-Bundle.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo Bundle validation failed. Stop and request a fresh copy.
) else (
  echo Bundle validation passed.
)
pause
exit /b %RC%
