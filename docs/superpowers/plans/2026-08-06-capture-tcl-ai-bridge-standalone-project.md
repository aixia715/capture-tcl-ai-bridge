# Capture Tcl AI Bridge 独立项目实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Capture Tcl AI Bridge 从 TCLBOM 干净迁移到 `D:\Documents\codeprj\capture-tcl-ai-bridge`，形成可独立安装、使用、测试和卸载的 Git 项目，并修复 `/internal/result` 确定性 4xx 导致控制台刷屏和永久 `busy` 的缺陷。

**Architecture:** 保留现有 Capture Tcl 轮询端、localhost FastAPI broker 和共享 HTTP/CLI 执行链路；用 `%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json` 解耦部署路径。先在新仓库完成导入、修复、文档、示例和自动测试，再用真实 Capture 验收；只有验收通过后才从 TCLBOM 删除重复实现。

**Tech Stack:** Windows PowerShell 7、Python 3.12+、FastAPI、Uvicorn、pytest、Tcl 8.x、OrCAD Capture 17.4 Dbo Tcl API、Git。

---

## 执行约束

- 使用 `superpowers:subagent-driven-development`，每个 Task 交给一个新的实现子代理；父代理在每个 Task 后检查 spec 覆盖、代码质量和测试输出，再进入下一 Task。
- Task 1 至 Task 10 顺序执行；它们修改同一新仓库，不并行。Task 11 必须等真实 Capture 验收通过后才能执行。
- 创建和写入 `D:\Documents\codeprj\capture-tcl-ai-bridge` 前，执行代理必须取得该目录的文件系统写入权限。
- 不清理、不重置、不删除来源工作树 `D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge`；其中未提交改动是迁移输入。
- 除机械复制外，新增或修改文本文件使用 `apply_patch`。
- 每次修改 `captureAiBridge.tcl` 后，交付说明必须包含：

  ```tcl
  source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
  ```

- 自动测试不能替代 Task 10 的真实 OrCAD Capture 17.4 验收。
- 每个 Task 标出的 **Working directory** 是强制执行上下文。子代理调用 shell 工具时必须显式设置该 `workdir`；不得依赖上一条命令的 `Set-Location` 状态。

## 固定路径和基线

```text
来源仓库：D:\Documents\codeprj\tcl_bom
来源工作树：D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge
来源分支：codex/tcl-bridge-impl
来源提交：2b86475 feat: connect Capture Tcl to AI bridge
设计提交：d1312d8 docs: design standalone Capture Tcl AI bridge
目标仓库：D:\Documents\codeprj\capture-tcl-ai-bridge
目标默认分支：main
```

当前迁移源的桥接测试基线：

```text
Python bridge tests: 236 collected, zero failed/error
Tcl bridge test: PASS: capture AI bridge execution helpers
```

不同 Windows 进程/权限条件会改变平台相关 skip 的数量；已观察到 `232 passed, 4 skipped` 和缺 README 时的 `234 passed, 1 skipped, 1 failed`。因此门禁固定总收集数和零失败，不固定 pass/skip 的分配；每次执行仍须记录实际 pass/skip 数。

系统临时目录可能因 Windows ACL 导致 pytest `PermissionError`。所有计划中的 pytest 命令均把 `TEMP` 和 `TMP` 指到仓库内 `.tmp`，不能把该环境错误解释为产品测试失败。

---

## Task 1：建立干净的独立仓库和可复现迁移基线

**Working directories:** Step 1 使用 `D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge`；Step 2-7 使用 `D:\Documents\codeprj\capture-tcl-ai-bridge`（目录创建前的 Step 2 使用其父目录 `D:\Documents\codeprj`）。

**Files:**

- Create: `D:\Documents\codeprj\capture-tcl-ai-bridge\.gitignore`
- Create: `D:\Documents\codeprj\capture-tcl-ai-bridge\requirements.txt`
- Create: `D:\Documents\codeprj\capture-tcl-ai-bridge\requirements-dev.txt`
- Create: `D:\Documents\codeprj\capture-tcl-ai-bridge\pytest.ini`
- Create: `D:\Documents\codeprj\capture-tcl-ai-bridge\MIGRATION.md`
- Copy and rename: source `readme.md` → target `README.md`
- Copy: `captureAiBridge.tcl`
- Copy: `capture_tcl_bridge_server.py`
- Copy: `capture_tcl_cli.py`
- Copy: `tests\test_capture_ai_bridge.tcl`
- Copy: `tests\test_capture_tcl_bridge_server.py`
- Copy: `tests\test_capture_tcl_cli.py`
- Copy: `tests\test_capture_tcl_bridge_integration.py`

- [ ] **Step 1：重新核对来源状态，禁止静默丢失未提交修正**

  Run:

  ```powershell
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge status --short
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge rev-parse HEAD
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge diff --check
  ```

  Expected: HEAD 为 `2b864757c2e84fff9550b933dbca802a04398ecd`；桥接 Tcl/Python/测试的 modified/untracked 状态与迁移说明一致；`diff --check` 无输出。若来源在计划后继续变化，先把新的文件列表和来源 HEAD 写入 `MIGRATION.md`，再复制。

- [ ] **Step 2：创建新目标，或严格恢复尚未初始化 Git 的 Task 1 目录**

  Run:

  ```powershell
  $src = 'D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge'
  $dst = 'D:\Documents\codeprj\capture-tcl-ai-bridge'
  if (-not (Test-Path -LiteralPath $dst)) {
      New-Item -ItemType Directory -Path "$dst\tests" | Out-Null
      New-Item -ItemType Directory -Path "$dst\docs" | Out-Null
      New-Item -ItemType Directory -Path "$dst\examples" | Out-Null
  } else {
      if (Test-Path -LiteralPath "$dst\.git") {
          throw 'Target already has .git; inspect repository state instead of resuming Task 1.'
      }

      $allowedTopFiles = @(
          '.gitignore', 'requirements.txt', 'requirements-dev.txt', 'pytest.ini',
          'MIGRATION.md', 'README.md', 'captureAiBridge.tcl',
          'capture_tcl_bridge_server.py', 'capture_tcl_cli.py'
      )
      $allowedTopDirs = @(
          'tests', 'docs', 'examples', '__pycache__', '.pytest_cache', '.tmp'
      )
      $unknownTop = @(Get-ChildItem -LiteralPath $dst -Force | Where-Object {
          if ($_.PSIsContainer) { $_.Name -notin $allowedTopDirs }
          else { $_.Name -notin $allowedTopFiles }
      })
      if ($unknownTop.Count -ne 0) {
          throw "Unknown top-level migration content: $($unknownTop.Name -join ', ')"
      }

      $allowedTests = @(
          'test_capture_ai_bridge.tcl', 'test_capture_tcl_bridge_server.py',
          'test_capture_tcl_cli.py', 'test_capture_tcl_bridge_integration.py',
          '__pycache__'
      )
      $unknownTests = @(Get-ChildItem -LiteralPath "$dst\tests" -Force | Where-Object {
          $_.Name -notin $allowedTests
      })
      if ($unknownTests.Count -ne 0) {
          throw "Unknown migrated test content: $($unknownTests.Name -join ', ')"
      }
      if (@(Get-ChildItem -LiteralPath "$dst\docs" -Force).Count -ne 0 -or
          @(Get-ChildItem -LiteralPath "$dst\examples" -Force).Count -ne 0) {
          throw 'docs/examples contain work beyond Task 1; inspect manually.'
      }

      $sourcePairs = @(
          @('captureAiBridge.tcl', 'captureAiBridge.tcl'),
          @('capture_tcl_bridge_server.py', 'capture_tcl_bridge_server.py'),
          @('capture_tcl_cli.py', 'capture_tcl_cli.py'),
          @('tests\test_capture_ai_bridge.tcl', 'tests\test_capture_ai_bridge.tcl'),
          @('tests\test_capture_tcl_bridge_server.py', 'tests\test_capture_tcl_bridge_server.py'),
          @('tests\test_capture_tcl_cli.py', 'tests\test_capture_tcl_cli.py'),
          @('tests\test_capture_tcl_bridge_integration.py', 'tests\test_capture_tcl_bridge_integration.py'),
          @('readme.md', 'README.md')
      )
      foreach ($pair in $sourcePairs) {
          $targetFile = Join-Path $dst $pair[1]
          if (-not (Test-Path -LiteralPath $targetFile)) { continue }
          $sourceHash = (Get-FileHash -LiteralPath (Join-Path $src $pair[0]) -Algorithm SHA256).Hash
          $targetHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
          if ($sourceHash -ne $targetHash) {
              throw "Migrated source differs from Task 1 input: $($pair[1])"
          }
      }
  }
  ```

  Expected: 新目录创建成功，或确认它是可恢复的 Task 1 中断目录。恢复模式允许测试生成的 `.tmp/.pytest_cache/__pycache__`，但不读取、删除或暂存它们；任何未知文件、已有 `.git`、已修改迁入源码或非空 docs/examples 都必须停止人工检查。

