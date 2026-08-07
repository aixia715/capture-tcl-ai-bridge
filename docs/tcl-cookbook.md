# Capture Tcl Cookbook

`examples/` 下的七个脚本是可以直接发送给桥的完整独立脚本：不 `source` 任何
公共文件，不依赖 TCLBOM 的 `_dniWalk` / `CollectSelectedDNIOccs` 之类的辅助过程。
本手册对每个脚本逐一说明用途、风险、参数、三种调用方式、预期输出、
UI 阻塞风险、回读验证方式，以及撤销和不自动保存的约定。

**本文档嵌入的每段脚本原文都必须和 `examples/*.tcl` 逐字节一致。**
`tests/test_docs_contract.py` 会在每次运行时把本文档里两条
`<!-- BEGIN EXAMPLE SOURCE: ... -->` / `<!-- END EXAMPLE SOURCE: ... -->`
标记之间的内容抽出来，统一换行符后与磁盘上的对应文件比较；只要有一个字符
不一致，或者文档记录的脚本文件名集合和 `examples/*.tcl` 实际的集合对不上，
测试就会失败。改了任何一个 `examples/*.tcl` 之后，必须同步更新本文档里对应的
嵌入代码块，而不是反过来改脚本去迁就文档——脚本已经通过验收，脚本说了算。

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

**用途**：深度优先遍历当前设计的整棵 occurrence 树，输出每一个器件的
位号（RefDes）、Value 和层级路径（hierarchy path）。

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

**预期输出**：每个器件一行，形如
`refdes R1 value 10k path /U1/R1`（`dict create` 的列表形式）；
非器件的 occurrence（层级块、页面）不会单独输出一行，只作为遍历路径上的
容器被展开。

**UI 阻塞风险**：Capture 在 Tcl/UI 线程上执行脚本，`list_components.tcl`
会递归访问整棵 occurrence 树，设计越大、层级越深，运行时间越长，期间
Capture 界面会无响应。`POST /v1/execute` 的 30 秒等待**超时不会取消**
已经在 Capture 里跑的遍历——脚本会继续跑到结束，超时只是让 HTTP 客户端
提前拿到 504 和命令 ID，之后可以用 `GET /v1/commands/{id}` 按 ID 查询
最终是否跑完、跑出了什么。

**回读验证**：只读脚本没有写入动作，不需要回读；每一行输出都是当次
`GetPartValue`/`GetPath` 的即时结果。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: list_components.tcl -->
```tcl
# List every component occurrence in the active design, depth-first.
#
# Self-contained: Capture submits example scripts as-is through the bridge,
# so this script carries its own occurrence walker rather than depending on
# TCLBOM's shared depth-first-search walker helper. Read-only: it never
# writes a part value or saves the design, so it is safe to run against a
# design that is open for edit.
#
# Output: one line per component, `dict create refdes ... value ... path ...`.

proc _listComponentsWalk {occurrence} {
    if {[$occurrence GetObjectType] eq {occDbComponent}} {
        set refdes [$occurrence GetReference]
        set value [$occurrence GetPartValue]
        set hierarchyPath [$occurrence GetPath]
        puts [dict create refdes $refdes value $value path $hierarchyPath]
    }

    # Every occurrence, component or not, may have children -- a
    # hierarchical block's children are the components and blocks nested
    # inside it -- so the walker always descends and always frees the
    # iterator it opens, whether or not this node turned out to be a leaf.
    set childrenIter [$occurrence NewChildrenIter]
    try {
        while {1} {
            set child [$childrenIter Next]
            if {$child eq {}} { break }
            _listComponentsWalk $child
        }
    } finally {
        $childrenIter delete
    }
}

set design [GetActivePMDesign]
_listComponentsWalk [$design GetRootOccurrence]
```
<!-- END EXAMPLE SOURCE: list_components.tcl -->

---

## `selected_refs.tcl`

**用途**：读取 Capture 当前的选择集，过滤出器件 occurrence（丢弃导线、
端口等非器件图形对象），输出去重、排序后的位号列表。

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

**预期输出**：每行一个位号，按字典序排序，没有重复；同一个 occurrence
被选中多次，或者两个不同 occurrence 恰好共享同一个位号，都只出现一行。

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
# component occurrences (dropping wires, ports and other non-component
# graphics), maps each surviving occurrence to its reference designator,
# and prints the deduplicated, sorted list -- one refdes per line.
# Selecting the same occurrence twice, or several occurrences that happen
# to share a refdes, must not produce a duplicate line.

