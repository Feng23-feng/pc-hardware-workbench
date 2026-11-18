# 安装与升级

[中文](installation.md) | [English](en/installation.md)

## 系统要求

- Windows 10 或 Windows 11 x64；
- 自动采集需要 Windows PowerShell 5.1 或 PowerShell 7；
- 其他操作系统只提供手动排障指导，不自动读取硬件；
- 可选监控需要用户已经启动 LibreHardwareMonitor；本项目不会安装或启动它。

当前 `2.8.0` 仍是测试版，尚未正式发布。干净 Windows 安装、卸载和完整用户签收
继续作为发布门禁。

## 先选一种包

按使用场景安装对应的包。不要把同一个 PCHW Skill 的多个副本放进同一个宿主的
Skill 扫描目录。

| 包 | 适用场景 | 包含 | 操作面板 |
| --- | --- | --- | --- |
| 简易便携包 | 不安装 Skill 宿主 | PowerShell 采集、CSV、图表和报告 | 无 SkillDock，使用本地菜单 |
| DSH core-only 包 | DeepSeek Harness | PCHW Skill、DSH 适配 | 无 SkillDock |
| Codex + SkillDock 包 | Codex Desktop 当前对话 | PCHW Skill、SkillDock Runtime、单一安装入口 | 仅 Codex |

当前候选资产名称：

```text
pc-hardware-portable-v2.8.0.zip
pc-hardware-workbench-deepseek-harness-v2.8.0.zip
SkillDock-PCHW-0.1.0-rc.1-win-x64-user.zip
```

2.8.0 尚未正式发布；只使用 Releases 中实际存在的文件和对应 SHA-256 sidecar，
不要把旧版本的 ZIP、Skill 目录和 Runtime 混在一起。

## Codex + SkillDock

### 安装

1. 下载 `SkillDock-PCHW-0.1.0-rc.1-win-x64-user.zip`。
2. 核对 ZIP 与 `.sha256` sidecar。
3. 解压完整目录。
4. 双击 `Install.cmd`。
5. 等待安装完成，然后重新打开 Codex。

安装器会自动判断当前环境：

- 没有旧版 PCHW Skill 时执行全新安装；
- 已有旧版时先备份，再执行安全升级；
- 替换或后续 Runtime 验证失败时恢复旧 Skill；
- 不需要用户选择 clean 或 upgrade 模式。

安装器只复制 PCHW Skill 和 SkillDock Runtime，不运行硬件采集器，不请求管理员
权限，不自动启动 `SkillDock.exe`。

### 安装位置

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
%LOCALAPPDATA%\SkillDock
```

已有 Skill 的备份位于：

```text
%USERPROFILE%\.codex\skills\.skilldock-backups
```

Runtime 与迁移数据的备份位于：

```text
%LOCALAPPDATA%\SkillDockBackups
```

### 当前对话打开面板

安装后不需要手动寻找 runner、端口、token 或环境变量。在 Codex 当前对话中说：

```text
我玩游戏二十分钟后开始掉帧，这是 HWiNFO CSV。可以打开图形化分析吗？
```

同意后，页面应带入当前 Task、问题和支持的附件。首次本地分析选择一次
“仅本次允许”，即可查看 SVG、判断、支持与冲突、不确定性和低风险建议。

如果 Ask-for-approval 模式使自动打开失败，使用提示中的“手动打开面板”短期链接
或本地 `.url` 快捷方式。结果返回后页面会自动更新。

关闭并重启后，同一 Task、附件、图表和结论应恢复，不创建第二个 Thread。

## DeepSeek Harness

DSH 使用 core-only 包，不安装 SkillDock Runtime。

默认 Skill 目录：

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

设置 `DSH_HOME` 时：

```text
%DSH_HOME%\skills\pc-hardware-workbench
```

调用方式：

```text
/pc-hardware-workbench
```

DSH 可以使用配置读取、排障、聊天、采集和 CSV 分析，但没有本版 Codex
SkillDock 面板。适配细节见 [DSH adapter](../adapters/dsh/README.md)。

## 简易便携包

不需要 Codex、DSH 或 SkillDock。解压后运行：

```powershell
cd portable
.\开始使用.cmd
```

在菜单中选择标准或隐私脱敏模式，再明确同意只读采集。便携包只在本机处理数据；
可选图表与报告保存在用户选择的本地目录。

## 验证安装

Codex core Skill：

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
Test-Path (Join-Path $skill "scripts")
Test-Path (Join-Path $skill "references")
```

前三项都应为 `True`。如果 Codex 中仍看不到 Skill，先重启 Codex。

Codex + SkillDock 还应确认 Runtime 指针存在：

```powershell
$pointer = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-location.json"
Test-Path $pointer
```

不要把端口、令牌或本机绝对路径发布到 Issue 中。

## 更新与回滚

### Codex + SkillDock

再次运行新包中的 `Install.cmd`。安装器会：

- 比较并验证旧 Skill；
- 备份旧目录；
- 安装新 Skill；
- 备份旧 Runtime；
- 在冲突或失败时保留备份并回到对话。

### DSH

关闭 DSH，将旧 Skill 目录移到备份位置，再安装新 core-only 包。不要把两个包含
`SKILL.md` 的版本同时留在 DSH 扫描根中。

## 卸载

### Codex + SkillDock

打开已安装的 SkillDock 程序目录，运行其中的 SkillDock 卸载脚本。默认卸载移除
程序和快捷入口，但保留 Task 数据与备份。只有确认不再需要恢复时才彻底清理数据。

### DSH

关闭 DSH 后删除：

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

### 便携包

先确认没有正在运行的采集或报告进程，再删除解压目录。用户自行选择的报告目录
不会被便携包自动清理。

## 支持矩阵

| 宿主 | PCHW 聊天、采集与 CSV | SkillDock 面板 |
| --- | --- | --- |
| Codex 当前用户对话 | 支持 | 支持，唯一承诺的面板宿主 |
| DeepSeek Harness | 支持 | 不提供 |
| 其他 Agent 宿主 | 可按其文件访问能力使用 Skill | 不承诺 |
| 简易便携包 | 不依赖 Skill 宿主 | 无 SkillDock，独立本地工具 |

## 已知限制

- `2.8.0` 尚未正式发布，干净 Windows 签收仍待完成。
- SkillDock 面板只支持 Codex 当前用户对话。
- Panel 不可用、权限被拒绝或工作区冲突时必须回到对话，不能暴露开发入口。
- 实时采集取决于 Windows 权限和宿主沙箱，不能把权限拒绝误报为缺件。
- 不自动修改 BIOS、固件、驱动、频率、电压、功耗、风扇或内存时序。