- [ ] **Step 3：机械复制桥接运行文件和测试**

  Run:

  ```powershell
  $src = 'D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge'
  $dst = 'D:\Documents\codeprj\capture-tcl-ai-bridge'
  Copy-Item -Force -LiteralPath "$src\captureAiBridge.tcl","$src\capture_tcl_bridge_server.py","$src\capture_tcl_cli.py" -Destination $dst
  Copy-Item -Force -LiteralPath "$src\readme.md" -Destination "$dst\README.md"
  Copy-Item -Force -LiteralPath "$src\tests\test_capture_ai_bridge.tcl","$src\tests\test_capture_tcl_bridge_server.py","$src\tests\test_capture_tcl_cli.py","$src\tests\test_capture_tcl_bridge_integration.py" -Destination "$dst\tests"
  ```

  Expected: 3 个运行文件、4 个测试文件和 `README.md` 存在；来源工作树不发生变化。此 README 只是为了保持迁入测试的基线依赖，Task 6 会把其中混合的 TCLBOM 内容重写为独立项目文档。

- [ ] **Step 4：写入最小依赖和忽略规则**

  `.gitignore` 内容：

  ```gitignore
  __pycache__/
  .pytest_cache/
  .tmp/
  *.py[cod]
  *.log
  capture_tcl_bridge.json
  capture_tcl_bridge.*.tmp
  ```

  `requirements.txt` 内容：

  ```text
  fastapi>=0.115,<0.116
  uvicorn>=0.30.6,<0.31
  ```

  `requirements-dev.txt` 内容：

  ```text
  -r requirements.txt
  httpx>=0.27.2,<0.28
  pytest>=8.3.3,<9
  pytest-asyncio>=0.24,<0.25
  ```

  `pytest.ini` 内容：

  ```ini
  [pytest]
  asyncio_default_fixture_loop_scope = function
  ```

- [ ] **Step 5：写入明确的迁移来源**

  `MIGRATION.md` 至少记录：来源仓库、`codex/tcl-bridge-impl`、基线 `2b86475`、当前 modified/untracked 桥接文件、`readme.md` → `README.md` 的临时基线映射、其他文件映射、端口 `8767`、描述文件兼容性、未解决的 HTTP 400 缺陷、TCLBOM 在真实验收前仍作为回退来源。不得写成已经验收或已经删除来源。

- [ ] **Step 6：在新位置验证原始基线**

  Run:

  ```powershell
  Set-Location D:\Documents\codeprj\capture-tcl-ai-bridge
  $taskTemp = Join-Path (Get-Location) '.tmp\baseline'
  New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
  $env:TEMP = $taskTemp
  $env:TMP = $taskTemp
  python -m pytest tests/test_capture_tcl_bridge_server.py tests/test_capture_tcl_cli.py tests/test_capture_tcl_bridge_integration.py -q
  tclsh tests/test_capture_ai_bridge.tcl
  ```

  Expected: pytest 收集 236 项，全部结果只能是 passed/skipped，且 `failed=0`、`errors=0`；记录本次实际 pass/skip 数。Tcl 输出末行包含 `PASS: capture AI bridge execution helpers`。

- [ ] **Step 7：初始化干净 Git 历史并提交**

  Run:

  ```powershell
  Set-Location D:\Documents\codeprj\capture-tcl-ai-bridge
  git init -b main
  git add .gitignore requirements.txt requirements-dev.txt pytest.ini README.md MIGRATION.md captureAiBridge.tcl capture_tcl_bridge_server.py capture_tcl_cli.py tests
  git commit -m "chore: import Capture Tcl AI bridge"
  git status --short
  ```

  Expected: 创建首个独立提交；最后 `git status --short` 无输出。

---

## Task 2：让服务端在无效当前结果上释放 `busy`

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Modify: `capture_tcl_bridge_server.py:497-505,629-684,760-791`
- Modify: `tests/test_capture_tcl_bridge_server.py:495-615`
- Modify: `tests/test_capture_tcl_bridge_integration.py`

- [ ] **Step 1：先把旧的“无效结果保留 active”测试拆成安全边界测试**

  保留并强化以下行为：

  - 已完成结果的幂等重投仍返回 completed；
  - 结构有效但 ID 不同返回 `409 COMMAND_ID_MISMATCH`，不覆盖当前命令；
  - 未 claim 的 queued 命令不接受结果；
  - 每次 `/internal/result` 都必须带 `X-Capture-Command-Id`；header、有效 payload ID 与 active ID 必须绑定；
  - 只有通过 Capture Token、PID 和 command ID 三重认证，且当前状态为 `executing` 的无效结果才生成合成完成结果；缺 header、迟到请求和重放请求不能终结后来命令。

- [ ] **Step 2：写失败回归测试**

  新测试必须断言无效 JSON、缺字段、错误类型、不可编码 Unicode 和超大结果体至少各覆盖一类；核心断言如下：

  ```python
  headers = capture_headers()
  headers["X-Capture-Command-Id"] = command_id
  response = client.post("/internal/result", headers=headers, content=b"{")
  assert response.status_code == 400
  body = response.json()
  assert body["error"]["code"] == "INVALID_RESULT"
  assert body["id"] == command_id
  assert body["state"] == "completed"

  assert bridge.bridge.active is None
  completed = bridge.bridge.completed[command_id]
  assert completed["ok"] is False
  assert completed["returnCode"] == 1
  assert completed["errorCode"] == ["CAPTURE", "AI", "BRIDGE", "INVALID_RESULT"]
  assert token not in json.dumps(body)
  ```

  再用缺少 command ID、错误 command ID、旧 command ID 各投一次畸形 JSON，断言返回 `409 COMMAND_ID_MISMATCH` 且当前 active 不变。同时启动一个等待中的 `/v1/execute`，确认正确绑定的 invalid result 使它收到合成结果，而不是继续等待或返回永久 `BRIDGE_BUSY`。在真实 FastAPI + 假 Capture integration 中再提交下一条正常命令，确认 broker 已恢复接受执行。

