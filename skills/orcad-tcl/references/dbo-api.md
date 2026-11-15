# Capture DBO Tcl 调用参考

这份静态参考整理自项目的 Tcl 示例、DBO 实测记录及 MCP 的 Tcl builder。
示例所依据的主要实测环境为 Capture 16.6，部分连接查询也在 17.4 验收；
按目标版本和实际对象确认调用，不将一个对象的签名推广到所有同名方法。

## 1. 入口和对象族

| API / 对象 | 用法 |
| --- | --- |
| `GetActivePMDesign` | 全局无参，返回 DboDesign；检查 `NULL` |
| `GetSelectedObjects` | 全局无参，返回页面对象列表，可能混合多种类型 |
| `GetInstanceOccurrence` | 当前编辑页的层次上下文，可能为 `NULL` |
| `$design GetRootOccurrence $st` | 进入整设计 occurrence 树；检查状态和句柄 |
| `DboBaseObject_GetObjectType $obj` | 对有效对象读类型，类型常量使用具名全局变量 |

**Occurrence** 是某个设计层次中的逻辑实例；**页面实例**是原理图页上绘制的对象。
同一页在多个 hierarchy 下复用时，一个页面对象可能对应多个 occurrence。

整树遍历中先检查 `$::DboBaseObject_INST_OCCURRENCE`，再调用
`DboOccurrenceToDboInstOccurrence` 转为类型专属句柄，之后才能按示例使用
`GetReference/GetPathName/IsPrimitive/NewChildrenIter`。
器件和层次块都可能是 INST_OCCURRENCE，用 `IsPrimitive($st)` 区分叶子器件。

页面上的器件通常按 `$::DboBaseObject_DRAWN_INSTANCE` 或
`$::DboBaseObject_PLACED_INSTANCE` 筛选，而不是根据名字猜 PART_INSTANCE。
选中对象转 occurrence 的已用链路为：

```tcl
set parent [GetInstanceOccurrence]
if {$parent eq "NULL"} { error "NO_ACTIVE_INSTANCE_OCCURRENCE" }
# object 必须是已判定类型的页面器件。
set occurrence [$object GetObjectOccurrence $parent]
if {$occurrence eq "NULL"} { error "OCCURRENCE_NOT_FOUND" }
if {[DboBaseObject_GetObjectType $occurrence] != $::DboBaseObject_INST_OCCURRENCE} {
    error "UNEXPECTED_OCCURRENCE_TYPE"
}
set instance [DboOccurrenceToDboInstOccurrence $occurrence]
set out [DboTclHelper_sMakeCString]
$instance GetReferenceDesignator $out
set annotatedReference [DboTclHelper_sGetConstCharPtr $out]
```

完整上下文见 [selected_occurrence_refs.tcl](../examples/selected_occurrence_refs.tcl)。
`GetReferenceDesignator` 与 `GetReference` 用法不能凭名字互换。

## 2. DboState 与 CString

调用形式至少有两类：接收已有 `DboState` 的调用，以及返回新状态对象的调用。
按实际方法签名处理，状态失败通常不会自动变成 Tcl 异常。

```tcl
set st [DboState]
set root [$design GetRootOccurrence $st]
if {[$st OK] != 1} {
    set messageC [DboTclHelper_sMakeCString]
    $st Message $messageC
    set message [DboTclHelper_sGetConstCharPtr $messageC]
    $st -delete
    error "DBO_CALL_FAILED: GetRootOccurrence: $message"
}
$st -delete
```

`OK/Code/Severity` 等直接返回值；`Message` 需要 CString 出参，`[$st Message]` 会
让错误诊断本身发生参数错误。CString 是 C++ 对象句柄，不是 Tcl 变量名：

```tcl
set out [DboTclHelper_sMakeCString]
set st [$instance GetReference $out]
# 先检查 st，成功后再取字符串。
set refdes [DboTclHelper_sGetConstCharPtr $out]
$st -delete
```

上段只展示参数形式；可直接复用完整示例的 `_stringOut`，其失败分支也会释放状态。
不要照这个形式猜 `$design GetName $out`：项目曾因未经确认的该调用导致 Capture 崩溃。
方法名存在不代表签名或接收对象正确。

## 3. 属性读取、缺失与写入

属性名称和值按 CString 传入：

