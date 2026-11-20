# Evidence checklist

必需结构化文件：

```text
evidence\acceptance-start-result.json
evidence\00-preflight.json
evidence\01-install-result.json
evidence\02-environment.json
evidence\03-uninstall-result.json
```

`acceptance-start-result.json` 必须为 `passed`，并指向对应的
`acceptance-start-<时间>\acceptance-start.log`。

必需截图：

```text
evidence\10-permission-allow-once.png
evidence\11-answer-card.png
evidence\12-chart-evidence.png
evidence\20-restart-same-task.png
evidence\30-uninstall-clean.png
```

人工确认：

```text
- Skill 从 Codex 当前对话触发，而不是手动启动开发入口
- 页面带入当前 Task 和附件
- 只消费一次 one-time permission
- SVG 是真实图形，不是 artifact 名称占位
- 结论直接回答 CSV 中的掉帧问题
- 支持/冲突/背景、不确定性、低风险建议均可见
- 两个复制操作可用
- Agent 写回后页面自动出现结果
- 点击分析后出现新的 permission.requested，且“仅本次允许”是真人页面点击
- submit、analysis、permission decide API 没有被 Agent 代替点击
- 默认 Runtime ACL 结果已记录；Public portable 只标为 fallback
- 普通 Edge、干净 Edge、手动 root/panel URL、Explorer 交接四条路径已分别记录
- Explorer 交接返回成功前，页面已回执短期 handoff probe
- 浏览器地址栏只出现短期 open_id，不出现超长签名 token
- Explorer URL 交接不是隐藏窗口启动
- 自动 ACK 超时时返回 manual_open_required、manual_open_url 和 manual_open_file
- 手动 URL 或 .url 文件打开后，同一 probe 的 ACK 为 acknowledged
- 若出现 Edge 0x80000003/RADAR_PRE_LEAK_64，WER 事件已保留且未强行判 PASS
- Runtime 重启后同一 Task、artifact 和结论恢复
- 没有创建第二个 Thread 或额外模型 Turn
- 卸载后没有 SkillDock/Node 子进程残留
```

不要把密码、Cookie、capability/source/panel token、完整聊天记录或其他 Task
放入 evidence。
