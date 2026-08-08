# Capture Tcl Cookbook

`examples/` 下的七个脚本是可以直接发送给桥的完整独立脚本：不 `source` 任何
公共文件，不依赖 TCLBOM 的 `_dniWalk` / `CollectSelectedDNIOccs` 之类的辅助过程。
七个脚本都是照 [docs/capture-dbo-api-notes.md](capture-dbo-api-notes.md) 写的——
那份笔记记录了在真实 Capture 16.6 上实测确认的 Dbo Tcl API 调用约定，本手册的
每一段代码示例和风险描述都以它为准。本手册对每个脚本逐一说明用途、风险、参数、
三种调用方式、预期输出、UI 阻塞风险、回读验证方式，以及撤销和不自动保存的约定。

**本文档嵌入的每段脚本原文都必须和 `examples/*.tcl` 逐字节一致。**
`tests/test_docs_contract.py` 会在每次运行时把本文档里两条
`<!-- BEGIN EXAMPLE SOURCE: ... -->` / `<!-- END EXAMPLE SOURCE: ... -->`
标记之间的内容抽出来，统一换行符后与磁盘上的对应文件比较；只要有一个字符
不一致，或者文档记录的脚本文件名集合和 `examples/*.tcl` 实际的集合对不上，
测试就会失败。改了任何一个 `examples/*.tcl` 之后，必须同步更新本文档里对应的
嵌入代码块，而不是反过来改脚本去迁就文档——脚本已经通过验收，脚本说了算。

## 真实 API 的安全规则：基类方法 vs 类型专属方法

七个脚本共同遵守 `docs/capture-dbo-api-notes.md` 里的规则，读每个脚本前先了解
一次就够了，各脚本小节不再重复展开：

1. **状态检查**：几乎每个 Dbo 调用都要一个 `DboState`，调用失败时不会抛出
   Tcl 错误，而是悄悄给出一个空/无效句柄，继续用它会出更难查的错。七个脚本
   都在每次这样的调用之后立即检查 `[$lStatus OK] == 1`，失败就用 `error`
   带着 `DBO_CALL_FAILED:` 前缀清楚地报出来。**`Message` 本身也是一个 CString
   出参**，不是像 `OK`/`Succeeded`/`Failed`/`Code`/`Severity` 那样的普通返回值
   ——本项目更早一版全部七个脚本都直接写 `[$st Message]`，这是一个实打实的
   bug：一旦某次 Dbo 调用真的失败，取诊断信息这一步自己先抛出 Tcl 参数个数
   错误，把真正的失败原因整个盖掉，而且只在失败路径才会触发，正常路径的
   测试完全测不出来。现在七个脚本都用统一的 `_statusMessage` 辅助过程通过
   出参读：

   ```tcl
   proc _statusMessage {st} {
       set msgC [DboTclHelper_sMakeCString]
       $st Message $msgC
       return [DboTclHelper_sGetConstCharPtr $msgC]
   }
   ```

   `tests/test_examples.tcl` 里专门有端到端的回归测试：故意让某次调用失败，
   断言最终报出来的 Tcl 错误文本里**真的包含**那次失败的 `Message` 内容，
   而不是一段 `wrong # args` 的参数个数错误。
2. **只有类型专属方法才需要转型前先查类型**。真正决定要不要转型的是
   `DboBaseObject`（基类）方法和类型专属方法的区分：
   - **基类方法，任何句柄都能直接调，不需要转型**：`GetObjectType`、
     `GetTypeString`、`GetName`、`GetId`、`GetEffectivePropStringValue`、
     `SetEffectivePropStringValue`。七个脚本里所有的属性读写（位号、
     Value）都走这条路径，因此选择集脚本（见下文）完全不需要转型。
   - **类型专属方法，转型前必须先查类型**：`GetReference`、`GetPathName`、
     `IsPrimitive`、`NewChildrenIter`。把类型不对的句柄直接喂给
     `DboOccurrenceToDboInstOccurrence` 或直接调用上面这几个方法，**不会
     报 Tcl 错误，会让整个 Capture 进程崩溃**。因此涉及这几个方法的脚本
     在每一次转型前都先用 `DboBaseObject_GetObjectType` 确认类型，
     `tests/test_examples.tcl` 的 `safety` suite 专门验证了这一点：故意塞
     一个类型不对的句柄进去，脚本必须报出可读的错误，而不是走到真正的
     转型调用。

写入用的是 `SetEffectivePropStringValue`——**不是** `SetPropStringValue`，
后者在 Cadence 自带脚本里零命中，是本项目更早一版凭类比编出来、已被证伪的
名字。

### 两套对象族

- **occurrence 族**（`list_components.tcl`、`get_component_value.tcl`、
  `set_component_value.tcl`、`extract_topology.tcl` 用）：从
  `$design GetRootOccurrence` 或某个 `NewChildrenIter` 迭代器拿到的都是泛型
  `DboOccurrence` 句柄。调用 `GetReference`、`GetPathName`、`IsPrimitive`、
  `NewChildrenIter` 前必须先查类型再用 `DboOccurrenceToDboInstOccurrence`
  转型成 `DboInstOccurrence`；但读 `Value` 属性用的
  `GetEffectivePropStringValue` 是基类方法，直接在同一个句柄上调用即可，
  不需要额外转型。
- **选择集族**（`selected_refs.tcl`、`mark_selected_suffix.tcl`、
  `remove_selected_suffix.tcl` 用）：全局命令 `GetSelectedObjects`（无参，
  没有 `GetActivePMSelection` 这个东西）返回的是**页面级**对象。放置在
  页面上的器件报告的类型是 `DRAWN_INSTANCE`(12) 或 `PLACED_INSTANCE`(13)
  ——**不是** `PART_INSTANCE`(11)，尽管名字看起来最像；`capRotate.tcl` 和
  `capPSpiceSourceApp.tcl` 都是判 `12 || 13`。这些对象上**没有**类型专属的
  `GetReference`，也没有 `DboObjectToDboPartInstance` 这个转型函数（同样是
  更早一版凭类比编出来、在 Cadence 脚本里零命中的名字）：位号和 Value 都
  通过基类的 `GetEffectivePropStringValue`/`SetEffectivePropStringValue`
  读写，位号对应的属性名是 `"Part Reference"`（见 `capCIS.tcl`、
  `capAnnotateHBlockPageNumber.tcl`），Value 对应 `"Value"`。因此选择集
  脚本从头到尾**没有任何转型**，类型检查只是为了正确挑出器件，不是为了
  防崩溃。

