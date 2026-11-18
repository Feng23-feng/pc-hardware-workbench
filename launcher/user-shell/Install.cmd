@echo off
setlocal
chcp 65001 >nul
set "ENTRY=%~dp0payload\Install-User.ps1"
if not exist "%ENTRY%" (
  echo.
  echo 安装文件不完整。Installation files are incomplete.
  echo 请重新解压完整安装包。Please extract the complete package again.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ENTRY%"
set "INSTALL_EXIT_CODE=%ERRORLEVEL%"
if not "%INSTALL_EXIT_CODE%"=="0" (
  echo.
  echo 安装失败。Installation failed with exit code %INSTALL_EXIT_CODE%.
  echo 日志位置 / Logs: %LOCALAPPDATA%\SkillDock\install-logs
) else (
  echo.
  echo 安装完成。Installation completed.
  echo 请回到当前 Codex 对话使用电脑硬件工作台。
  echo Continue in the current Codex conversation.
)
echo.
pause
exit /b %INSTALL_EXIT_CODE%
