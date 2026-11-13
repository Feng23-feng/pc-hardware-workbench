# 技术架构

PC Hardware Workbench 是一个面向 Windows 的只读硬件工作流。它通过一个
Skill 入口完成配置读取、故障排查、遥测分析、手动调校指导和升级判断，但不自动
修改硬件。

## 设计原则

- **先证据，后建议**：先区分已知、缺失和冲突的信息，再讨论参数、替换件或实验。
- **只读优先**：采集默认不提权，不上传数据，不自动修改 BIOS、频率、电压、功耗、
  风扇、内存时序或固件。
- **单变量实验**：一次只改变一个条件，并提前写明通过条件、中止信号和恢复方式。
- **用户保留控制权**：持久硬件变更必须由用户手工作业。
- **按需加载**：入口只负责路由，具体能力在对应任务出现时再加载。

## 统一入口

主入口位于
[`skill/pc-hardware-workbench/SKILL.md`](../skill/pc-hardware-workbench/SKILL.md)。
它根据问题类型路由到以下工作流：

| 问题 | 输出 |
| --- | --- |
| 查看当前配置 | 只读硬件摘要和身份边界 |
| 排查故障 | 风险分类、缺失证据、一次一个区分问题 |
| 分析遥测 | 时间窗、缺失值、版本来源、趋势和图表 |
| 调参 | 五项门禁、单变量实验卡、恢复方式 |
| 判断升级 | 保留现有硬件的候选方案和购买证据 |

### 入口预算

入口使用 LF 规范化后的 UTF-8 字节计算。10.5 KiB（10,752 B）是日常目标，
11 KiB（11,264 B）是硬上限；超过日常目标时先迁移解释、示例和低频流程到按需
reference，不先抬高预算。当前入口为 10,562 B。Quick 初始加载硬上限为 20 KiB，
当前为 19,571 B。

普通修改超过 11 KiB 会直接失败。只有会阻止安全事故或数据损失的紧急修复可以使用
`tests/entry-budget-exception.json`：最多临时多 256 B、最长 72 小时，并必须写明
安全影响和迁移承诺。例外过期、未超线时残留、用途不是 `safety-hotfix` 或缺少必要
字段时，预算测试仍失败。例外存续期间不得继续加入无关功能，迁移完成后必须删除
例外文件。

入口只保留安全停止、参数提示、调参门禁、任务路由和文件指针。详细路由组合继续由
`component-playbooks.md`、`gpu-auto-candidates.md`、`hardware-case.md` 等文件按需展开。

## 调参门禁

任何硬件参数建议都必须先确认五项信息：

1. 当前机器和平台形态；
2. 同场景稳定状态；
3. 当前控制值；
4. 固定测试场景；
5. 恢复路径和中止信号。

信息不足时不生成可执行参数。详情见
[`references/tuning/experiment-loop.md`](../skill/pc-hardware-workbench/references/tuning/experiment-loop.md)。

## 排障模型

排障按风险顺序推进，而不是按硬件部件罗列：

1. 物理安全；
2. 启动与数据；
3. 稳定性与崩溃；
4. 功能和输出路径；
5. 性能。

高风险问题不能由低层性能证据覆盖。事件日志、ETL、转储和遥测分别路由到
Event Viewer、WPR/WPA、WinDbg 和内置分析器。详情见
[`references/triage/triage-checklist.md`](../skill/pc-hardware-workbench/references/triage/triage-checklist.md)
与
[`references/triage/risk-taxonomy.md`](../skill/pc-hardware-workbench/references/triage/risk-taxonomy.md)。

## 遥测与证据

遥测分析器支持 CSV、SensorSnapshot 和校验后的中文表头，保留采样间隔、缺失值、
窗口哈希和数据来源。CSV 是统计与时间窗比较的主要依据；单张监控截图只代表可见
瞬间，不能证明长期稳定。

归一化后的数据携带来源、采样一致性、混用来源警告和可绘图序列。内置 SVG
渲染器在没有外部绘图库时也能生成最多三条序列的确定性概览。

相关实现：

- [`scripts/analyze-telemetry.ps1`](../skill/pc-hardware-workbench/scripts/analyze-telemetry.ps1)
- [`scripts/normalize-telemetry.ps1`](../skill/pc-hardware-workbench/scripts/normalize-telemetry.ps1)
- [`scripts/render-telemetry-chart.ps1`](../skill/pc-hardware-workbench/scripts/render-telemetry-chart.ps1)

## 本地 RAG

供应商事实通过本地证据层管理，而不是直接相信搜索摘要。来源卡记录官方域名、
发布日期、抓取时间和失效范围；社区资料只作为 `lead-only` 线索。过期或冲突资料
继续作为历史证据保留。