字符串类返回值（位号、层级路径、属性值、网络名/端口名）一律走"C 字符串
出参"约定：先用 `DboTclHelper_sMakeCString` 分配一个出参对象，调用本身
返回一个 `DboState`，成功后用 `DboTclHelper_sGetConstCharPtr` 读回字符串，
最后释放状态对象。

### 已知未确认、本手册的脚本刻意不实现的部分

`extract_topology.tcl` 输出网络名、它连接的层级端口，以及它有多少个 net
occurrence（flat net 上引脚级连接的等价物——`info commands *PinOccurrence*`
在真机上完全为空，flat net 上没有任何引脚级 API）。`NewNetOccurrencesIter`
和 `NextNetOccurrence` 都已确认存在（`info commands DboFlatNetNetOccurrences*`
返回 `DboFlatNetNetOccurrencesIter`、`..._GetKey`、`..._Next`、
`..._NextNetOccurrence`）——本项目更早一版曾经因为在 Cadence 自带脚本里搜不到
用例而误判 `NextNetOccurrence` 不存在、整段砍掉，那个判断是错的：
Cadence 自带脚本没用到不等于真实 API 里没有。

但一件事仍然没有确认：一个 net occurrence 本身能读到什么字段（位号、
引脚名、引脚号、所属器件——一概未验证）。猜一个类型专属方法的名字不是
语法风险，是崩溃风险——把类型不对的**句柄**喂给一个真实存在的类型专属
方法会让 Capture 直接崩溃，因此脚本只用已确认的 `NextNetOccurrence` 把
每个网络的 net occurrence **数一遍**，从不在返回的句柄上调用任何方法。
脚本文件顶部和对应位置都用 `UNCONFIRMED` 标出这一处，并给出下一步在真机
上探测的具体命令，等确认后只需要在标记处补一段代码。

这个迭代器本身**会**被释放，这和"不猜字段方法名"不矛盾：释放函数按这个
API 里"每种迭代器都有自己的 `delete_<迭代器类>`"的命名规律，猜测名字是
`delete_DboFlatNetNetOccurrencesIter`（`DboFlatNetNetOccurrencesIter` 这个
类名本身已经用 `info commands` 实测确认存在）。调用一个类型专属方法时
喂错**句柄**会崩溃，但调用一个根本不存在的 Tcl **命令名**只是一个普通的、
`catch` 得住的错误——两者是不同的风险类别。脚本因此用
`info commands delete_DboFlatNetNetOccurrencesIter` 在运行时探测这个猜测
出来的名字是否存在，存在才调用，不存在就照旧跳过，两条分支
`tests/test_examples.tcl` 的 `topology` suite 都测到了。

## 三种调用方式

以 `examples/selected_refs.tcl` 为例，下面是三种等价的提交方式。

### 1. CLI，用 `-f` 传文件

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
```

### 2. CLI，用标准输入传内容

```powershell
Get-Content -Raw .\examples\selected_refs.tcl | python C:\tclpython\capture_tcl_cli.py
```

两种 CLI 调用等价；多行脚本、多行 UTF-8 输出都原样支持。不加 `--json` 时
先打印捕获的 stdout/stderr，再打印结果或 Tcl 错误摘要；退出码含义见
[README.md](../README.md#3-用命令行执行-tcl)。

### 3. HTTP，供 AI 客户端直接调用

运行描述文件 `%TEMP%\capture_tcl_bridge.json` 里的 `baseUrl` 和 `token`
每次 `CaptureAiBridgeStart` 都会变化，**永远从这个文件现读，不要把 token
抄进脚本、文档或提交记录**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\selected_refs.tcl) } | ConvertTo-Json)
```

调用前建议先校验 `$runtime.service`、`$runtime.protocolVersion` 和
`$runtime.capturePid`，完整字段和状态机见 [docs/protocol.md](protocol.md)。
`puts` 的内容会同时出现在响应的 `stdout` 字段和 Capture 控制台里，
两边都能看到同一份输出。

下面每个脚本的 HTTP 调用小节都是同一个模式，只是 `-Body` 里换成对应的
`examples\<script>.tcl`。

---

## `list_components.tcl`

**用途**：深度优先遍历当前设计的整棵 occurrence 树，输出每一个**叶子器件**
（`IsPrimitive` 为真的 occurrence）的位号（RefDes）、Value 和层级路径
（hierarchy path）。

**风险级别**：只读，不修改设计；但是遍历整个设计，在大原理图上可能运行
很久，属于下面单独说明的 UI 阻塞风险。

