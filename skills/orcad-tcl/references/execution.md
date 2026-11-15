# 运行环境、执行与验证

## 1. 选择环境

| 环境 | 访问对象 | 条件 |
| --- | --- | --- |
| Capture Tcl 控制台 | 正在打开的设计与当前选择 | 已运行 Capture 并打开相应设计/页面 |
| AiBridge | 同一个 Capture 全局 Tcl 解释器 | 已安装并启动桥，Capture 正在处理事件 |
| 独立 Cadence tclsh + DBO DLL | 磁盘 DSN | 匹配的 Cadence 运行时和有效许可证，不依赖 GUI |

Windows 路径推荐 `/`，含空格时正确引用。Linux agent 生成的脚本最终在 Windows
Capture 上执行；`source`、输出文件和 DSN 路径都按执行主机解释。

## 2. Tcl 8.4 / 8.6 与全局解释器

Capture 16.6 的典型环境为 Tcl 8.4，17.4 为 Tcl 8.6，以 `info patchlevel` 为准。
包内多个 GUI 示例使用 `try/dict/lassign`：8.6 可直接用；AiBridge 在 8.4 中提供了
其需要的兼容子集。普通 8.4 控制台或 standalone 不自动拥有这些命令。

独立 8.4 代码使用 `catch` 加显式清理替代 try/finally。下面是保留错误信息的清理模式，
其中实际资源释放逻辑放在标注处：

```tcl
set code [catch {
    # 资源使用和业务逻辑；此块约定正常结束或抛 error。
} result]
if {$code == 1} {
    set savedInfo $::errorInfo
    set savedCode $::errorCode
}
# 无论成功失败都释放自己创建的状态对象和 iterator。
if {$code == 1} {
    return -code error -errorinfo $savedInfo -errorcode $savedCode $result
}
if {$code != 0} { return -code $code $result }
```

新脚本用独立 namespace 包裹辅助过程，结束后清理自身临时变量。
避免覆盖其他脚本或桥的辅助函数；包内独立示例使用全局过程，整合时需改名或封装。

用户输入用 `list` 构造命令参数或按 UTF-8 hex 编码后解码，不直接拼成 Tcl 源码：

```tcl
set newValue [encoding convertfrom utf-8 [binary format H* {3130306e46}]]
# 上面的 hex 表示 100nF；实际由调用端编码输入。
```

## 3. 控制台执行

先在 Windows 主机可访问的位置保存脚本，再在 Capture 执行：

```tcl
source {C:/work/read_components.tcl}
```

小范围只读调用成功后再运行修改。脚本在 UI 线程执行，大范围遍历和模态对话框会阻塞界面。
GUI 属性修改通常只改变内存，包内 GUI 写示例不自动保存；任务要求保存时需另外实现并验证
目标版本已确认的保存方式，不能推测 GUI Save 命令。

## 4. 已安装 AiBridge 时

本技能不附带桥的安装程序；以下适用于已经安装的默认路径。

```powershell
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py --json -c "expr {6 * 7}"
C:\tclpython\runtime\python.exe C:\tclpython\capture_tcl_cli.py --json -f "C:\work\read_components.tcl"
```

远程通过已配置的 HTTP 地址和当前 Bearer token 提交 JSON：

```json
{"script":"puts hello\nexpr {6 * 7}"}
```

目标接口为 `POST /v1/execute`，请求头为 `Content-Type: application/json` 和
`Authorization: Bearer <token>`。使用 JSON 序列化器处理多行和转义。
脚本参数与输出不要拼入 URL。远程访问需要 Windows 桥监听可达网卡且端口已放行；
默认仅本机回环。token 可由操作者通过 Capture `AiBridge status` 获取，每次启动轮换。
令牌不写入脚本、提交或测试报告。

执行响应中检查 `ok/returnCode/result/stdout/stderr/errorInfo/errorCode/errorLine`。
HTTP 200 也可能包含 Tcl 失败；16.6/8.4 的 errorLine 可能为 null。
`resultTruncated/stdoutTruncated/stderrTruncated` 表示输出不完整，需要缩小查询范围。

同一桥串行提交。504 超时不取消已经执行的脚本，拿到 command id 后使用
`GET /v1/commands/{id}` 查询原命令；避免重复提交可能仍在执行的写操作。
连接异常先检查 `GET /v1/health` 的 `captureConnected`，健康接口也要求 token。
仅端口通或 health 200 不足以证明脚本已执行。

### Tcl 事件循环诊断

真实使用中曾出现桥停留在 starting，手动 `update; AiBridge status` 后才连接。
排除模态窗口和长脚本后，可让操作者短时间运行事件循环，以便外部测试程序提交命令：

```tcl
after 20000 {set ::OrcadAgentTestDone 1}
vwait ::OrcadAgentTestDone
unset ::OrcadAgentTestDone
```

这是有界测试窗口，不是永久修复；应在 Capture 控制台执行，而非通过卡住的桥自修复。
测试报告注明是否依赖手动驱动事件循环。

## 5. Standalone DBO / 离线 DSN

包内 [离线示例](../examples/headless_set_first_capacitor_value.tcl) 使用 `cds_root cds_root`
找到 Cadence，然后加载 `tools/capture/orDb_Dll_TCL`（DboTclWriteBasic），创建 session，
通过 GetDesignAndSchematics 打开 DSN，修改并 SaveDesign，最后 RemoveLib/DeleteSession。
本项目离线路径依据 SPB 16.6 的匹配 tclsh/DLL 验证；不要混用不同版本或位数的运行时。

该脚本会直接覆盖输入 DSN 的第一个匹配电容，只对测试副本执行：

```powershell
& 'C:\Cadence\SPB_16.6\tools\tcl84\bin\tclsh.exe' `
  '<技能目录>\examples\headless_set_first_capacitor_value.tcl' `
  'C:\work\test-copy.DSN' '100nF'
```

生产任务采用：明确输入/输出 → 私有副本 → 精确 refdes/path 修改 → 保存 →
全新进程打开并回读 → 验证成功后发布输出。
锁文件反映设计占用，不能自行删锁强行覆盖；离线读取看到的是磁盘上次保存状态。
保持许可证环境可用；启动 Capture GUI 成功不等于独立进程也继承了许可配置。

## 6. 验收清单

- 记录目标版本及执行环境，明确真实运行或仅静态检查。
- 只读：核对设计、对象数量、层次路径、缺失与空值、未连接引脚；完整性受截断影响。
- 写入：目标唯一、before/after 可解释、回读等于预期值；声明是否保存。
- 离线：验证输出 DSN 可由新进程重开，且目标属性真实持久化。
- 错误路径：无设计、空选择、重复 refdes、属性不存在、DBO 状态失败均能给出可读结果。
- 清理：状态与 iterator 正常和异常路径都释放；不删借用的设计对象，不缓存跨执行句柄。

一次示例成功不证明所有对象/版本兼容；没有目标环境时交付脚本并列出需要现场验证的分支。
