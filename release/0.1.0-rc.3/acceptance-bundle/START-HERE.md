# SkillDock 干净 Windows 验收包

外层 `README.txt` 和 `README.en.txt` 是普通用户使用说明；本文件是内部验收
清单和诊断说明。

这个目录只用于干净 Windows 用户或 VM 的人工验收，**不是公开发布包**。
当前候选 RC 位于本文件同目录。文件名、字节数和 SHA-256 以
`OUTER-BUNDLE-INFO.json`、相邻 `.sha256` sidecar 和 verification JSON 为准。

## 当前 RC

```text
identity: OUTER-BUNDLE-INFO.json + adjacent sidecar
state:    clean-local-committed-clean-windows-pending
```

## 主流程：只双击一个入口

把整个 `SkillDockRC` 文件夹留在 Windows 本机，不要上传到 Codex 对话里。
安装阶段回到外层 `SkillDockRC` 目录，只双击：

```text
Start-Acceptance.cmd
```

它会严格按顺序执行：

```text
99-Validate-Bundle.ps1
00-Preflight.ps1
01-Install.ps1
```

任一步失败会立即停止，并显示失败阶段、退出码和日志路径。结果写入：

```text
payload\evidence\acceptance-start-result.json
payload\evidence\acceptance-start-<时间>\acceptance-start.log
```

只有窗口显示 `Acceptance startup: PASS` 后才进入下一节。全部页面验收完成后，
再把 `04-Package-Evidence` 生成的 evidence ZIP 和 sidecar 带回对话。

如果该 Windows Profile 已经装过老款 PCHW Skill 或 SkillDock Runtime，不要
使用严格的 `Start-Acceptance.cmd`。在普通用户升级场景中回到外层目录运行：

```text
payload\Start-Upgrade.cmd
```

升级模式仍会校验 Bundle 和 Preflight，但允许已有安装。旧 Skill 会先移动到
`.codex\skills\.skilldock-backups`，新 Skill 校验失败时自动恢复旧目录。
这属于正常升级验证，不是 clean Windows PASS。

## 开始前

必须使用一个全新的 Windows 11 x64 用户 Profile，或干净 VM。
该 Profile 中不能有旧 SkillDock、PCHW Skill、Runtime、Task 或历史权限。

先安装并登录：

- Microsoft Edge
- Codex Desktop

不要在普通主账户中运行本验收。不要复制旧 `.codex`、SkillDock 数据或凭据。

## 高级诊断：分开执行三个阶段

通常不需要运行本节。脚本失败、需要定位具体阶段时才在 `payload` 内分开运行：

```text
99-Validate-Bundle.cmd
00-Preflight.cmd
01-Install.cmd
```

`01-Install.cmd` 会：

1. 再次运行预检；
2. 解压最终 RC 到 `payload\stage`；
3. 安装 PCHW 2.8.0 Skill；
4. 安装 SkillDock Runtime 0.1.0-rc.3；
5. 记录安装日志和版本状态。

脚本不会启动真实 Thread，也不会手动打开 SkillDock。

## 3. 主用户路径

在新 Profile 的 Codex 当前对话中提出硬件问题，例如：

```text
这份 HWiNFO CSV 显示游戏约二十分钟后掉帧。
可以打开图形化分析吗？
```

同意后应由 Skill 自动打开 SkillDock。不要手动寻找 runner、env、端口或测试入口。
不要由 Agent 调用 `/api/submit`、analysis API 或权限 decide API 代替你的页面点击。

上传：

```text
acceptance-assets\ACCEPTANCE-FIXTURE-NOT-FOR-DISTRIBUTION.csv
```

只选择一次“仅本次允许”。确认页面出现：

- 当前 Task 和附件；
- “电脑硬件工作台”；
- 真实 SVG；
- 针对 CSV 的具体判断；
- 支持、冲突、背景证据；
- 不确定性和两到三条低风险建议；
- 两个复制操作。

