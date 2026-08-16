# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

## [0.1.0-beta.5] - 2026-08-16

### Changed

- Capture Tcl 生命周期 Interface 从 `CaptureAiBridgeStart`、
  `CaptureAiBridgeStatus`、`CaptureAiBridgeStop` 合并为 `AiBridge start`、
  `AiBridge status`、`AiBridge stop`；旧的三个命令已移除。

## [0.1.0-beta.4] - 2026-08-15

### Added

- 新增 `capture_nogui_read_dsn_component_properties` 与
  `capture_nogui_set_dsn_component_property`，通过 SPB 16.6 standalone DBO Session
  在不启动 Capture GUI 的情况下读取或持久化修改 DSN。
- 离线写入使用私有 staging、`.DSNlck` 防护、输出副本或显式原地发布、临时备份、
  独立写入/验证进程和可配置超时。

### Changed

- `capture_set_component_property` 现在可以创建完全缺失的 occurrence property；
  新旧 setter 的 `before`/`after` 都改用 `present/value` 记录。
- Embedded Python runtime 现在把安装目标父目录加入模块搜索路径，并在 Release
  smoke test 中实际启动 MCP server，避免同级模块导入失败。
- Offline Design 子进程在 Hermes 未继承许可证变量时，会从 Windows 用户或机器
  持久环境补齐 `CDS_LIC_FILE`/`LM_LICENSE_FILE`，避免误报 `ORDBDLL-1017`。

### Validated

- SPB 16.6 真机验证了 `FNC_PD.DSN` 的无 GUI 完整 Component Information 读取、
  缺失属性输出副本写入、第二进程重开验证、源文件哈希不变和原地发布备份清理。

## [0.1.0-beta.3] - 2026-08-12

### Added

- Release ZIP 现在内置 Python 3.12 embeddable runtime、FastAPI、Uvicorn 及其依赖；
  用户无需安装系统 Python、pip 或第三方包即可运行 `install.ps1`。
- 安装清单升级到 schema 3，记录桥接专用 `runtime\python.exe`；Capture 启动桥接时
  固定使用该解释器。安装器会检测每个已存在的 Capture `capAutoLoad` 目录。

- 新增本地 stdio Capture MCP Server，向 Codex、Claude Code、Hermes 等 Agent
  暴露元器件属性读取与单项属性修改工具；写入后立即回读，但不自动保存设计。
- 同时支持初始化式 MCP `2024-11-05` 至 `2025-11-25` 和无状态
  `2026-07-28` 协议，并提供严格参数校验、Tcl 注入隔离及结构化结果。
- 安装器和卸载器现在把 `capture_mcp_server.py` 纳入带 SHA-256 的所有权清单。

- 新增只读 MCP 工具 `capture_inspect_selection`，在调用时读取当前原理图选择，
  支持器件、层次块、标量/总线、全局符号、跨页连接器、文字、端口和标题栏；
  混合选择保序返回，未知类型不会被误当成可定位对象。
- 组件查询现在同时返回 occurrence（design/refdes/path）与 page instance
  （design/page/object_id）双定位信息。

### Changed

- `capture_read_component_properties` 与 `capture_inspect_selection` 共用 Component
  Information 和属性读取逻辑。默认属性改为 `Value`、`PCB Footprint`；显式属性名
  替换默认值并按首次出现去重。
- 属性结果现在用 `present` 区分缺失、存在空字符串和值。这是 beta 输出契约的
  不兼容变更；旧的 `{refdes,path,properties:{name:value}}` 结构不再返回。
- MCP 指令明确要求“当前/新选择”在写入前刷新 selection，明确的先前对象才复用
  locator，歧义写入目标不得猜测。

### Validated

- 自动 MCP 测试覆盖两代协议发现、空/异构/未知选择、双定位、属性缺失与空值、
  对象级错误隔离、截断、Unicode 和 Tcl 注入隔离。
- OrCAD Capture 16.6 真机只读验证了选中 U3 的 page instance → occurrence 映射、
  design-wide occurrence → page instance 反查、两个入口相同输出及缺失属性语义。

## [0.1.0-beta.2] - 2026-08-09

### Added

- Capture Tcl、运行描述文件、`/v1/health` 和 CLI `status` 公开同一软件版本，
  并拒绝连接版本不一致的部署文件。

## [0.1.0-beta.1] - 2026-08-09

首个公开 beta 候选版本。

### Added

- 通过经认证的 localhost HTTP/CLI 通道，在正在运行的 OrCAD Capture Tcl
  解释器中执行脚本并返回 stdout、stderr、结果和 Tcl 错误详情。
- 显式启动/停止、随机 Bearer token、Capture PID 校验、单命令串行化、30 秒
  等待超时与完成结果查询。
- Windows 安装、可选自启和保守卸载脚本。
- 原理图只读检查、器件属性修改、headless DSN BOM 及 flat-net 拓扑示例。
- 中文协议、安全、故障排查、Cookbook 和真实 Capture 验收文档。
- MIT License。

### Validated

- 自动测试：357 passed, 1 skipped。
- OrCAD Capture 16.6 / Tcl 8.4.15：桥生命周期、CLI/HTTP、错误恢复、并发、
  超时、token 轮换、只读和写入示例均已真机验证。
- flat-net 拓扑真机覆盖普通网络、复用模块同名网络、全局电源网络、未命名网络、
  72 位总线、跨页连接器和多单元器件。

### Known limitations

- OrCAD Capture 17.4 / Tcl 8.6 有自动兼容测试和随附 API 文档支撑，但尚未真机验收。
- `selected_refs.tcl` 对已标注的层次设计可能只能读取页面占位位号；需要真实位号时
  使用 `selected_occurrence_refs.tcl` 或 `inspect_selected_components.tcl`。
- 重复位号写入拒绝已由 fixture 覆盖，但当前真机设计没有重复位号，尚无真机案例。
- 本仓库是执行中间层，不是自然语言 Agent 或 MCP Server；AI 客户端通过 CLI 或
  HTTP 协议调用它。

[0.1.0-beta.1]: https://github.com/aixia715/capture-tcl-ai-bridge/releases/tag/v0.1.0-beta.1
[0.1.0-beta.2]: https://github.com/aixia715/capture-tcl-ai-bridge/compare/v0.1.0-beta.1...v0.1.0-beta.2
[0.1.0-beta.3]: https://github.com/aixia715/capture-tcl-ai-bridge/compare/v0.1.0-beta.2...v0.1.0-beta.3
[0.1.0-beta.4]: https://github.com/aixia715/capture-tcl-ai-bridge/compare/v0.1.0-beta.3...v0.1.0-beta.4
[0.1.0-beta.5]: https://github.com/aixia715/capture-tcl-ai-bridge/compare/v0.1.0-beta.4...v0.1.0-beta.5
