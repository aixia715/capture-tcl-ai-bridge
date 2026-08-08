# 真实 OrCAD Capture 验收清单

自动测试全绿**不等于**验收通过。这份清单是 Task 10 里必须在真实 Capture 上
逐条执行的部分，需要人来操作 GUI。

请准备一个**可以随便改的测试原理图**，不要用生产设计。写入类步骤会修改设计
（但不会保存）。

记录方式：每条勾上，并把实际输出贴到本文件末尾的记录区，或另存一份。

## 每条前面的标记

| 标记 | 含义 |
| --- | --- |
| **【真机】** | 只有真实 Capture 能证明。**这些必须做。** |
| 【复验】 | 自动测试已覆盖，真机跑一遍只是端到端确认，可快速带过 |
| 【已验】 | 已在真机沙箱路径上验证通过，可跳过 |

**时间不够就只跑【真机】。** 其中最有价值的是阶段 2 —— `examples/*.tcl` 是对着
模拟的 Dbo 接口写的，API 形状没确认之前，后面所有示例失败都无法归因。

一轮最小集合：**0.1 → 阶段 2 → 3.3 → 3.5 → 6.3**。

---

## 阶段 0：环境与安装

- [ ] **0.1** 【真机】 确认 Capture 版本与 Tcl 版本。在 Capture 的 Tcl 命令行执行：

      puts [info patchlevel]

      记录结果。16.6 预期 `8.4.x`，17.4 预期 `8.6.x`。
      这决定了后面 `errorLine` 该期望什么。

- [ ] **0.2** 【真机】 在仓库目录安装：

      python -m pip install -r requirements.txt
      .\install.ps1                      # 16.6 需加 -CaptureTclTarget

      预期：只输出三个运行文件加一个 manifest 路径，然后给出 source / Start /
      Status 三条命令。**不应**启动 Capture 或桥。

- [ ] **0.3** 【已验】 比对部署文件与仓库文件的 SHA-256 一致：

      Get-FileHash .\captureAiBridge.tcl, "<CaptureTclTarget>\captureAiBridge.tcl" |
          Select-Object Hash, Path

- [ ] **0.4** 【已验】（沙箱已验：文件未重写、manifest 未变）再跑一次 `.\install.ps1`，确认幂等：manifest 不变、文件不被重写。

## 阶段 1：加载与显式启动

- [ ] **1.1** 【复验】 在 Capture Tcl 命令行：

      source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl

      预期：`source` **本身什么都不启动**，没有服务、没有轮询。

- [ ] **1.2** 【真机】

      CaptureAiBridgeStart
      CaptureAiBridgeStatus

      预期：显示运行在 `127.0.0.1:8767`，状态 connected / idle。

- [ ] **1.3** 【真机】 确认 `%TEMP%\capture_tcl_bridge.json` 已生成，且 `capturePid`
      等于当前 Capture 进程 PID。**不要把 token 抄到任何地方。**

- [ ] **1.4** 【复验】 再执行一次 `CaptureAiBridgeStart`，确认不会起第二个服务。

## 阶段 2：Dbo API 形状确认（务必先做）

`examples/*.tcl` 是对着模拟接口写的。先确认真实 API 形状，否则后面的失败会
被误判成示例逻辑错误。MIGRATION.md 列了全部假设，这里逐条实测：

- [ ] **2.1** 【真机】 用 CLI 提交，逐条打印真实返回：

      set design [GetActivePMDesign]
      puts "design=$design"
      set root [$design GetRootOccurrence]
      puts "rootType=[$root GetObjectType]"
      set it [$root NewChildrenIter]
      set first [$it Next]
      puts "firstChild=$first"
      puts "firstChildType=[$first GetObjectType]"
      $it delete

      **重点确认**：组件 occurrence 的 `GetObjectType` 到底是不是
      `occDbComponent`。这是风险最高的假设。

- [ ] **2.2** 【真机】 确认迭代器耗尽时 `Next` 返回空字符串，且释放方法确实叫 `delete`。

- [ ] **2.3** 【真机】 在原理图里选中一个器件，然后：

      set sel [GetActivePMSelection]
      puts "selected=[$sel GetSelectedObjects]"

      确认返回的是句柄列表而不是迭代器。

- [ ] **2.4** 【真机】 确认 pin/port occurrence 的父对象访问器名字。假设是
      `GetPartOccurrence`，实测确认：

      set netsIter [$design NewFlatNetsIter]
      set net [$netsIter Next]
      puts "net=[$net GetName]"
      set pinIter [$net NewPinOccurrencesIter]
      set pin [$pinIter Next]
      puts "pinCmds: [catch {$pin GetPartOccurrence} r]/$r"
      $pinIter delete
      $netsIter delete

      **任何一条与假设不符，先记录差异并停下**，不要边猜边改示例。

## 阶段 3：只读链路

- [ ] **3.1** 【复验】 CLI 五种形式全部走通：

      python C:\tclpython\capture_tcl_cli.py status
      python C:\tclpython\capture_tcl_cli.py -c "expr {1 + 1}"
      python C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
      Get-Content -Raw .\examples\selected_refs.tcl | python C:\tclpython\capture_tcl_cli.py
      python C:\tclpython\capture_tcl_cli.py --json -c "expr {1 + 1}"

- [ ] **3.2** 【复验】 多行 + UTF-8 脚本，确认返回值与中文原样往返。

