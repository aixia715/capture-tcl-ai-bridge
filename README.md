# Capture Tcl AI Bridge

把本机 AI 客户端或人工命令行提交的多行 Tcl，交给**正在运行的** OrCAD Capture
全局 Tcl 解释器执行，并把 `puts` 输出、返回值和 Tcl 错误详情原样带回来。
`puts` 的内容同时保留在 Capture 控制台里，不会被"吞掉"。

桥只监听 `127.0.0.1:8767`，每次启动生成新的随机 Bearer 令牌，且**只能显式启动**
——加载脚本本身没有任何副作用，也没有空闲自动退出。

> 这个桥**不是沙箱**。持有令牌就等于拥有 Capture Tcl 控制台的全部权限。
> 使用前请先读 [docs/security.md](docs/security.md)。

## 系统要求

- Windows 10 或 Windows 11
- Python 3.12 或更高版本，且已安装 `fastapi` 与 `uvicorn`
- OrCAD Capture 17.4（Tcl 8.6）或 OrCAD Capture 16.6（Tcl 8.4）

桥自带 Tcl 8.4 兼容层和 JSON 解析器，因此两个 Capture 版本都能直接运行，
不需要额外安装 tcllib，也不需要配置 `TCLLIBPATH`。
16.6 的唯一差异见[版本差异](#版本差异)。

## 最短使用路径

### 1. 安装

```powershell
python -m pip install -r requirements.txt
.\install.ps1
```

`install.ps1` 只部署三个运行文件，并把它们连同 SHA-256 记到
`%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json`：

| 文件 | 默认目标 |
| --- | --- |
| `capture_tcl_bridge_server.py` | `C:\tclpython` |
| `capture_tcl_cli.py` | `C:\tclpython` |
| `captureAiBridge.tcl` | `C:\cadence\SPB_17.4\tools\capture\tclscripts\capAutoLoad` |

Capture 16.6 或自定义位置用参数指定：

```powershell
.\install.ps1 -CaptureTclTarget 'C:\Cadence\SPB_16.6\tools\capture\tclscripts\capAutoLoad'
```

安装器不会覆盖任何它无法证明属于自己的文件；被本机改过的文件也默认拒绝覆盖，
需要显式加 `-ForceOverwriteModified`。它在复制第一个字节之前会检查全部三个目标，
所以被拒绝时机器保持原样。

### 2. 在 Capture 中加载并显式启动

在 Capture 的 Tcl 命令行里：

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
CaptureAiBridgeStart
CaptureAiBridgeStatus
```

`source` 本身不会启动任何东西，必须显式 `CaptureAiBridgeStart`。
启动后 `CaptureAiBridgeStatus` 应显示运行在 `127.0.0.1:8767`。
每次修改 `captureAiBridge.tcl` 后都要重新 `source`。

### 3. 用命令行执行 Tcl

```powershell
python C:\tclpython\capture_tcl_cli.py status
python C:\tclpython\capture_tcl_cli.py -c "expr {1 + 1}"
python C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
Get-Content -Raw .\examples\selected_refs.tcl | python C:\tclpython\capture_tcl_cli.py
python C:\tclpython\capture_tcl_cli.py --json -c "GetActiveDesign"
```

`-c`、`-f` 和管道标准输入三者必选其一，且只能选一个。
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

### 5. 停止与卸载

```tcl
CaptureAiBridgeStop
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
- [docs/security.md](docs/security.md) —— 权限边界与威胁模型
- [docs/troubleshooting.md](docs/troubleshooting.md) —— 端口占用、描述文件过期、
  路径解析、HTTP 400、pending dump
- [docs/tcl-cookbook.md](docs/tcl-cookbook.md) —— 中文 Capture Tcl 示例手册
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
