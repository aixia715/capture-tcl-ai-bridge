# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。

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
