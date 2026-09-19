# Codex SelfHeal

当前脚本版本：1.2.0（日志随脚本目录保存，增强路径兼容性及跨副本并发保护）。

用于 Windows 上 Codex 运行环境部署不完整、启动后没有显示窗口等特定故障的辅助启动器。它检查安装包、进程和日志，在满足条件时修复 `cua_node`，然后重新尝试启动。

这是个人维护的辅助脚本，不是 OpenAI 官方工具。它补救文件部署问题，不修改 Codex 的更新机制，也不能解决所有“没有窗口”的故障。

## 普通用户下载

打开 [最新 Release](https://github.com/IGondorI/Codex-SelfHeal/releases/latest)，在 **Assets** 中下载 `Codex-SelfHeal-v版本号-windows.zip`。

1. 将 ZIP **完整解压**到可写文件夹，不要在压缩包里直接运行。
2. 保存工作并正常退出 Codex。
3. 双击解压后的 **Codex-SelfHeal.cmd**，等待中文提示。

ZIP 中附有“先读我.txt”。不需要安装 Git、Python 或 Node.js；普通使用无需下载 Source code 源码包。

## 使用

需要 Windows、Windows PowerShell 5.1，以及当前用户已安装并注册的 Codex 应用。无需下载额外依赖或以管理员身份运行。

下载项目后，将以下文件保留在同一文件夹，双击 `Codex-SelfHeal.cmd`：

- `Codex-SelfHeal.cmd`：启动入口。
- `Codex-SelfHeal.ps1`：检查、修复和启动流程。
- `Codex-Progress.ps1`：终端内中文进度条。
- `Codex-Cleanup.ps1`：有条件的旧运行环境清理。

终端显示中文状态摘要；复制时显示文件进度、百分比和当前路径。运行结束后，无论成功或失败都会显示日志路径，双击入口会等待按键关闭。

进度文本会根据终端宽度限制为单行，过长路径省略前段并保留文件名末尾，避免进度区域因换行反复改变高度。普通复制进度最多约每 300 毫秒刷新一次，首个文件、最后一个文件及阶段切换会及时更新。

完整 JSON 日志默认保存在脚本自己的目录下（与当前终端工作目录无关）：

```text
<脚本目录>\logs\self-heal.log
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
| `-LogPath` | 自定义日志路径；相对路径以脚本目录为基准。目录不可写时明确报错，不自动写到其他位置。 |
| `-PackageName` | 指定注册的应用包名称，默认 `OpenAI.Codex`；仍需满足受支持的清单和运行环境结构。 |
| `-TryCliFallback` | 在特定日志证据和路径条件满足时，额外尝试一次临时 CLI 路径重试。 |
| `-NoGui` | 为兼容旧用法保留；现在始终使用终端进度。 |

## 工作流程与限制

### 可移植性与写入位置

将四个运行脚本一起复制或解压到可写文件夹即可使用，支持包含空格和中文的路径。入口会在适用时选择本机原生 Windows PowerShell，避免从 32 位宿主调用时的文件系统重定向问题。开始处理前检查 Windows、Windows PowerShell 和必要系统命令；不自动下载依赖，不写注册表，不设置计划任务，不修改系统环境变量。

默认日志和轮转日志 `self-heal.log.1` 位于脚本旁的 `logs` 目录。日志锁文件仅在运行期间存在，结束后自动移除。不同位置的脚本副本也通过同一个运行环境互斥锁防止并发修复。旧版本已写入用户目录的日志不会自动迁移或删除。

Codex 自身需要的运行环境、备份仍写入 `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node`；把它们随意搬到脚本目录会破坏应用对运行环境的查找。因此本工具免安装、工具日志随目录保存，但不承诺完全不写用户目录。移除工具时可删除其文件夹；不要在 Codex 运行时删除应用正在使用的运行环境。

当前仅支持 Windows 上可查询的 AppX/MSIX 安装及已识别的运行环境布局，不支持任意解压版 EXE、macOS 或 Linux。`-PackageName` 允许显式选择包名，不会自动猜测未知安装位置。没有跨设备或 ARM64 的实机验证。

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Codex-Portability.ps1
```

清理检查需要创建测试用目录链接；启动检查会创建一个无害的测试子进程。受限制的运行环境可能拒绝这些操作。测试会在用户临时目录保留诊断用文件。

退出码：`0` 表示诊断完成或检测到运行就绪证据；`1` 表示操作失败；`2` 表示启动未确认或需要人工处理。仅诊断模式的 `0` 不代表运行环境一定完整。

## 构建发布包

维护者可执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Release.ps1`，在 `dist` 获得 ZIP 和 SHA-256 校验文件。发布包使用固定文件清单，仅含四个运行脚本及中文快速指南，不包含本机日志、测试数据或安装记录。

将 `release/version.txt`、脚本版本与 `release/NOTES.md` 更新并推送到 `main`，GitHub Actions 会在 Windows 上测试、打包并创建 Release。也可在 Actions 中手动运行发布流程。已存在的同版本 Release 不会被覆盖。
