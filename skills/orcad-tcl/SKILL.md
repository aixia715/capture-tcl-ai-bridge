---
name: orcad-tcl
description: 为 OrCAD Capture 编写、修改和排查 Tcl/DBO 脚本。用于读取当前选择、遍历层次器件、查询或修改属性、提取引脚网络拓扑，以及独立 DBO 进程读写 DSN；需要通过 Capture 控制台或 AiBridge 执行 Tcl 时也使用。
---

# OrCAD Capture Tcl 编写技能

本目录是自包含静态技能包。将整个 `orcad-tcl` 文件夹复制到目标项目的
`.agents/skills/`，使入口为 `.agents/skills/orcad-tcl/SKILL.md`。
参考路径全部相对此文件所在目录，读取时不依赖 agent 的当前工作目录。
技能不安装 Cadence、Python 或 AiBridge；完整示例已随包提供，无需原始仓库。

## 编写流程

1. **明确执行环境与目标。** 确认 Capture 版本、Tcl `info patchlevel`、GUI 还是
   standalone DBO、当前选择还是指定设计、读取还是写入、是否需要保存。
   结束条件：知道脚本运行在哪里、处理哪些对象及是否落盘。
2. **读取匹配参考。** 先读 [DBO 调用约定](references/dbo-api.md)，按
   [示例索引](references/examples.md) 选择并读取最接近的完整 Tcl 脚本。
   独立进程/桥内执行和错误处理参见 [执行与验证](references/execution.md)。
   结束条件：对象族、实际 API 签名、状态及资源清理方式均有包内依据。
3. **先只读定位。** 用户说“当前/刚选中”时重新读取选择；整设计查询先输出
   refdes 和 occurrence path。一个 refdes 可以对应多个层次实例，写入必须唯一。
   页面对象与 occurrence 分别解析，跨调用保存定位信息而非原生句柄。
4. **实现脚本。** 参数与逻辑分开；用户输入通过 Tcl list 或 UTF-8 hex 编码作为数据。
   每次 DBO 调用检查对应状态，类型专属调用前判类型并转型，清理自己拥有的资源。
   修改记录 before，重新读取 after；只读脚本不隐式保存，写入按任务明确保存语义。
5. **运行并验证。** 先做小范围只读试运行，再验证目标修改。检查 Tcl 返回码及业务
   回读值，而非仅检查 HTTP 200 或进程退出。仅做语法检查时明确标为“未在 Capture 验证”。
6. **交付。** 给出脚本、执行命令、输入参数、适用版本、输出解释及保存行为。
   报告测试目标、实际返回值和未验证的分支；离线落盘需独立进程重开回读。

## 按需读取

| 任务 | 文件 |
| --- | --- |
| DboState、CString、对象类型、迭代器、属性语义 | [DBO 参考](references/dbo-api.md) |
| 查找可以改写的完整示例 | [12 个示例的索引](references/examples.md) |
| Tcl 8.4/8.6、控制台/AiBridge、离线 DSN、超时与验收 | [执行参考](references/execution.md) |
| 许可 | [LICENSE](LICENSE) |

## 使用边界

- 本技能来自 Capture Tcl AI Bridge 项目中的真实实现与示例，主要涉及 Capture
  16.6 / Tcl 8.4 和 17.4 / Tcl 8.6；不是所有版本、对象和 API 的通用保证。
- 原生 DBO 错类型句柄可能使 Capture 进程崩溃，`catch` 只能捕获 Tcl 错误。
  包内没有依据的新 API，先查目标机器的官方签名；无法确认时说明缺口，不类推调用。
- 完整示例是阅读起点，不都是生产级模板。尤其离线“第一个电容”示例会直接保存，
  选择诊断脚本可能将属性失败简化为空；按任务补上精确定位、presence 和错误清理。
- 原始示例会定义全局辅助过程。整合到其他项目时使用项目自己的命名空间，避免互相覆盖。
