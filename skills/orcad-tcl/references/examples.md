# 完整示例索引

本表覆盖包内全部十二个 Tcl 脚本。脚本是独立示例，不需要从原项目 source 公共 helper。
编辑顶部参数后执行；下面的文件链接都在技能包内。

| 示例 | 用途与输入 | 副作用和适配要点 |
| --- | --- | --- |
| [list_components.tcl](../examples/list_components.tcl) | 遍历 Active Design 的叶子 occurrence，输出 refdes/value/path | 只读；整设计遍历可能阻塞 UI |
| [get_component_value.tcl](../examples/get_component_value.tcl) | 顶部 `targetRefdes`，查一个器件的 Value/path | 只读；同名多个 occurrence 时拒绝，需增加 path 筛选 |
| [set_component_value.tcl](../examples/set_component_value.tcl) | `targetRefdes/newValue`，唯一目标写入 Value 后回读 | 修改内存，不保存；重复 refdes 不能任取第一个 |
| [selected_refs.tcl](../examples/selected_refs.tcl) | 当前页面选择的 `Part Reference`，排序去重 | 只读；页面属性不一定是层次标注位号 |
| [selected_occurrence_refs.tcl](../examples/selected_occurrence_refs.tcl) | 将选中页面器件映射到当前 hierarchy occurrence，读标注位号 | 只读；需要有效 GetInstanceOccurrence |
| [inspect_selected_components.tcl](../examples/inspect_selected_components.tcl) | 读取选中 occurrence 的常用属性 | 探索用；属性错误可能返回空字符串，不能用于严格缺失判断 |
| [inspect_selection.tcl](../examples/inspect_selection.tcl) | 当前混合选择的类型、名称及相关信息 | 只读诊断；按对象类型理解结果 |
| [inspect_selected_pin_nets.tcl](../examples/inspect_selected_pin_nets.tcl) | 选中器件的引脚和网络 | 只读；页面引脚编号不应直接当作多单元封装有效编号 |
| [extract_topology.tcl](../examples/extract_topology.tcl) | 全设计 flat net 和器件端点 path、引脚名/编号 | 只读；适合学习 DboFlatNet/PortOccurrence 链路，注意编号语义 |
| [mark_selected_suffix.tcl](../examples/mark_selected_suffix.tcl) | `suffix`（默认 `*`），选中页面器件 Value 加后缀 | 修改、不保存；已带该后缀会跳过 |
| [remove_selected_suffix.tcl](../examples/remove_selected_suffix.tcl) | `suffix`，删除一个末尾后缀 | 修改、不保存；不是通用撤销，不能证明后缀由前一次脚本添加 |
| [headless_set_first_capacitor_value.tcl](../examples/headless_set_first_capacitor_value.tcl) | 独立 tclsh，argv 为 DSN 路径、新值 | 直接保存第一个匹配电容；只在测试副本试用，不作为精确目标生产写入模板 |

## 常见改写方向

### 层次安全地查询和修改一个器件

从 `get_component_value.tcl` 的遍历开始：记录每个匹配的 `GetReference` 和 `GetPathName`。
需要消歧时增加 `targetPath`，按调用返回的完整路径精确比较。读取不唯一时保留候选供
选择；写入前同时匹配 refdes/path 且匹配数必须为 1，然后套用 `set_component_value.tcl`
的 before→set→after。若目标设计已切换，重新定位。

### 当前选中的器件属性

先选择对象族：若是页面批量标记，可参考后缀示例；若是指定层次实例的属性，则参考
`selected_occurrence_refs.tcl` 的 `GetObjectOccurrence` 映射。两者不能仅替换一个函数名。
“当前选择”在执行时读取；选择可能包含导线、文字或层次块，先筛选类型。

### 引脚与网络

小范围检查使用 `inspect_selected_pin_nets.tcl`，全设计遍历参考 `extract_topology.tcl`。
保留层次端点 path；相同页面被重复实例化时不是同一个 occurrence。标签相同不能证明
属于同一 flat net；未连接引脚需要独立保留，不能因无网而当成不存在。
多单元器件要进一步验证 occurrence 有效 `Number`，见 [DBO 参考](dbo-api.md)。

### 离线写入

离线示例展示 DBO 加载、session、GetDesignAndSchematics、SaveDesign 和资源释放。
生产任务改为用户给定的精确 locator、先写副本、独立进程重开验证、再发布输出；
“保存前回读成功”不是“文件已正确保存”的证据。

## 将示例作为代码输入

在 Capture 中 `source` 的路径必须是 Capture 主机可访问的路径；远程 agent 可以通过
AiBridge 上传脚本文本，但不能把 Linux 本地路径直接交给 Windows Tcl `source`。
普通控制台/standalone 的 Tcl 8.4 不一定具备示例使用的 `try/dict/lassign`；读取
[执行参考](execution.md) 后决定是否改写兼容性逻辑。
