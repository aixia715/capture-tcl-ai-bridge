# Capture Tcl AI Bridge

当前预发布版本：**0.1.0-beta.5**。
版本变化见 [CHANGELOG.md](CHANGELOG.md)。

把本机 AI 客户端或人工命令行提交的多行 Tcl，交给**正在运行的** OrCAD Capture
全局 Tcl 解释器执行，并把 `puts` 输出、返回值和 Tcl 错误详情原样带回来。
`puts` 的内容同时保留在 Capture 控制台里，不会被"吞掉"。

桥只监听 `127.0.0.1:8767`，每次启动生成新的随机 Bearer 令牌。默认**只在你显式
启动时才开启**——加载脚本本身没有任何副作用，也没有空闲自动退出；需要的话可以
装一个自启文件让它随 Capture 启动（见[安装](#1-安装)）。

> 这个桥**不是沙箱**。持有令牌就等于拥有 Capture Tcl 控制台的全部权限。
> 使用前请先读 [docs/security.md](docs/security.md)。

## 系统要求

- Windows 10 或 Windows 11
- 无需单独安装 Python 或 Python 第三方包；发布包内含 Python 3.12 运行时和依赖
- OrCAD Capture 17.4（Tcl 8.6）或 OrCAD Capture 16.6（Tcl 8.4）

桥自带 Tcl 8.4 兼容层和 JSON 解析器，因此两个 Capture 版本都能直接运行，
不需要额外安装 tcllib，也不需要配置 `TCLLIBPATH`。
16.6 的唯一差异见[版本差异](#版本差异)。

真实 Capture 验收目前在 16.6 / Tcl 8.4.15 上完成。17.4 / Tcl 8.6 已由自动兼容
测试覆盖，但尚未进行真机验收；beta 使用者应将这一点视为已知验证边界。

## 最短使用路径

### 1. 安装

```powershell
.\install.ps1
```

从 Release ZIP 解压后直接运行 `install.ps1`。它部署包内已预装依赖的 Python 3.12
embeddable runtime，不使用系统 Python、`PATH`、pip 或网络；并把所有部署文件连同
SHA-256 记到 `%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json`：

| 文件 | 默认目标 |
| --- | --- |
| `capture_tcl_bridge_server.py` | `C:\tclpython` |
| `capture_tcl_cli.py` | `C:\tclpython` |
| `capture_mcp_server.py` | `C:\tclpython` |
| bundled `python.exe` + dependencies | `C:\tclpython\runtime` |
| `captureAiBridge.tcl` | 自动检测到的每个 `C:\Cadence\SPB_*\tools\capture\tclscripts\capAutoLoad` |

如果自动检测不到非标准 Capture 安装目录，脚本只会给出提示；可用参数指定：

```powershell
.\install.ps1 -CaptureTclTarget 'C:\Cadence\SPB_16.6\tools\capture\tclscripts\capAutoLoad'
```

安装器不会覆盖任何它无法证明属于自己的文件；被本机改过的文件也默认拒绝覆盖，
需要显式加 `-ForceOverwriteModified`。它在复制第一个字节之前会检查全部目标，
所以被拒绝时机器保持原样。

**可选：Capture 启动时自动开桥**

```powershell
.\install.ps1 -EnableAutoStart -LogFile C:\temp\capture_ai_bridge.log
```

这会多装一个 `captureAiBridgeAutoStart.tcl`，省掉每次手动 Start。代价是桥的存在
时间从"你主动开启时"变成"Capture 开着时"——先读 [docs/security.md](docs/security.md)
里的取舍说明。`-LogFile` 可选，用来同时打开诊断日志。

`uninstall.ps1` 会一并删除它；只想关掉自启就删这一个文件。

### 2. 在 Capture 中加载并显式启动

在 Capture 的 Tcl 命令行里：

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
AiBridge start
AiBridge status
```

`source` 本身不会启动任何东西，必须显式 `AiBridge start`。
启动后 `AiBridge status` 应显示运行在 `127.0.0.1:8767`。
每次修改 `captureAiBridge.tcl` 后都要重新 `source`。

查看 Capture 当前实际加载的桥版本：

```tcl
puts $::CaptureAiBridgeVersion
AiBridge status
```

`AiBridge status` 的第一行会显示版本，例如
`Capture Tcl AI Bridge v0.1.0-beta.5`。

### 3. 用命令行执行 Tcl

```powershell
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py status
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py -c "expr {1 + 1}"
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
Get-Content -Raw .\examples\selected_refs.tcl | C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py --json -c "GetActiveDesign"
```

`-c`、`-f` 和管道标准输入三者必选其一，且只能选一个。
`status` 同时显示服务端软件版本；`status --json` 的 `version` 字段提供机器可读版本。
不加 `--json` 时先打印捕获的 stdout/stderr，再打印结果或 Tcl 错误摘要。
退出码：Tcl 执行失败为 1，命令行用法错误为 2，桥接/认证/协议/传输失败为 3。

### 4. 用 HTTP 执行 Tcl（供 AI 客户端）

客户端从 `%TEMP%\capture_tcl_bridge.json` 读取 `baseUrl` 和 `token`
（先校验服务名、协议版本和 Capture PID），然后每个请求都带
`Authorization: Bearer <token>`：

```http
POST /v1/execute
{"script": "puts \"hello\"\nexpr {1 + 1}"}
```

完整协议见 [docs/protocol.md](docs/protocol.md)。

### 5. 让 AI Agent 通过 MCP 读写元器件属性

安装后可把 stdio MCP 服务注册给 Codex：

```powershell
codex mcp add capture -- C:\tclpython\runtime\python.exe C:\tclpython\capture_mcp_server.py
```

它暴露五个工具：三个工具检查或修改 Capture GUI 中的 Active Design，另外两个
工具通过 SPB 16.6 自带的 `tclsh.exe + orDb_Dll_TCL` 直接读写磁盘上的 DSN，
不启动 `capture.exe` 或 Capture GUI。离线写入先操作私有副本，再由第二个全新
Cadence Tcl 进程重开验证，验证成功后才发布输出文件或替换原文件。所有属性写入
都只操作 occurrence；本地属性不存在时创建 override。不会开放任意 Tcl。
Codex、Claude Code、Hermes 的完整配置和工具参数见 [docs/mcp.md](docs/mcp.md)。

### 6. 诊断日志（可选）

桥报告给 Capture 控制台的消息不会进入任何脚本的输出。需要留证时：

```tcl
set ::CaptureAiBridgeLogFile C:/temp/capture_ai_bridge.log
```

默认关闭；上限 20 MiB（`::CaptureAiBridgeLogLimitBytes`），超限截断并保留最新内容；
每行带时间戳；不含 Bearer 令牌。装了自启的话用 `-LogFile` 更省事。

### 7. 停止与卸载

```tcl
AiBridge stop
```

```powershell
.\uninstall.ps1
```

`uninstall.ps1` 只删除清单能证明是自己装的文件；被改过的文件默认保留
（要删需加 `-ForceModified`），并且从不删除目标目录本身或目录里的其他项目文件。

## 行为约定

- **一次只跑一条命令。** 并发提交返回 `BRIDGE_BUSY`。
- **`POST /v1/execute` 最多等 30 秒。** 超时返回 504 和命令 ID，
  但**不会取消**已经在 Capture 里执行的 Tcl；随后可按 ID 查询结果。
- **Tcl 报错不是协议错误。** Tcl 失败仍是 HTTP 200，用 `ok`、`returnCode`、
  `errorInfo`、`errorCode`、`errorLine` 描述。
- **`puts` 会 tee。** 捕获到客户端的同时，原样转发给 Capture 控制台。
- **Capture 在 Tcl/UI 线程上执行脚本。** 长时间或阻塞脚本会让界面无响应，
  HTTP 超时和客户端断开都不会终止它。

大小限制：脚本 1 MiB；`result`、`stdout`、`stderr` 各 4 MiB，
分别用 `resultTruncated`、`stdoutTruncated`、`stderrTruncated` 标明截断。

## 版本差异

Capture 16.6 的 Tcl 是 8.4，它的 `catch` 没有选项字典，因而没有 `-errorline`。
在 16.6 上执行失败的脚本，`errorInfo` 和 `errorCode` 正常返回，
但 `errorLine` 恒为 `null`。17.4（Tcl 8.6）返回准确行号。

## 文档

- [docs/protocol.md](docs/protocol.md) —— HTTP 接口、运行描述文件、状态机
- [docs/runtime-packaging.md](docs/runtime-packaging.md) —— 离线 Python runtime 的发布打包方式
- [docs/mcp.md](docs/mcp.md) —— Codex、Claude Code、Hermes 接入与元器件属性工具
- [docs/security.md](docs/security.md) —— 权限边界与威胁模型
- [docs/troubleshooting.md](docs/troubleshooting.md) —— 端口占用、描述文件过期、
  路径解析、HTTP 400、pending dump
- [docs/tcl-cookbook.md](docs/tcl-cookbook.md) —— 中文 Capture Tcl 示例手册
- [docs/headless-dsn-bom.md](docs/headless-dsn-bom.md) —— 不启动 Capture GUI，独立读取
  DSN 并导出基础 BOM
- [docs/acceptance-checklist.md](docs/acceptance-checklist.md) —— 真实 Capture 验收清单
- [MIGRATION.md](MIGRATION.md) —— 从 TCLBOM 迁移的来源与验收状态

## 开发

```powershell
python -m pip install -r requirements-dev.txt
python -m pytest -q
tclsh tests\test_capture_ai_bridge.tcl
tclsh tests\test_capture_ai_compat.tcl
```

Tcl 套件在 8.4 和 8.6 上都必须通过。若 PATH 上的 `tclsh` 不是要验证的版本，
用 `CAPTURE_TCL_TCLSH` 指定集成测试使用的解释器。

## 许可证

本项目采用 [MIT License](LICENSE)。
