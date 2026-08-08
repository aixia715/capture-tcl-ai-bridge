# 不启动 Capture GUI 读取 DSN 并导出 BOM

本文说明如何直接使用 Cadence 自带的 Tcl 解释器和 Capture Dbo DLL 读取 `.DSN`
数据库，并导出基础 BOM 明细。整个过程不启动 `Capture.exe`，不需要当前项目的
bridge，也不会把设计显示在 Capture Project Manager 中。

本文方法已于 2026-08-08 在本机 Cadence SPB 16.6（Tcl 8.4）上验证：独立读取
`FNC_PD.DSN`，成功遍历 411 个 primitive occurrence，并取得最终位号、`Value`
和层次路径。

## 适用范围

这个方法适合：

- 批量扫描 `.DSN`；
- 在 CI、命令行工具或离线脚本中生成基础 BOM；
- 在不占用 Capture GUI 的情况下读取设计数据；
- 读取最终位号、`Value` 和层次路径等 Dbo 属性。

它不是 Capture GUI 自动化。二者的区别：

| 操作 | 实现 | 是否启动 Capture GUI |
| --- | --- | --- |
| 把 `.DSN` 加载为 Dbo 数据库 | `DboSession GetDesignAndSchematics` | 否 |
| 在 Project Manager 中打开设计 | Capture 的 File/Open GUI 流程 | 是 |

## 前提条件

1. 本机必须安装 Cadence/OrCAD Capture；普通 Tcl 无法自行解析 Capture 的复合二进制
   数据库。
2. 使用 Cadence 自带的 `tclsh`，并加载同一套安装目录里的 `orDb_Dll_TCL`。
3. Cadence 版本必须能读取目标 `.DSN`。不要用旧版本读取由更高版本升级后保存的
   数据；不确定时先备份原文件。
4. 本文脚本只读，不调用 `SaveDesign` 或 `SaveDesignAs`，但生产环境仍建议对输入
   文件使用只读副本。

在 Windows 命令提示符中确认当前环境：

```bat
where cds_root
where tclsh
```

本机 SPB 16.6 的实测路径是：

```text
C:\Cadence\SPB_16.6\tools\bin\cds_root.exe
C:\Cadence\SPB_16.6\tools\tcl84\bin\tclsh.exe
```

如果安装了多个 Cadence 版本，执行脚本时应明确使用目标版本的 `tclsh.exe`，不要
依赖 `PATH` 恰好指向正确版本。

## 核心打开流程

独立读取 `.DSN` 的最小流程是：

```tcl
set cdnInstallPath [exec cds_root cds_root]
load [file normalize [file join $cdnInstallPath tools capture orDb_Dll_TCL]] DboTclWriteBasic

set status [DboState]
set session [DboTclHelper_sCreateSession]
set designPath [file normalize {C:/path/to/design.dsn}]
set designPathCStr [DboTclHelper_sMakeCString $designPath]
set design [$session GetDesignAndSchematics $designPathCStr $status]

if {[string equal $design NULL] || ![$status OK]} {
    error "Could not open $designPath"
}

# 在这里读取 $design。

$session RemoveLib $design
DboTclHelper_sDeleteSession $session
$status -delete
```

`GetDesignAndSchematics` 返回的是当前独立 `DboSession` 中的 `DboDesign` 句柄。
脚本完成后必须依次移除设计、删除 Session，并释放 `DboState`。

## 为什么必须遍历 occurrence

已标注的层次化设计可能在页面实例的 `Part Reference` 中仍保存 `C?`、`R?`，最终
的 `C209`、`R149` 等位号保存在 occurrence 层。因此 BOM 应使用：

```text
DboDesign
  -> GetRootOccurrence
  -> NewChildrenIter(..., $::IterDefs_INSTS)
  -> DboOccurrenceToDboInstOccurrence
  -> IsPrimitive
  -> GetReference / GetEffectivePropStringValue("Value")
```

不要从 `Design -> Schematic -> Page -> PartInst` 的页面实例直接生成最终 BOM。该路径
适合访问页面对象，但在实测设计中只得到 7 个占位位号：`C?`、`J?`、`L?`、`P?`、
`R?`、`U?`、`X?`；改为 occurrence 遍历后得到 411 个实际器件位号。

