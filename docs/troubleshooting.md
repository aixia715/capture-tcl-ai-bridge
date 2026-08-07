# 故障排查

先跑这条，它能区分"桥没起来"和"桥起来了但调用有问题"：

```tcl
CaptureAiBridgeStatus
```

## Start 报告端口冲突

现象：Capture 控制台显示启动失败，提示 8767 冲突或服务启动失败。

- 端口 8767 被别的进程占用。查一下是谁：

  ```powershell
  Get-NetTCPConnection -LocalPort 8767 -State Listen |
      Select-Object OwningProcess |
      ForEach-Object { Get-Process -Id $_.OwningProcess }
  ```

- 如果是上一次 Capture 会话遗留的桥服务，先在原 Capture 里 `CaptureAiBridgeStop`；
  该 Capture 已经退出的话，父进程监视器通常已经让它自己退出了。
- 重复执行 `CaptureAiBridgeStart` 不会启动第二个服务，所以反复 Start 无济于事。

## 客户端说描述文件无效或过期

现象：CLI 或 AI 客户端报告找不到、无法校验 `%TEMP%\capture_tcl_bridge.json`。

- 桥没启动，或者上一次没干净停止。在 Capture 里 `CaptureAiBridgeStatus` 确认。
- 描述文件里的 `capturePid` 属于另一个 Capture 进程。多开 Capture 时，
  只有真正启动了桥的那个进程才拥有描述文件。
- 停止后描述文件会被删除；看到残留文件说明上一次清理没完成，
  再执行一次 `CaptureAiBridgeStop` 重试清理。
- **不要**把令牌从描述文件里抄出来存到别处。它每次启动都变。

## Start 报告找不到 server 脚本

现象：控制台提示 `capture_tcl_bridge_server.py` 不存在，并给出它实际解析到的路径。

解析顺序是：`source` 之前显式设置的 `::CaptureAiBridgePythonPath` →
`%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json` 的 `pythonTarget` →
默认 `C:/tclpython`。

- 报错里那个路径就是实际用到的路径，先确认文件在不在那儿。
- 检查清单是否有效：

  ```powershell
  Get-Content "$env:LOCALAPPDATA\capture-tcl-ai-bridge\install.json"
  ```

  `schemaVersion` 必须是 1，`project` 必须是 `capture-tcl-ai-bridge`，
  `pythonTarget` 必须是绝对路径。任何一项不满足都会被安全忽略并回退到默认值——
  所以"清单明明写了却不生效"通常是清单本身没通过校验。
- 重新安装可修复清单：`.\install.ps1`（必要时带 `-PythonTarget`）。

## 改了 captureAiBridge.tcl 但行为没变

Capture 不会自动重载。每次修改后都要重新 `source`：

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
```

如果桥正在运行，先 `CaptureAiBridgeStop`，再 `source`，再 `CaptureAiBridgeStart`。
注意 `source` 的是**已安装**的那份文件，不是仓库里的源文件——
改完仓库要先跑 `.\install.ps1` 才会同步过去。

## 控制台反复刷 HTTP 400

现象：Capture 控制台不断出现桥的协议错误。

这是设计上不该发生的：确定性 4xx（`INVALID_RESULT`、`REQUEST_TOO_LARGE`）
只会报告一次，然后丢弃 pending 结果继续轮询；相同的传输错误连续发生时也会去重。
如果真的看到刷屏：

1. `CaptureAiBridgeStatus` 看是否已进入 polling-halted 状态；
2. 需要取证时，显式导出待回传的结果：

   ```tcl
   CaptureAiBridgeDumpPendingResult C:/temp/pending_result.json
   ```

   该命令只在你调用时才写盘，文件不含 Bearer 令牌；没有 pending 结果时会明确报错。
   看完请自行决定是否删除这个文件——它含有脚本的输出内容。
3. `CaptureAiBridgeStop` 然后 `CaptureAiBridgeStart`。Stop→Start 会重置
   polling-halted、协议错误、退避延时和上次轮询错误，不会把故障状态带到下一个实例。

## 桥卡在 busy

现象：每次提交都返回 `BRIDGE_BUSY`。

- 确实有一条长时间运行的 Tcl 还在跑。HTTP 超时**不会**取消它，只能等它结束。
  `GET /v1/commands/{id}` 可以看当前状态。
- 如果 Capture 界面无响应，说明脚本占住了 Tcl/UI 线程，桥无法插手。
- 结果体不合法导致的卡死已经修复：服务端会合成一条 `INVALID_RESULT`
  完成结果并释放 busy。若仍观察到永久 busy，请按上一节导出 pending 结果留证。

## Stop 之后服务没退出

`CaptureAiBridgeStop` 是异步的。`CaptureAiBridgeStatus` 显示 `stopping`
表示正在等服务端确认；显示需要清理时，再执行一次 `CaptureAiBridgeStop` 重试。
退出 Capture 后，父进程监视器也会让服务退出并清掉描述文件。

## 卸载没删干净

`uninstall.ps1` 故意保留被本机改过的文件，并把它们留在清单里。
输出会逐个说明保留了什么。确实想删就加 `-ForceModified`。
它从不删除目标目录本身，也不碰目录里其他项目的文件。