- [ ] **Step 3：运行定向测试并确认红灯原因正确**

  Run:

  ```powershell
  python -m pytest tests/test_capture_tcl_bridge_server.py -q -k "invalid_result or command_id_mismatch or unencodable or result_body"
  ```

  Expected: 新增的释放 `busy`、合成结果和字段诊断断言失败；既有认证/ID 安全边界仍通过。

- [ ] **Step 4：实现字段级安全校验**

  用固定字段名和固定原因代码报告失败，不回显原始 payload：

  ```python
  REQUIRED_RESULT_FIELDS = frozenset(
      {
          "id", "returnCode", "result", "stdout", "stderr", "errorInfo",
          "errorCode", "errorLine", "stdoutTruncated", "stderrTruncated",
          "resultTruncated",
      }
  )


  class ResultValidationError(ValueError):
      def __init__(self, field: str, reason: str) -> None:
          super().__init__(reason)
          self.field = field
          self.reason = reason


  def validate_and_normalize_result(payload: Any) -> dict[str, Any]:
      if not isinstance(payload, dict):
          raise ResultValidationError("body", "not_object")
      missing = sorted(REQUIRED_RESULT_FIELDS.difference(payload))
      if missing:
          raise ResultValidationError(missing[0], "missing")

      command_id = payload["id"]
      if not is_utf8_text(command_id) or not command_id:
          raise ResultValidationError("id", "invalid_text")
      return_code = payload["returnCode"]
      if not isinstance(return_code, int) or isinstance(return_code, bool):
          raise ResultValidationError("returnCode", "invalid_integer")
      for field in ("result", "stdout", "stderr", "errorInfo"):
          if not is_utf8_text(payload[field]):
              raise ResultValidationError(field, "invalid_text")
      error_code = payload["errorCode"]
      if not isinstance(error_code, list) or any(not is_utf8_text(item) for item in error_code):
          raise ResultValidationError("errorCode", "invalid_text_list")
      error_line = payload["errorLine"]
      if error_line is not None and (
          not isinstance(error_line, int) or isinstance(error_line, bool)
      ):
          raise ResultValidationError("errorLine", "invalid_optional_integer")
      flags = ("stdoutTruncated", "stderrTruncated", "resultTruncated")
      for field in flags:
          if not isinstance(payload[field], bool):
              raise ResultValidationError(field, "invalid_boolean")

      bounded_error_info, _ = truncate_utf8(payload["errorInfo"], FIELD_LIMIT_BYTES)
      normalized: dict[str, Any] = {
          "id": command_id,
          "state": "completed",
          "ok": return_code == 0,
          "returnCode": return_code,
          "errorInfo": bounded_error_info,
          "errorCode": truncate_utf8_list(error_code, FIELD_LIMIT_BYTES),
          "errorLine": error_line,
      }
      for field, flag in (
          ("result", "resultTruncated"),
          ("stdout", "stdoutTruncated"),
          ("stderr", "stderrTruncated"),
      ):
          text, truncated = truncate_utf8(payload[field], FIELD_LIMIT_BYTES)
          normalized[field] = text
          normalized[flag] = payload[flag] or truncated
      return normalized


  def normalize_result(payload: Any) -> dict[str, Any] | None:
      try:
          return validate_and_normalize_result(payload)
      except ResultValidationError:
          return None
  ```

  `normalize_result` 保留兼容包装，既有直接调用测试不必改为异常 API。

- [ ] **Step 5：实现合成协议失败结果和原子释放**

  ```python
  def protocol_failure_result(command_id: str, field: str, reason: str) -> dict[str, Any]:
      return {
          "id": command_id,
          "state": "completed",
          "ok": False,
          "returnCode": 1,
          "result": "Capture returned an invalid bridge result.",
          "stdout": "",
          "stderr": "",
          "errorInfo": f"Invalid internal result payload: {field}:{reason}",
          "errorCode": ["CAPTURE", "AI", "BRIDGE", "INVALID_RESULT"],
          "errorLine": None,
          "stdoutTruncated": False,
          "stderrTruncated": False,
          "resultTruncated": False,
      }
  ```

  在读取请求体前取 `X-Capture-Command-Id`。路由顺序固定为：

  1. header 为空时返回 `409 COMMAND_ID_MISMATCH`；
  2. 第一次持有 `bridge.lock`：若 header ID 已在 completed 中，立即返回 completed ack，实现无害幂等重投；否则确认 header 恰好等于 executing active ID，记录 active 快照；
  3. 读取并校验 body；有效 JSON 还要求 payload ID 等于 header；
  4. 第二次持有 `bridge.lock`：再次检查 completed（处理并发重投），并重新确认 active ID/state 未变化；
  5. 只有二次复核通过后，才保存 valid 或 synthetic result，并置 `bridge.active = None`。

  任一 ID/state 绑定失败均返回 `409 COMMAND_ID_MISMATCH` 且不改变 active。HTTP 400/413 返回体附带 `id`、`state="completed"`、`field`、`reason`；不得附带请求正文、Token 或 Tcl 脚本。

- [ ] **Step 6：运行服务端测试并提交**

  Run:

  ```powershell
  python -m pytest tests/test_capture_tcl_bridge_server.py tests/test_capture_tcl_bridge_integration.py -q
  git diff --check
  git add capture_tcl_bridge_server.py tests/test_capture_tcl_bridge_server.py tests/test_capture_tcl_bridge_integration.py
  git commit -m "fix: release bridge after invalid Capture result"
  ```

  Expected: 服务端测试全部通过；无 whitespace error。

---

## Task 3：让 Tcl 区分可重试传输错误与确定性 HTTP 4xx

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Modify: `captureAiBridge.tcl:27-29,486-550`
- Modify: `tests/test_capture_ai_bridge.tcl:620-780`

- [ ] **Step 1：写 Tcl 失败回归测试**

  使用现有 `_captureAiRequest` stub 覆盖：

  - 传输异常保留 pending result；
  - HTTP 500 保留 pending result，并按 250、500、1000、2000、5000ms 上限退避；
  - 只有 response ID 等于 pending ID、`state=completed` 的 HTTP 400 `INVALID_RESULT` 或 HTTP 413 `REQUEST_TOO_LARGE` 才报告一次、清除 pending、继续轮询；
  - HTTP 409 `COMMAND_ID_MISMATCH` 不无限重投；
  - pending result 的 POST 带 `X-Capture-Command-Id`，值严格等于 `::CaptureAiBridgePendingResultId`；
  - HTTP 401、PID mismatch 和其他未确认 completed 的 4xx 进入明确的 polling-halted 协议错误状态，Status 可见，Stop 仍可执行；
  - 没有 pending result 时，`/internal/command` 的 transport/5xx 也使用相同退避和错误去重；成功轮询后重置退避；
  - 进入 polling-halted 后执行 Stop → Start，会重置 halted、protocol error、retry delay 和 last poll error，并能正常执行下一条命令；
  - 相同传输错误连续发生时不连续刷屏；错误发生变化或恢复后可再次报告；
  - `CaptureAiBridgeStop` 在 pending/退避状态下取消 `after`，清空本地 pending 并收敛；
  - 显式 dump 能保存 pending JSON；空 pending 明确报错；文件内容不含 Bearer Token。

