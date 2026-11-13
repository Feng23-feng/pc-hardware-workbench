# 测试与发布检查

## 测试分层

仓库有三类主要验证：

1. **Skill 结构验证**：检查 `SKILL.md`、references、scripts 和包结构。
2. **行为契约测试**：覆盖正常请求、缺失证据、冲突证据、安全停止和调参门禁。
3. **同步与打包检查**：确认 Skill、Portable 和发行包之间没有意外漂移。

实机采集测试默认不运行，必须由用户显式授权并选择隐私模式。

## 全量测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-all-tests.ps1 `
  -SkillRoot .\skill\pc-hardware-workbench
```

## Skill 验证

首次使用需要准备持久化验证环境：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\validate-skill.ps1 -Bootstrap
```

之后的离线验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\validate-skill.ps1
```

持久环境默认位于：

```text
%LOCALAPPDATA%\pc-hardware-workbench\.validation-venv
```

可以通过 `-VenvPath` 或 `CODEX_VALIDATION_VENV` 改到其他位置。

## Portable 自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\portable\start.ps1 -SelfTest
```

## 安装器回归

验证远程安装器与 Release ZIP 安装器都会安装新版本、保留旧版，并把备份放在
Codex Skill 扫描目录之外：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\test-skill-installers.ps1
```

## 同步检查

检查 Skill 与 portable 共享脚本是否漂移：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\check-portable-sync.ps1
```

检查 Skill 树与已打包目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\check-package-sync.ps1 `
  -LeftRoot .\skill\pc-hardware-workbench `
  -RightRoot <unpacked-package-dir>\skill\pc-hardware-workbench `
  -IgnoreEolOnly
```

退出码：

- `0`：一致；
- `1`：发现漂移；
- `2`：参数或路径错误。

## 统一版本索引

扫描本地 Codex、Portable、DeepSeek Harness、本机安装备份和 Git 标签，
生成统一的 Markdown 与 JSON 索引：

```powershell
python .\tools\build-release-index.py
```

默认输出到本地 `releases\VERSION-INDEX.md` 和
`releases\VERSION-INDEX.json`，不会修改任何历史发行包。

PresentMon CSV 回归：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-presentmon-analysis-tests.ps1 `
  -AnalyzerPath .\skill\pc-hardware-workbench\scripts\analyze-presentmon.ps1
```

CSV SVG 与时间计划甘特图回归（含防覆盖和非法输入）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-telemetry-chart-tests.ps1 `
  -AnalyzerPath .\skill\pc-hardware-workbench\scripts\analyze-telemetry.ps1 `
  -RendererPath .\skill\pc-hardware-workbench\scripts\render-telemetry-chart.ps1
```

## 模型行为回归

行为回归默认只检查本地评分器，不调用模型。先验证固定场景和正反例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\run-behavior-evals.ps1 -SelfTest
```

评分已有回答：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\run-behavior-evals.ps1 `
  -InputRoot .\work\behavior-evals\my-run\answers
```

只有显式传入 `-Live` 才会通过 `codex exec` 启动真实模型会话。默认最多运行
5 个场景、每个 1 次；可分别调整 `-MaxCases` 和 `-Runs`。实时运行使用只读
沙箱、临时会话并禁用 hooks，回答、日志和报告全部写入
`work\behavior-evals\<timestamp>\`。
每个 `-Runs` 都使用独立的 `*.runN.md`，不会复用前一次回答。

首次联调可只运行一个场景，再按 ID 补齐其余场景：

```powershell
... -Live -ScenarioIds missing-recovery-candidate -Runs 1
```

测试尚未安装的源码规则时，使用源码模式。子会话会直接读取仓库中的
`SKILL.md`，不会覆盖本机安装版：

```powershell
... -Live `
  -SkillSourcePath .\skill\pc-hardware-workbench `
  -ScenarioIds history-is-not-current -Runs 1
```

机器检查只验证安全提示、问题数量、历史值与当前值、截图证据和缺失证据等硬约束；
结果中的 `humanReview` 始终保持 `PENDING`，不能替代独立人工签署。

## 发布前检查

- 自动测试和结构验证通过；
- 两种安装器的备份路径回归通过；
- Portable 自检通过；
- 包同步检查通过；
- 版本号在 `SKILL.md`、变更记录和构建产物中一致；
- 真实设备测试作为显式 opt-in 项单独记录；
- 不宣称尚未完成的人工验收或广泛发布状态。

## 构建测试包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\build-release.ps1 `
  -Label test `
  -ValidatorPath "C:\Users\<user>\Documents\Codex\tools\skill-creator-validator\validate-skill.ps1"
```

构建器只读取 Git 跟踪文件，并生成 Codex、DeepSeek Harness 和 Portable 三种包。
