@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Acceptance.ps1" -UpgradeExisting
set "ACCEPTANCE_EXIT_CODE=%ERRORLEVEL%"
if not "%ACCEPTANCE_EXIT_CODE%"=="0" (
  echo.
  echo SkillDock existing-install upgrade FAILED with exit code %ACCEPTANCE_EXIT_CODE%.
  echo Review evidence\acceptance-start-result.json and the newest acceptance-start log.
) else (
  echo.
  echo SkillDock existing-install upgrade completed successfully.
  echo Continue in the current Codex conversation.
)
echo.
pause
exit /b %ACCEPTANCE_EXIT_CODE%
