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

`capture-tcl-ai-bridge` 现在是这份代码的唯一维护位置，但**尚未通过真实 OrCAD
Capture 验收**。当前状态：

| 项目 | 状态 |
| --- | --- |
| `/internal/result` 确定性 4xx 导致刷屏与永久 busy | 自动测试已修复，真实 Capture **待验收** |
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

自动测试不等于真实验收。在真实 Capture 中签收之前，`tcl_bom` 仍是回退来源；
不要把它的工作树或源文件作为本次迁移的一部分删除。

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

## 已知限制：extract_topology.tcl 尚不可用

真机验证显示该示例能跑完不报错，但输出**达不到它的用途**：只有网络名和引脚
编号，没有引脚所属的器件位号，因此无法回答"这条网络连了哪些器件的哪些脚"。
`netOccurrenceCount` 恒为 1，说明 net occurrence 不是逐引脚的对象。

补齐需要"从 port occurrence 回到所属器件 occurrence"的访问器，该 API 尚未确认。
文件头部记录了安全的探测方式。其余六个示例不受影响。

## 已知的验收环境限制

用于验证的虚拟机装的是 OrCAD SPB 16.6，其 Capture 链接 `tcl84.dll`（Tcl 8.4.15），
整个 SPB_16.6 树中没有任何 8.5/8.6 运行时，`http` 包为 2.5.3（不支持 `-method`）。
桥因此加入了 Tcl 8.4 兼容层和自带 JSON 解析器，两个 Capture 版本共用同一份源码。
Tcl 8.4 的 `catch` 没有选项字典，所以 16.6 上 `errorLine` 恒为 `null`；
这是记录在案的平台差异，不是缺陷。
