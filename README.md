# PC Hardware Workbench

[中文](README.md) | [English](README.en.md)

一个面向 Windows 的只读硬件工作台。它可用于 Codex、DeepSeek Harness 或其他
兼容 Agent，也提供不需要 Agent、API 或安装的独立便携工具。它把配置读取、故障
排查、遥测分析、手动调校和升级判断收敛到一套工作流，同时把每一次硬件变更留给
用户亲手完成。

当前版本为 **2.9.1 测试版**（源码标签 `2.9.1-test.1`）。公开下载仍为
`2.9.0-test.1 + SkillDock 0.1.0-rc.5`，GitHub main 领先于最近一个公开 Release。
本版收紧显存 profile 的 GPU、原始工具和显示工具版本门禁，并收敛显存图表规则；
此前 2.9.0 新增的确定性本地证据 CLI、纯 PCHW Skill、PCHW Portable 和
DeepSeek Harness 包继续保留。2.9.0 还声明
`pchw-source-hosted` `1.0.0` 面板契约，使后续 Skill 更新可按最低版本、
契约 SemVer 和能力协商，而不必每次写死一个 Skill 版本。SkillDock `0.1.0-rc.5`
已作为公开测试版适配该契约；上一个 `0.1.0-rc.4` 面板包继续供 PCHW `2.8.0`
用户使用。目前没有正式版。完整自动测试和本轮真实 CSV 功能验收
已通过；真实设备覆盖、干净 Windows 安装/卸载和其余交互场景签署仍在继续。
项目不会把测试版包装成稳定版。

![文件星球预览](docs/skill-evolution/assets/orrery-preview.png)

[项目说明](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/) ·
[情景演示](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/interactive/) ·
[文件星球](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/orrery/)

## 目录

