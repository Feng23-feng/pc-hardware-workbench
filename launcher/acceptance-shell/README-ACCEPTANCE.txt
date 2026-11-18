SkillDock + PC Hardware Workbench 内部验收包

这个包只供干净 Windows 验收和内部诊断使用，不是普通用户安装包。
请勿把本目录重新命名为用户发布包，也不要替换成普通用户 README。

根目录结构
==========

README-ACCEPTANCE.txt
Start-Acceptance.cmd
payload\

Start-Acceptance.cmd
====================

双击根目录的 Start-Acceptance.cmd，执行以下阶段：

99-Validate-Bundle.ps1
00-Preflight.ps1
01-Install.ps1

它只允许严格 clean Profile。如果发现已有 PCHW Skill、SkillDock Runtime 或
备份，会停止安装，不会自动覆盖。

已有安装的升级诊断
==================

已有安装需要使用 payload\Start-Upgrade.cmd。该模式会：

- 备份旧版 PCHW Skill；
- 使用 staging 安装并验证新 Skill；
- 失败时恢复旧 Skill；
- 记录 Runtime 和迁移备份结果。

升级模式不是 clean Windows PASS。

payload 内容
============

payload 内含 99/00/01/02/03/04 阶段脚本、验收 fixture、证据说明、内部文档、
完整日志和固定的 safe-upgrade RC。

证据位置
========

payload\evidence\acceptance-start-result.json
payload\evidence\acceptance-start-<时间>\acceptance-start.log

完成页面流程后，在 payload 内依次运行：

02-Collect-Evidence.cmd
03-Uninstall.cmd
04-Package-Evidence.cmd

回传 04 生成的 evidence ZIP 和 SHA-256 sidecar，不要回传整个验收目录。

页面验收
========

- 在当前 Codex 对话中询问是否打开电脑硬件工作台，并明确同意；
- 上传验收 fixture CSV；
- 只点一次“仅本次允许”；
- 确认真实 SVG、具体判断、证据、不确定性、低风险建议和复制操作；
- 结果自动出现，不按 F5；
- 重启后仍是同一 Task、附件、artifact 和结论。

默认 LOCALAPPDATA 不可写时，必须记录安全回退。Ask-for-approval 下自动浏览器
交接失败时，记录“手动打开面板”、manual open URL 或本地 .url，不能把自动打开
写成 PASS。

安全边界
========

不自动修改 BIOS、固件、驱动、频率、电压、功耗、风扇、内存时序或系统设置。
不创建第二个 Thread，不使用 API 或 headless browser 代替真人页面操作。