**输入参数**：无需编辑任何变量，脚本按当前的 Active Design 遍历。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\list_components.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\list_components.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\list_components.tcl) } | ConvertTo-Json)
```

**预期输出**：每个叶子器件一行，形如
`refdes R1 value 10k path /U1/R1`（`dict create` 的列表形式）；
层次块（`IsPrimitive` 为假的 occurrence，包括根 occurrence 本身）不会单独
输出一行，只作为遍历路径上的容器被展开。

**UI 阻塞风险**：Capture 在 Tcl/UI 线程上执行脚本，`list_components.tcl`
会递归访问整棵 occurrence 树，设计越大、层级越深，运行时间越长，期间
Capture 界面会无响应。`POST /v1/execute` 的 30 秒等待**超时不会取消**
已经在 Capture 里跑的遍历——脚本会继续跑到结束，超时只是让 HTTP 客户端
提前拿到 504 和命令 ID，之后可以用 `GET /v1/commands/{id}` 按 ID 查询
最终是否跑完、跑出了什么。

**回读验证**：只读脚本没有写入动作，不需要回读；每一行输出都是当次
`GetEffectivePropStringValue`/`GetPathName` 的即时结果。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: list_components.tcl -->
```tcl
# List every component occurrence in the active design, depth-first.
#
# Self-contained: Capture submits example scripts as-is through the bridge,
# so this script carries its own occurrence walker and its own copies of
# the real Dbo Tcl API plumbing -- DboState status objects, C-string
# out-parameters, the DboOccurrenceToDboInstOccurrence downcast -- rather
# than depending on any shared helper file. Read-only: it never mutates a
# property or saves the design, so it is safe to run against a design that
# is open for edit.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately.
#   2. GetReference, GetPathName, IsPrimitive and NewChildrenIter are
#      type-specific DboInstOccurrence methods: a wrongly-typed handle
#      passed to them (via DboOccurrenceToDboInstOccurrence) does not raise
#      a Tcl error, it crashes the whole Capture process, so every
#      occurrence handle pulled out of an iterator is checked with
#      DboBaseObject_GetObjectType before it is ever downcast. GetObjectType
#      itself and GetEffectivePropStringValue are DboBaseObject methods --
#      safe on any handle, no downcast needed -- which is why the property
#      read below runs with no extra guarding.
#
# Output: one line per leaf component, `dict create refdes ... value ... path ...`.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
    }
}

# Calls a Convention-A Dbo method (one C-string out-parameter, the call
# itself returns a fresh DboState) and returns the decoded string, freeing
# both the out-parameter's status and itself.
proc _stringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $cstr]
    $st -delete
    return $value
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

# Checks the object family before downcasting: every child pulled out of an
# occurrence's children iterator is expected to be INST_OCCURRENCE, but
# "expected" is not "guaranteed", and DboOccurrenceToDboInstOccurrence on
# anything else is a crash, not a catchable error.
proc _toInstOccurrence {occHandle what} {
    set objType [DboBaseObject_GetObjectType $occHandle]
    if {$objType != $::DboBaseObject_INST_OCCURRENCE} {
        error "UNEXPECTED_OBJECT_TYPE: $what: expected INST_OCCURRENCE, got object type $objType"
    }
    return [DboOccurrenceToDboInstOccurrence $occHandle]
}

proc _listComponentsWalk {st occHandle} {
    set instOcc [_toInstOccurrence $occHandle {list_components: occurrence}]

    set isPrimitive [$instOcc IsPrimitive $st]
    _requireOk $st {IsPrimitive}
    if {$isPrimitive == 1} {
        set refdes [_stringOut $instOcc GetReference {GetReference}]
        set value [_getEffectiveProp $instOcc Value {GetEffectivePropStringValue(Value)}]
        set hierarchyPath [_stringOut $instOcc GetPathName {GetPathName}]
        puts [dict create refdes $refdes value $value path $hierarchyPath]
    }

    # Every occurrence, leaf or hierarchical block, can have children -- a
    # block's children are the components and blocks nested inside it -- so
    # the walker always descends and always frees the iterator it opens,
    # whether or not this node turned out to be a leaf.
    set childrenIter [$instOcc NewChildrenIter $st $::IterDefs_INSTS]
    _requireOk $st {NewChildrenIter}
    $childrenIter Sort $st
    _requireOk $st {Sort}
    try {
        while {1} {
            set child [$childrenIter NextOccurrence $st]
            # A finished iterator returns NULL and at the same time sets the
            # status to error 1022 ("At normal end of iteration"), so the
            # sentinel has to be tested before the status -- checking status
            # first turns every completed walk into a reported failure.
            if {$child eq {NULL}} { break }
            _requireOk $st {NextOccurrence}
            _listComponentsWalk $st $child
        }
    } finally {
        delete_DboOccurrenceChildrenIter $childrenIter
    }
}

set st [DboState]
try {
    set design [GetActivePMDesign]
    set rootOcc [$design GetRootOccurrence $st]
    _requireOk $st {GetRootOccurrence}
    _listComponentsWalk $st $rootOcc
} finally {
    $st -delete
}
```
<!-- END EXAMPLE SOURCE: list_components.tcl -->

---

## `selected_refs.tcl`

**用途**：读取 Capture 当前的选择集（`GetSelectedObjects`），过滤出
`DRAWN_INSTANCE`/`PLACED_INSTANCE` 类型的对象（丢弃其余非器件对象），
输出去重、排序后的位号列表。

**风险级别**：只读，低风险；只处理当前选择集，不遍历整个设计。

**输入参数**：无需编辑变量，但运行前必须先在 Capture 里选中要查询的对象
——脚本读的是提交时刻的选择状态。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\selected_refs.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\selected_refs.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\selected_refs.tcl) } | ConvertTo-Json)
```

**预期输出**：每行一个位号，按字典序排序，没有重复；同一个实例
被选中多次，或者两个不同实例恰好共享同一个位号，都只出现一行。

**UI 阻塞风险**：只处理选择集，不做整设计遍历，通常很快；选择集本身很大
时耗时会随之增长，但不会像 `list_components.tcl` 那样遍历整棵层级树。

**回读验证**：只读，无写入，无需回读。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: selected_refs.tcl -->
```tcl
# Reference designators of the components in the current selection.
#
# Self-contained and read-only: filters the current selection down to
# component instances (dropping wires and other non-component page
# objects), maps each surviving instance to its reference designator, and
# prints the deduplicated, sorted list -- one refdes per line. Selecting
# the same instance twice, or several instances that happen to share a
# refdes, must not produce a duplicate line.
#
# Selection objects are a different object family from occurrence objects
# (see list_components.tcl for that family): GetSelectedObjects hands back
# page-level instances, and a component placed on a page reports
# DRAWN_INSTANCE or PLACED_INSTANCE -- *not* PART_INSTANCE, despite the
# name; capRotate.tcl and capPSpiceSourceApp.tcl both check "12 || 13".
# There is no type-specific GetReference on these objects and no
# DboObjectToDboPartInstance downcast -- refdes is read the same way any
# other property is, through the DboBaseObject method
# GetEffectivePropStringValue with the property name "Part Reference". That
# means no downcast, and no crash risk, on this path at all: the type check
# below exists to correctly select components, not to guard against a
# type-specific call.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

set refdesList {}
foreach obj [GetSelectedObjects] {
    set objType [DboBaseObject_GetObjectType $obj]
    if {$objType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    lappend refdesList [_getEffectiveProp $obj {Part Reference} {GetEffectivePropStringValue(Part Reference)}]
}

foreach refdes [lsort -unique $refdesList] {
    puts $refdes
}
```
<!-- END EXAMPLE SOURCE: selected_refs.tcl -->

