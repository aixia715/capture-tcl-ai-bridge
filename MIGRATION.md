# Capture Tcl AI bridge migration

This standalone repository imports the bridge baseline from
`D:\Documents\codeprj\tcl_bom`, worktree
`D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge`, on branch
`codex/tcl-bridge-impl`.

## Baseline and source state

- Baseline commit: `2b86475` (`2b864757c2e84fff9550b933dbca802a04398ecd`).
- The source working tree intentionally had uncommitted bridge work at import:
  - modified: `captureAiBridge.tcl`, `capture_tcl_bridge_server.py`,
    `readme.md`, `tests/test_capture_ai_bridge.tcl`,
    `tests/test_capture_tcl_bridge_server.py`,
    `docs/superpowers/plans/2026-08-02-capture-tcl-ai-bridge.md`, and
    `docs/superpowers/specs/2026-08-02-capture-tcl-ai-bridge-design.md`;
  - untracked: `capture_tcl_cli.py`,
    `tests/test_capture_tcl_cli.py`,
    `tests/test_capture_tcl_bridge_integration.py`, and transient `.tmp/`
    test artifacts.
- The source status and commit were reconfirmed immediately before copying.
  No source file was edited or deleted by this migration.

## Imported files

| Source | Destination |
| --- | --- |
| `captureAiBridge.tcl` | `captureAiBridge.tcl` |
| `capture_tcl_bridge_server.py` | `capture_tcl_bridge_server.py` |
| `capture_tcl_cli.py` | `capture_tcl_cli.py` |
| `readme.md` | `README.md` (temporary migration compatibility mapping) |
| `tests/test_capture_ai_bridge.tcl` | `tests/test_capture_ai_bridge.tcl` |
| `tests/test_capture_tcl_bridge_server.py` | `tests/test_capture_tcl_bridge_server.py` |
| `tests/test_capture_tcl_cli.py` | `tests/test_capture_tcl_cli.py` |
| `tests/test_capture_tcl_bridge_integration.py` | `tests/test_capture_tcl_bridge_integration.py` |

The service continues to use localhost port `8767`.  Its runtime descriptor
remains compatible with the existing `capture_tcl_bridge.json` contract.

## Acceptance boundary

`capture-tcl-ai-bridge` 现在是这份代码的唯一维护位置。

**桥本身已于 2026-08-08 通过真实 OrCAD Capture 16.6 验收**（Tcl 8.4.15）。
示例中的 flat-net 拓扑链路及其阶段二边界场景已经通过真实设计验证；
`selected_refs.tcl` 仍有下文记录的页面位号限制。

验收范围：安装、加载、启动/停止、CLI 四种调用、`puts` 双向 tee、并发串行化、
超时不取消、无效结果恢复、Token 轮换、退出 Capture 后 watchdog 收尾、
以及全部三个写入示例的真实修改与还原。**未**验收 OrCAD Capture 17.4——
本机没有该版本。

当前状态：

| 项目 | 状态 |
| --- | --- |
| `/internal/result` 确定性 4xx 导致刷屏与永久 busy | **真实 Capture 已验证**：合成 `INVALID_RESULT`、释放 busy，且同一失败只记录一次 |
| JSON 写出未转义反斜杠（Windows 路径产生非法 JSON） | **真实 Capture 已验证**：`puts "C:\\cadence\\SPB_16.6"` 正常返回 |
| Tcl 8.4 / OrCAD 16.6 兼容 | **真实 Capture 已验证**：桥在 16.6 加载运行，CLI 全通 |
| 只读示例对真实设计 | **已验证**：`list_components.tcl` 完整遍历 400+ 器件，位号/值/层次路径全对 |
| `get_component_value.tcl` 零匹配 | **已验证**：`COMPONENT_NOT_FOUND` |
| `set_component_value.tcl` 唯一匹配写入 | **已验证**：`68kR → 68kR-BRIDGETEST`，独立回读确认，已还原 |
| `set_component_value.tcl` 重复位号拒绝 | **未验证**：测试设计 411 个位号全唯一，无法构造（fixture 有覆盖） |
| 后缀追加 / 幂等 / 移除 | **已验证**：3 个器件 `100nF → 100nF*`；再跑一次 `changed 0 skipped 3`（无 `**`）；移除后回到 `100nF`，每步独立回读 |
| 写入不自动保存 | **已验证**：全部写入后设计仍为未保存状态 |
| 安装与卸载脚本 | 自动测试与临时目录 smoke 已通过 |
| `puts` tee（Capture 控制台 + 客户端双向） | **真实 Capture 已验证** |
| 并发串行化（`BRIDGE_BUSY`） | **真实 Capture 已验证**（并修复了长脚本期间误报 `CAPTURE_DISCONNECTED`） |
| 30 秒超时不取消脚本，结果可按 ID 取回 | **真实 Capture 已验证**：504 后 45 秒脚本仍跑完，`state=completed` |
| Tcl 8.4 上 `errorLine` 为 null | **真实 Capture 已验证**，与文档记载一致 |
| 无效结果合成 `INVALID_RESULT` 并释放 busy | **真实 Capture 已验证**：坏 JSON 后下一条命令正常返回 |
| Stop 清理描述文件 | **真实 Capture 已验证** |
| 退出 Capture 后 watchdog 收尾 | **真实 Capture 已验证**：8767 无监听、描述文件已删 |
| Token 每次启动轮换 | **真实 Capture 已验证**：Stop→Start 前后 token 的 SHA-256 不同，serverPid 也变化，其间描述文件确实被删除（全程未打印 token 明文） |
| 控制台不刷屏（同一确定性 4xx 只报一次） | **真实 Capture 已验证**：诊断日志中该次失败**恰好一条**记录 |