set selection [GetActivePMSelection]

set refdesList {}
foreach occurrence [$selection GetSelectedObjects] {
    if {[$occurrence GetObjectType] ne {occDbComponent}} {
        continue
    }
    lappend refdesList [$occurrence GetReference]
}

foreach refdes [lsort -unique $refdesList] {
    puts $refdes
}
```
<!-- END EXAMPLE SOURCE: selected_refs.tcl -->

---

## `get_component_value.tcl`

**用途**：按位号在整个设计里查找唯一的器件，输出它的 Value 和层级路径。

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
的那一刻的 `GetPartValue` 结果。

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

proc _findComponentByRefdes {occurrence targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    if {[$occurrence GetObjectType] eq {occDbComponent} &&
        [$occurrence GetReference] eq $targetRefdes} {
        lappend matches [list \
            [$occurrence GetReference] \
            [$occurrence GetPartValue] \
            [$occurrence GetPath]]
    }

    set childrenIter [$occurrence NewChildrenIter]
    try {
        while {1} {
            set child [$childrenIter Next]
            if {$child eq {}} { break }
            _findComponentByRefdes $child $targetRefdes matches
        }
    } finally {
        $childrenIter delete
    }
}

set design [GetActivePMDesign]
set matches {}
_findComponentByRefdes [$design GetRootOccurrence] $targetRefdes matches

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

**用途**：按 flat net（拍平后的网络）输出设计的连接拓扑：每个网络的名字、
连接到的层级端口，以及连接到的器件引脚（位号 + 引脚号/引脚名）。

**风险级别**：只读，但同样是整设计级的遍历（所有 flat net，以及每个
net 上的所有端口和引脚），在大设计上可能长时间运行。

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
层级端口输出一行 `net N1 port IN`；每个连接到该网络的引脚输出一行
`net N1 refdes R1 pin 1 name A1`。三种行都用 `dict create` 格式，
`net` 字段把同一个网络的所有行关联起来。

**UI 阻塞风险**：和 `list_components.tcl` 一样，Capture 在 Tcl/UI
线程上执行脚本，`extract_topology.tcl` 要遍历所有 flat net 及其端口
和引脚，设计越大运行越久，期间界面无响应。`POST /v1/execute` 的 30 秒
等待**超时不会取消**已经在 Capture 里跑的遍历，脚本会继续跑到结束，
之后可以按命令 ID 查询最终结果。

**回读验证**：只读，无写入，不需要回读。

**撤销与不自动保存**：只读，不产生任何修改，无需撤销，也不涉及保存设计。

**完整脚本**：

<!-- BEGIN EXAMPLE SOURCE: extract_topology.tcl -->
```tcl
# Flat-net topology of the active design: for every net, its hierarchical
# ports and the component pins it connects.
#
# Self-contained and read-only: walks Capture 17.4's flat-net view directly
# (NewFlatNetsIter) rather than any TCLBOM net-walking helper. A flat net
# collapses hierarchy, so a single N1 here may connect a pin inside one
# hierarchical block to a pin inside another -- the hierarchical ports on a
# net are exactly the boundary crossings that made that possible. Every
# iterator this script opens (nets, ports, pins) is freed exactly once,
# even when a later net is never reached because there are no more nets
# left to enumerate.

