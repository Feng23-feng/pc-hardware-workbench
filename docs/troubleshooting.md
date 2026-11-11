# 常见问题

## Codex 中看不到 Skill

确认目录存在：

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
```

返回 `False` 时重新运行安装器。返回 `True` 但 Codex 中仍不可用时，重启 Codex
后再次输入 `$pc-hardware-workbench`。

## 安装脚本被阻止

安装不需要管理员权限。使用普通 PowerShell 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $installer
```

如果目标已存在，先阅读脚本输出中的备份路径，再用 `-Force` 更新。

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

## 测试环境缺失

首次验证前运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\validate-skill.ps1 -Bootstrap
```

后续验证可以离线运行。完整命令见 [测试与发布检查](testing.md)。

## 安全报告

不要在公开 Issue 中上传硬件日志、截图、设备序列号或本地路径。私下报告方式见
[SECURITY.md](../SECURITY.md)。