自动测试不等于真实验收，上表里凡是标"已验证"的都有真机证据；标"未验证"的
是真机上无法构造或未观察到的，不要当成已通过。

`tcl_bom` 仍是回退来源；不要把它的工作树或源文件作为本次迁移的一部分删除。

## 自动测试基线（2026-08-09）

```text
Python：357 passed, 1 skipped        （CAPTURE_TCL_TCLSH 指向真实 tclsh 8.4）
tests/test_capture_ai_bridge.tcl     8.4 与 8.6 均 0 FAIL
tests/test_capture_ai_compat.tcl     8.4 与 8.6 均 0 FAIL
tests/test_examples.tcl              8.4 与 8.6 均 0 FAIL
```

## Dbo API 假设：已实测，全部推翻

`examples/*.tcl` 第一版是对着**模拟的** Dbo 接口写的。2026-08-08 在真实
Capture 16.6 上实测，六条假设**无一成立**：

| 原假设 | 实测结果 |
| --- | --- |
| `GetActivePMSelection` 返回选择集 | 不存在；实际是全局命令 `GetSelectedObjects` |
| `GetObjectType` 返回 `occDbComponent` | 返回**整数**，具名常量形如 `$::DboBaseObject_PART_CELL` |
| 迭代器 `Next` 返回空字符串表示结束 | 方法名是 `NextOccurrence`/`NextFlatNet` 等，哨兵是字符串 `"NULL"` |
| 迭代器用 `delete` 方法释放 | 用全局函数 `delete_<迭代器类>` |
| pin/port 父访问器 `GetPartOccurrence` | 未确认；`DboFlatNet` 上根本没有 `NewPinOccurrencesIter` |
| 后缀标记作用在 Value 字段 | **已确认**：真实设计里 `HOLE*`、`100nF*`、`PIN*` 等空贴标记都在 Value 上 |

另外还发现三条第一版完全没有的约定：几乎所有调用都要 `DboState` 参数、
字符串出参必须用 `DboTclHelper_sMakeCString` 分配、基类句柄必须先用
`DboOccurrenceToDboInstOccurrence` 显式转型。

**最严重的一条**：类型专属函数不做类型检查，喂错类型的句柄会让 Capture
进程**直接闪退**而不是报错。探测过程中已实际触发过一次。

正确的调用约定见 [docs/capture-dbo-api-notes.md](docs/capture-dbo-api-notes.md)，
来源是实测加 Cadence 自带脚本。示例与 fixture 需按该文件重写。

## 已知限制：selected_refs.tcl 报不出真实位号

真机验证（层次化、已标注的设计）：选中 C209/C211/C214 三个器件后，脚本只输出
一行 `C?`。原因是标注把位号赋给 **occurrence**，而 `GetSelectedObjects` 返回的
页面级实例保留未标注占位符 `C?`；三个都读成 `C?`，去重后剩一个。

`Value` 在页面实例上读写都正确，所以两个后缀脚本不受影响、已验证通过。
补齐需要"页面实例 → occurrence"的关联，该 API 尚未确认。

## 已解决：extract_topology.tcl 完整端点解析

2026-08-09 在真实 Capture 16.6 上确认
`DboPortOccurrence_sGetPathName` 与 `GetPortInst` 链路，并用
`REF_INPUT` 验证得到 `SMA-19.1`、`R377.1`、`R380.1`。
脚本现在输出网络、器件位号、引脚号、引脚名和 occurrence 路径，不再输出
没有端点意义且恒为 1 的 `netOccurrenceCount`。

同日完成阶段二完整边界验收：

| 场景 | 真机结果 |
| --- | --- |
| 普通网络 `REF_INPUT` | `SMA-19.1`、`R377.1`、`R380.1`，完全匹配 |
| 复用模块同名网络 `PD_DC_N_1` | 正确区分各模块 flat net；`FNC-SP` 的 5 个端点完全匹配 |
| 全局网络 `VCC_+12V` | 正确合并 TOP 与四个复用模块，7 个端点完全匹配 |
| 未命名网络 | 2 个端点与人工结果完全匹配 |
| 72 位总线 | 72 个成员、144 个端点；无缺失且每成员恰好 2 个端点 |
| 跨页连接器 | 两侧端点与人工结果完全匹配，连接器未被误报为器件端点 |
| 多单元器件 | 所选单元 16 个已连接引脚全部找到；物理器件 1575 个端点无重复 |

## 已知的验收环境限制

用于验证的虚拟机装的是 OrCAD SPB 16.6，其 Capture 链接 `tcl84.dll`（Tcl 8.4.15），
整个 SPB_16.6 树中没有任何 8.5/8.6 运行时，`http` 包为 2.5.3（不支持 `-method`）。
桥因此加入了 Tcl 8.4 兼容层和自带 JSON 解析器，两个 Capture 版本共用同一份源码。
Tcl 8.4 的 `catch` 没有选项字典，所以 16.6 上 `errorLine` 恒为 `null`；
这是记录在案的平台差异，不是缺陷。

## MCP Current Selection 验收状态（2026-08-12）

OrCAD Capture 16.6 上已通过只读真机链路：当前选择中的 U3 从 page instance
解析到 occurrence，并返回设计路径、`refdes/path`、页面名和 `object_id=3324`；
design-wide 查询对同一 occurrence 反向解析出相同 page instance；默认 Value 与
PCB Footprint 在两个入口完全一致；不存在属性返回 `present:false`，重复属性名被
去重。未修改、未保存设计。

仍需人工完成：七类非器件代表字段、层次设计 occurrence → page instance 反查、
非原理图焦点错误，以及 OrCAD Capture 17.4 的同组验收。自动 fixture 覆盖不替代
这些原生 DBO 调用的真机证明。