## 完整 CSV 导出脚本

下面的脚本兼容 Cadence SPB 16.6 自带的 Tcl 8.4。它输出一行一个 primitive
occurrence，字段为：

```text
RefDes,Value,Path
```

其中 `Path` 用于区分层次化设计中的 occurrence。脚本不修改、不保存输入设计。

<!-- BEGIN HEADLESS BOM TCL -->
```tcl
if {$argc != 2} {
    puts stderr "Usage: tclsh export_dsn_bom.tcl input.dsn output.csv"
    exit 2
}

proc statusMessage {status} {
    set messageCStr [DboTclHelper_sMakeCString]
    $status Message $messageCStr
    return [DboTclHelper_sGetConstCharPtr $messageCStr]
}

proc requireOk {status operation} {
    if {![$status OK]} {
        error "$operation failed: [statusMessage $status] (code [$status Code])"
    }
}

proc stringOut {object method} {
    set valueCStr [DboTclHelper_sMakeCString]
    set status [$object $method $valueCStr]
    if {![$status OK]} {
        set message [statusMessage $status]
        set code [$status Code]
        $status -delete
        error "$method failed: $message (code $code)"
    }
    set value [DboTclHelper_sGetConstCharPtr $valueCStr]
    $status -delete
    return $value
}

proc getEffectiveProperty {object propertyName} {
    set nameCStr [DboTclHelper_sMakeCString $propertyName]
    set valueCStr [DboTclHelper_sMakeCString]
    set status [$object GetEffectivePropStringValue $nameCStr $valueCStr]
    if {![$status OK]} {
        set message [statusMessage $status]
        set code [$status Code]
        $status -delete
        error "GetEffectivePropStringValue($propertyName) failed: $message (code $code)"
    }
    set value [DboTclHelper_sGetConstCharPtr $valueCStr]
    $status -delete
    return $value
}

proc walkOccurrences {occurrence status recordsName} {
    upvar $recordsName records

    # 类型专属方法不会安全地拒绝错误句柄，转型前必须检查类型。
    set objectType [DboBaseObject_GetObjectType $occurrence]
    if {$objectType != $::DboBaseObject_INST_OCCURRENCE} {
        error "Unexpected occurrence object type: $objectType"
    }
    set instOccurrence [DboOccurrenceToDboInstOccurrence $occurrence]

    set primitive [$instOccurrence IsPrimitive $status]
    requireOk $status IsPrimitive
    if {$primitive} {
        set refdes [string trim [stringOut $instOccurrence GetReference]]
        set value [string trim [getEffectiveProperty $instOccurrence Value]]
        set path [stringOut $instOccurrence GetPathName]
        lappend records [list $refdes $value $path]
    }

    set childrenIter [$instOccurrence NewChildrenIter $status $::IterDefs_INSTS]
    requireOk $status NewChildrenIter
    $childrenIter Sort $status
    requireOk $status Sort

    # Tcl 8.4 没有 try/finally，用 catch 保证迭代器在递归失败时也会释放。
    set walkCode [catch {
        set child [$childrenIter NextOccurrence $status]
        while {![string equal $child NULL]} {
            # 正常迭代结束会同时返回 NULL 并设置 ORDBDLL-1022，所以先判 NULL。
            requireOk $status NextOccurrence
            walkOccurrences $child $status records
            set child [$childrenIter NextOccurrence $status]
        }
    } walkResult]
    catch {delete_DboOccurrenceChildrenIter $childrenIter}
    if {$walkCode} {
        error $walkResult
    }
}

proc csvField {value} {
    set escaped [string map [list {"} {""}] $value]
    return "\"$escaped\""
}

set designPath [file normalize [lindex $argv 0]]
set outputPath [file normalize [lindex $argv 1]]
set session ""
set design NULL
set status ""
set output ""
set records {}

set resultCode [catch {
    set cdnInstallPath [exec cds_root cds_root]
    load [file normalize [file join $cdnInstallPath tools capture orDb_Dll_TCL]] DboTclWriteBasic

    set status [DboState]
    set session [DboTclHelper_sCreateSession]
    set designPathCStr [DboTclHelper_sMakeCString $designPath]
    set design [$session GetDesignAndSchematics $designPathCStr $status]
    if {[string equal $design NULL] || ![$status OK]} {
        error "GetDesignAndSchematics failed: [statusMessage $status]"
    }

    set rootOccurrence [$design GetRootOccurrence $status]
    requireOk $status GetRootOccurrence
    walkOccurrences $rootOccurrence $status records

    # 读取全部成功后才创建输出，避免 Dbo 读取错误留下半份 BOM。
    set output [open $outputPath w]
    fconfigure $output -encoding utf-8 -translation crlf
    puts $output {"RefDes","Value","Path"}
    foreach record [lsort -dictionary -index 0 $records] {
        foreach {refdes value path} $record break
        puts $output "[csvField $refdes],[csvField $value],[csvField $path]"
    }
    close $output
    set output ""
} result]

if {![string equal $output ""]} {
    catch {close $output}
}
if {![string equal $session ""] && ![string equal $design NULL]} {
    catch {$session RemoveLib $design}
}
if {![string equal $session ""]} {
    catch {DboTclHelper_sDeleteSession $session}
}
if {![string equal $status ""]} {
    catch {$status -delete}
}

if {$resultCode} {
    puts stderr "BOM_EXPORT_FAILED=$result"
    exit 1
}

puts "BOM_ROWS=[llength $records]"
puts "BOM_FILE=$outputPath"
```
<!-- END HEADLESS BOM TCL -->

