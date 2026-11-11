# 让 AI 安装 PC Hardware Workbench

把下面整段交给能够执行本地命令的 Codex 或其他 AI 助手。

```text
请在这台 Windows 电脑上安装 PC Hardware Workbench Skill。

项目地址：
https://github.com/Feng23-feng/pc-hardware-workbench

安装目标：
%USERPROFILE%\.codex\skills\pc-hardware-workbench

执行要求：
1. 先检查目标目录是否已经存在。
2. 如果不存在，下载 main 分支压缩包，只复制仓库中的
   skill\pc-hardware-workbench 到目标目录。
3. 如果已经存在，不要覆盖；先把它移动到同目录下带时间戳的备份，
   再安装新版本。
4. 安装完成后确认目标目录包含 SKILL.md、scripts 和 references。
5. 不要运行硬件采集器，不要请求管理员权限，不要修改 BIOS、驱动或系统设置。
6. 最后告诉我安装路径、备份路径（如有），以及应该如何重新启动 Codex。
```

也可以直接让 AI 执行安装脚本：

```powershell
$installer = Join-Path $env:TEMP "install-pc-hardware-workbench.ps1"
curl.exe -fsSL "https://raw.githubusercontent.com/Feng23-feng/pc-hardware-workbench/main/tools/install-skill.ps1" -o $installer
powershell -NoProfile -ExecutionPolicy Bypass -File $installer
```

如果已经安装过并需要更新，AI 应先向用户说明备份行为，再运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File $installer -Force
```

安装脚本只复制 Skill 文件，不执行硬件采集、不提权，也不会修改硬件设置。
