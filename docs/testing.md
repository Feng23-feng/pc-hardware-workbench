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

## 发布前检查

- 自动测试和结构验证通过；
- Portable 自检通过；
- 包同步检查通过；
- 版本号在 `SKILL.md`、变更记录和构建产物中一致；
- 真实设备测试作为显式 opt-in 项单独记录；
- 不宣称尚未完成的人工验收或广泛发布状态。

## 构建测试包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\build-release.ps1 `
  -RepositoryRoot . `
  -Label test `
  -ValidatorPath "C:\Users\<user>\Documents\Codex\tools\skill-creator-validator\validate-skill.ps1"
```

构建器只读取 Git 跟踪文件，并生成 Codex、DeepSeek Harness 和 Portable 三种包。