- [ ] **Step 2：运行 Tcl 测试并确认红灯**

  Run:

  ```powershell
  tclsh tests/test_capture_ai_bridge.tcl
  ```

  Expected: 新增的 4xx 清理、限速、退避和 dump 断言失败；原执行/生命周期测试继续运行。

- [ ] **Step 3：让 `_captureAiRequest` 保留结构化 HTTP 错误**

  将 `_captureAiRequest` 签名扩展为 `proc _captureAiRequest {method path {payload {}} {extraHeaders {}}}`；`extraHeaders` 只允许内部代码添加 `X-Capture-Command-Id`，拒绝覆盖 Authorization、PID 或 Host。HTTP 非 2xx 时解析现有 JSON 错误体并返回 Tcl `-errorcode`，把脱敏的 remote code、response ID 和 state 一并放入 options，消息中不得包含 Token：

  ```tcl
  set remoteCode UNKNOWN
  set remoteMessage "Capture AI bridge request failed."
  set errorBody {}
  if {![catch {::json::json2dict $responseBody} errorBody]} {
      if {[dict exists $errorBody error code]} {
          set remoteCode [dict get $errorBody error code]
      }
      if {[dict exists $errorBody error message]} {
          set remoteMessage [dict get $errorBody error message]
      }
  }
  set responseId {}
  set responseState {}
  if {[dict exists $errorBody id]} { set responseId [dict get $errorBody id] }
  if {[dict exists $errorBody state]} { set responseState [dict get $errorBody state] }
  return -code error \
      -errorcode [list CAPTURE_AI_BRIDGE HTTP $statusCode $remoteCode \
          $responseId $responseState] \
      "Capture AI bridge returned HTTP $statusCode ($remoteCode): $remoteMessage"
  ```

  网络、DNS、连接拒绝和超时保留为 `[list CAPTURE_AI_BRIDGE TRANSPORT]`。

- [ ] **Step 4：集中实现 pending POST 决策和有上限退避**

  新增状态：

  ```tcl
  set ::CaptureAiBridgeRetryDelayMs 250
  set ::CaptureAiBridgeRetryMaxMs 5000
  set ::CaptureAiBridgeLastPollError ""
  set ::CaptureAiBridgePollingHalted 0
  set ::CaptureAiBridgeProtocolError ""
  ```

  新增 `_captureAiPostPendingResult`，返回 `posted`、`discarded` 或 `retry`：

  - 2xx：清 pending、重置退避和 last error；
  - 400/413 且 remote code 为 `INVALID_RESULT`/`REQUEST_TOO_LARGE`、response ID 等于 pending ID、state 为 completed：报告一次、清 pending，返回 discarded；
  - `409 COMMAND_ID_MISMATCH`：报告一次并丢弃陈旧 pending；
  - 401、`CAPTURE_PID_MISMATCH`、未知 4xx 或没有 completed 证明的拒绝：保留诊断信息，设置 polling-halted，不再安排轮询；`CaptureAiBridgeStatus` 显示协议错误，`CaptureAiBridgeStop` 仍执行生命周期清理；
  - transport/5xx：保留 pending，将 delay 翻倍但最大 5000ms；
  - 每个 `_captureAiTick` 只安排一个 `after`；Stop 取消它。

  pending POST 固定使用：

  ```tcl
  _captureAiRequest POST /internal/result \
      $::CaptureAiBridgePendingResultJson \
      [list X-Capture-Command-Id $::CaptureAiBridgePendingResultId]
  ```

  限速逻辑按完整脱敏错误消息去重；成功一次后清空 last error，因此以后同类新故障仍会输出一次。

  把 `/internal/command` 和 pending POST 放在同一层 tick error classifier 下；即使没有 pending，transport/5xx 也按 `CaptureAiBridgeRetryDelayMs` 安排下一次 tick，而不是固定 250ms。任何成功的 command poll 或 result POST 都把 delay 重置为 250ms。

  `CaptureAiBridgeStop` 的本地状态收敛路径和 `CaptureAiBridgeStart` 的新 generation 初始化路径都必须执行同一个 `_captureAiResetPollRecoveryState`，把 polling-halted 置 0、protocol error/last error 清空、retry delay 置 250ms。测试完整走一遍“认证/PID 错误 → Status 显示 halted → Stop → Start → 正常命令完成”，防止错误状态跨实例泄漏。

- [ ] **Step 5：增加显式诊断命令**

  ```tcl
  proc CaptureAiBridgeDumpPendingResult {path} {
      if {$::CaptureAiBridgePendingResultJson eq ""} {
          error "Capture AI bridge has no pending result."
      }
      set channel [open $path wb]
      try {
          fconfigure $channel -translation binary -encoding binary
          puts -nonewline $channel \
              [encoding convertto utf-8 $::CaptureAiBridgePendingResultJson]
      } finally {
          close $channel
      }
      return [file normalize $path]
  }
  ```

  命令只在用户显式调用时写盘，不自动保存完整结果。

- [ ] **Step 6：运行 Tcl 和 Python 回归并提交**

  Run:

  ```powershell
  tclsh tests/test_capture_ai_bridge.tcl
  python -m pytest tests/test_capture_tcl_bridge_server.py tests/test_capture_tcl_bridge_integration.py -q
  git diff --check
  git add captureAiBridge.tcl tests/test_capture_ai_bridge.tcl
  git commit -m "fix: stop retrying rejected Capture results"
  ```

  Expected: Tcl 末行 PASS；Python 相关测试通过；控制台测试输出中同一模拟错误只出现一次。

---

## Task 4：移除 `::TclPythonPath` 依赖并读取独立安装清单

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Modify: `captureAiBridge.tcl:1-80,930-1030`
- Modify: `tests/test_capture_ai_bridge.tcl`

- [ ] **Step 1：写路径优先级失败测试**

  测试顺序必须是：

  1. source 前显式设置的 `::CaptureAiBridgePythonPath`；
  2. `%LOCALAPPDATA%\capture-tcl-ai-bridge\install.json` 的 `pythonTarget`；
  3. `C:/tclpython` 默认值。

  同时断言代码不再读取 `::TclPythonPath`；损坏清单、缺字段、非绝对路径均安全回退默认值且不自动启动服务。

- [ ] **Step 2：运行定向 Tcl 测试确认红灯**

  Run:

  ```powershell
  tclsh tests/test_capture_ai_bridge.tcl
  ```

  Expected: 安装清单和专属覆盖变量测试失败。

- [ ] **Step 3：实现清单读取和路径规范化**

  新增 `_captureAiInstallManifestPath`、`_captureAiReadInstallManifest`、`_captureAiResolvePythonPath`。只读取 JSON，不执行 Tcl 配置；验证 `schemaVersion == 1`、`project == "capture-tcl-ai-bridge"`、`pythonTarget` 为绝对路径。显式变量只在 source 前已存在时优先：

  ```tcl
  if {![info exists ::CaptureAiBridgePythonPath]} {
      set ::CaptureAiBridgePythonPath ""
  }

  proc _captureAiResolvePythonPath {} {
      if {$::CaptureAiBridgePythonPath ne ""} {
          return [file normalize $::CaptureAiBridgePythonPath]
      }
      set manifest [_captureAiReadInstallManifest]
      if {[dict exists $manifest pythonTarget]} {
          return [file normalize [dict get $manifest pythonTarget]]
      }
      return [file normalize C:/tclpython]
  }
  ```

  `CaptureAiBridgeStart` 用该目录定位 `capture_tcl_bridge_server.py`，错误消息必须指出实际解析路径。

