# 协议

服务只监听 `http://127.0.0.1:8767`。所有接口都要求认证，健康检查和内部接口也不例外。

## 运行描述文件

启动时生成新的随机 Bearer 令牌，并把下列内容原子写入
`%TEMP%\capture_tcl_bridge.json`：

```json
{
  "service": "capture-tcl-bridge",
  "version": "0.1.0-beta.3",
  "protocolVersion": 1,
  "baseUrl": "http://127.0.0.1:8767",
  "token": "<每次启动都不同的随机令牌>",
  "capturePid": 1234,
  "serverPid": 5678
}
```

客户端在使用前必须校验 `service`、`version`、`protocolVersion`，以及 `capturePid` 是否
指向自己期望的 Capture 进程。写了一半或已过期的描述文件必须拒绝，而不是将就使用。
停止时描述文件被删除。

本文档不含真实令牌，也不应该有人把令牌抄进任何文档、日志或提交里。

## 认证

```http
Authorization: Bearer <token>
```

缺失或错误的令牌一律返回 401。

## 公开接口

```text
GET  /v1/health
POST /v1/execute
GET  /v1/commands/{id}
```

### GET /v1/health

返回服务名、软件版本、协议版本、`captureConnected`、`busy`、Capture PID 和服务 PID。
Tcl 端的心跳维持连接状态；连续 5 秒没有成功心跳后，新的执行请求会以
`CAPTURE_DISCONNECTED` 失败。

### POST /v1/execute

```http
POST /v1/execute
Content-Type: application/json

{"script": "puts \"hello\"\nexpr {1 + 1}"}
```

同一时刻只允许一条命令处于 pending 或 executing。第二条提交得到
HTTP 409 与稳定错误码 `BRIDGE_BUSY`。Capture 未连接时是 HTTP 503 与
`CAPTURE_DISCONNECTED`。

**已有命令处于 `executing` 时，busy 优先于 disconnected。** Capture 在自己的
Tcl/UI 线程上执行脚本，因此任何超过心跳窗口（5 秒）的脚本都会让心跳暂停，
直到它跑完。此时报 `CAPTURE_DISCONNECTED` 会让调用方以为桥没了而放弃，
但正确的动作是等待——而一条已被 Capture 领取的命令本身就证明 Capture 在。
仅仅排队（`queued`）尚未被领取的命令不构成这种证明，仍按连接状态判断。

非法 JSON、缺失或非字符串的 `script`、超限脚本得到 HTTP 400 或 413。脚本上限为 1 MiB UTF-8。

请求最多等待 **30 秒**。Tcl 执行完成即返回 HTTP 200，无论 Tcl 本身成功与否。
等待超时返回 HTTP **504**，附带命令 ID 和当前状态——**超时不会取消**已经排队
或正在 Capture 中执行的 Tcl，它仍会跑完，结果随后可以按 ID 取回。

成功响应：

```json
{
  "id": "7ecda83c-8f71-4f0e-90d6-513331650f11",
  "state": "completed",
  "ok": true,
  "returnCode": 0,
  "result": "2",
  "stdout": "hello\n",
  "stderr": "",
  "errorInfo": "",
  "errorCode": [],
  "errorLine": null,
  "stdoutTruncated": false,
  "stderrTruncated": false,
  "resultTruncated": false
}
```

字段含义：

| 字段 | 说明 |
| --- | --- |
| `ok` | 仅当 `returnCode` 为 0 时为 true |
| `returnCode` | Tcl `catch` 的完成码 |
| `result` | Tcl 返回值，上限 4 MiB |
| `stdout` / `stderr` | 捕获的 `puts` 输出，各上限 4 MiB |
| `errorInfo` / `errorCode` / `errorLine` | 来自 Tcl 选项字典，缺失时为空或 `null` |
| `*Truncated` | 对应字段是否被截断，三个标志相互独立 |

`errorLine` 在 Capture 16.6（Tcl 8.4）上恒为 `null`，因为该版本的 `catch`
没有选项字典。

### GET /v1/commands/{id}

返回该命令的当前状态或最终结果。broker 在内存中保留最近 100 条已完成命令，
便于同步请求超时后再取回结果；第 101 条完成时挤掉最旧的一条。
服务重启后结果不保留。

## 错误语义

传输和桥接错误使用非 200 状态码加稳定符号错误码；**Tcl 自身的错误使用 HTTP 200**，
`state` 为 `completed`、`ok` 为 false、`returnCode` 非零。这个区分是为了让 AI
客户端不会把协议故障误当成 Capture Tcl 故障。

常见错误码：

| HTTP | 错误码 | 含义 |
| --- | --- | --- |
| 401 | — | 令牌缺失或错误 |
| 400 | `INVALID_RESULT` | Capture 回传的结果体不合法 |
| 400 / 413 | `REQUEST_TOO_LARGE` | 请求体超限 |
| 409 | `BRIDGE_BUSY` | 已有命令在执行 |
| 409 | `COMMAND_ID_MISMATCH` | 结果的命令 ID 与当前命令不符 |
| 503 | `CAPTURE_DISCONNECTED` | 心跳超时，Capture 未连接 |
| 504 | — | 同步等待超时，命令未取消 |

服务端日志记录生命周期和协议失败，但不记录令牌，也不记录提交的完整脚本。

## 内部轮询接口

Tcl 端用同样的认证访问这些接口：发布心跳和 Capture PID、领取待执行命令、
回传结果、请求干净关闭。

领取是原子的。结果回传遵循明确的状态机：

- 每次 `POST /internal/result` 都必须带 `X-Capture-Command-Id`；
- header 的 ID、请求体里的 ID 和当前 active 命令 ID 必须三者一致；
- 只有状态为 `executing` 的当前命令才接受结果；
- 未知或不匹配的命令 ID 返回 409 `COMMAND_ID_MISMATCH`，且不改变 active；
- 同一命令 ID 若已 `completed`，重复回传返回同样的完成确认而不覆盖结果——
  这是给"结果已送达但没收到 HTTP 确认"的 Tcl 端准备的幂等重试路径；
- 通过三重认证但结果体不合法时，服务端合成一条
  `INVALID_RESULT` 完成结果并释放 `busy`，避免桥永久卡死。

Tcl 端据此区分可重试与确定性失败：传输错误和 5xx 保留 pending 结果并按
250 / 500 / 1000 / 2000 / 5000 ms 退避重试；确定性 4xx 只报告一次就丢弃 pending；
401、PID 不匹配等未确认的 4xx 进入 polling-halted 状态，`CaptureAiBridgeStatus`
可见，`CaptureAiBridgeStop` 仍可执行。

## 安装清单

`install.ps1` 写入 `%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json`，
`captureAiBridge.tcl` 用它定位 broker：

```json
{
  "schemaVersion": 1,
  "project": "capture-tcl-ai-bridge",
  "pythonTarget": "C:\\tclpython",
  "captureTclTarget": "C:\\cadence\\SPB_17.4\\tools\\capture\\tclscripts\\capAutoLoad",
  "files": [{"path": "...", "sha256": "..."}]
}
```

Tcl 端解析 Python 目录的优先级是：`source` 之前显式设置的
`::CaptureAiBridgePythonPath` → 清单的 `pythonTarget` → 默认 `C:/tclpython`。
清单损坏、缺字段、`schemaVersion` 不为 1、`project` 不匹配或路径非绝对路径时，
一律安全回退到默认值，并且不会自动启动任何服务。