- [ ] **3.3** 【真机】 **`puts` tee**：提交 `puts "hello-from-bridge"`，确认这行
      **同时**出现在 Capture 控制台和客户端 stdout。这是核心保证。

- [ ] **3.4** 【真机】 故意失败的 Capture API 调用，确认返回 `errorInfo`、`errorCode`；
      `errorLine` 按 0.1 的版本决定期望（8.6 有精确行号，8.4 为 `null`）。

- [ ] **3.5** 【真机】 依次跑通四个只读示例：`selected_refs`、`list_components`、
      `get_component_value`、`extract_topology`。
      `get_component_value.tcl` 另外验证三种情况：不存在 → `COMPONENT_NOT_FOUND`，
      唯一 → 正常输出，重复位号 → `COMPONENT_NOT_UNIQUE`。

## 阶段 4：写入链路（测试原理图！）

- [ ] **4.1** 【真机】 `set_component_value.tcl`：确认只改唯一命中的那个 occurrence，
      输出 before/after，且回读一致。**先记下 before 值以便还原。**

- [ ] **4.2** 【真机】 重复位号时确认修改次数为 0。

- [ ] **4.3** 【真机】 `mark_selected_suffix.tcl`：选中若干器件执行，确认 Value 追加 `*`；
      **再执行一次**，确认不会变成 `**`（幂等）。

- [ ] **4.4** 【真机】 `remove_selected_suffix.tcl`：确认只去掉一个尾部 `*`。

- [ ] **4.5** 【真机】 确认设计**没有被自动保存**（标题栏仍显示未保存），
      并确认没有调用 `RefreshParts`。

- [ ] **4.6** 【真机】 把改动还原到测试前的值，或直接关闭不保存。

## 阶段 5：并发、超时与故障恢复

- [ ] **5.1** 【复验】 提交一条长脚本，在它执行期间提交第二条，确认稳定返回 `BRIDGE_BUSY`。

- [ ] **5.2** 【复验】 提交一条超过 30 秒的脚本，确认：HTTP 返回 504、**脚本没有被取消**、
      随后 `GET /v1/commands/<id>` 能取到完成结果。

- [ ] **5.3** 【真机】 **HTTP 400 恢复**（只在你同意的本机测试会话做）。在 Capture 控制台：

      rename ::_captureAiResultJson ::_captureAiResultJsonAcceptanceReal
      proc ::_captureAiResultJson {args} {
          after 0 {
              rename ::_captureAiResultJson {}
              rename ::_captureAiResultJsonAcceptanceReal ::_captureAiResultJson
          }
          return "\{"
      }

      然后用 CLI 提交一条正常短命令，确认：
      - Tcl 侧收到**一次** HTTP 400；
      - 控制台只输出**一次**脱敏错误，不刷屏；
      - 等待中的客户端收到合成的 `INVALID_RESULT` 结果；
      - `/v1/health` 的 `busy` 恢复 `false`；
      - **下一条正常命令能成功执行**。

      做完用 `info commands ::_captureAiResultJsonAcceptanceReal` 确认它已消失、
      原 proc 已还原。若自动还原没发生，立刻手动 rename 还原。
      这个临时包装**绝不能写进部署文件**。

- [ ] **5.4** 【复验】 跑一个会产生大结果或复杂 `errorInfo` 的脚本，确认不出现连续 400 刷屏，
      且下一条正常命令仍可执行。

- [ ] **5.5** 【复验】 含反斜杠的输出（这是修掉的那个 JSON 缺陷）：

      puts "C:\\cadence\\SPB_16.6"

      确认正常返回，**不会**触发 `INVALID_RESULT`。

- [ ] **5.6** 【复验】 在 pending / 故障状态下执行 `CaptureAiBridgeStop`，确认能输入且能收敛。

- [ ] **5.7** 【复验】 只在需要取证时才执行 `CaptureAiBridgeDumpPendingResult <path>`，
      确认文件内容**不含 token**。看完自行决定是否删除。

## 阶段 6：生命周期

- [ ] **6.1** 【复验】 `CaptureAiBridgeStop`，确认描述文件消失、服务进程结束。

- [ ] **6.2** 【复验】 Stop → Start，比较前后描述文件里的 token，**必须不同**。

- [ ] **6.3** 【真机】 退出 Capture，确认 8767 端口无监听、服务 PID 已结束、描述文件已清理：

      Get-NetTCPConnection -LocalPort 8767 -State Listen -ErrorAction SilentlyContinue
      Test-Path "$env:TEMP\capture_tcl_bridge.json"

- [ ] **6.4** 【真机】 重启 Capture，确认必须重新 `source` 才能再次 Start。

## 阶段 7：卸载

- [ ] **7.1** 【已验】（沙箱已验，含拒绝换目标路径、保留他人文件）`.\uninstall.ps1`，确认三个运行文件和 manifest 都消失，
      **目标目录本身仍在**，目录里其他项目的文件没被动过。

---

## 记录区

| 阶段 | 结果 | 备注 |
| --- | --- | --- |
| 0.1 Tcl 版本 | | |
| 2.x API 差异 | | |
| 3.3 puts tee | | |
| 5.3 400 恢复 | | |
| 6.2 token 轮换 | | |

全部通过后，才可以把 `MIGRATION.md` 的状态从"待验收"改为已验收，
并记录日期、Capture 版本和测试范围。**不要**记录 token、原理图敏感内容
或完整的 pending payload。