- [ ] **Step 4：验证、扫描旧依赖并提交**

  Run:

  ```powershell
  tclsh tests/test_capture_ai_bridge.tcl
  rg -n "TclPythonPath|tcl_bom|TCLBOM" captureAiBridge.tcl capture_tcl_bridge_server.py capture_tcl_cli.py
  git diff --check
  git add captureAiBridge.tcl tests/test_capture_ai_bridge.tcl
  git commit -m "feat: load bridge path from standalone install manifest"
  ```

  Expected: Tcl PASS；`rg` 无运行时耦合命中。

---

## Task 5：实现幂等、安全边界明确的安装与卸载

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Create: `install.ps1`
- Create: `uninstall.ps1`
- Create: `tests/test_install_scripts.py`

- [ ] **Step 1：先写 PowerShell 集成测试**

  pytest 子进程设置临时 `LOCALAPPDATA`，并传入临时 `-PythonTarget`、`-CaptureTclTarget`。覆盖：

  - Python 3.12+ 和 FastAPI/Uvicorn 检查；
  - 三个且仅三个运行文件被复制；
  - manifest schema、项目名、绝对目标路径和 SHA-256；
  - 重复安装幂等；
  - 首次安装遇到同名不同内容文件时拒绝覆盖；
  - 升级时只覆盖“旧 manifest 归属且当前哈希仍等于旧记录”的文件；用户修改过的归属文件默认拒绝覆盖，只有 `-ForceOverwriteModified` 才覆盖；
  - 自定义路径可被 Tcl 清单解析；
  - 已有有效 manifest 的 Python/Capture 目标与本次参数不同时，在复制前中止并提示先运行卸载；不能覆盖 manifest 后遗留旧目录文件；
  - 默认卸载删除未修改的归属文件；
  - 修改过的文件默认保留并继续写在 manifest 中；
  - `-ForceModified` 删除修改文件；
  - 不删除目标父目录或同目录其他项目文件。

- [ ] **Step 2：运行安装测试确认红灯**

  Run:

  ```powershell
  python -m pytest tests/test_install_scripts.py -q
  ```

  Expected: 因 `install.ps1`、`uninstall.ps1` 不存在而失败。

- [ ] **Step 3：实现 `install.ps1`**

  参数定义固定为：

  ```powershell
  param(
      [string]$PythonTarget = 'C:\tclpython',
      [string]$CaptureTclTarget = 'C:\cadence\SPB_17.4\tools\capture\tclscripts\capAutoLoad',
      [switch]$ForceOverwriteModified
  )
  ```

  安装前执行 `python --version` 与 `python -c "import fastapi, uvicorn"`。为三个目标文件逐一构造记录，再使用临时文件加 `Move-Item` 原子写入：

  ```powershell
  $installedFiles = @(
      Join-Path $PythonTarget 'capture_tcl_bridge_server.py'
      Join-Path $PythonTarget 'capture_tcl_cli.py'
      Join-Path $CaptureTclTarget 'captureAiBridge.tcl'
  )
  $manifest = [ordered]@{
      schemaVersion = 1
      project = 'capture-tcl-ai-bridge'
      pythonTarget = [IO.Path]::GetFullPath($PythonTarget)
      captureTclTarget = [IO.Path]::GetFullPath($CaptureTclTarget)
      files = @($installedFiles | ForEach-Object {
          [ordered]@{
              path = [IO.Path]::GetFullPath($_)
              sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
          }
      })
  }
  ```

  首版固定检查并使用 PATH 中的 `python`，与 Tcl Start 的解释器选择保持一致，不提供只影响安装检查的解释器参数。在复制前构造三个 canonical allowed paths，并先完成全部目标的 ownership/hash preflight，任一目标不安全就必须在复制第一个文件前停止。已有有效 manifest 的 canonical targets 与本次参数不同则中止，要求先用旧 manifest 卸载。目标不存在则复制；目标哈希等于新源文件则幂等跳过；目标不同但被现有有效 manifest 归属、且当前哈希等于旧记录时允许升级；其他同名文件默认停止，不做部分覆盖。只有显式 `-ForceOverwriteModified` 才覆盖不同内容。成功后输出 source、Start、Status 命令；脚本本身不启动 Capture 或桥接。

- [ ] **Step 4：实现 `uninstall.ps1`**

  参数固定为：

  ```powershell
  param([switch]$ForceModified)
  ```

  先规范化 manifest 的 `pythonTarget` 与 `captureTclTarget`，构造且只信任以下三个 canonical allowed paths：`pythonTarget\capture_tcl_bridge_server.py`、`pythonTarget\capture_tcl_cli.py`、`captureTclTarget\captureAiBridge.tcl`。每条记录的 canonical path 和 basename 都必须精确属于该集合，重复路径、相对路径、集合外路径、错误 project/schema 一律中止且不删除任何文件。通过边界校验后，哈希相同则删除；哈希不同默认保留并重写 manifest，只留下未删除条目；`-ForceModified` 才删除。全部条目处理完才删除 manifest；不得递归删除 Python/Capture 目标目录。

- [ ] **Step 5：运行测试和真实临时目录 smoke test**

  Run:

  ```powershell
  python -m pytest tests/test_install_scripts.py -q
  $sandbox = Join-Path (Get-Location) '.tmp\install-smoke'
  $env:LOCALAPPDATA = Join-Path $sandbox 'localappdata'
  .\install.ps1 -PythonTarget (Join-Path $sandbox 'python') -CaptureTclTarget (Join-Path $sandbox 'capture')
  .\uninstall.ps1
  Get-ChildItem -LiteralPath $sandbox -Recurse -Force
  ```

  Expected: 安装测试通过；卸载后没有三个运行文件和 manifest，父目录仍存在。

- [ ] **Step 6：提交**

  ```powershell
  git add install.ps1 uninstall.ps1 tests/test_install_scripts.py
  git commit -m "feat: add safe standalone installer"
  ```

---

## Task 6：补齐独立项目 README、协议、安全和故障排查文档

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Modify: `README.md`
- Create: `docs/protocol.md`
- Create: `docs/security.md`
- Create: `docs/troubleshooting.md`
- Modify: `MIGRATION.md`
- Modify: `tests/test_capture_tcl_bridge_integration.py`

- [ ] **Step 1：写文档契约测试**

  Create `tests/test_docs_contract.py`，读取文档并断言出现以下固定事实：`127.0.0.1:8767`、随机 Token、`%TEMP%\capture_tcl_bridge.json`、显式 Start/Status/Stop、30 秒不取消、`puts` tee、非沙箱、安装和卸载命令、`CaptureAiBridgeDumpPendingResult`、真实 Capture 验收边界。同时把迁入集成测试中的 `(ROOT / "readme.md")` 统一为 `(ROOT / "README.md")`，消除对 Windows 大小写不敏感行为的隐式依赖。

- [ ] **Step 2：运行测试确认红灯**

  ```powershell
  python -m pytest tests/test_docs_contract.py -q
  ```

  Expected: 旧 README 缺少独立项目完整文档契约而失败；不是 `FileNotFoundError`。