---

## `get_component_value.tcl`

**用途**：按位号在整个设计里查找唯一的叶子器件，输出它的 Value 和层级路径。

**风险级别**：只读，但和 `list_components.tcl` 一样要遍历整棵
occurrence 树来确认唯一性，在大设计上同样可能运行较久。

**输入参数**：文件顶部

```tcl
set targetRefdes C3
```

发送前把 `C3` 改成要查询的位号。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\get_component_value.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\get_component_value.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\get_component_value.tcl) } | ConvertTo-Json)
```

**预期输出**：唯一匹配时输出一行
`refdes C3 value 100nF path /U2/C3`；一个位号都没找到时 Tcl 报错
`COMPONENT_NOT_FOUND`；同一个位号在设计里出现不止一次时报错
`COMPONENT_NOT_UNIQUE`——脚本主动拒绝在多个候选里瞎猜一个,而是要求调用方
先用层级路径把歧义消掉。两种错误都通过 Tcl `error` 抛出，CLI/HTTP 会把
它们当作正常的 Tcl 失败上报（`returnCode` 非零、`errorInfo` 里能看到
错误信息），不是协议层错误。

**UI 阻塞风险**：查找阶段遍历整个设计，和 `list_components.tcl` 一样
在大设计上可能长时间阻塞 Capture UI；HTTP 超时同样不会取消已经在跑的
查找。

**回读验证**：只读查询，不写入，不需要回读；输出的 `value` 就是查询到
的那一刻的 `GetEffectivePropStringValue` 结果。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: get_component_value.tcl -->
```tcl
# Look up one component's value and hierarchical path by reference
# designator.

# Edit this before sending:
set targetRefdes C3

# Self-contained and read-only: carries its own occurrence walker (see
# list_components.tcl for the sibling script that lists everything instead
# of one refdes) because a schematic can legally contain more than one
# occurrence with the same reference designator -- e.g. two components
# under different hierarchical blocks that happen to share a refdes -- and
# the caller needs to know that before trusting a value.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately.
#   2. GetReference, GetPathName, IsPrimitive and NewChildrenIter are
#      type-specific DboInstOccurrence methods: a wrongly-typed handle
#      passed to them (via DboOccurrenceToDboInstOccurrence) does not raise
#      a Tcl error, it crashes the whole Capture process, so every
#      occurrence handle pulled out of an iterator is checked with
#      DboBaseObject_GetObjectType before it is ever downcast. GetObjectType
#      itself and GetEffectivePropStringValue are DboBaseObject methods --
#      safe on any handle, no downcast needed -- which is why the property
#      read below runs with no extra guarding.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
    }
}

proc _stringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $cstr]
    $st -delete
    return $value
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

proc _toInstOccurrence {occHandle what} {
    set objType [DboBaseObject_GetObjectType $occHandle]
    if {$objType != $::DboBaseObject_INST_OCCURRENCE} {
        error "UNEXPECTED_OBJECT_TYPE: $what: expected INST_OCCURRENCE, got object type $objType"
    }
    return [DboOccurrenceToDboInstOccurrence $occHandle]
}

proc _findComponentByRefdes {st occHandle targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    set instOcc [_toInstOccurrence $occHandle {get_component_value: occurrence}]

    set isPrimitive [$instOcc IsPrimitive $st]
    _requireOk $st {IsPrimitive}
    if {$isPrimitive == 1} {
        set refdes [_stringOut $instOcc GetReference {GetReference}]
        if {$refdes eq $targetRefdes} {
            set value [_getEffectiveProp $instOcc Value {GetEffectivePropStringValue(Value)}]
            set hierarchyPath [_stringOut $instOcc GetPathName {GetPathName}]
            lappend matches [list $refdes $value $hierarchyPath]
        }
    }

    set childrenIter [$instOcc NewChildrenIter $st $::IterDefs_INSTS]
    _requireOk $st {NewChildrenIter}
    $childrenIter Sort $st
    _requireOk $st {Sort}
    try {
        while {1} {
            set child [$childrenIter NextOccurrence $st]
            # A finished iterator returns NULL and at the same time sets the
            # status to error 1022 ("At normal end of iteration"), so the
            # sentinel has to be tested before the status -- checking status
            # first turns every completed walk into a reported failure.
            if {$child eq {NULL}} { break }
            _requireOk $st {NextOccurrence}
            _findComponentByRefdes $st $child $targetRefdes matches
        }
    } finally {
        delete_DboOccurrenceChildrenIter $childrenIter
    }
}

set st [DboState]
set matches {}
try {
    set design [GetActivePMDesign]
    set rootOcc [$design GetRootOccurrence $st]
    _requireOk $st {GetRootOccurrence}
    _findComponentByRefdes $st $rootOcc $targetRefdes matches
} finally {
    $st -delete
}

set matchCount [llength $matches]
if {$matchCount == 0} {
    error "COMPONENT_NOT_FOUND: no component with reference designator \"$targetRefdes\""
}
if {$matchCount > 1} {
    error "COMPONENT_NOT_UNIQUE: $matchCount components with reference designator \"$targetRefdes\" -- disambiguate by hierarchical path"
}

