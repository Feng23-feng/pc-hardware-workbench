# 安装与升级

## 系统要求

- Windows 10 或 Windows 11；
- 自动采集需要 Windows PowerShell 5.1 或 PowerShell 7；
- 其他操作系统只提供手动排障指导，不自动读取硬件；
- 可选监控需要已经运行的 LibreHardwareMonitor；本项目不会安装或启动它。

## Codex：一键安装

安装脚本会下载 `main` 分支压缩包，只把
`skill/pc-hardware-workbench` 复制到 Codex Skill 目录，不会运行硬件采集器。

1. 在普通 PowerShell 中下载安装脚本。
2. 运行安装脚本。
3. 重启 Codex。
4. 输入 `$pc-hardware-workbench` 验证 Skill 已出现。

```powershell
$installer = Join-Path $env:TEMP "install-pc-hardware-workbench.ps1"
curl.exe -fsSL "https://raw.githubusercontent.com/Feng23-feng/pc-hardware-workbench/main/tools/install-skill.ps1" -o $installer
powershell -NoProfile -ExecutionPolicy Bypass -File $installer
```

默认安装到：

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

升级时加 `-Force`。脚本会把旧版本移出 Codex 的 Skill 扫描目录，再安装新版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Force
```

默认备份位置：

```text
%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\
```

不要把旧版本留在 `%USERPROFILE%\.codex\skills` 下。Codex 会扫描该目录中的
`SKILL.md`；带原清单的旧备份会和当前版本形成同名 Skill，造成路由歧义或启动警告。
新版安装器还会把旧安装器留在 `skills` 目录内的 `.backup-*` 副本迁移到上述
备份目录。需要自定义位置时，使用 `-BackupRoot <目录>`，该目录不能位于 Skill
扫描根内，也不能通过符号链接、目录联接或其他重解析点指向扫描根。

## Codex：手动安装

从源码安装时，复制整个 Skill 目录：

```text
skill\pc-hardware-workbench
```

目标位置：

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

不要只复制 `SKILL.md`；入口依赖同目录下的 `scripts/`、`references/` 和 `assets/`。

## Codex：从 Release ZIP 安装

每个测试版 Release 提供两个 Codex 附件：

1. 打开 GitHub Releases。
2. 选择 `pc-hardware-workbench-v<版本>-installer.zip`，解压后运行
   `Install-PC-Hardware-Workbench.cmd`，适合自动安装和覆盖升级。
3. 或选择 `pc-hardware-workbench-v<版本>-manual.zip`，解压后得到
   `pc-hardware-workbench/`，将它移动到
   `%USERPROFILE%\.codex\skills\pc-hardware-workbench`，适合手动管理安装。
4. 自动安装器发现旧版本时，会先放到
   `%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\`。
5. 重启 Codex，输入 `$pc-hardware-workbench`。

`installer.zip` 内保留 `安装说明.txt` 和 `BUILD-INFO.json`，可以核对版本、提交
和构建时间；`manual.zip` 内只有 Skill 目录。不要直接把 ZIP 文件放进 Skill
目录；Codex 需要的是解压后的 `pc-hardware-workbench` 文件夹。

## 让 AI 安装

完整提示词见 [AI 安装提示词](AI-INSTALL.md)。提示词明确要求 AI：

- 安装前检查目标目录；
- 不覆盖现有版本，先把旧版移出 Skill 扫描目录；
- 只复制 Skill 树；
- 验证 `SKILL.md`、`scripts/` 和 `references/`；
- 不运行采集器、不提权、不修改硬件设置。

## DeepSeek Harness

适配说明见 [`adapters/dsh/README.md`](../adapters/dsh/README.md)。

Skill 默认安装目录：

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

如果设置了 `DSH_HOME`，使用：

```text
%DSH_HOME%\skills\pc-hardware-workbench
```

调用方式：

```text
/pc-hardware-workbench
```

Harness 首次加载时可以选择 `AGENTS.md` 或 `DEEPSEEK.md` 作为项目适配入口。

## Portable Windows 工具

不需要 Skill 宿主时，可以运行独立版本：

```powershell
cd portable
.\开始使用.cmd
```

非硬件自检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -SelfTest
```

实机采集必须显式提供 `-AllowLiveCollector`、选择隐私模式并确认授权。

## 验证安装

检查关键文件：

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
Test-Path (Join-Path $skill "scripts")
Test-Path (Join-Path $skill "references")
```

三项都应为 `True`。如果 Codex 中仍看不到 Skill，先重启应用。

## 更新与回滚

- 更新使用安装脚本和 `-Force`；
- 安装脚本会把旧版本移动到 `.codex\skill-backups\pc-hardware-workbench\`；
- 回滚时关闭 Codex，将当前目录移到别处，再把备份目录改回
  `.codex\skills\pc-hardware-workbench`；
- 同一时间只保留一个包含 `SKILL.md` 的活动 Workbench 目录，避免同名 Skill
  被重复发现；
- 不要删除或覆盖正在使用中的旧版本，除非已经确认备份存在。

## 卸载

关闭 Codex 后，删除目标 Skill 目录：

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

删除前可以先把目录移动到其他备份位置。隐私和数据边界见
[隐私与安全边界](privacy-and-safety.md)。