Agent 写回结果后，页面应自动从等待状态更新到可查看结果。

如果点击“分析这份数据”后没有出现权限卡，或时间线里没有新的
`permission.requested`，本轮判为失败候选，不要用 API 补齐。

## 3A. 默认路径与浏览器隔离

必须先测试默认 `%LOCALAPPDATA%\SkillDock` 路径。Ask for approval 模式下若
ACL 仍拒绝，应看到 `runtime_access_blocked` 或安全回退，并回到当前对话。
只有用户明确再次同意后，才可使用 Public 便携数据根；该轮必须标记为
`permission_fallback`，不能算默认 clean PASS。

浏览器按以下顺序分别记录，不要因为一张崩溃页直接判产品结论：

1. 普通 Edge 打开普通网页；
2. 干净 Edge Profile 打开普通网页；
3. 在已运行的 Edge 中手动粘贴 SkillDock URL；
4. 由 Skill 调用交互式 `explorer.exe` 打开 SkillDock URL；Explorer 不能隐藏。

打开 URL 使用短期一次性 `open_id`，不再在地址栏携带超长签名 token。
只有页面真正加载并回执 handoff probe 后，启动器才算成功。

如果自动 Explorer 交接 6 秒内没有 ACK，启动器应返回：

- `interactive_desktop_unavailable`
- `manual_open_required=true`
- `manual_open_url`
- `manual_open_file`

此时页面会明确提示“手动打开面板”。点击短 URL 或本地 `.url` 文件后，
同一 handoff probe 应收到 ACK。不要把自动失败伪装成成功。

若出现 `msedge.exe` `0x80000003` 或 Windows Error Reporting
`RADAR_PRE_LEAK_64`，保留 Application/WER 事件，并将浏览器门禁标为待定。

关闭并重启同一个 Runtime，再从 Codex 当前对话恢复。确认仍是同一 Task、
同一 artifact 和同一结论，且没有创建新 Thread。

## 4. 保存截图

把截图放入 `payload\evidence`，严格使用以下文件名：

```text
10-permission-allow-once.png
11-answer-card.png
12-chart-evidence.png
20-restart-same-task.png
```

截图只截 SkillDock 页面或 Codex 当前对话，不要包含密码、token、Cookie、
邮箱、其他 Task 或个人文件。

## 5. 收集环境证据

在 `payload` 内运行：

```text
02-Collect-Evidence.cmd
```

脚本会记录 Windows、Edge、Codex、已安装 Runtime、进程和截图哈希。它不会读取
capability token、cookie 或聊天正文。

## 6. 卸载与残留检查

确认截图和状态已保存后，在 `payload` 内运行：

```text
03-Uninstall.cmd
```

它只在预检记录的同一个专用 Profile 中运行，并明确清理该验收 Profile 的：

- SkillDock Runtime；
- Runtime 数据与备份；
- RC 安装的 PCHW Skill 与 Skill 备份。

完成后补一张：

```text
30-uninstall-clean.png
```

可以是卸载命令结果，或显示 Skill/Runtime/Node 进程均不存在的窗口。

## 7. 打包证据

在 `payload` 内运行：

```text
04-Package-Evidence.cmd
```

完成后把 `payload` 中的以下两个文件带回：

```text
SkillDock-RC-Evidence-<时间>.zip
SkillDock-RC-Evidence-<时间>.zip.sha256
```

如果任一脚本报错，不要绕过。保留 `payload\evidence` 目录和错误文本，原样带回即可。

## 禁止事项

- 不使用当前已有 SkillDock/PCHW 的主 Profile 代替干净环境。
- 不通过 API、headless browser 或测试 harness 替代真实页面验收。
- 不通过 submit、analysis 或 permission decide API 替代用户点击。
- 不创建额外 Codex Thread。
- 不自动修改 BIOS、固件、驱动、频率、电压、功耗、风扇或内存时序。
- 不把测试 CSV、安装脚本或验收截图放回正式 RC ZIP。