lassign [lindex $matches 0] refdes value hierarchyPath
puts [dict create refdes $refdes value $value path $hierarchyPath]
```
<!-- END EXAMPLE SOURCE: get_component_value.tcl -->

---

## `extract_topology.tcl`

**用途**：按 flat net（拍平后的网络）输出设计的网络名、每个网络连接到的
层级端口，以及每个网络有多少个 net occurrence（引脚级连接的等价物）。
**不**输出每个 net occurrence 具体是哪个器件的哪个引脚——见下方"预期输出"
和脚本内注释里对这部分未确认 API 的说明。

**风险级别**：只读，但同样是整设计级的遍历（所有 flat net，以及每个
net 上的所有端口和 net occurrence），在大设计上可能长时间运行。

**输入参数**：无需编辑任何变量。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\extract_topology.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\extract_topology.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\extract_topology.tcl) } | ConvertTo-Json)
```

**预期输出**：每个网络先输出一行 `net N1`；随后每个连接到该网络的
层级端口输出一行 `net N1 port IN`；最后输出一行
`net N1 netOccurrenceCount 3`，即这个网络的 net occurrence 总数。三种行
都用 `dict create` 格式，`net` 字段把同一个网络的所有行关联起来。
**没有** `net N1 refdes ... pin ... name ...` 这一行——`NewNetOccurrencesIter`
和 `NextNetOccurrence` 都已确认存在，脚本也确实打开了这个迭代器、用
`NextNetOccurrence` 数出了总数，但一个 net occurrence 本身能读到什么字段
（位号、引脚名、引脚号、所属器件）还没确认，脚本因此只数数，不读取任何
字段——猜一个类型专属方法的名字去读字段，猜错了是崩溃 Capture 的风险，
不是语法风险。

这个迭代器**会**被释放，和只读部分的谨慎程度不一样：调用一个根本不存在
的 Tcl 命令名，只是一个普通的、能被 `catch` 住的错误，不是崩溃风险
——真正危险的是把类型不对的**句柄**喂给一个真实存在的类型专属方法。
所以脚本用 `info commands delete_DboFlatNetNetOccurrencesIter` 在运行时
探测这个按惯例推测出的释放函数名是否存在，存在就调用释放，不存在就照旧
跳过——这样命名猜对时不会在大设计上每个网络泄漏一个迭代器，猜错时也
不会崩溃，只是退回到之前"暂不回收"的状态。

**风险提示**（不是 crash 风险，是设计选择的边界）：`delete_DboFlatNetNetOccurrencesIter`
这个具体名字沿用了这个 API 里"每种迭代器都有自己的 `delete_<迭代器类>`"
这一贯穿全文档的命名规律，`DboFlatNetNetOccurrencesIter` 这个类名本身是
`info commands` 实测确认存在的，因此这个猜测有很强的依据，但**依据不等于
确认**，`tests/test_examples.tcl` 的 `topology` suite 两个分支都测：命令
存在时确实释放、命令不存在时确实优雅跳过。

**UI 阻塞风险**：和 `list_components.tcl` 一样，Capture 在 Tcl/UI
线程上执行脚本，`extract_topology.tcl` 要遍历所有 flat net、其端口和 net
occurrence，设计越大运行越久，期间界面无响应。`POST /v1/execute` 的 30 秒
等待**超时不会取消**已经在 Capture 里跑的遍历，脚本会继续跑到结束，
之后可以按命令 ID 查询最终结果。

