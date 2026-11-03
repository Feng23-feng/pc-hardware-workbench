# GitHub 提交与发布故障手册

本文件总结本仓库实际遇到过的 GitHub 推送、Actions、Pages 和冻结发布问题。遇到类似报错时先按“症状、根因、安全处理、验证”排查。

## 总原则

- 先判断是本地 Git、远端认证、网络传输、CI 还是 Pages 的问题，不要直接重置分支或强推。
- 普通 `git push` 失败不代表提交内容有问题。先验证 fetch、API 或网页读取是否仍正常。
- 任何绕过普通 push 的发布方式都必须先证明远端 tree 与本地 tree 完全一致。
- 同一个提交只有在 Windows CI 和 Pages 都成功后才算发布完成。
- 在 CI 和线上验证通过前，不创建或推送最终发布标签。

## 1. Git 报 dubious ownership

症状：

```text
fatal: detected dubious ownership in repository
```

原因：当前执行身份与工作区所有者不同。提权执行和沙箱内执行可能看到不同的 Windows 用户身份。

安全处理：只在当前命令里声明可信目录，不改全局 Git 配置：

```powershell
git -c safe.directory=C:/Users/28271/Documents/Codex/pc-hardware-workbench fetch origin
```

不要把 `safe.directory=*` 写入全局配置。

## 2. push 报连接被重置

症状：

```text
fatal: unable to access 'https://github.com/...': Recv failure: Connection was reset
```

排查顺序：

1. 重试普通 `git push`。
2. 用 `curl -I https://github.com` 检查 GitHub 是否可达。
3. 尝试 `fetch origin`，确认是仅 push 端点异常还是整体网络异常。
4. 必要时临时使用 HTTP/1.1 重试。
5. 仍然失败时，确认只读 API 是否可用。

普通 HTTPS 读取成功但 `git-receive-pack` 持续被重置，可能是网络中间层只阻断 push。不要在未核对内容时改用强推或覆盖远端引用。

## 3. GitHub Git Data API 兜底

仅当以下条件同时满足时使用：

- 用户明确要求推送。
- 远端当前 SHA 已知。
- 普通 push 多次因传输层失败，而不是认证或冲突失败。
- 能够使用本机已有 Git 凭据访问 GitHub API。

安全流程：

1. 用 API 读取远端基础提交和 tree。
2. 对本地提交相对基础提交的每个新增或修改文件创建 blob。
3. 基于远端 tree 创建新 tree。
4. 比较新 tree SHA 与本地提交 tree SHA；不一致立即停止。
5. 创建提交。
6. 再次比较提交 tree SHA。
7. 用非强制方式更新 `refs/heads/main`。
8. 等待该新提交触发 CI 和 Pages。

API 生成的提交对象 SHA 可能与本地提交 SHA 不同；只要 tree SHA 相同，文件内容就是一致的。不要仅凭 commit SHA 不同就判断代码不同。

凭据只从 Git credential helper 读取，不打印、不写入仓库、不写进日志。

## 4. API 推送后本地 main 显示 ahead/behind

原因：GitHub API 生成的提交对象头与本地提交不同，但 tree 可以完全相同。

处理：

1. 执行 `git fetch origin main`。
2. 比较 `HEAD^{tree}` 和 `origin/main^{tree}`。
3. tree 一致时，先创建本地备份引用。
4. 再将本地 `main` 指针同步到 `origin/main`。

不要只凭 ahead/behind 数量判断内容分叉。

## 5. CI 报生成物 stale，但本地检查通过

症状：

```text
Generated manifest is stale
Generated current orrery is stale
Generated current metadata is stale
```

根因通常不是页面坏了，而是生成器受宿主环境影响：

- Git 工作区是 `CRLF`，干净检出是 `LF`；
- `Sort-Object` 继承系统区域，`zh-CN` 与 `en-US` 顺序不同；
- PowerShell/JSON 序列化格式不同；
- 未跟踪文件没有进入 checkout；
- 路径大小写和排序规则不一致。

修复顺序：

1. 在 CI 日志中同时输出实际哈希和期望哈希。
2. 确认文件聚合摘要是否一致。
3. 若聚合一致但 manifest/page 不一致，优先检查排序和 JSON 文本格式。
4. 在哈希前统一换行符。
5. 所有排序显式指定区域和大小写规则。
6. 生成 JSON 使用压缩输出或语义比较。
7. 用 `zh-CN`、`en-US` 和干净检出分别运行检查。

不要通过手工替换 CI 生成的哈希来“修复”问题。

## 6. Windows CI 与 GitHub Runner 环境不同

本地检查必须尽量接近 CI：

- 使用 Windows PowerShell 5.1；
- 使用固定区域运行一次；
- 使用干净 clone 或工作树；
- 确认换行符转换与仓库 `.gitattributes` 一致。

在 PowerShell 5.1 中模拟区域：

```powershell
[Threading.Thread]::CurrentThread.CurrentCulture =
  [Globalization.CultureInfo]::GetCultureInfo("en-US")
[Threading.Thread]::CurrentThread.CurrentUICulture =
  [Globalization.CultureInfo]::GetCultureInfo("en-US")
& .\tools\build-skill-orrery.ps1 -Check
```

## 7. Pages 成功但 CI 失败

Pages 只表示静态文件完成部署，不表示完整测试通过。

发布完成要求：

- 同一远端 SHA；
- Windows CI 成功；
- Pages 构建成功；
- 线上冻结元数据正确；
- 线上页面实际出现本次改动。

旧提交的绿色结果不能替代新提交。

## 8. 发布标签

发布标签只应指向已经满足全部发布条件的提交。

如果早期标签指向了仍有 CI 问题的提交，不要未经确认强推或覆盖标签。创建新的最终标签，或明确记录旧标签已被哪个提交取代。

## 快速检查清单

```text
[ ] git status 只包含预期文件
[ ] 本地测试通过
[ ] zh-CN 检查通过
[ ] en-US 检查通过
[ ] 干净检出检查通过
[ ] 远端 tree SHA == 本地 tree SHA
[ ] 同一远端 SHA 的 Windows CI 成功
[ ] 同一远端 SHA 的 Pages 成功
[ ] 线上冻结元数据正确
[ ] 线上页面已完成人工查看
```