- [ ] **Step 3：写 README 和协议文档**

  README 采用“安装 → source → Start → CLI → HTTP → Stop → 卸载”的最短路径，并明确 Python 3.12+、Windows 10/11、Capture 17.4。

  `docs/protocol.md` 记录公开接口：

  ```text
  GET  /v1/health
  POST /v1/execute
  GET  /v1/commands/{id}
  ```

  同时记录内部轮询接口、认证头、运行描述文件 schema、完成结果字段、busy/timeout/invalid-result 状态机；不在文档中放真实 Token。

- [ ] **Step 4：写安全、排障和迁移状态**

  `docs/security.md` 明确桥接等同 Capture 控制台权限而非沙箱。`docs/troubleshooting.md` 给出端口占用、描述文件过期、路径解析、HTTP 400、pending dump、Stop、重新 source 的步骤。`MIGRATION.md` 把 HTTP 400 缺陷状态更新为“自动测试已修复、真实 Capture 待验收”，不能提前写完成。

- [ ] **Step 5：验证并提交**

  ```powershell
  python -m pytest tests/test_docs_contract.py -q
  rg -n "Bearer [A-Za-z0-9_-]{16,}" README.md MIGRATION.md docs
  git diff --check
  git add README.md MIGRATION.md docs tests/test_docs_contract.py tests/test_capture_tcl_bridge_integration.py
  git commit -m "docs: document standalone bridge operation"
  ```

  Expected: 文档契约通过；Token 扫描无命中。

---

## Task 7：实现独立的只读 Capture Tcl 示例

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Create: `examples/selected_refs.tcl`
- Create: `examples/list_components.tcl`
- Create: `examples/extract_topology.tcl`
- Create: `examples/get_component_value.tcl`
- Create: `tests/test_examples_static.py`
- Create: `tests/test_examples.tcl`

- [ ] **Step 1：写静态依赖失败测试**

  断言每个 `.tcl` 是完整可发送脚本，不包含：

  ```text
  _dniWalk
  CollectSelectedDNIOccs
  RefreshParts
  TclPythonPath
  source ../
  ```

  只读脚本不得调用 `SetPartValue`、`Save` 或修改 API。

- [ ] **Step 2：先建立可单独验证的假 Dbo fixture**

  `tests/test_examples.tcl` 接受 `fixture`、`occurrence`、`selection`、`topology`、`write` suite 参数。用 Tcl object-command dispatcher 模拟以下 Capture 17.4 表面：`GetActivePMDesign`、design 的 `GetRootOccurrence/NewFlatNetsIter`、occurrence 的 `GetReference/GetPartValue/GetPath/GetObjectType/NewChildrenIter/SetPartValue`、selection 的 `GetSelectedObjects`、flat net 的 `GetName/NewPinOccurrencesIter/NewPortOccurrencesIter`、pin/port 的 name/number/parent，以及各迭代器的 Next/delete。fixture 记录 SetPartValue 次数和 iterator delete 次数。

  Run:

  ```powershell
  tclsh tests/test_examples.tcl fixture
  ```

  Expected: fixture 自测 PASS，尚不 source 任何 example。

- [ ] **Step 3：先写 occurrence walker/list 的红灯测试**

  构造 root → U1 → R1/C3 和 root → U2 → C3 的层级树，断言 walker 深度优先遍历、保留 path、可识别重复 refdes、每个 iterator 恰好 delete 一次。

  ```powershell
  tclsh tests/test_examples.tcl occurrence
  ```

  Expected: `list_components.tcl` 不存在而失败。

- [ ] **Step 4：实现并通过 `list_components.tcl`**

  脚本自带 occurrence walker，不能 source 共用文件。器件记录格式统一为：

  ```tcl
  puts [dict create refdes $refdes value $value path $hierarchyPath]
  ```

  Run `tclsh tests/test_examples.tcl occurrence`; Expected: PASS。

- [ ] **Step 5：为 selection 写红灯测试，再实现 `selected_refs.tcl`**

  fixture 返回器件 occurrence、非器件图形对象和同一 occurrence 的重复选择；先运行 `tclsh tests/test_examples.tcl selection` 确认缺文件失败，再实现过滤、映射、去重和排序。实现后同一命令 PASS。

- [ ] **Step 6：为唯一位号查询写红灯测试，再实现 `get_component_value.tcl`**

  文件顶部固定可编辑参数：

  ```tcl
  set targetRefdes C3
  ```

  `occurrence` suite 分别构造零、唯一和重复匹配；先确认缺文件失败。脚本遍历全部 occurrence；零匹配报 `COMPONENT_NOT_FOUND`，多匹配报 `COMPONENT_NOT_UNIQUE`，唯一匹配输出 refdes/value/path。实现后 `tclsh tests/test_examples.tcl occurrence` PASS。

- [ ] **Step 7：为 flat-net 写红灯测试，再实现 `extract_topology.tcl`**

  fixture 构造 N1，连接 R1.1、U1.3 和层级端口 IN；先运行 `tclsh tests/test_examples.tcl topology` 确认缺文件失败。脚本使用 Capture 17.4 的 flat nets、port occurrences 和 pin occurrences 迭代器，逐网络输出网络名、层级端口、器件位号、引脚号/名。所有迭代器恰好释放一次，不修改设计。实现后同一命令 PASS。

- [ ] **Step 8：运行静态和全部 fixture 测试并提交**

  ```powershell
  python -m pytest tests/test_examples_static.py -q
  tclsh tests/test_examples.tcl
  git diff --check
  git add examples tests/test_examples_static.py tests/test_examples.tcl
  git commit -m "feat: add standalone read-only Capture examples"
  ```

---

## Task 8：实现 occurrence 级写入和幂等后缀示例

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Create: `examples/set_component_value.tcl`
- Create: `examples/mark_selected_suffix.tcl`
- Create: `examples/remove_selected_suffix.tcl`
- Modify: `tests/test_examples_static.py`
- Modify: `tests/test_examples.tcl`

- [ ] **Step 1：先写唯一位号写入失败测试**

  覆盖：

  - `set_component_value.tcl` 只修改唯一命中的 occurrence；
  - 两个同 Value 但不同 RefDes 的器件中只改目标；
  - 零匹配或多匹配时修改次数为 0；
  - 每个修改输出 before/after 并立即回读；
  - 不调用 `RefreshParts`，不自动保存设计。

- [ ] **Step 2：运行失败测试**

  ```powershell
  python -m pytest tests/test_examples_static.py -q
  tclsh tests/test_examples.tcl
  ```

  Expected: `set_component_value.tcl` 尚不存在而失败。

- [ ] **Step 3：实现唯一位号写入**

  文件顶部参数：

  ```tcl
  set targetRefdes C3
  set newValue 100nF
  ```

  先完成全设计唯一性检查，再在 occurrence 对象上执行：

  ```tcl
  set before [$targetOccurrence GetPartValue]
  $targetOccurrence SetPartValue $newValue
  set after [$targetOccurrence GetPartValue]
  puts [dict create refdes $targetRefdes before $before after $after]
  ```

  回读不等于 `newValue` 时抛错；不保存设计。

  Run `tclsh tests/test_examples.tcl write`; Expected: 唯一写入、零匹配和重复匹配测试 PASS。