**回读验证**：只读，无写入，不需要回读。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: extract_topology.tcl -->
```tcl
# Flat-net topology of the active design: for every net, its name, the
# hierarchical ports connected to it, and how many net occurrences (the
# flat net's equivalent of pin-level connections -- there is no pin API on
# a flat net at all) it has.
#
# Self-contained and read-only: walks the design's flat-net view directly
# (NewFlatNetsIter) rather than any TCLBOM net-walking helper. A flat net
# collapses hierarchy, so a single N1 here may connect a pin inside one
# hierarchical block to a pin inside another -- the hierarchical ports on a
# net are exactly the boundary crossings that made that possible. Every
# iterator this script opens (nets, ports, net occurrences) is freed
# exactly once, even when a later net is never reached because there are
# no more nets left to enumerate.
#
# docs/capture-dbo-api-notes.md confirms there is no NewPinOccurrencesIter
# on DboFlatNet (info commands *PinOccurrence* is completely empty on real
# Capture) and that NewNetOccurrencesIter/NextNetOccurrence are the
# confirmed replacement -- an earlier draft of this script dropped the
# net-occurrence walk entirely on a (wrong) report that NextNetOccurrence
# did not exist; it does. What is still NOT confirmed is what
# fields/methods a net occurrence itself exposes (refdes, pin name/number,
# owning component -- none of it verified): guessing a type-specific
# method name is a crash risk (a wrong type-specific method call on a real
# object does not raise a Tcl error, it crashes Capture), so this script
# stops at counting how many net occurrences a net has, never calling any
# method on a net occurrence handle.
#
# The free function for the DboFlatNetNetOccurrencesIter this opens is
# also not confirmed by name, but freeing is a different risk category
# from calling a type-specific method: passing a wrongly-typed *handle* to
# a real method crashes Capture, but calling a Tcl *command name* that
# simply does not exist is an ordinary catchable error. So the
# conventional delete_<ClassName> name (every other iterator in this API
# follows it, and DboFlatNetNetOccurrencesIter is confirmed to exist as a
# class) is probed at runtime with `info commands` rather than called
# blindly -- free if present, leave open if not, either way no crash.
# UNCONFIRMED -- probe on real Capture to turn this from "probably right,
# guarded" into "confirmed, unconditional":
#   info commands delete_DboFlatNetNetOccurrencesIter
#   info commands DboFlatNetNetOccurrencesIter_GetKey
#   catch {$lNetOcc SomeGuessAtAMethod} probeResult
# and inspect what a SWIG wrong-number-of-args error (or success) reveals
# about the real field-access API before reading anything off a net
# occurrence for real.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately.
#   2. GetName (on both a flat net and a port occurrence) is a
#      DboBaseObject method -- safe on any handle, no downcast needed -- so
#      this script performs no downcast at all; nothing here reaches a
#      type-specific method.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
    }
}

proc _stringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $cstr]
    $st -delete
    return $value
}

# Frees a DboFlatNetNetOccurrencesIter if (and only if) the conventional
# delete_<ClassName> name actually exists in this Capture session -- see
# the file header for why probing a command name is safe where probing a
# handle's type is not.
proc _freeNetOccurrencesIterIfPossible {iterHandle} {
    if {[llength [info commands delete_DboFlatNetNetOccurrencesIter]] > 0} {
        delete_DboFlatNetNetOccurrencesIter $iterHandle
    }
}

set st [DboState]
try {
    set design [GetActivePMDesign]
    set netsIter [$design NewFlatNetsIter $st]
    _requireOk $st {NewFlatNetsIter}
    try {
        while {1} {
            set net [$netsIter NextFlatNet $st]
            # A finished iterator returns NULL and at the same time sets the
            # status to error 1022 ("At normal end of iteration"), so the
            # sentinel has to be tested before the status -- checking status
            # first turns every completed walk into a reported failure.
            if {$net eq {NULL}} { break }
            _requireOk $st {NextFlatNet}

            set netName [_stringOut $net GetName {GetName(net)}]
            puts [dict create net $netName]

            set portsIter [$net NewPortOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewPortOccurrencesIter}
            try {
                while {1} {
                    set port [$portsIter NextPortOccurrence $st]
                    # A finished iterator returns NULL and at the same time sets the
                    # status to error 1022 ("At normal end of iteration"), so the
                    # sentinel has to be tested before the status -- checking status
                    # first turns every completed walk into a reported failure.
                    if {$port eq {NULL}} { break }
                    _requireOk $st {NextPortOccurrence}
                    set portName [_stringOut $port GetName {GetName(port)}]
                    puts [dict create net $netName port $portName]
                }
            } finally {
                delete_DboFlatNetPortOccurrencesIter $portsIter
            }

            # Net occurrences: the confirmed pin-level equivalent. Counted,
            # not inspected -- see the file header for exactly what is and
            # is not confirmed here.
            set netOccIter [$net NewNetOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewNetOccurrencesIter}
            try {
                set netOccurrenceCount 0
                while {1} {
                    set netOcc [$netOccIter NextNetOccurrence $st]
                    # A finished iterator returns NULL and at the same time sets the
                    # status to error 1022 ("At normal end of iteration"), so the
                    # sentinel has to be tested before the status -- checking status
                    # first turns every completed walk into a reported failure.
                    if {$netOcc eq {NULL}} { break }
                    _requireOk $st {NextNetOccurrence}
                    incr netOccurrenceCount
                    # UNCONFIRMED: no field of a net occurrence (refdes,
                    # pin name, pin number, owning component) is
                    # confirmed, so nothing is read off $netOcc beyond the
                    # fact that it exists.
                }
                puts [dict create net $netName netOccurrenceCount $netOccurrenceCount]
            } finally {
                _freeNetOccurrencesIterIfPossible $netOccIter
            }
        }
    } finally {
        delete_DboDesignFlatNetsIter $netsIter
    }
} finally {
    $st -delete
}
```
<!-- END EXAMPLE SOURCE: extract_topology.tcl -->

---

## `set_component_value.tcl`

**用途**：按位号在整个设计里确认唯一命中后，把该器件的 Value 改成
新值，并立即回读确认写入生效。

**风险级别**：写操作。风险由唯一性检查兜底：找不到或找到不止一个候选
时，脚本直接报错、**一次 `SetEffectivePropStringValue` 都不调用**，绝不
在多个候选里随便挑一个去改。

**输入参数**：文件顶部

```tcl
set targetRefdes C3
set newValue 100nF
```

发送前把这两行改成目标位号和目标 Value。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\set_component_value.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\set_component_value.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\set_component_value.tcl) } | ConvertTo-Json)
```

**预期输出**：唯一命中并写入成功时输出一行
`refdes C3 before 10k after 100nF`；`before`/`after` 都来自即时读到的
`GetEffectivePropStringValue`，不是脚本顶部设的字面量。零匹配报
`COMPONENT_NOT_FOUND`,多匹配报 `COMPONENT_NOT_UNIQUE`，两种情况修改次数
都是 0。

**UI 阻塞风险**：查找目标 occurrence 的阶段和只读的
`get_component_value.tcl` 一样要遍历整个设计，大设计上可能较久；
真正的写入（`SetEffectivePropStringValue` 一次调用）本身很快。

**回读验证**：`SetEffectivePropStringValue` 之后立刻用
`GetEffectivePropStringValue` 回读，和请求的 `newValue` 做字符串比较；
不一致时报错 `VALUE_WRITE_FAILED`，绝不会把一次没有真正生效的写入当作
成功打印出来。

**撤销与不自动保存**：脚本从不调用 `Save`，也不调用刷新器件的 API，
修改只停留在 Capture 内存里的设计上，是否落盘由使用者自己决定。要撤销，
把打印出来的 `before` 值填回 `newValue`（`targetRefdes` 不变）再跑一次
即可——打印的 `before` 本身就是撤销要用的原值。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: set_component_value.tcl -->
```tcl
# Set one component's value by reference designator, after confirming the
# refdes is unique in the design.

# Edit this before sending:
set targetRefdes C3
set newValue 100nF

# Self-contained: carries its own occurrence walker and the same
# whole-design uniqueness check as get_component_value.tcl, because
# writing a value to the wrong occurrence -- one of several sharing a
# refdes -- would be worse than refusing to write at all. Never forces a
# part-values refresh and never saves the design; the caller decides
# when, and whether, to save.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately -- including the
#      write itself.
#   2. GetReference, GetPathName, IsPrimitive and NewChildrenIter are
#      type-specific DboInstOccurrence methods: a wrongly-typed handle
#      passed to them (via DboOccurrenceToDboInstOccurrence) does not raise
#      a Tcl error, it crashes the whole Capture process, so every
#      occurrence handle pulled out of an iterator is checked with
#      DboBaseObject_GetObjectType before it is ever downcast.
#      GetEffectivePropStringValue/SetEffectivePropStringValue (the actual
#      write) are DboBaseObject methods -- safe on any handle, no downcast
#      needed. The real write call is SetEffectivePropStringValue; there is
#      no SetPropStringValue.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
    }
}