- [功能](#功能)
- [快速开始](#快速开始)
- [打开 SkillDock 操作面板](#打开-skilldock-操作面板)
- [使用示例](#使用示例)
- [安全边界](#安全边界)
- [支持矩阵](#支持矩阵)
- [已知限制](#已知限制)
- [文档](#文档)
- [常见问题](#常见问题)
- [版本与许可](#版本与许可)

## 功能

- **读取电脑配置。** 只读查看处理器、显卡、主板、内存、存储、显示器和电池等
  当前可见信息，不猜测缺失型号。
- **排障先保安全。** 按物理安全、启动与数据、稳定性、功能故障和性能排序，避免
  用超频或换件掩盖尚未解释的问题。
- **分析真实遥测。** 读取 CSV、HWiNFO 导出和结构化传感器快照，保留采样间隔、
  缺失值、来源和时间窗口；有可用指标时生成 SVG 图表。
- **显存口径可追溯。** 默认总览保留 HWiNFO 原始显存值；只有 GPU、原始工具、
  显示工具和版本全部匹配受控 profile 时，显式深度图才派生 Afterburner 等效值，
  `provisional` profile 默认拒绝。
- **确定性本地证据 CLI。** 通过统一的 `pcwb.ps1` 返回固定 JSON envelope、
  结构化状态/退出码、输入与 artifact 哈希；只读封装盘点、遥测、PresentMon、
  证据包、声明核验和 Doctor，不提供硬件写入或自动提权。
- **展示时间计划。** 多阶段调校、预热、复查、重启和回归时间线可生成甘特图；
  单步建议或时长不明时不会硬画。`done` 表示执行结束但未判定，`pass/fail` 仍表示测试结论。
- **核验用户声明。** 区分当前实测、用户刚确认、历史记录、估算和冲突，避免把旧值
  自动升级成当前值。
- **分析帧时间。** 只读导入 PresentMon CSV，统计平均 FPS、P95/P99、1%/0.1% low、
  尖峰帧与尖峰簇，不自动启动工具或接入游戏进程。
- **主动保存排查现场。** 多轮、多证据或包含参数变更的调试会维护一个私人本地案卷，
  记录证据、基线、实验、通过/中止条件、恢复方式和下一步；新对话可用紧凑恢复摘要
  接续，不需要重放全部聊天。
- **调参必须有证据。** 参数请求先通过设备、基线、恢复路径、固定负载和停止条件
  门禁；信息不足时不生成可直接套用的数字。
- **GPU 起始候选。** 仅对可识别且条件齐全的显卡给出一个有限、可回退的单变量
  起点；未知、专业卡、核显、虚拟适配器和多适配器目标会被阻断。
- **升级判断。** 比较继续保留、维护和购买新硬件的收益，不用一个跑分替代场景、
  预算和证据。
- **按需接入更多证据。** 支持本地 RAG 证据缓存、宿主可用时的联网查证、已经运行
  的本机 LibreHardwareMonitor、视觉截图说明和跨轮硬件案卷。
- **始终只读。** 不自动修改 BIOS、频率、电压、功耗、风扇、内存时序或固件。

## 下载包与版本线

[下载当前 PCHW 2.9.0 + SkillDock rc.5 测试版](https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v0.1.0-rc.5)，
按使用场景只选一个包；不要把同一个 Skill 的多个副本放进同一个宿主扫描目录。
普通用户默认选择不含面板的纯 PCHW Skill；只有明确需要网页操作面板时，再选择
SkillDock 面板包（需已安装 Codex）。没有 Agent，或希望完全不安装时，选择独立
便携工具。

| 包 | 适合谁 | 包含 | SkillDock 面板 |
| --- | --- | --- | --- |
| PCHW Skill（Codex / DSH / 其他 Agent 通用，无面板） | 普通用户默认选择；Codex 单独使用，或已有 DSH / 其他兼容 Agent 宿主 | PCHW Skill 2.9.0 发布子集 | 无 |
| PCHW Portable（独立 Windows，无需 Agent） | 没有 Codex / DSH，或不希望安装 Skill 与 Runtime | 独立菜单、采集、CSV 与证据工具 | 无 |
| DeepSeek Harness 适配包 | 使用 DSH，并且需要与 PCHW Skill 一起安装 | 2.9.0 Skill 与 DSH 适配文件 | 不提供 |
| SkillDock Runtime-only | 已安装兼容 PCHW Skill，只缺 SkillDock 应用与 Node | SkillDock Runtime + Node.js 24.22.1 | 仅 Codex 当前对话 |
| SkillDock 面板包（公开测试版 rc.5） | 已安装 Codex Desktop，并使用 PCHW 2.9.0 surface contract | PCHW 2.9.0 Skill、SkillDock rc.5 Runtime、安装入口 | 仅 Codex 当前对话 |

2.9.0-test.1 文件：

```text
PCHW-Skill-2.9.0-test.1-installer.zip
PCHW-Skill-2.9.0-test.1-manual.zip
pc-hardware-portable-v2.9.0-test.1.zip
pc-hardware-workbench-deepseek-harness-v2.9.0-test.1.zip
SkillDock-PCHW-0.1.0-rc.5-win-x64-user.zip
SkillDock-Runtime-0.1.0-rc.5-win-x64.zip
SHA256SUMS.txt
```

本轮 SkillDock 面板文件位于 `v0.1.0-rc.5`。`v0.1.0-rc.4` 保留为上一版
PCHW 2.8.0 面板测试包。不要在同一个宿主中混装 2.8.0 与 2.9.0 Skill。

这是公开测试版，clean Windows 安装/卸载和最终签收仍为 PENDING。不要混装多个
Skill 或旧 Runtime。

<a id="what-is-skilldock"></a>

### SkillDock 是什么

SkillDock 是 PCHW 在 **Codex 当前任务**中可选的图形操作面板。用户提出硬件问题
并提供 CSV 等文件后，面板会带入当前任务、问题和附件，集中展示图表、结论、证据
冲突、不确定性与下一步建议。本地分析需要明确授权；结果返回后页面自动更新，
关闭重开仍可恢复同一任务。

SkillDock 不是独立 Agent，也不替代 Codex：推理和对话仍在 Codex 中完成，它负责
本地可视化与交互。面板仅支持 Codex，DSH 和其他 Agent 使用无面板的通用 Skill。

rc.4 继承 rc.3 的本地存储面板：可导出受保护的 Runtime 回退备份（含共享 Node
引擎和逐文件 SHA-256 清单）；普通（非 source-hosted）Task 与证据必须先下载
当前导出，才能二次确认清空。source-hosted Task 暂不允许在面板中清空。清理会
保留 Agent Session、权限凭证、Runtime、共享引擎和回退备份。

如果只需要聊天、硬件采集和 CSV 分析，选择无面板的 PCHW Skill 即可，不必安装
SkillDock；完全不需要 Agent 时，才选择独立便携包。SkillDock 对硬件始终只读，
不会自动修改任何硬件设置。

<a id="pchw-portable"></a>

### PCHW Portable 便携工具（无需 Agent）

1. 下载 `pc-hardware-portable-v2.9.0-test.1.zip`，并按 Release 的校验文件或
   GitHub asset digest 校验。
2. 解压完整目录，不需要安装、管理员权限、API key 或网络连接。
3. 双击 `开始使用.cmd` 进入菜单。

便携版提供配置读取、排障、遥测 CSV、PresentMon、证据包和手动调校指导，但不
提供 SkillDock 面板。它共享的遥测分析器 `1.2.4` 支持 `Timestamp`、`DateTime`、
`Date/Time`、`时间戳` 和 `日期时间` 列，并输出实际采样跨度。所有硬件变更仍由
用户手动完成。

### SkillDock 面板包（用于 Codex）

使用前需要安装 Codex Desktop。

1. 下载 SkillDock 面板包，并按 Release 中的 `SHA256SUMS.txt` 或 GitHub 页面显示的 asset digest 校验。
2. 解压后双击 `Install.cmd`。
3. 已有旧版 PCHW Skill 时，安装器会先备份，再执行安全升级；不需要先删除旧 Skill。
   成功安装后，Runtime 程序备份只保留最近一个可回退版本，Task 数据不受影响。
4. 安装完成后打开 Codex 当前对话。
5. 描述硬件问题并明确同意打开图形化分析。

用户不需要寻找 runner、端口、token 或环境变量，也不需要手动启动
`SkillDock.exe`。安装器会从同一个候选包中安装 PCHW Skill 与 SkillDock Runtime。

<a id="pchw-skill-only"></a>

### PCHW Skill（Codex / DSH / 其他 Agent 通用，无面板）

这个包只包含 PCHW Skill，不是 SkillDock 面板包，也不含 SkillDock、
Node、测试 runner 或 DSH 观察窗。它可用于 Codex、DSH 或其他兼容 Agent 宿主，
适合不需要面板的用户。将 `pc-hardware-workbench` 目录安装到目标 Agent 的 Skill
扫描目录。Codex 默认位置：

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

DSH 默认位置：

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

详细步骤见 [安装与升级](docs/installation.md#pchw-skill-only)。

### SkillDock Runtime-only

此包只供已经安装兼容 PCHW Skill、但缺少 SkillDock 应用与 Node 的高级用户使用。
rc.5 对精确 PCHW `2.8.0` 走 legacy 桥；2.8.0 之后的版本必须声明
`surface_contracts["pchw-source-hosted"]`，契约版本在
`>=1.0.0 <2.0.0` 内，满足 `min_skill_version`，并声明
`telemetry.csv.analyze` 等必需能力。上一版 rc.4 Runtime 只接受 PCHW 2.8.0。解压对应
Runtime 后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
```

安装后仍从 Codex 当前对话触发面板，不需要手动启动 `SkillDock.exe`。本版只
验证了 Runtime-only 包清单与 Runtime 安装；尚未单独认证所有 Skill-only 与
Runtime-only 的跨包组合。

## 打开 SkillDock 操作面板

安装 PCHW Skill 和 SkillDock Runtime 后，不需要寻找 runner 或设置环境变量。
在 Codex 当前对话中直接描述问题和附件，例如：

```text
我玩游戏二十分钟后开始掉帧，这是 HWiNFO CSV。可以打开图形化分析吗？
```

同意打开后，Skill 会把当前问题、Task 和支持的附件带入本地面板。首次分析时，
页面会请求一次明确的“仅本次允许”；允许后可以查看真实 SVG、具体判断、支持与冲突
证据、不确定性，以及两到三条低风险采集建议。结果会自动写回页面。
复制结果回到当前 Codex 对话继续；关闭并重启后，同一 Task、图表和结论仍可恢复。

需要管理本机占用时，使用页面顶部的“本地存储”。可导出最近一个 Runtime 回退
备份；Task 清理必须先下载导出并确认，过期、损坏或导出后数据发生变化的文件
不能解锁清理。导出 ZIP 默认保留在 `%LOCALAPPDATA%\SkillDock\storage-exports`，
下载有效期 24 小时，过期文件会在 Runtime 启动或刷新存储面板时清理。

同一附件成功完成一次本地分析后，重复分析时才可能出现“同一附件后续分析”。
它仍只覆盖当前 Task 中的这份 CSV，2 小时内有效；更换附件需要重新选择
“仅本次允许”。

如果 Codex 的 Ask-for-approval 模式使页面无法自动打开，页面会提示“手动打开面板”。
使用提示中的短期链接或本地 `.url` 快捷方式打开同一面板即可。默认 Runtime 目录
不可写、面板无法启动或已有其他工作区时，留在当前对话继续，不创建第二个 Thread。

本版只有 Codex 当前对话承诺 `pchw-source-hosted` SkillDock 面板。DSH 和其他宿主
仍可使用 PCHW 的聊天、采集和 CSV 分析核心能力，但不承诺打开这个面板。权限被拒绝、
面板无法启动或当前工作区冲突时，继续在对话中处理即可；页面不存在不会阻断对话。

SkillDock 面板只执行用户确认的只读分析和 Task artifact 写入，不会自动修改 BIOS、
固件、驱动、频率、电压、功耗、风扇或内存时序。

## 使用示例

```text
帮我看看这台电脑现在的配置，有哪些信息读不到？
```

```text
游戏偶尔卡顿。先判断还需要哪些证据，不要直接给我超频参数。
```

```text
这是我导出的一天 HWiNFO CSV，帮我检查趋势、缺失值和异常时间窗。
```

```text
这是 PresentMon CSV。帮我分析卡顿，并给一张能直看的帧时间图。
```

```text
这是我已知各阶段时长的调校计划，帮我把时间顺序画清楚。
```

```text
我想让这张显卡更安静，但还没有恢复点和固定测试场景。
```

Skill 会根据问题进入配置、排障、遥测、调参或升级路线。信息不足时，只返回最小
补证动作，不会跳过安全门禁。

## 安全边界

- 不自动修改 BIOS/UEFI、频率、电压、功耗墙、风扇、内存时序或固件；
- 不自动提权、安装驱动或启动监控软件；
- 不绕过权限、反作弊、厂商锁或安全限制；
- 出现焦味、火花、液体、熔化接头、鼓包电池或可见破损时，先停止；
- 没有恢复路径和中止信号时，不生成硬件参数实验；
- LibreHardwareMonitor 只在已经运行且用户明确允许时，通过本机 loopback Web
  或只读 WMI 后备读取数据。

参数仅供参考，请以安全为第一要务。

完整说明见 [隐私与安全边界](docs/privacy-and-safety.md)。

## 支持矩阵

| 宿主 | 配置、排障、聊天、CSV | SkillDock 面板 |
| --- | --- | --- |
| Codex 当前用户对话 | 支持 | 支持 |
| DeepSeek Harness | 支持 | 不提供 |
| 其他 Agent 宿主 | 按宿主文件访问能力使用 | 不承诺 |

## 已知限制

- `2.9.1` 是当前源码 PCHW Skill/Portable 测试线，目前没有正式版；
- 当前公开 SkillDock 测试包为 `0.1.0-rc.5 + PCHW 2.9.0`；
- 上一版 `0.1.0-rc.4` 继续作为 PCHW 2.8.0 面板测试包；
- rc.5 最终 ZIP 的 Clean Windows 安装/卸载与人工签收仍为 PENDING；
- 干净 Windows 安装/卸载、真实设备覆盖和完整用户签收仍在进行；
- SkillDock 面板只承诺 Codex 当前用户对话；
- Ask-for-approval 模式可能要求使用“手动打开面板”链接或 `.url`；
- DSH 和其他宿主没有本版 SkillDock 面板；
- 不提供后台自动分析、自动恢复或自动硬件修改。

## 文档

- [安装与升级](docs/installation.md)
- [使用方式](docs/usage.md)
- [技术架构](docs/architecture.md)
- [常见问题](docs/troubleshooting.md)
- [隐私与安全边界](docs/privacy-and-safety.md)
- [English README](README.en.md)
- [English installation](docs/en/installation.md)
- [English privacy and safety](docs/en/privacy-and-safety.md)
- [变更记录](CHANGELOG.md)
- [GitHub Releases](https://github.com/Feng23-feng/pc-hardware-workbench/releases)
- [贡献指南](CONTRIBUTING.md)
- [安全报告](SECURITY.md)

## 常见问题

- **Codex 里看不到 Skill**：确认安装目录中的 `SKILL.md` 存在，然后重启 Codex。
- **采集出现权限拒绝**：先在普通、非提权 PowerShell 中重试；Agent 沙箱可能限制
  CIM、存储或显示器信息读取。
- **LHM 没有数据**：LHM 必须已经由用户启动，Web Server 只绑定 loopback，并且
  用户明确允许读取。
- **CSV 被拒绝**：不要使用 UNC 路径、映射网络盘、云占位文件、符号链接、目录
  联接或重解析点。
- **GPU 调参被阻断**：先补齐型号、当前控制值、基线、固定负载、恢复路径和停止
  条件；不要通过改写提问绕过门禁。

更多问题见 [常见问题](docs/troubleshooting.md)。

## 版本与许可

版本状态以 [GitHub Releases](https://github.com/Feng23-feng/pc-hardware-workbench/releases)
和 [CHANGELOG.md](CHANGELOG.md) 为准。当前工作台源码版本为 `2.9.1` 测试版，尚未正式
发布；GitHub main 可能领先于最近一个公开 Release。

源码使用 [MIT License](LICENSE)。

Copyright (c) 2026 Feng23-feng.

第三方软件、安装器、图片和厂商资料继续遵循各自许可证；未经单独许可不得重新
分发。
