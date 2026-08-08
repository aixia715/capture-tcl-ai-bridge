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

## 入口命令

`GetActivePMDesign` 是**全局命令，无参数、不需要 status**，直接返回 `DboDesign`
句柄（实测确认）。`GetSelectedObjects` 同理。

## 命令名 vs 句柄：风险完全不同

这条区分决定什么时候可以试探、什么时候绝对不能：

| 情况 | 后果 | 能否试探 |
| --- | --- | --- |
| 调用**不存在的命令名** | 普通的 Tcl 错误，可 `catch` | ✅ 可以，`info commands` 守卫即可 |
| 给真实的类型专属函数传**错类型的句柄** | 解引用野指针，**Capture 进程闪退** | ❌ 绝对不行 |

所以对不确定的函数名，写成守卫调用是安全且划算的：

```tcl
if {[llength [info commands delete_DboFlatNetNetOccurrencesIter]] > 0} {
    delete_DboFlatNetNetOccurrencesIter $iterHandle
}
```

名字对就正常释放，名字错就静默跳过，两种情况都不会崩。

## 事故记录：`$design GetName $cstring` 会让 Capture 闪退

2026-08-08，为了确认"当前活动的是哪个设计"，执行了：

```tcl
set design [GetActivePMDesign]
set nameC  [DboTclHelper_sMakeCString]
set st2    [$design GetName $nameC]      ;# <-- Capture 卡死，随后闪退
```

签名是**从 `GetReference` 类比推来的，没有先探测**。结果先是 Tcl 线程卡死
（桥状态变成 `disconnected, busy`），随后整个 Capture 进程消失。

**违反的是本文件自己写的规则**：调用任何未确认的方法前，先用零参数调用逼出签名。
`GetName` 出现在 `DboBaseObject` 的方法表里，但"方法存在"不等于"这样调是对的"。

判定当前活动设计的安全做法尚未确立。下次要做，先探测再调用：

```tcl
catch {DboDesign_GetName} m ; puts $m
catch {DboBaseObject_GetName} m ; puts $m
```

顺带两条：

- **崩溃在诊断日志里不留痕迹。** 进程被硬杀，桥来不及写任何东西。日志能查
  协议错误和刷屏，查不了崩溃。
- **崩溃后的清理是可靠的。** 实测 Capture 消失后，服务端自行退出、
  `%TEMP%` 描述文件被删除、8767 端口无监听——父进程 watchdog 按设计工作。

## GUI 命令：另一类风险

`Open`、`capOpenDesign`、`capOpenProject`、`capFileOpen` 是内建的 **GUI 命令**。
对它们**不能**用"零参数逼签名"这招——参数不足很可能不是报错，而是**弹出模态
对话框**，把 Capture 的 Tcl 线程一直阻塞到有人去点它。

Cadence 自己脚本里唯一带路径参数的 `capOpenDesignDialog` 实际也是弹文件选择框。
**目前没有已确认的、程序化打开设计的命令**；需要打开某个设计，请人工操作。

## 状态对象

几乎所有会失败的调用都要一个 `DboState`：

```tcl
set lStatus [DboState]
# ... 使用 ...
$lStatus -delete
```

判断成功用 `[$lStatus OK] == 1`。

**注意 `Message` 也是 CString 出参**，不能当返回值用：

| 方法 | 签名 | 用法 |
| --- | --- | --- |
| `OK` / `Succeeded` / `Failed` | `self` | 直接返回 0/1 |
| `Code` / `Severity` | `self` | 直接返回整数 |
| `Message` | `self msg` | **CString 出参** |

```tcl
proc _statusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}
```

写成 `[$st Message]` 会让**错误处理路径自己报错**，把真正的诊断信息盖掉——
而且只在出错时才暴露，正常路径测不出来。

## 字符串出参

出参**不是 Tcl 变量名**，而是一个 C++ 字符串对象，要显式分配和取值：

```tcl
set lName   [DboTclHelper_sMakeCString]
set lStatus [$pInstOcc GetReference $lName]
set ref     [DboTclHelper_sGetConstCharPtr $lName]
$lStatus -delete
```

## 类型常量