set design [GetActivePMDesign]
set netsIter [$design NewFlatNetsIter]
try {
    while {1} {
        set net [$netsIter Next]
        if {$net eq {}} { break }

        set netName [$net GetName]
        puts [dict create net $netName]

        set portsIter [$net NewPortOccurrencesIter]
        try {
            while {1} {
                set port [$portsIter Next]
                if {$port eq {}} { break }
                puts [dict create net $netName port [$port GetName]]
            }
        } finally {
            $portsIter delete
        }

        set pinsIter [$net NewPinOccurrencesIter]
        try {
            while {1} {
                set pin [$pinsIter Next]
                if {$pin eq {}} { break }
                set parent [$pin GetPartOccurrence]
                puts [dict create \
                    net $netName \
                    refdes [$parent GetReference] \
                    pin [$pin GetNumber] \
                    name [$pin GetName]]
            }
        } finally {
            $pinsIter delete
        }
    }
} finally {
    $netsIter delete
}
```
<!-- END EXAMPLE SOURCE: extract_topology.tcl -->

---

## `set_component_value.tcl`

**用途**：按位号在整个设计里确认唯一命中后，把该器件的 Value 改成
新值，并立即回读确认写入生效。

**风险级别**：写操作。风险由唯一性检查兜底：找不到或找到不止一个候选
时，脚本直接报错、**一次 `SetPartValue` 都不调用**，绝不在多个候选里
随便挑一个去改。

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
`GetPartValue`，不是脚本顶部设的字面量。零匹配报 `COMPONENT_NOT_FOUND`,
多匹配报 `COMPONENT_NOT_UNIQUE`，两种情况修改次数都是 0。

**UI 阻塞风险**：查找目标 occurrence 的阶段和只读的
`get_component_value.tcl` 一样要遍历整个设计，大设计上可能较久；
真正的写入（`SetPartValue` 一次调用）本身很快。

**回读验证**：`SetPartValue` 之后立刻 `GetPartValue` 回读，和请求的
`newValue` 做字符串比较；不一致时报错 `VALUE_WRITE_FAILED`，绝不会把
一次没有真正生效的写入当作成功打印出来。

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

proc _findComponentByRefdes {occurrence targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    if {[$occurrence GetObjectType] eq {occDbComponent} &&
        [$occurrence GetReference] eq $targetRefdes} {
        lappend matches $occurrence
    }

    set childrenIter [$occurrence NewChildrenIter]
    try {
        while {1} {
            set child [$childrenIter Next]
            if {$child eq {}} { break }
            _findComponentByRefdes $child $targetRefdes matches
        }
    } finally {
        $childrenIter delete
    }
}

set design [GetActivePMDesign]
set matches {}
_findComponentByRefdes [$design GetRootOccurrence] $targetRefdes matches

set matchCount [llength $matches]
if {$matchCount == 0} {
    error "COMPONENT_NOT_FOUND: no component with reference designator \"$targetRefdes\""
}
if {$matchCount > 1} {
    error "COMPONENT_NOT_UNIQUE: $matchCount components with reference designator \"$targetRefdes\" -- disambiguate by hierarchical path"
}

set targetOccurrence [lindex $matches 0]
set before [$targetOccurrence GetPartValue]
$targetOccurrence SetPartValue $newValue
set after [$targetOccurrence GetPartValue]
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
不会变成 `**`；非器件的选择项直接忽略；同一个 occurrence 被选中多次也
只处理一次。

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

**回读验证**：每次 `SetPartValue` 之后立刻 `GetPartValue` 回读，和
预期的新值（原值加后缀）比较；不一致时报错 `SUFFIX_WRITE_FAILED`。

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

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

set selection [GetActivePMSelection]

# Dedupe before mutating: the same occurrence can appear more than once in
# a selection, and each occurrence must be touched at most once.
set seen {}
set targets {}
foreach occurrence [$selection GetSelectedObjects] {
    if {[$occurrence GetObjectType] ne {occDbComponent}} {
        continue
    }
    if {[lsearch -exact $seen $occurrence] >= 0} {
        continue
    }
    lappend seen $occurrence
    lappend targets $occurrence
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [$occurrence GetPartValue]
    if {[_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want "$before$suffix"
    $occurrence SetPartValue $want
    set after [$occurrence GetPartValue]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for [$occurrence GetReference]"
    }
    puts [dict create refdes [$occurrence GetReference] before $before after $after]
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
中间时不动；没有后缀的器件跳过；同一个 occurrence 被选中多次也只处理
一次。

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

**回读验证**：每次 `SetPartValue` 之后立刻 `GetPartValue` 回读，和
预期的新值（原值去掉末尾一个后缀）比较；不一致时报错
`SUFFIX_WRITE_FAILED`。

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

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

set selection [GetActivePMSelection]

# Dedupe before mutating: the same occurrence can appear more than once in
# a selection, and each occurrence must be touched at most once.
set seen {}
set targets {}
foreach occurrence [$selection GetSelectedObjects] {
    if {[$occurrence GetObjectType] ne {occDbComponent}} {
        continue
    }
    if {[lsearch -exact $seen $occurrence] >= 0} {
        continue
    }
    lappend seen $occurrence
    lappend targets $occurrence
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [$occurrence GetPartValue]
    if {![_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want [string range $before 0 end-[string length $suffix]]
    $occurrence SetPartValue $want
    set after [$occurrence GetPartValue]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for [$occurrence GetReference]"
    }
    puts [dict create refdes [$occurrence GetReference] before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
```
<!-- END EXAMPLE SOURCE: remove_selected_suffix.tcl -->
