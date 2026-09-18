# Codex SelfHeal

用于 Windows 上 Codex 运行环境部署不完整、启动后没有显示窗口等特定故障的辅助启动器。它检查安装包、进程和日志，在满足条件时修复 `cua_node`，然后重新尝试启动。

这是个人维护的辅助脚本，不是 OpenAI 官方工具。它补救文件部署问题，不修改 Codex 的更新机制，也不能解决所有“没有窗口”的故障。

## 使用

需要 Windows、Windows PowerShell 5.1，以及当前用户已安装并注册的 Codex 应用。无需下载额外依赖或以管理员身份运行。

下载项目后，将以下文件保留在同一文件夹，双击 `Codex-SelfHeal.cmd`：

- `Codex-SelfHeal.cmd`：启动入口。
- `Codex-SelfHeal.ps1`：检查、修复和启动流程。
- `Codex-Progress.ps1`：终端内中文进度条。
- `Codex-Cleanup.ps1`：有条件的旧运行环境清理。

终端显示中文状态摘要；复制时显示文件进度、百分比和当前路径。运行结束后，无论成功或失败都会显示日志路径，双击入口会等待按键关闭。

完整 JSON 日志默认保存在：

```text
%LOCALAPPDATA%\OpenAI\Codex\self-heal.log
```

日志可能包含本机路径等诊断信息，提交问题时请先检查需要分享的内容。

## 参数

在项目目录的 PowerShell 中运行：

```powershell
.\Codex-SelfHeal.cmd
.\Codex-SelfHeal.cmd -Diagnose
.\Codex-SelfHeal.cmd -RepairIncomplete
.\Codex-SelfHeal.cmd -TimeoutSeconds 120
```

| 参数 | 含义 |
| --- | --- |
| `-Diagnose` | 只检查和记录日志，不启动、停止、修复或清理应用。 |
| `-RepairIncomplete` | 应用退出后，允许修复已存在但不完整、且没有 staging 残留的正式运行环境。 |
| `-TimeoutSeconds` | 每轮等待启动的时间，默认 90 秒，范围 30–300 秒。 |
| `-LogPath` | 自定义完整日志路径。 |
| `-TryCliFallback` | 在特定日志证据和路径条件满足时，额外尝试一次临时 CLI 路径重试。 |
| `-NoGui` | 为兼容旧用法保留；现在始终使用终端进度。 |

## 工作流程与限制

1. 读取当前用户的 AppX 安装信息，确认应用路径和运行环境标识。
2. 检查进程、启动日志和运行环境文件；已有前端运行证据时不重启。
3. 默认只在运行环境不完整、且存在对应 staging 残留时考虑修复。新版本没有残留时先尝试普通启动。
4. 在临时目录复制文件，补齐遗漏的长路径文件，并逐一验证全部文件的 SHA-256。
5. 校验成功后将原目录保留为备份，再将临时目录切换为正式运行环境。
6. 尝试安全清理，启动 Codex，并等待窗口、前端进程或日志中的就绪证据。

检测到前端进程不等于已经确认可见窗口，终端会区分这两种结果。活跃后端或承载当前任务的进程会受到保护，因此某些“只有后台进程”的情况需要先正常退出 Codex。未知布局、无法查询的状态或校验失败不会被当作修复成功。

进度按文件数量而非字节计算，大文件复制时百分比可能暂时不动。日志中 `repair_complete` 表示文件修复完成；`launch_ok` 或 `launch_ok_after_repair` 表示发现启动就绪证据，两者不是同一件事。

## 空间清理

清理只针对 `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node` 下符合命名规则的目录：

- 保留当前运行环境、最近一个旧运行环境、最近一份备份。
- 满足条件后删除其余旧副本，以及 `.selfheal-…`、`.staging-…` 临时目录。
- 删除前完整校验当前环境，并检查所有 Windows 会话中的相关进程。
- 进程仍在运行、查询失败、路径越界或出现重解析点时推迟清理。

清理失败不会阻止正常启动。脚本不清理聊天记录、用户配置或项目文件。

## 验证

下面的检查使用临时文件和模拟状态，不用于真实 Codex 冷启动验收。请使用 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-SelfHeal.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-Cleanup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-Progress.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-Summary.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-Launch.ps1
```

清理检查需要创建测试用目录链接；启动检查会创建一个无害的测试子进程。受限制的运行环境可能拒绝这些操作。测试会在用户临时目录保留诊断用文件。

退出码：`0` 表示诊断完成或检测到运行就绪证据；`1` 表示操作失败；`2` 表示启动未确认或需要人工处理。仅诊断模式的 `0` 不代表运行环境一定完整。