类型是**整数**，但有具名全局变量。**永远写常量名，不要写魔数。**
完整列表可用 `info globals DboBaseObject_*` / `IterDefs_*` 打印。本项目用到的：

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `$::DboBaseObject_INST_OCCURRENCE` | 66 | occurrence（器件**和**层次块都是它） |
| `$::DboBaseObject_PART_INSTANCE` | 11 | 页面级器件实例 |
| `$::DboBaseObject_DRAWN_INSTANCE` | 12 | 页面级已绘制实例 |
| `$::DboBaseObject_PLACED_INSTANCE` | 13 | 页面级已放置实例 |
| `$::IterDefs_INSTS` | 19 | 子 occurrence 迭代模式 |
| `$::IterDefs_PRIMITIVES` | 21 | 只要叶子 |
| `$::IterDefs_ALL` | 0 | 全部 |

### 两个容易踩的坑

**坑一：类型区分不了器件和层次块。** 子 occurrence 迭代器返回的每一个都是
`INST_OCCURRENCE`。要判断是不是叶子器件，必须用 `IsPrimitive`：

```tcl
set lIsPrimitive [$pInstOcc IsPrimitive $lStatus]
if { $lIsPrimitive == 1 } { ... 是器件 ... }
```

**坑二：选择集和 occurrence 是两套对象族。** `GetSelectedObjects` 返回的是
**页面级**对象（`PART_INSTANCE` / `DRAWN_INSTANCE` / `PLACED_INSTANCE`），
不是 occurrence。`capRotate.tcl` 的判断方式：

```tcl
set lObjType [DboBaseObject_GetObjectType $lObj]
if { $lObjType == $::DboBaseObject_DRAWN_INSTANCE ||
     $lObjType == $::DboBaseObject_PLACED_INSTANCE } { ... }
```

因此"对选中器件做修改"和"遍历设计里的 occurrence"不能共用同一套访问代码。

## 基类方法 vs 类型专属方法（决定要不要转型）

这条区分直接决定会不会崩。`DboBaseObject` 的方法对**任何**句柄都安全，
不需要转型；类型专属方法必须先判类型再转型。

| 安全（基类，任何句柄可用） | 需要转型 |
| --- | --- |
| `GetObjectType`、`GetTypeString`、`GetName`、`GetId` | `GetReference` |
| `GetEffectivePropStringValue` | `GetPathName` |
| `SetEffectivePropStringValue` | `IsPrimitive` |
| | `NewChildrenIter` |

完整的基类方法表可以故意在基类句柄上调一个不存在的方法逼出来——报错会把
`Must be one of: ...` 全列出来。

**推论：属性读写不需要转型。** 因此对选择集对象取值/改值完全走基类路径，
既简单又没有崩溃风险。

## 写属性

写入用 `SetEffectivePropStringValue`（**不是** `SetPropStringValue`，那个不存在）。
两个参数都是 CString 输入，返回状态对象。范例见
`capCustomSamples\capCommServerMethods.tcl`、`capUtils\capSearchExecute.tcl`：

```tcl
set lNameC  [DboTclHelper_sMakeCString "Value"]
set lValueC [DboTclHelper_sMakeCString $newValue]
set lStatus [$lObject SetEffectivePropStringValue $lNameC $lValueC]
if { [$lStatus OK] != 1 } { ... }
$lStatus -delete
```

## 常用属性名

| 属性名 | 含义 |
| --- | --- |
| `Value` | 器件值 |
| `Part Reference` | 位号（页面级对象上取位号用这个，见 `capCIS.tcl`） |

occurrence 上取位号可以用类型专属的 `GetReference`；页面级选择集对象上
没有 `GetReference`，用 `GetEffectivePropStringValue "Part Reference"`。

## ⚠️ 位号只在 occurrence 上，页面实例是 `C?`

实测（层次化、已标注的设计）：`GetSelectedObjects` 返回的页面级实例上，
`Part Reference` 和 `Reference` 两个属性**都返回未标注占位符 `C?`**，
而不是标注后的 `C209` / `C211` / `C214`。

标注是把位号赋给 **occurrence** 的；页面实例保留占位符。所以：

| 想要的信息 | 该走哪一侧 |
| --- | --- |
| 真实位号、层次路径 | **occurrence**（`GetRootOccurrence` → 遍历 → `GetReference`） |
| 选中了什么、改选中项的 Value | **页面实例**（`GetSelectedObjects`） |

`Value` 在两侧都读得对，所以"改选中器件的值"是可行的；不可行的是
"报告选中器件的位号"。两侧之间的关联（页面实例 → occurrence）尚未确认。

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

