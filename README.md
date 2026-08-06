# TCLBOM
## 功能概述
1. 自定义常用TCL脚本，用于提升ORCAD Capture的使用效率

2. BOM表导出，相比与ORCAD自带的BOM表导出工具有以下优势：

    a. 可以自动去除空贴器件，自动整理出结构BOM和手工焊接的BOM

    b. 导出的BOM表增加“PCB Footprint”、“自带”列

3. BOM表导入

4. 设置/恢复空贴

## 系统要求
1. 安装 Python 3.12 以及以上版本，并安装 `openpyxl`、`fastapi`、`uvicorn` 包

2. ORCAD Capture 17.4及以上版本

## 使用方法

### 脚本安装

1. 先确保安装 Python 3.12 以及以上版本，并安装依赖：

    ```
    pip install openpyxl fastapi uvicorn
    ```

2. 将工程中的.tcl文件放在``C:\cadence\SPB_17.4\tools\capture\tclscripts\capAutoLoad``目录中

3. 将工程中的.py文件放在``C:\tclpython``目录中

运行``cpcode.bat``脚本可以自动完成上述步骤2和3。

4. 当ORCAD Capture启动时，脚本会自动加载，如果启动后脚本内容变更，可以用以下两种方法重载脚本

    a. 在ORCAD Capture中输入命令
    ```
    source <更新的TCL文件路径>
    ```

    b. 关闭ORCAD Capture后，重新启动


### 脚本使用

#### 导出BOM表
1. 在ORCAD Capture中打开需要导出BOM表的原理图

2. 在命令行输入
    ```
    ExportBom
    ```

3. 在指令执行完成后将输出BOM表导出的路径（与原理图在相同目录中，文件名为bom_output.csv）

#### 导入BOM表
1. 在ORCAD Capture中打开需要导入BOM表的原理图

2. 在命令行输入
    ```
    ImportBom <bom_file_path>
    ```
    支持 `.xlsx` 和 `.csv` 两种格式。

3. 在指令执行完成后将输出导入结果

##### 输入文件格式要求

导入文件须满足以下要求（xlsx 和 csv 格式相同）：

| 列序号 | 列名（表头，可随意命名） | 内容说明 |
|--------|--------------------------|----------|
| 第1列  | Item                     | 序号，导入时忽略 |
| 第2列  | Quantity                 | 数量，导入时忽略 |
| **第3列** | **Reference**         | **位号列表，多个位号用英文逗号分隔，如 `R1,R2,R3`** |
| **第4列** | **Part**              | **器件值，如 `10k`、`100nF`** |
| 第5列起 | （其他列）              | 导入时忽略 |

- 第一行必须为表头行（会被跳过）
- xlsx 文件无编码要求；csv 文件须使用 UTF-8（推荐带 BOM 的 UTF-8-sig）编码
- `ExportBom` 导出的 `bom_output.csv` 可直接作为 `ImportBom` 的输入

#### 网页 DNI Panel

1. 在 OrCAD Capture 命令行运行：

    ```
    DNIPanel
    ```

2. 命令会启动仅监听 `127.0.0.1:8766` 的本机服务并打开浏览器。

3. 在原理图中选择一个 Instance。网页会显示它的全部 occurrence，可编辑 Value、DNI，并通过目标行批量设置 PCB Footprint。

4. 网页中的修改只保存在草稿里；点击“应用修改”后，Capture 内部的 Tcl 才会写入 OrCAD。

5. 如果仍需使用旧版 Tcl/Tk 界面，可运行：

    ```
    DNITkPanel
    ```

停止网页与 Capture 之间的轮询桥接可运行 `DNIWebStop`。关闭浏览器不会自动停止本机服务。

#### Capture Tcl AI 调试桥

该调试桥把 AI 或命令行提交的 Tcl 脚本转发到当前 OrCAD Capture 的全局 Tcl 解释器执行，并同时把 `puts` 输出保留在 Capture 控制台、返回给调用方。桥只允许显式启动，不会随脚本加载自动运行，也没有空闲自动退出。