```tcl
set nameC [DboTclHelper_sMakeCString {Value}]
set valueC [DboTclHelper_sMakeCString]
set st [$object GetEffectivePropStringValue $nameC $valueC]
```

从当前 MCP 实现整理出的 presence 模式如下；`1021` 是该属性读取路径中用于缺失的
状态码，不能把所有 DBO 失败统一当成“缺失”：

```tcl
proc agentReadProperty {object propertyName} {
    set nameC [DboTclHelper_sMakeCString $propertyName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$object GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] == 1} {
        set value [DboTclHelper_sGetConstCharPtr $valueC]
        $st -delete
        return [list 1 $value]
    }
    set code [$st Code]
    if {$code == 1021} {
        $st -delete
        return [list 0 {}]
    }
    set messageC [DboTclHelper_sMakeCString]
    $st Message $messageC
    set message [DboTclHelper_sGetConstCharPtr $messageC]
    $st -delete
    error "DBO_CALL_FAILED: $propertyName: $message (code $code)"
}
```

结果 `{1 {}}` 是存在的空值，`{0 {}}` 是缺失。页面位号属性名为 `Part Reference`；
Value 为 `Value`。occurrence 位号与路径优先从其对应专属方法获取。

已使用的有效属性写法为：

```tcl
set nameC [DboTclHelper_sMakeCString $propertyName]
set valueC [DboTclHelper_sMakeCString $newValue]
set st [$target SetEffectivePropStringValue $nameC $valueC]
# 检查状态并释放，再以 GetEffectivePropStringValue 回读比较。
```

完整实现见 [set_component_value.tcl](../examples/set_component_value.tcl)。
页面实例写入和 occurrence 写入的覆盖层不同；先选对 `$target`，尤其不要为了属性不存在
就悄悄改父级或库对象。需要创建任意缺失属性时进一步确认目标版本的创建/override 行为，
Value 示例本身不证明所有属性的创建均已验证。不存在经过确认的 `SetPropStringValue` 用法。

## 4. 遍历与清理

主链：`GetRootOccurrence → 判类型/转型 → IsPrimitive → NewChildrenIter → Sort → NextOccurrence`。

```tcl
set child [$childrenIter NextOccurrence $st]
if {$child eq "NULL"} {
    # 正常遍历结束；此时 status 可能同时为 1022。
} else {
    # 检查 status，再继续处理 child。
}
```

先判断结束标志再检查状态，避免把正常结束当错误。
自己创建的状态对象使用 `$st -delete`；子 occurrence iterator 使用
`delete_DboOccurrenceChildrenIter`，其他 iterator 用对应类型的释放函数。
资源获取后立刻建立错误清理路径，避免 Sort 或后续调用失败时泄漏；成功和失败都释放一次。
借用的设计、occurrence、页面对象不作为临时资源随意删除。

跨请求保存 `design/refdes/path` 或 `design/page/type/object_id` 这类定位信息，
下次执行重新解析对象，不缓存 DBO 指针。引用设计或当前选择发生变化时重新核对目标。

## 5. 引脚与设计级 flat net

[extract_topology.tcl](../examples/extract_topology.tcl) 使用
`DboFlatNet → DboPortOccurrence → GetPortInst`，通过端点 occurrence path 保留层次身份，
通过 port instance 取得引脚名/编号。它是拓扑遍历模板，不是所有封装编号语义的保证。

多单元器件的 symbol 默认编号可能不等于实际封装编号。项目当前严格查询以 occurrence
有效 `Number` 属性作为编号；号码缺失时报告失败，不退回符号默认号。为这种任务写新脚本时，
先用目标设计验证有效属性读取及端点映射。引脚号码是字符串，可能含字母。

网络查询使用实际返回的 design-wide flat net 名；同名页标签、总线名不能直接替代它。
保留未连接引脚；共享封装端点重复时只去除已证明身份相同的记录，不按编号单独合并。

## 6. 不确定的调用

可用 `info commands` 检查命令是否存在，但不能证明原生参数类型正确。
GUI 命令（例如 Open 系列）缺参数时可能弹模态窗口，阻塞 Tcl/UI 线程；不把无参调用
当作通用签名探测手段。包内没有确认的 GUI 自动打开设计流程，必要时让操作者打开目标设计。