- [ ] **Step 4：写后缀追加红灯测试，再实现 `mark_selected_suffix.tcl`**

  `write` suite 覆盖后缀 `*` 已存在时不生成 `**`、非器件选择项忽略、重复 occurrence 只修改一次、before/after 和 changed/skipped 统计。先确认缺文件失败，再实现并运行 suite 至 PASS。

- [ ] **Step 5：写后缀移除红灯测试，再实现 `remove_selected_suffix.tcl`**

  `write` suite 覆盖只删除一个尾部 `*`、中间位置的 `*` 不动、无后缀对象 skipped、同一对象只修改一次。先确认缺文件失败，再实现并运行 suite 至 PASS。

- [ ] **Step 6：统一两个后缀脚本的输入和输出契约**

  两个脚本顶部均使用：

  ```tcl
  set suffix *
  ```

  追加条件为字符串尾部尚无 suffix；移除条件为字符串尾部恰好有 suffix。先收集并去重 occurrence，再修改，避免同一对象重复处理。每个对象输出 refdes/before/after，最后输出 changed/skipped 统计。

- [ ] **Step 7：验证并提交**

  ```powershell
  python -m pytest tests/test_examples_static.py -q
  tclsh tests/test_examples.tcl
  git diff --check
  git add examples tests/test_examples_static.py tests/test_examples.tcl
  git commit -m "feat: add safe Capture mutation examples"
  ```

---

## Task 9：编写中文 Tcl Cookbook，并确保示例和文档同步

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Create: `docs/tcl-cookbook.md`
- Modify: `tests/test_docs_contract.py`
- Modify: `tests/test_examples_static.py`

- [ ] **Step 1：写 Cookbook 契约失败测试**

  对 7 个示例逐个断言文档包含：用途、风险级别、输入、CLI `-f`、标准输入、HTTP 调用、预期输出、UI 阻塞风险、回读验证、撤销/不自动保存说明。测试还要比对 cookbook 中的示例文件名与 `examples/*.tcl` 集合完全相同。

- [ ] **Step 2：运行测试确认红灯**

  ```powershell
  python -m pytest tests/test_docs_contract.py tests/test_examples_static.py -q
  ```

  Expected: `docs/tcl-cookbook.md` 不存在而失败。

- [ ] **Step 3：写 Cookbook 总则和三种调用方式**

  CLI 文件调用使用：

  ```powershell
  python C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
  ```

  stdin 调用使用 `Get-Content -Raw .\examples\selected_refs.tcl | python C:\tclpython\capture_tcl_cli.py`；HTTP 示例从 `%TEMP%\capture_tcl_bridge.json` 读取 `baseUrl` 和 `token`，不硬编码 Token。

- [ ] **Step 4：为 7 个示例写完整中文条目**

  明确 topology/list 可能长时间阻塞 Capture UI；Value 和 suffix 为写操作、不自动保存；用户应在保存前回读并可用原值撤销。每个条目必须嵌入对应 `examples/*.tcl` 的完整内容，并用稳定的示例起止标记让契约测试抽取代码块、统一换行后与示例文件全文比较，防止 Cookbook 与可执行文件漂移。

- [ ] **Step 5：验证并提交**

  ```powershell
  python -m pytest tests/test_docs_contract.py tests/test_examples_static.py -q
  git diff --check
  git add docs/tcl-cookbook.md tests/test_docs_contract.py tests/test_examples_static.py
  git commit -m "docs: add Chinese Capture Tcl cookbook"
  ```

---

## Task 10：运行独立项目全套自动验证并部署到真实 Capture

**Working directory:** `D:\Documents\codeprj\capture-tcl-ai-bridge`

**Files:**

- Modify only if failures reveal a defect in: runtime, tests, installer, examples, or docs
- Update after acceptance: `MIGRATION.md`

- [ ] **Step 1：运行全套 Python/Tcl 测试**

  ```powershell
  Set-Location D:\Documents\codeprj\capture-tcl-ai-bridge
  $taskTemp = Join-Path (Get-Location) '.tmp\full-suite'
  New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
  $env:TEMP = $taskTemp
  $env:TMP = $taskTemp
  python -m pytest -q
  tclsh tests/test_capture_ai_bridge.tcl
  tclsh tests/test_examples.tcl
  python -m py_compile capture_tcl_bridge_server.py capture_tcl_cli.py
  git diff --check
  ```

  Expected: 全部 Python 测试通过，仅保留有明确平台原因的 skip；两个 Tcl 测试 PASS；py_compile 和 diff check 无输出。

- [ ] **Step 2：安装到正式默认路径**

  ```powershell
  .\install.ps1
  ```

  Expected: 只部署 3 个运行文件并写 manifest；输出重新 source 和显式 Start 命令。记录安装前后文件哈希，确认来自新仓库。

- [ ] **Step 3：在 Capture 控制台重新加载并显式启动**

  ```tcl
  source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
  CaptureAiBridgeStart
  CaptureAiBridgeStatus
  ```

  Expected: source 本身不启动；Start 后显示 `127.0.0.1:8767`；Status 为 connected/idle。

- [ ] **Step 4：执行真实只读链路验收**

  依次验证：CLI status、`-c`、`-f`、stdin、`--json`；多行 UTF-8；`puts` 同时出现在 Capture 控制台和客户端 stdout；Tcl error 返回 errorInfo/errorCode/errorLine；selected refs、器件列表、topology、按位号读取。

- [ ] **Step 5：执行真实写入示例并回读/撤销**

  在用户允许修改的测试设计中运行 Value 修改、`*` 追加和移除；确认 occurrence 级唯一修改、幂等、不自动保存、不调用 RefreshParts。测试结束将值恢复到测试前状态，除非用户明确要求保留。

- [ ] **Step 6：执行并发、超时和 HTTP 400 恢复验收**

  - 同时提交第二条命令，确认稳定返回 `BRIDGE_BUSY`；
  - 运行超过 30 秒的 Tcl，确认 HTTP timeout 不取消命令，随后可按 ID 查询完成；
  - 在 Capture 控制台把 `::_captureAiResultJson` 临时 rename 为 `::_captureAiResultJsonAcceptanceReal`，安装一个仅首次返回字面量 `{` 的包装 proc；包装 proc 在首次调用时通过 `after 0` 自动恢复原 proc。随后用 CLI 提交一条正常短命令，使真实 Capture pending POST 携带正确 `X-Capture-Command-Id` 但使用损坏 JSON；确认 Tcl 实际收到一次 HTTP 400、控制台只输出一次脱敏错误、等待客户端/命令查询收到合成 `INVALID_RESULT`、health 恢复 `busy=false`，下一条正常命令成功；
  - 再运行曾触发大结果/复杂 `errorInfo` 的组合脚本，确认无连续 400 刷屏，且下一条正常命令仍可执行；
  - 在 pending/故障状态调用 Stop，确认可输入且可收敛；
  - 只有需要取证时显式调用 `CaptureAiBridgeDumpPendingResult`，测试文件随后由用户决定是否保留。

  临时包装不得写入部署文件；测试后用 `info commands` 确认 `::_captureAiResultJsonAcceptanceReal` 已不存在且原 `::_captureAiResultJson` 已恢复。若自动恢复未发生，立即手动 rename 恢复后再继续。该步骤只用于已获用户同意的本机测试会话。

