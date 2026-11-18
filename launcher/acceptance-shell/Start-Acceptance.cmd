@echo off
setlocal
set "ENTRY=%~dp0payload\Start-Acceptance.ps1"
if not exist "%ENTRY%" (
  echo.
  echo SkillDock acceptance payload is missing.
  echo Request a fresh copy of this bundle.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ENTRY%"
set "ACCEPTANCE_EXIT_CODE=%ERRORLEVEL%"
if not "%ACCEPTANCE_EXIT_CODE%"=="0" (
  echo.
  echo SkillDock acceptance startup FAILED with exit code %ACCEPTANCE_EXIT_CODE%.
  echo Review payload\evidence\acceptance-start-result.json and the newest log.
) else (
  echo.
  echo SkillDock acceptance startup completed successfully.
  echo Continue in the current Codex conversation.
)
echo.
pause
exit /b %ACCEPTANCE_EXIT_CODE%