proc _stringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $cstr]
    $st -delete
    return $value
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

proc _setProp {obj propName propValue what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString $propValue]
    set st [$obj SetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    $st -delete
}

proc _toInstOccurrence {occHandle what} {
    set objType [DboBaseObject_GetObjectType $occHandle]
    if {$objType != $::DboBaseObject_INST_OCCURRENCE} {
        error "UNEXPECTED_OBJECT_TYPE: $what: expected INST_OCCURRENCE, got object type $objType"
    }
    return [DboOccurrenceToDboInstOccurrence $occHandle]
}

proc _findComponentByRefdes {st occHandle targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    set instOcc [_toInstOccurrence $occHandle {set_component_value: occurrence}]

    set isPrimitive [$instOcc IsPrimitive $st]
    _requireOk $st {IsPrimitive}
    if {$isPrimitive == 1} {
        set refdes [_stringOut $instOcc GetReference {GetReference}]
        if {$refdes eq $targetRefdes} {
            lappend matches $instOcc
        }
    }

    set childrenIter [$instOcc NewChildrenIter $st $::IterDefs_INSTS]
    _requireOk $st {NewChildrenIter}
    $childrenIter Sort $st
    _requireOk $st {Sort}
    try {
        while {1} {
            set child [$childrenIter NextOccurrence $st]
            # A finished iterator returns NULL and at the same time sets the
            # status to error 1022 ("At normal end of iteration"), so the
            # sentinel has to be tested before the status -- checking status
            # first turns every completed walk into a reported failure.
            if {$child eq {NULL}} { break }
            _requireOk $st {NextOccurrence}
            _findComponentByRefdes $st $child $targetRefdes matches
        }
    } finally {
        delete_DboOccurrenceChildrenIter $childrenIter
    }
}

set st [DboState]
set matches {}
try {
    set design [GetActivePMDesign]
    set rootOcc [$design GetRootOccurrence $st]
    _requireOk $st {GetRootOccurrence}
    _findComponentByRefdes $st $rootOcc $targetRefdes matches
} finally {
    $st -delete
}

set matchCount [llength $matches]
if {$matchCount == 0} {
    error "COMPONENT_NOT_FOUND: no component with reference designator \"$targetRefdes\""
}
if {$matchCount > 1} {
    error "COMPONENT_NOT_UNIQUE: $matchCount components with reference designator \"$targetRefdes\" -- disambiguate by hierarchical path"
}

set targetOccurrence [lindex $matches 0]
set before [_getEffectiveProp $targetOccurrence Value {GetEffectivePropStringValue(Value)}]
_setProp $targetOccurrence Value $newValue {SetEffectivePropStringValue(Value)}
set after [_getEffectiveProp $targetOccurrence Value {GetEffectivePropStringValue(Value) readback}]
if {$after ne $newValue} {
    error "VALUE_WRITE_FAILED: readback \"$after\" does not match requested \"$newValue\" for $targetRefdes"
}
puts [dict create refdes $targetRefdes before $before after $after]
```
<!-- END EXAMPLE SOURCE: set_component_value.tcl -->

---

## `mark_selected_suffix.tcl`

**用途**：给当前选择集里每个器件的 Value 追加一个标记后缀（默认 `*`），
用来批量标记一批待复查/待处理的器件。

**风险级别**：写操作，风险较低：幂等——已经带后缀的值不会被再追加一次,
不会变成 `**`；非器件（`DRAWN_INSTANCE`/`PLACED_INSTANCE` 之外的对象）的
选择项直接忽略；同一个实例被选中多次也只处理一次。

**输入参数**：文件顶部

```tcl
set suffix *
```

默认后缀是 `*`，可以改成任意字符串。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\mark_selected_suffix.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\mark_selected_suffix.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\mark_selected_suffix.tcl) } | ConvertTo-Json)
```

**预期输出**：每个被实际修改的器件输出一行
`refdes R1 before 10k after 10k*`；最后一行是汇总
`changed 1 skipped 1`——已经带后缀的器件和非器件对象都计入 `skipped`，
不计入 `changed`。同一个选择集再跑一次，`changed` 应该变成 0（全部
`skipped`），值不会被追加第二次后缀。

**UI 阻塞风险**：只处理当前选择集，不遍历整个设计，通常很快。

**回读验证**：每次 `SetEffectivePropStringValue` 之后立刻用
`GetEffectivePropStringValue` 回读，和预期的新值（原值加后缀）比较；
不一致时报错 `SUFFIX_WRITE_FAILED`。

