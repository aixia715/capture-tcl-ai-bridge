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
| JSON 写出未转义反斜杠（Windows 路径产生非法 JSON） | 自动测试已修复，真实 Capture **待验收** |
| Tcl 8.4 / OrCAD 16.6 兼容 | 自动测试已通过（8.4 与 8.6 双跑），真实 Capture **待验收** |
| 安装与卸载脚本 | 自动测试与临时目录 smoke 已通过 |

自动测试不等于真实验收。在真实 Capture 中签收之前，`tcl_bom` 仍是回退来源；
不要把它的工作树或源文件作为本次迁移的一部分删除。

## 待真实 Capture 确认的 Dbo API 假设

`examples/*.tcl` 是对着**模拟的** Dbo 接口写并测试的，没有链接真实 Capture。
下面这些形状必须在真实验收时逐条确认；任何一条不成立，对应示例就要改：

| 假设 | 风险 |
| --- | --- |
| `GetActivePMDesign` / `GetActivePMSelection` 是全局命令，直接返回句柄 | 中 |
| 组件 occurrence 的 `GetObjectType` 返回字符串 `occDbComponent` | **高**——示例只判等，没有枚举其他取值 |
| 迭代器耗尽时 `Next` 返回空字符串 | 中 |
| 迭代器用 `delete` 方法释放（而非 `Delete` 或引用计数） | 中 |
| pin/port occurrence 提供 `GetName`、`GetNumber`、`GetPartOccurrence` | **高**——`GetPartOccurrence` 是推测的父对象访问器 |
| `GetSelectedObjects` 直接返回句柄列表，而不是迭代器 | 中 |

验收时建议先用 CLI 逐条打印这些调用的真实返回值，再跑示例。

## 已知的验收环境限制

用于验证的虚拟机装的是 OrCAD SPB 16.6，其 Capture 链接 `tcl84.dll`（Tcl 8.4.15），
整个 SPB_16.6 树中没有任何 8.5/8.6 运行时，`http` 包为 2.5.3（不支持 `-method`）。
桥因此加入了 Tcl 8.4 兼容层和自带 JSON 解析器，两个 Capture 版本共用同一份源码。
Tcl 8.4 的 `catch` 没有选项字典，所以 16.6 上 `errorLine` 恒为 `null`；
这是记录在案的平台差异，不是缺陷。
