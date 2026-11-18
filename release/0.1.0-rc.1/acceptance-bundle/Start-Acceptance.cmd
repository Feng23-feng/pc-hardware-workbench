@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Acceptance.ps1"
set "ACCEPTANCE_EXIT_CODE=%ERRORLEVEL%"
if not "%ACCEPTANCE_EXIT_CODE%"=="0" (
  echo.
  echo SkillDock acceptance startup FAILED with exit code %ACCEPTANCE_EXIT_CODE%.
  echo Review evidence\acceptance-start-result.json and the newest acceptance-start log.
) else (
  echo.
  echo SkillDock acceptance startup completed successfully.
  echo Continue in the current Codex conversation.
)
echo.
pause
exit /b %ACCEPTANCE_EXIT_CODE%