**撤销与不自动保存**：脚本从不调用 `Save`。要撤销，对同一个选择集运行
`remove_selected_suffix.tcl` 去掉刚加上的后缀即可；每行打印的 `before`
也是可以直接手工填回去的原值。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: mark_selected_suffix.tcl -->
```tcl
# Append a marker suffix to the Value of every selected component -- e.g.
# flagging a batch of parts for review.

# Edit this before sending:
set suffix *

# Self-contained; never forces a part-values refresh and never saves the
# design. Idempotent: running it twice on the same selection changes
# nothing the second time, because a value that already ends with the
# suffix is skipped rather than getting a second suffix appended.
#
# Selection objects are a different object family from occurrence objects
# (see list_components.tcl for that family): GetSelectedObjects hands back
# page-level instances, and a component placed on a page reports
# DRAWN_INSTANCE or PLACED_INSTANCE -- *not* PART_INSTANCE, despite the
# name; capRotate.tcl and capPSpiceSourceApp.tcl both check "12 || 13".
# There is no type-specific GetReference/SetPartValue on these objects and
# no DboObjectToDboPartInstance downcast -- both refdes and Value are read
# and written the same way, through the DboBaseObject methods
# GetEffectivePropStringValue/SetEffectivePropStringValue with property
# names "Part Reference" and "Value". That means no downcast, and no crash
# risk, on this path at all: the type check below exists to correctly
# select components, not to guard against a type-specific call.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

proc _setProp {obj propName propValue what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString $propValue]
    set st [$obj SetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    $st -delete
}

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

# Dedupe before mutating: the same instance can appear more than once in a
# selection, and each instance must be touched at most once.
set seen {}
set targets {}
foreach obj [GetSelectedObjects] {
    set objType [DboBaseObject_GetObjectType $obj]
    if {$objType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    if {[lsearch -exact $seen $obj] >= 0} {
        continue
    }
    lappend seen $obj
    lappend targets $obj
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value)}]
    if {[_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want "$before$suffix"
    _setProp $occurrence Value $want {SetEffectivePropStringValue(Value)}
    set after [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value) readback}]
    set refdes [_getEffectiveProp $occurrence {Part Reference} {GetEffectivePropStringValue(Part Reference)}]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for $refdes"
    }
    puts [dict create refdes $refdes before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
```
<!-- END EXAMPLE SOURCE: mark_selected_suffix.tcl -->

---

## `remove_selected_suffix.tcl`

**用途**：去掉当前选择集里每个器件 Value 末尾的一个标记后缀（默认
`*`），是 `mark_selected_suffix.tcl` 的逆操作。

**风险级别**：写操作，风险较低：只删末尾恰好一个后缀；后缀出现在字符串
中间时不动；没有后缀的器件跳过；同一个实例被选中多次也只处理一次。

**输入参数**：文件顶部

```tcl
set suffix *
```

必须和当初 `mark_selected_suffix.tcl` 用的后缀一致才能正确撤销标记。

**CLI `-f` 调用**：

```powershell
python C:\tclpython\capture_tcl_cli.py -f .\examples\remove_selected_suffix.tcl
```

**标准输入调用**：

```powershell
Get-Content -Raw .\examples\remove_selected_suffix.tcl | python C:\tclpython\capture_tcl_cli.py
```

**HTTP 调用**：

```powershell
$runtime = Get-Content "$env:TEMP\capture_tcl_bridge.json" | ConvertFrom-Json
Invoke-RestMethod -Method Post -Uri "$($runtime.baseUrl)/v1/execute" `
  -Headers @{ Authorization = "Bearer $($runtime.token)" } `
  -ContentType 'application/json' `
  -Body (@{ script = (Get-Content -Raw .\examples\remove_selected_suffix.tcl) } | ConvertTo-Json)
```

**预期输出**：每个被实际修改的器件输出一行
`refdes R3 before 10k* after 10k`；最后一行汇总 `changed 1 skipped 2`
——中间位置带 `*` 的值和完全没有后缀的值都计入 `skipped`。

**UI 阻塞风险**：只处理当前选择集，不遍历整个设计，通常很快。

**回读验证**：每次 `SetEffectivePropStringValue` 之后立刻用
`GetEffectivePropStringValue` 回读，和预期的新值（原值去掉末尾一个后缀）
比较；不一致时报错 `SUFFIX_WRITE_FAILED`。

**撤销与不自动保存**：脚本从不调用 `Save`。要撤销，对同一个选择集运行
`mark_selected_suffix.tcl` 把后缀加回去即可；每行打印的 `before` 也是
可以直接手工填回去的原值。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: remove_selected_suffix.tcl -->
```tcl
# Remove one trailing marker suffix from the Value of every selected
# component, undoing mark_selected_suffix.tcl.

# Edit this before sending:
set suffix *

# Self-contained; never forces a part-values refresh and never saves the
# design. Only a suffix at the very end of the value is removed -- a `*`
# sitting in the middle of a value is left alone -- and only one trailing
# suffix is stripped per run, the mirror image of mark_selected_suffix.tcl
# appending exactly one.
#
# Selection objects are a different object family from occurrence objects
# (see list_components.tcl for that family): GetSelectedObjects hands back
# page-level instances, and a component placed on a page reports
# DRAWN_INSTANCE or PLACED_INSTANCE -- *not* PART_INSTANCE, despite the
# name; capRotate.tcl and capPSpiceSourceApp.tcl both check "12 || 13".
# There is no type-specific GetReference/SetPartValue on these objects and
# no DboObjectToDboPartInstance downcast -- both refdes and Value are read
# and written the same way, through the DboBaseObject methods
# GetEffectivePropStringValue/SetEffectivePropStringValue with property
# names "Part Reference" and "Value". That means no downcast, and no crash
# risk, on this path at all: the type check below exists to correctly
# select components, not to guard against a type-specific call.

# Message is itself a CString out-parameter, not a plain return value like
# OK/Succeeded/Failed/Code/Severity -- calling it directly and using its
# raw result as a string makes the error-reporting path itself throw a Tcl
# arity error, replacing the real diagnostic with a confusing one, and only
# on the failure path that nothing else exercises.
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _getEffectiveProp {obj propName what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

proc _setProp {obj propName propValue what} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString $propValue]
    set st [$obj SetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_statusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    $st -delete
}

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

# Dedupe before mutating: the same instance can appear more than once in a
# selection, and each instance must be touched at most once.
set seen {}
set targets {}
foreach obj [GetSelectedObjects] {
    set objType [DboBaseObject_GetObjectType $obj]
    if {$objType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    if {[lsearch -exact $seen $obj] >= 0} {
        continue
    }
    lappend seen $obj
    lappend targets $obj
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value)}]
    if {![_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want [string range $before 0 end-[string length $suffix]]
    _setProp $occurrence Value $want {SetEffectivePropStringValue(Value)}
    set after [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value) readback}]
    set refdes [_getEffectiveProp $occurrence {Part Reference} {GetEffectivePropStringValue(Part Reference)}]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for $refdes"
    }
    puts [dict create refdes $refdes before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
```
<!-- END EXAMPLE SOURCE: remove_selected_suffix.tcl -->
