# OrCAD Capture Dbo Tcl API 实测笔记

本文件记录 **在 OrCAD Capture 16.6 上实测确认** 的调用约定。来源有二：

1. 在真实 Capture Tcl 控制台上的探测；
2. Cadence 自带脚本，位于
   `C:\Cadence\SPB_16.6\tools\capture\tclscripts\`，其中最有参考价值的是
   `capUtils\capRecurseParts.tcl`、`capCustomSamples\capGenerateBOM.tcl`、
   `capGUIUtils\capRotate.tcl`、`capISCFExport\tcl\capDesignPhysicalViewReader.tcl`。

`examples/*.tcl` 必须照本文件写。**不要凭直觉猜 API 形状**——本项目第一版示例
就是猜的，七个全错。

---

## ⚠️ 安全警告：类型不符会让 Capture 直接崩溃

`DboInstOccurrence_*` 这类**类型专属**函数不做类型检查。把一个基类句柄
（例如迭代器返回的 `DboOccurrence`）直接喂进去，会当作派生类指针解引用，
**整个 Capture 进程闪退**，不是返回错误。

因此两条硬规则：

1. 拿到句柄先用 `DboBaseObject_GetObjectType`（基类方法，任何句柄都安全）
   判断类型；
2. 调用类型专属方法前，必须先用 `DboXxxToDboYyy` 显式转型。

选择集尤其危险：`GetSelectedObjects` 可能返回导线、图形等任意对象，
盲目当器件处理必崩。

---

## 状态对象

几乎所有会失败的调用都要一个 `DboState`：

```tcl
set lStatus [DboState]
# ... 使用 ...
$lStatus -delete
```

判断成功用 `[$lStatus OK] == 1`。其他可用方法：`Succeeded`、`Failed`、
`Code`、`Message`、`Severity`。

## 字符串出参

出参**不是 Tcl 变量名**，而是一个 C++ 字符串对象，要显式分配和取值：

```tcl
set lName   [DboTclHelper_sMakeCString]
set lStatus [$pInstOcc GetReference $lName]
set ref     [DboTclHelper_sGetConstCharPtr $lName]
$lStatus -delete
```

## 类型常量

类型是**整数**，但有具名全局变量，形如 `$::DboBaseObject_PART_CELL`。
不要写魔数。用以下方式列出全部可用常量：

```tcl
foreach v [lsort [info globals DboBaseObject_*]] { puts "$v = [set ::$v]" }
foreach v [lsort [info globals IterDefs_*]]      { puts "$v = [set ::$v]" }
```

`capRotate.tcl` 的判断方式可作范例：

```tcl
set lObjType [DboBaseObject_GetObjectType $lObj]
if { $lObjType == 12 || $lObjType == 13 } { ... }
```

## 遍历 occurrence 层次（权威范例：capRecurseParts.tcl）

```tcl
set lStatus  [DboState]
set lRootOcc [$dsn GetRootOccurrence $lStatus]
set lRootOcc [DboOccurrenceToDboInstOccurrence $lRootOcc]

set lIter [$pInstOcc NewChildrenIter $lStatus $::IterDefs_INSTS]
$lIter Sort $lStatus
set lChildOcc [$lIter NextOccurrence $lStatus]
while { $lChildOcc != "NULL" } {
    set lInstOcc [DboOccurrenceToDboInstOccurrence $lChildOcc]
    # ... 处理 $lInstOcc ...
    set lChildOcc [$lIter NextOccurrence $lStatus]
}
delete_DboOccurrenceChildrenIter $lIter
$lStatus -delete
```

要点，每一条都和本项目第一版示例的写法不同：

| 项 | 正确写法 | 第一版错误写法 |
| --- | --- | --- |
| 创建迭代器 | `NewChildrenIter $lStatus $::IterDefs_INSTS` | `NewChildrenIter`（无参） |
| 取下一个 | `NextOccurrence $lStatus` | `Next` |
| 结束哨兵 | 字符串 `"NULL"` | 空字符串 |
| 释放迭代器 | `delete_DboOccurrenceChildrenIter $lIter` | `$lIter delete` |
| 句柄转型 | `DboOccurrenceToDboInstOccurrence` | 无（直接用，会崩） |

**每一种迭代器都有自己的 `Next<类型>` 和 `delete_<迭代器类>`**，名字不通用。

## 读取属性

位号：

```tcl
set lName   [DboTclHelper_sMakeCString]
set lStatus [$pInstOcc GetReference $lName]
set refdes  [DboTclHelper_sGetConstCharPtr $lName]
$lStatus -delete
```

任意属性（含 `Value`）用 `GetEffectivePropStringValue`：

```tcl
set lPropName  [DboTclHelper_sMakeCString "Value"]
set lPropValue [DboTclHelper_sMakeCString]
set lStatus    [$pInstOcc GetEffectivePropStringValue $lPropName $lPropValue]
if { [$lStatus OK] == 1 } {
    set value [DboTclHelper_sGetConstCharPtr $lPropValue]
}
$lStatus -delete
```

## 遍历 flat net（范例：capDesignPhysicalViewReader.tcl）

```tcl
set lFlatNetsIter [$pDesign NewFlatNetsIter $lStatus]
set lFlatNet      [$lFlatNetsIter NextFlatNet $lStatus]
while { $lFlatNet != "NULL" } {
    set lPortOccIter [$lFlatNet NewPortOccurrencesIter $lStatus $::IterDefs_PRIMITIVES]
    # ...
    delete_DboFlatNetPortOccurrencesIter $lPortOccIter
    set lFlatNet [$lFlatNetsIter NextFlatNet $lStatus]
}
delete_DboDesignFlatNetsIter $lFlatNetsIter
```

注意 `DboFlatNet` 上**没有** `NewPinOccurrencesIter`，可用的是
`NewNetOccurrencesIter` 和 `NewPortOccurrencesIter`。

## 选择集

`GetSelectedObjects` 是**全局命令**，无参，返回句柄列表
（没有 `GetActivePMSelection` 这个东西）：

```tcl
set lSelObjs [GetSelectedObjects]
foreach lObj $lSelObjs {
    set lObjType [DboBaseObject_GetObjectType $lObj]
    # 必须先判类型再转型，否则崩溃
}
```

## 已确认不存在的方法

`GetPath`、`GetActivePMSelection`、`DboFlatNet_NewPinOccurrencesIter`、
迭代器的 `delete` 方法、迭代器的 `Next` 方法。

层次路径应改用 `DboInstOccurrence` 的 `GetPathName` / `GetHierPathName` /
`GetRefPathName`（均需按出参约定调用，具体签名用零参数调用逼出）。

## 探测技巧

SWIG 的报错信息本身就带签名，零参数调用即可逼出，且在执行任何逻辑前就报错，
因此是安全的：

```tcl
catch {DboInstOccurrence_GetReference} msg
# => Wrong number of arguments :DboInstOccurrence_GetReference self ref  argument 1
```

但**不要**用错误类型的句柄去试真实调用——那会崩溃，不会报错。