- [ ] **Step 7：验证 Token 轮换和 Capture 退出 watchdog**

  Stop/Start 前后比较描述文件 Token，必须变化；退出 Capture 后确认端口 8767 无监听、服务 PID 结束、描述文件清理。重新启动 Capture 后重新 source 才能再次显式 Start。

- [ ] **Step 8：记录真实验收并提交**

  只有全部真实项通过后，把 `MIGRATION.md` 的状态改为“自动测试和 OrCAD Capture 17.4 真实验收通过”，记录日期、Capture 版本和测试范围；不记录 Token、原理图敏感内容或完整 pending payload。

  ```powershell
  git add MIGRATION.md
  git commit -m "docs: record OrCAD Capture acceptance"
  git status --short
  ```

  Expected: 新仓库 clean。

---

## Task 11：真实验收通过后，从 TCLBOM 移除重复维护边界

**Working directory:** `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge`（Step 1 创建成功后）；Step 1 的 `git worktree add` 使用 `D:\Documents\codeprj\tcl_bom`。

**Gate:** Task 10 全部通过；否则禁止执行本 Task。

**Files:**

- Create: `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge\docs\capture-tcl-ai-bridge-migration.md`
- Modify: `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge\readme.md`
- Modify if bridge globs/entries remain: `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge\cpcode.bat`
- Create: `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge\tests\test_capture_bridge_boundary.py`
- Delete if present on the chosen TCLBOM integration branch: bridge runtime files and bridge-only tests

- [ ] **Step 1：创建独立清理工作树，先检查目标分支内容**

  ```powershell
  git -C D:\Documents\codeprj\tcl_bom worktree add D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge -b codex/remove-capture-tcl-ai-bridge codex/tcl-bridge
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge status --short
  rg -n "captureAiBridge|capture_tcl_bridge|Capture Tcl AI Bridge" D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge
  ```

  Expected: 新工作树 clean。若该分支从未包含 bridge runtime，则不制造虚假删除，只处理实际存在的 README/计划/部署引用。

- [ ] **Step 2：先写并运行固定的 TCLBOM 边界回归测试**

  `tests/test_capture_bridge_boundary.py` 固定断言：仓库根目录不存在 `captureAiBridge.tcl`、`capture_tcl_bridge_server.py`、`capture_tcl_cli.py`；`tests/` 不存在四个 bridge-only test；`cpcode.bat` 不含三个 bridge runtime 文件名；迁移文档存在并同时包含 `D:\Documents\codeprj\capture-tcl-ai-bridge` 和“新项目是唯一维护位置”；BOM/DNI 的既有入口文件仍存在。

  Run:

  ```powershell
  python -m pytest tests/test_capture_bridge_boundary.py -q
  ```

  Expected before cleanup: 若目标分支含 bridge runtime/test 则红灯；若从未合入 runtime，则只因迁移文档尚不存在而红灯。

- [ ] **Step 3：删除实际存在的重复源码和测试**

  只删除已在新仓库验收过、且内容属于 bridge 的文件；不删除 BOM、DNI、历史 spec/plan 或来源工作树。删除前用 `git ls-files` 生成精确的 bridge 文件清单，逐个复核后用 `apply_patch` 删除文本文件，并立即对相同的精确 pathspec 执行 `git add -u -- path`；不得使用仓库级 `git add -u`。若 runtime 从未合入该分支，此步骤记录为 no-op。

- [ ] **Step 4：收窄部署脚本并写迁移说明**

  `cpcode.bat` 若仍以宽泛规则把 bridge 文件纳入部署，则改为 TCLBOM 自有文件白名单或明确排除 bridge。迁移文档说明：新项目位置、安装命令、重新 source 命令、TCLBOM 不再维护 bridge 源码、原实现工作树暂保留用于回退。

- [ ] **Step 5：运行 TCLBOM 全套回归**

  ```powershell
  Set-Location D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge
  $taskTemp = Join-Path (Get-Location) '.tmp\tclbom-regression'
  New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
  $env:TEMP = $taskTemp
  $env:TMP = $taskTemp
  python -m pytest -q
  Get-ChildItem tests -Filter '*.tcl' | ForEach-Object { tclsh $_.FullName }
  git diff --check
  ```

  Expected: BOM/DNI Python 和 Tcl 测试全部通过；不存在 bridge 导入错误。

- [ ] **Step 6：提交 TCLBOM 清理**

  ```powershell
  git add readme.md docs/capture-tcl-ai-bridge-migration.md tests/test_capture_bridge_boundary.py
  if ((git status --short -- cpcode.bat).Length -gt 0) { git add cpcode.bat }
  git status --short
  git commit -m "chore: move Capture AI bridge to standalone project"
  git status --short
  ```

  Expected: 提交成功且工作树 clean；不删除任何 worktree/branch。

---

## Task 12：最终跨仓库验证和交付选择

**Working directories:** 新项目检查使用 `D:\Documents\codeprj\capture-tcl-ai-bridge`；TCLBOM 检查使用 `D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge`。

**Files:** None unless verification reveals a defect.

- [ ] **Step 1：重新验证新项目安装来源和运行状态**

  比较正式部署文件与新仓库文件 SHA-256；确认 `CaptureAiBridgeStatus`、CLI health 和 `%TEMP%\capture_tcl_bridge.json` 指向同一 server PID/capture PID；确认 Token 不进入 Git 或测试日志。

- [ ] **Step 2：重新验证两个仓库工作树和提交边界**

  ```powershell
  git -C D:\Documents\codeprj\capture-tcl-ai-bridge log --oneline --decorate -8
  git -C D:\Documents\codeprj\capture-tcl-ai-bridge status --short
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge log -1 --oneline
  git -C D:\Documents\codeprj\tcl_bom\.worktrees\remove-capture-tcl-ai-bridge status --short
  ```

  Expected: 两个目标工作树 clean；新项目有独立历史；TCLBOM 清理提交独立存在；原 `codex/tcl-bridge-impl` 工作树仍保留。

- [ ] **Step 3：使用 `superpowers:finishing-a-development-branch` 让用户选择集成方式**

  分别报告新仓库和 TCLBOM 分支的测试证据，询问用户是保留本地、推送、创建 PR，还是在确认备份后清理旧工作树。没有用户明确选择，不推送、不合并、不删除来源分支/工作树。

---

## 最终验收清单

- [ ] 新仓库不依赖 TCLBOM 即可安装、source、Start、Status、Stop、卸载。
- [ ] HTTP 和 CLI 共用 `127.0.0.1:8767`、随机 Token 和同一描述文件。
- [ ] `puts` 在 Capture 控制台 tee，并在客户端结果中返回。
- [ ] 确定性 `/internal/result` 4xx 不无限重试、不刷屏、不永久 `busy`。
- [ ] transport/5xx 保留 pending，并用最大 5 秒退避和错误去重恢复。
- [ ] installer 幂等；uninstaller 不删除共享目录或其他项目文件。
- [ ] 7 个示例全部独立，不引用 TCLBOM helper；写操作 occurrence 级、唯一、幂等且不自动保存。
- [ ] 中文 Cookbook 覆盖调用、风险、输出、阻塞、回读和撤销。
- [ ] 自动测试和真实 OrCAD Capture 17.4 验收均有证据。
- [ ] TCLBOM 的 BOM/DNI 回归通过，且只保留迁移说明。
- [ ] 原迁移源分支和工作树在用户决定前保留。