部署时运行 `cpcode.bat`，它会把 Python 文件复制到 `C:/tclpython`，把 Tcl 文件复制到 Capture 的 `capAutoLoad` 目录。桥需要 Capture Tcl 环境提供 `http` 和 `json` 包；缺少依赖时 Start 会在 Capture 控制台报告错误。首次使用或 Tcl 文件更新后，在 Capture 中重新加载并显式启动：

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
CaptureAiBridgeStart
CaptureAiBridgeStatus
CaptureAiBridgeStop
```

`CaptureAiBridgeStatus` 会报告 `starting`、`running`、`stopping` 等当前阶段。停止是异步过程；显示 `stopping` 时正在等待服务端确认，显示 `server cleanup required` 时轮询已停但清理尚未完成，可再次执行 `CaptureAiBridgeStop` 重试清理。重复执行 Start 不会启动第二个服务。退出 Capture 时，父进程监视器也会停止服务。

##### HTTP 接口（供 AI 使用）

服务仅监听 `http://127.0.0.1:8767`。每次启动都会生成新的随机令牌，并把服务身份、基础 URL、令牌、Capture PID 和服务 PID 原子写入 `%TEMP%\capture_tcl_bridge.json`。客户端必须先校验描述文件，并在每个 HTTP 请求中发送：

```http
Authorization: Bearer <token>
```

对外接口如下：

- `GET /v1/health`：查询服务身份、Capture 连接状态和忙闲状态。
- `POST /v1/execute`：以 `{"script":"..."}` 提交 Tcl 脚本。
- `GET /v1/commands/<id>`：按命令 ID 查询排队中、执行中或已完成的结果。

一次只允许一个待处理或执行中的命令；并发提交会返回 `BRIDGE_BUSY`。`POST /v1/execute` 最多等待 30 秒，超时会返回仍可查询的命令 ID 和状态，**不会取消**已经排队或在 Capture 中执行的 Tcl。Tcl 自身报错仍会以完成结果返回，其 `ok`、`returnCode`、`errorInfo`、`errorCode` 和 `errorLine` 用于说明 Tcl 执行状态。

##### 命令行（供人使用）

命令行与 AI 使用同一描述文件、令牌和 HTTP 接口，支持命令参数、UTF-8 文件、管道标准输入以及完整 JSON 输出：

```powershell
python C:/tclpython/capture_tcl_cli.py status
python C:/tclpython/capture_tcl_cli.py -c "GetActiveDesign"
python C:/tclpython/capture_tcl_cli.py -f debug_script.tcl
Get-Content debug_script.tcl | python C:/tclpython/capture_tcl_cli.py
python C:/tclpython/capture_tcl_cli.py --json -c "expr {1 + 1}"
```

如需指定非默认描述文件，可追加 `--runtime-file <path>`。`-c`、`-f` 和管道输入三者必须且只能选择一个。普通输出先显示捕获的 stdout/stderr，再显示结果或 Tcl 错误；`--json` 返回完整协议对象。Tcl 失败退出码为 1，桥接、认证、协议或传输失败退出码为 3，命令行用法错误退出码为 2。

##### 限制与安全

- Tcl 脚本最大为 1 MiB UTF-8 数据。
- `result`、`stdout` 和 `stderr` 各有 4 MiB UTF-8 上限，并分别通过 `resultTruncated`、`stdoutTruncated`、`stderrTruncated` 标明截断。`errorInfo` 有 4 MiB 上限，`errorCode` 列表共享 4 MiB 元数据预算；这两项只保留预算内的 UTF-8 前缀，没有对应的截断标志。
- CLI 最多读取 160 MiB HTTP 响应，以覆盖 JSON 转义后的最坏情况并限制客户端内存使用。
- Capture 在其 Tcl/UI 线程中执行脚本；长时间或阻塞脚本可能让界面无响应，HTTP 超时或客户端断开均不会终止它。
- 该桥**不是沙箱**。任何持有有效令牌的调用方都能执行任意 Tcl，并拥有 Capture 进程可用的文件系统和进程权限。仅监听本机和使用随机 Bearer 令牌不能防御同一 Windows 用户下能够读取临时描述文件的恶意进程；不要共享令牌或在不可信环境启用本桥。