## 执行方式

把上面的完整脚本保存到任意工作目录，例如 `C:\temp\export_dsn_bom.tcl`，然后用
对应 Cadence 版本的 Tcl 执行：

```bat
"C:\Cadence\SPB_16.6\tools\tcl84\bin\tclsh.exe" ^
  "C:\temp\export_dsn_bom.tcl" ^
  "C:\Users\aixia\Desktop\temp\FNC_PD.DSN" ^
  "C:\Users\aixia\Desktop\temp\FNC_PD-bom.csv"
```

成功输出类似：

```text
BOM_ROWS=411
BOM_FILE=C:/Users/aixia/Desktop/temp/FNC_PD-bom.csv
```

CSV 内容示例：

```csv
"RefDes","Value","Path"
"C5","1uF","FNC-QQ/C5"
"J1","J30J-15ZKWP14-J%","J1"
"R1","68kR","R1"
"U1","AD620ANZ","FNC-QQ/U1"
```

## BOM 边界

本文脚本输出的是基础 occurrence 明细，不等同于可直接投产的完整 CIS BOM：

- `Value` 相同不代表制造料号、封装和可替代料相同，不能只按 `Value` 合并数量；
- `P*`、`X*`、测试点、安装孔等 primitive 是否纳入 BOM，应按项目规则过滤；
- 多单元器件是否按 occurrence、位号或物理封装合并，需要结合设计规范；
- Variant、DNI/Not Fitted、CIS 数据库字段和公司自定义属性需要额外读取；
- 扩展字段前先确认设计中的准确属性名，不要凭名字猜 Dbo API 或属性。

如需生成生产 BOM，建议保留本脚本的 occurrence 读取层，在其后增加经过项目确认的
料号、封装、装配状态、Variant 和分组规则。

## Dbo 安全规则

- `DboState Message` 是 CString 出参，不能写成 `[$status Message]`；
- `NextOccurrence` 返回 `NULL` 时可能同时设置 ORDBDLL-1022，必须先判断 `NULL`；
- `DboOccurrenceToDboInstOccurrence` 前必须检查
  `DboBaseObject_GetObjectType`；错误类型的句柄可能让进程直接崩溃；
- 每个 occurrence 迭代器都要用 `delete_DboOccurrenceChildrenIter` 释放；
- 每次结束都要 `RemoveLib`、`DboTclHelper_sDeleteSession` 和删除 `DboState`；
- 不要调用 `SaveDesign`/`SaveDesignAs`，除非任务明确要求写回设计。

更多已验证的 Dbo API 约定见
[capture-dbo-api-notes.md](capture-dbo-api-notes.md)。
