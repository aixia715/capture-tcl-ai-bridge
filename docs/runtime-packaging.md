# 离线运行时打包

发布 workflow 生成 Windows x64 ZIP：其中包含 Python 3.12 embeddable runtime、FastAPI、
Uvicorn、全部传递依赖，以及 bridge、CLI 与 MCP server 文件。终端用户只需运行
`install.ps1`；安装过程不会下载依赖，也不会使用系统 Python。

仓库不会提交 `runtime/` 目录：它只在 Release archive 的构建过程中生成。因此直接在
源码 checkout 运行 `install.ps1` 会提示缺少 bundled runtime，这是预期行为。