### ⚠️ 迭代正常结束会把 status 设成"错误"

**实测**：迭代取完最后一个元素后，下一次 `NextOccurrence` 会返回 `"NULL"`，
**同时**把 status 置为：

```
ERROR(ORDBDLL-1022): At normal end of iteration
```

也就是说"正常结束"在 status 里表现为**错误码 1022**。如果在迭代步之后无条件
`[$st OK]` 检查，每次遍历都会在正常结束时误报失败。

Cadence 自己的脚本（`capRecurseParts.tcl`）**根本不检查迭代步的 status**，
只判 `!= "NULL"`。本项目的写法是两者结合——先判哨兵，只有真的拿到句柄时
才校验状态：

```tcl
set lChild [$lIter NextOccurrence $st]
if { $lChild eq "NULL" } { break }   ;# 先判哨兵，1022 就落在这里
_requireOk $st {NextOccurrence}      ;# 拿到句柄了才追究状态
```

这样既不会把正常结束当失败，又不会像 Cadence 那样把真实错误一并吞掉。

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
`NewNetOccurrencesIter` 和 `NewPortOccurrencesIter`。实测
`info commands *PinOccurrence*` **完全为空**——flat net 上不存在引脚级 API，
net occurrence 就是等价物。

### ⚠️ 两个迭代器构造函数签名不同

看着像一对，其实参数完全不一样，实测确认：

| 方法 | 签名 |
| --- | --- |
| `NewPortOccurrencesIter` | `self status mode`（要 status 和 `$::IterDefs_*`） |
| `NewNetOccurrencesIter` | `self` —— **不接受任何参数** |

按 `NewPortOccurrencesIter` 的样子去写 `NewNetOccurrencesIter` 会被拒：
`Wrong # args.:DboFlatNet_NewNetOccurrencesIter self  argument 2`。
**同一个类上的同族方法不能假定签名一致。**

`DboFlatNetNetOccurrencesIter` 提供 `Next self status` 和
`NextNetOccurrence self status`；`delete_DboFlatNetNetOccurrencesIter` 实测存在。

`DboFlatNet_GetName self Name` 是 CString 出参；port occurrence 的 `GetName`
实测同样如此。

## 选择集

`GetSelectedObjects` 是**全局命令**，无参，返回句柄列表
（没有 `GetActivePMSelection` 这个东西）：

```tcl
foreach lObj [GetSelectedObjects] {
    set lObjType [DboBaseObject_GetObjectType $lObj]
    if { $lObjType != $::DboBaseObject_DRAWN_INSTANCE &&
         $lObjType != $::DboBaseObject_PLACED_INSTANCE } { continue }
    # 只用基类方法（属性读写），不需要转型
}
```

**注意判的是 12/13，不是 11。** 放置在页面上的器件是 `DRAWN_INSTANCE` 或
`PLACED_INSTANCE`；`PART_INSTANCE`(11) 匹配不到选中的器件。
`capGUIUtils\capRotate.tcl` 和 `capAutoLoad\capPSpiceSourceApp.tcl` 都是这么判的。

## 已确认不存在的方法

`GetPath`、`GetActivePMSelection`、`DboFlatNet_NewPinOccurrencesIter`、
`SetPropStringValue`、`DboObjectToDboPartInstance`、`GetPartOccurrence`、
迭代器的 `delete` 方法、迭代器的 `Next` 方法。

（后三个是本项目重写时凭类比编出来的名字，在 Cadence 自带脚本里零命中，
**不要使用**。）

层次路径改用 `GetPathName`，出参约定同 `GetReference`（见 `capUtils\capPdfUtil.tcl`）：

```tcl
set lPath   [DboTclHelper_sMakeCString]
set lStatus [$lObj GetPathName $lPath]
set path    [DboTclHelper_sGetConstCharPtr $lPath]
$lStatus -delete
```

`DboTclHelper_sMakeCString` 是重载的：无参分配空串，带参用给定内容初始化
（`DboTclHelper_sMakeCString "Value"`）。

## 探测技巧

SWIG 的报错信息本身就带签名，零参数调用即可逼出，且在执行任何逻辑前就报错，
因此是安全的：

```tcl
catch {DboInstOccurrence_GetReference} msg
# => Wrong number of arguments :DboInstOccurrence_GetReference self ref  argument 1
```

但**不要**用错误类型的句柄去试真实调用——那会崩溃，不会报错。
