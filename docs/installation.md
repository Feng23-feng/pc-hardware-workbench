# 安装与升级

[中文](installation.md) | [English](en/installation.md)

## 系统要求

- Windows 10 或 Windows 11 x64；
- 自动采集需要 Windows PowerShell 5.1 或 PowerShell 7；
- 其他操作系统只提供手动排障指导，不自动读取硬件；
- 可选监控需要用户已经启动 LibreHardwareMonitor；本项目不会安装或启动它。

当前 PCHW `2.8.0` 是测试版，最新公开测试包集成 SkillDock `0.1.0-rc.3`，目前
没有正式版。PCHW Skill 与 Portable 源码未变化，因此继续提供各自的
`2.8.0-rc.2` 资产。干净 Windows 安装、卸载和完整用户签收继续作为发布门禁。

## 先选一种包

按使用场景安装对应的包。不要把同一个 PCHW Skill 的多个副本放进同一个宿主的
Skill 扫描目录。
普通用户默认选择不含面板的纯 PCHW Skill；只有明确需要网页操作面板时，再选择
SkillDock 面板包（需已安装 Codex）。没有 Agent，或希望完全不安装时，选择
PCHW Portable。

| 包 | 适用场景 | 包含 | 操作面板 |
| --- | --- | --- | --- |
| PCHW Skill（Codex / DSH / 其他 Agent 通用，无面板） | 普通用户默认选择；Codex 单独使用，或已有 DSH / 其他兼容 Agent 宿主 | 仅 PCHW Skill 发布子集 | 无 |
| PCHW Portable（独立 Windows，无需 Agent） | 没有 Codex / DSH，或不希望安装 Skill 与 Runtime | 独立菜单、采集、CSV 与证据工具 | 无 |
| SkillDock Runtime-only | 已安装兼容 PCHW Skill，只缺应用与 Node | SkillDock Runtime、Node.js 24.22.1 | 仅 Codex 当前对话 |
| SkillDock 面板包（用于 Codex） | 已安装 Codex Desktop，并明确需要图形操作面板 | PCHW Skill、SkillDock Runtime、安装入口 | 仅 Codex |

[下载最新测试版](https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v0.1.0-rc.3)：

```text
PCHW-Skill-2.8.0-rc.2.zip
pc-hardware-portable-v2.8.0-rc.2.zip
SkillDock-Runtime-0.1.0-rc.3-win-x64.zip
SkillDock-PCHW-0.1.0-rc.3-win-x64-user.zip
SHA256SUMS.txt
```

SkillDock 资产为 `0.1.0-rc.3`；PCHW Skill 与 Portable 资产继续使用未变化的
`2.8.0-rc.2`。clean Windows 安装、卸载和最终签收仍是 PENDING。不要把旧版本
ZIP、Skill 目录和 Runtime 混在一起。

<a id="pchw-portable"></a>

## PCHW Portable（独立 Windows，无需 Agent）

这个包不需要 Codex、DSH、API key、安装程序或管理员权限。校验 ZIP 后解压完整
目录，双击 `开始使用.cmd` 即可进入菜单。

便携版提供只读配置采集、排障、HWiNFO / PresentMon CSV、证据包、遥测图表和手动
调校指导，但不提供 SkillDock 面板或 Agent 对话能力。共享遥测分析器 `1.2.4`
支持 `Timestamp`、`DateTime`、`Date/Time`、`时间戳` 和 `日期时间` 列，并输出
实际采样跨度。

便携包完全在本地运行，不主动联网，不会自动修改 BIOS、固件、驱动、频率、电压、
功耗、风扇或内存时序。

## SkillDock 面板包（用于 Codex）

使用前需要安装 Codex Desktop。

### 安装

1. 下载 `SkillDock-PCHW-0.1.0-rc.3-win-x64-user.zip`。
2. 按 Release 中的 `SHA256SUMS.txt` 或 GitHub asset digest 核对 ZIP。
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

Runtime 程序备份在成功安装后轮转为最近一个可回退版本；更旧的
`Runtime-*` 程序目录会被清理。Task 数据、任务附件和迁移数据备份不参与这个
轮转，仍按卸载或显式清理流程处理。

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

### 本地存储

页面顶部的“本地存储”用于查看和清理 SkillDock 本机占用：

