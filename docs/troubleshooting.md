# 常见问题

## 不确定该下载哪个包

- 使用 Codex、DSH 或其他兼容 Agent 宿主，只缺 Skill：使用通用 PCHW Skill（无面板）；
- 没有 Codex / DSH，或不希望安装 Skill 与 Runtime：使用 PCHW Portable；
- 已安装兼容 PCHW Skill，只缺 SkillDock 应用与 Node：使用 Runtime-only；
- 使用 Codex Desktop 并希望从当前对话打开操作面板：使用集成包。

2.9.3 是当前 PCHW Skill/Portable 测试版。当前公开 SkillDock
测试包是 `0.1.0-rc.7 + PCHW 2.9.3`，并机器校验 UI `1.2`、事件 `1.0`
与 required capabilities；`0.1.0-rc.5 + PCHW 2.9.0` 和
`0.1.0-rc.4 + PCHW 2.8.0` 作为历史测试线保留。rc.7 的 Clean Windows 签收仍为
PENDING。不要把不同版本 Skill 混装。

## Codex 中看不到 Skill

确认目录存在：

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
```

返回 `False` 时重新运行安装器。返回 `True` 但 Codex 中仍不可用时，重启 Codex
后再次输入 `$pc-hardware-workbench`。

## SkillDock 面板包无法开始安装

确认已解压完整 ZIP，并双击根目录 `Install.cmd`。安装不需要管理员权限，也不应
要求用户手动启动 `SkillDock.exe`、寻找 runner、设置端口或环境变量。

如果杀毒软件阻止脚本，先确认文件哈希与 Release sidecar 一致，再检查隔离记录。
不要从第三方镜像下载安装包。

已有旧版 PCHW Skill 时，安装器会自动备份并升级；不要先手动删除旧 Skill。备份
位置是 `%USERPROFILE%\.codex\skills\.skilldock-backups`。

## 硬件采集出现权限拒绝

先在普通、非提权 PowerShell 中重试。Agent 沙箱可能限制 CIM、存储或显示器信息
读取；只有仍然取决于权限的字段才值得由用户主动启动一次提权 PowerShell。

Skill 不会自行启动 UAC，也不会因为提权而获得固件隐藏的温度、时钟或风扇数据。

## LHM 没有数据

确认：

- LibreHardwareMonitor 已经由用户启动；
- Web Server 已启用并只绑定 loopback；
- 用户已经明确同意读取；
- 请求没有使用非 loopback 主机。

本项目不会安装、启动或配置 LHM。

## SkillDock 面板没有自动打开

如果 Codex 使用 “Ask for approval” 模式，自动浏览器交接可能不可用。此时：

1. 查看 Skill 是否提示“手动打开面板”；
2. 使用提示中的短期链接或本地 `.url` 快捷方式；
3. 在打开的同一面板中选择 CSV 并继续；
4. 不要创建第二个 Thread，也不要寻找开发入口。

如果默认 Runtime 目录不可写、面板无法启动或已有其他工作区，保留在当前 Codex
对话即可。聊天分析与安全建议不应因为页面失败而中断。

## 页面一直停在等待状态

当前版本通常会在本地分析完成后自动显示结果。如果超过等待窗口仍没有结果：

- 确认权限卡已经选择“仅本次允许”；
- 确认当前对话仍是原来的 Task；
- 不要把旧 artifact 或旧 Task 的结论当成本次结果；
- 在 Skill 提供的范围内回到当前对话继续，不创建第二个 Thread。

## 权限卡里没有“同一附件后续分析”

这是首次分析的正常状态。首次只提供“仅本次允许”和“拒绝”。只有同一 Task
中的同一附件已经成功完成一次一次性分析后，下一次对同一 CSV 的重复分析才会
出现该选项；更换附件时仍应重新选择“仅本次允许”。

## CSV 被拒绝

遥测分析不接受 UNC 路径、映射网络盘、云占位文件、符号链接、目录联接和重解析点。
先把文件复制到普通本地目录，再重新选择。

## GPU 调参被阻断

常见原因包括：

- 显卡型号未知或属于专业卡、核显、虚拟适配器；
- 当前控制值或报告新鲜度未提供；
- 缺少稳定基线、固定负载或恢复配置；
- 存在未解释的蓝屏、驱动重置或硬件风险。

先补齐门禁信息，不要通过更换说法要求跳过检查。

## 安全报告

不要在公开 Issue 中上传硬件日志、截图、设备序列号或本地路径。私下报告方式见
[SECURITY.md](../SECURITY.md)。