参考：
[`references/integration/dynamic-rag.md`](../skill/pc-hardware-workbench/references/integration/dynamic-rag.md)。

## LibreHardwareMonitor

可选的 LHM 适配器只读取已经运行的本机 loopback Web 接口。它不会安装或启动
LHM、不会提权、不会连接非 loopback 主机，也不会写入硬件设置。旧 WMI 仅作为
兼容路径保留。

参考：
[`references/integration/lhm-adapter.md`](../skill/pc-hardware-workbench/references/integration/lhm-adapter.md)。

## 用户声明核验

用户说“我刚确认过当前值”时，Skill 将声明标记为用户报告证据；旧记录在被确认前保持
历史状态。可用的本地证据通过只读 JSON 比较器逐项检查，结果分别记录为匹配、冲突、
用户确认、历史或无法核验。

参考：[`claim-verification.md`](../skill/pc-hardware-workbench/references/integration/claim-verification.md)。

## PresentMon 帧时间

PresentMon CSV 作为遥测输入，而不是新的顶层模式。分析器只读取用户导出的本地文件，
计算平均 FPS、长尾帧时间、1%/0.1% low、尖峰帧和尖峰簇。它不启动 PresentMon、
不提权、不接入游戏进程，也不会把单次帧时间与某个硬件故障直接画等号。

参考：[`presentmon-frame-time.md`](../skill/pc-hardware-workbench/references/integration/presentmon-frame-time.md)。

## 时间计划甘特图

存在预热、候选测试、重启或浸泡等多个阶段，并且持续时间已知时，工作台可从本地
JSON 计划生成无依赖 SVG 甘特图。它用于表达计划和并行验证轨道，不替代遥测曲线，
也不表示计划已经执行或硬件已经稳定。

参考：[`telemetry-analysis.md`](../skill/pc-hardware-workbench/references/integration/telemetry-analysis.md)。

## GPU 起始候选

GPU 调参只有在常规门禁完成后才会生成一个受限、可回退的单变量起始候选。未知、
专业卡、核显、虚拟适配器和多适配器目标在给出数值前阻断。笔记本功耗墙被视为
板级上限状态，不代表实际功耗；第一轮通过也不自动等于长期稳定。

参考：
[`references/tuning/gpu-auto-candidates.md`](../skill/pc-hardware-workbench/references/tuning/gpu-auto-candidates.md)
与
[`references/tuning/gpu-auto-oc-tier-authority.json`](../skill/pc-hardware-workbench/references/tuning/gpu-auto-oc-tier-authority.json)。

## 硬件案卷

跨轮调查可以在本地保存哈希化证据、假设、时间线、基线、实验和下一步。案卷可以
导出为无外部依赖的静态 HTML；证据内容默认不入库，可选预览有大小限制并拒绝活动
或外部链接 SVG。

案卷采用事件驱动检查点：多轮、多证据、存在参数变更或可能因上下文丢失而中断时，
在读取大型证据前创建或恢复；只在证据、基线、实验、恢复、决策或阻塞变化时更新。
普通概念问答不建案卷，也不逐轮复制聊天记录。

实验记录可绑定基线和多个证据 ID，并保存通过/中止条件、恢复方式、结果状态和是否
在重启后验证。实验可先以 `pending` 登记，测完后用 `UpdateExperiment` 补齐结果。
新增字段均为可选，旧版 `case.json` 保持可读。`Resume` 输出紧凑恢复摘要，不回放
旧聊天，也不显示外部证据源路径。

参考：
[`references/integration/hardware-case.md`](../skill/pc-hardware-workbench/references/integration/hardware-case.md)。

## Skill Doctor

只读诊断覆盖安装、脚本语法和编码、输出目录可写性、PowerShell 版本、CIM、
validator 和可选监控工具。`PERMISSION_REQUIRED` 与 `BROKEN` 分开报告，Doctor
不会安装、提权、启动软件或修复文件。

入口：
[`scripts/doctor.ps1`](../skill/pc-hardware-workbench/scripts/doctor.ps1)。

## 分发结构

- `skill/pc-hardware-workbench/`：Codex 与 DeepSeek Harness 共用的 Skill 树；
- `adapters/dsh/`：DeepSeek Harness 项目适配信息；
- `portable/`：独立 Windows 工具；
- `tools/`：验证、同步、打包和站点检查；
- `docs/skill-evolution/`：项目说明站、交互演示和文件星球。

## 进一步阅读

- [安装与升级](installation.md)
- [使用方式](usage.md)
- [测试与发布检查](testing.md)
- [隐私与安全边界](privacy-and-safety.md)
- [版本记录](https://github.com/Feng23-feng/pc-hardware-workbench/releases)