- “导出最近回退备份”会生成含受保护 Runtime 回退、共享 Node 引擎和逐文件
  SHA-256 清单的 ZIP；损坏或逃逸引擎目录的引用会 fail closed。
- Task/证据必须先导出一份与当前 State、Session 和事件计数绑定的 ZIP，并点击
  下载后，清理按钮才会解锁。
- 清理前还会二次确认。过期、哈希不符或导出后数据发生变化的文件不会删除 Task。
- 清理会保留 Agent Session、权限凭证、Runtime、共享引擎、安装日志和回退备份。

导出文件位于 `%LOCALAPPDATA%\SkillDock\storage-exports`。下载有效期 24 小时；
过期文件在 Runtime 启动或刷新存储面板时清理。默认卸载保留导出，显式
`-PurgeUserData` 才会删除。

<a id="pchw-skill-only"></a>

## PCHW Skill（Codex / DSH / 其他 Agent 通用，无面板）

这个包只包含 PCHW Skill，不是 SkillDock 面板包，也不安装 SkillDock
Runtime、Node 或 DSH 观察窗。它可用于 Codex、DSH 或其他兼容 Agent 宿主，适合
不需要面板的用户。把包内 `pc-hardware-workbench` 目录放到目标 Agent 的 Skill
扫描目录。

Codex 默认 Skill 目录：

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

设置 `CODEX_HOME` 时：

```text
%CODEX_HOME%\skills\pc-hardware-workbench
```

DSH 默认 Skill 目录：

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

PCHW Skill 可以使用配置读取、排障、聊天、采集和 CSV 分析，但没有本版 Codex
SkillDock 面板。DSH 适配细节见 [DSH adapter](../adapters/dsh/README.md)。

## SkillDock Runtime-only

仅在已经安装兼容 PCHW Skill、但缺少 SkillDock 应用和 Node 时使用。解压后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
```

安装完成后仍从 Codex 当前对话触发面板，不需要手动启动 `SkillDock.exe`。

## 验证安装

Codex core Skill：

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
Test-Path (Join-Path $skill "scripts")
Test-Path (Join-Path $skill "references")
```

前三项都应为 `True`。如果 Codex 中仍看不到 Skill，先重启 Codex。

SkillDock 面板包还应确认 Runtime 指针存在：

```powershell
$pointer = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-location.json"
Test-Path $pointer
```

不要把端口、令牌或本机绝对路径发布到 Issue 中。

## 更新与回滚

### SkillDock 面板包（用于 Codex）

再次运行新包中的 `Install.cmd`。安装器会：

- 比较并验证旧 Skill；
- 备份旧目录；
- 安装新 Skill；
- 备份旧 Runtime；
- 在冲突或失败时保留备份并回到对话。

### PCHW Skill（Codex / DSH / 其他 Agent 通用，无面板）

关闭宿主，将旧 Skill 目录移到备份位置，再安装新的 PCHW Skill 包。不要把两个
包含 `SKILL.md` 的版本同时留在 DSH 扫描根中。

## 卸载

### SkillDock 面板包（用于 Codex）

打开已安装的 SkillDock 程序目录，运行其中的 SkillDock 卸载脚本。默认卸载移除
程序和快捷入口，但保留 Task 数据、导出与备份。只有确认不再需要恢复时才彻底
清理数据。

### DSH

关闭 DSH 后删除：

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

## 支持矩阵

| 宿主 | PCHW 聊天、采集与 CSV | SkillDock 面板 |
| --- | --- | --- |
| Codex 当前用户对话 | 支持 | 支持，唯一承诺的面板宿主 |
| DeepSeek Harness | 支持 | 不提供 |
| 其他 Agent 宿主 | 可按其文件访问能力使用 Skill | 不承诺 |

## 已知限制

- `2.8.0` 目前只有测试版，没有正式版；干净 Windows 签收仍待完成。
- SkillDock 面板只支持 Codex 当前用户对话。
- Panel 不可用、权限被拒绝或工作区冲突时必须回到对话，不能暴露开发入口。
- 实时采集取决于 Windows 权限和宿主沙箱，不能把权限拒绝误报为缺件。
- 不自动修改 BIOS、固件、驱动、频率、电压、功耗、风扇或内存时序。
