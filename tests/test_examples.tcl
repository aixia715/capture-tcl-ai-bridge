# Headless tests for the standalone examples/*.tcl scripts.
#
# Run with: tclsh tests/test_examples.tcl ?suite?
# where suite is one of: fixture, occurrence, selection, topology, write,
# safety. With no argument, every suite runs.
#
# This fixture simulates the *real* OrCAD Capture Dbo Tcl API, as recorded
# in docs/capture-dbo-api-notes.md from live probing on Capture 16.6 plus
# Cadence's own capUtils/capCustomSamples/capGUIUtils/capISCFExport tclscripts.
# The shape is nothing like a simple "$handle Method args" RPC: there is a
# DboState status object threaded through most calls, C-string out-parameters
# allocated and read back through DboTclHelper_s* helpers, "NULL" (the
# string, not empty string) as the iterator-exhausted sentinel, and
# per-iterator-class Next<Type>/delete_Dbo... pairs rather than a uniform
# Next/delete. Every fake object handle forwards "$handle Method ?arg ...?"
# to [$dispatcher $handle Method {arg ...}]; fx::makeHandle mints a unique
# command name and installs a forwarding proc for it, and each object's real
# behaviour lives in a per-kind dispatcher proc keyed off state stored in
# global fx:: arrays.
#
# The one distinction that decides whether a call needs a checked downcast
# is base-class vs type-specific (see docs/capture-dbo-api-notes.md's "基类
# 方法 vs 类型专属方法"): GetObjectType, GetName, GetEffectivePropStringValue
# and SetEffectivePropStringValue live on DboBaseObject and are safe on any
# handle; GetReference, GetPathName, IsPrimitive and NewChildrenIter are
# type-specific and need DboOccurrenceToDboInstOccurrence first, checked with
# DboBaseObject_GetObjectType. Selection objects (GetSelectedObjects) never
# need a downcast at all -- there is no DboObjectToDboPartInstance (invented
# in an earlier draft, zero hits in Cadence's scripts, removed) -- they are
# read and written purely through the base-class property calls.
#
# This file must source the repo's captureAiBridge.tcl first so the Tcl 8.4
# shims for dict/lassign/try exist exactly as they do in production --
# examples are always submitted through the bridge, never run standalone.

set repoRoot [file normalize [file join [file dirname [info script]] ..]]
set bridgeFile [file join $repoRoot captureAiBridge.tcl]
set examplesDir [file join $repoRoot examples]
source $bridgeFile

set ::fail 0

proc check {description actual expected} {
    if {$actual ne $expected} {
        puts stderr "FAIL: $description -> got '{$actual}', want '{$expected}'"
        set ::fail 1
    }
}

proc checkTrue {description value} {
    if {!$value} {
        puts stderr "FAIL: $description"
        set ::fail 1
    }
}

# --- fake Dbo fixture --------------------------------------------------

namespace eval fx {
    variable counter 0
}

# Every fake object handle forwards "$handle Method ?arg ...?" to
# [$dispatcher $handle Method {arg ...}]. The handle name is baked into the
# proc body as a literal via string map (not substituted from a variable at
# call time), so the generated proc needs no closure support -- which
# matters because this fixture must stay portable to Tcl 8.4 too.
proc fx::makeHandle {prefix dispatcher} {
    variable counter
    set handle [format {::fxobj_%s%d} $prefix [incr counter]]
    proc $handle {method args} [string map [list %DISPATCH% $dispatcher %HANDLE% $handle] {
        return [%DISPATCH% {%HANDLE%} $method $args]
    }]
    return $handle
}

proc fx::resetAll {} {
    variable counter
    set counter 0
    foreach arrayName {occRef occValue occPath occObjType occIsPrimitive \
            occChildren occRejectWrite occForceFail occProps occPartInst \
            selObjType selProps selRejectWrite selForceFail selId selName \
            selOwner selOccurrence selTypeString \
            selLocation selStart selEnd selNet selPinType selPinName \
            selPinNumber selPinPosition selRotation selBounds selStyles \
            iterKind iterItems iterIndex iterAlive \
            stOK stCode stMessage \
            netName netPorts netNetOccs \
            portName \
            designRoot designFlatNets designName \
            selectionObjects pageName} {
        if {[array exists ::fx::$arrayName]} {
            array unset ::fx::$arrayName
        }
    }
    set ::fx::setPropCalls 0
    set ::fx::iterDeleteCalls 0
    set ::fx::iterDeletedHandles {}
    set ::fx::activeDesign {}
    set ::fx::activePage NULL
    set ::fx::instanceOccurrence NULL
    set ::fx::selectionObjectsList {}
    set ::fx::selectionIdCounter 1000
    # Write-suite safety counters: the read-only examples never touch these
    # commands and the write examples must not either.
    set ::fx::refreshPartsCalls 0
    set ::fx::designSaveCalls 0
    # Crash-simulation counter: DboOccurrenceToDboInstOccurrence invoked on a
    # handle of the wrong concrete type does not raise a catchable Tcl error
    # in real Capture -- it dereferences a foreign vtable and takes the
    # whole process down. The fixture can't reproduce a segfault, so it
    # counts every time an example would have hit that path; a passing
    # example run must always leave this at 0, and the safety suite proves
    # a deliberately wrong-typed handle trips the *example's own* type
    # check instead of ever reaching here. There is no equivalent counter
    # for selection objects: per docs/capture-dbo-api-notes.md, property
    # reads/writes on a selection object are base-class calls and carry no
    # downcast, hence no crash risk, regardless of the object's concrete type.
    set ::fx::unsafeInstOccurrenceDowncasts 0
    array unset ::fx::iterForceFail
    unset -nocomplain ::fx::iterFailAllWith
}
fx::resetAll

# -- DboState -------------------------------------------------------------

proc fx::makeState {} {
    set handle [fx::makeHandle st fx::stateDispatch]
    set ::fx::stOK($handle) 1
    set ::fx::stCode($handle) 0
    set ::fx::stMessage($handle) OK
    return $handle
}

proc fx::okState {handle} {
    # Every successful Dbo call resets its status object. Modelling this is
    # what keeps the error-1022 a finished iterator leaves behind from
    # poisoning every later call that shares the same DboState.
    set ::fx::stOK($handle) 1
    set ::fx::stCode($handle) 0
    set ::fx::stMessage($handle) OK
}

proc fx::failState {handle code message} {
    set ::fx::stOK($handle) 0
    set ::fx::stCode($handle) $code
    set ::fx::stMessage($handle) $message
}

proc fx::stateDispatch {handle method argsList} {
    switch -exact -- $method {
        OK        { return $::fx::stOK($handle) }
        Succeeded { return $::fx::stOK($handle) }
        Failed    { return [expr {!$::fx::stOK($handle)}] }
        Code      { return $::fx::stCode($handle) }
        Severity  { return [expr {$::fx::stOK($handle) ? 0 : 3}] }
        Message {
            # Confirmed real signature: DboState_Message self msg -- a
            # CString out-parameter, unlike OK/Succeeded/Failed/Code/
            # Severity, which are plain returns. An example that wrote
            # [$st Message] directly (an earlier draft of every example in
            # this repo did) would fail here with a wrong-number-of-args
            # error the instant a real Dbo call failed, masking the actual
            # diagnostic -- exactly the live bug this fixture must catch,
            # so the required out-param is enforced by arity, same as SWIG
            # would enforce it for real.
            if {[llength $argsList] != 1} {
                error "wrong # args: should be \"DboState_Message self msg\""
            }
            set cstr [lindex $argsList 0]
            fx::setCString $cstr $::fx::stMessage($handle)
            return {}
        }
        -delete {
            unset -nocomplain ::fx::stOK($handle) ::fx::stCode($handle) \
                ::fx::stMessage($handle)
            rename $handle {}
            return {}
        }
        default { error "fake DboState: unsupported method \"$method\"" }
    }
}

# ::DboState is a bare constructor (SWIG-wrapped C++ constructor exposed as
# a global command), not a method on anything.
proc ::DboState {} { return [fx::makeState] }

# -- DboTclHelper C-string out-parameters ----------------------------------
#
# DboTclHelper_sMakeCString is overloaded: no argument allocates an empty
# string, one argument initialises it. DboTclHelper_sGetConstCharPtr reads
# the current value back. Neither is a method on an object handle -- both
# are bare global commands, same as DboState.

namespace eval fx { variable cstringCounter 0 }

proc ::DboTclHelper_sMakeCString {args} {
    if {[llength $args] > 1} {
        error {wrong # args: DboTclHelper_sMakeCString ?initialValue?}
    }
    set handle [format {::fxcstr_%d} [incr ::fx::cstringCounter]]
    set ::fx::cstringValue($handle) [expr {[llength $args] == 1 ? [lindex $args 0] : {}}]
    return $handle
}

proc ::DboTclHelper_sGetConstCharPtr {cstringHandle} {
    return $::fx::cstringValue($cstringHandle)
}

# Internal helper the fixture's own dispatchers use to fill an out-parameter
# CString, mirroring what the real SWIG binding does on a successful call.
proc fx::setCString {cstringHandle value} {
    set ::fx::cstringValue($cstringHandle) $value
}

# -- object-type constants and DboBaseObject_GetObjectType ----------------
#
# Real, confirmed values from docs/capture-dbo-api-notes.md. GetObjectType
# is itself a base-class accessor safe on *any* handle, so the fixture must
# answer it correctly for every kind of object it hands out.

set ::DboBaseObject_INST_OCCURRENCE 66
set ::DboBaseObject_PART_INSTANCE 11
set ::DboBaseObject_DRAWN_INSTANCE 12
set ::DboBaseObject_PLACED_INSTANCE 13
set ::DboBaseObject_PORT_INSTANCE 15
set ::DboBaseObject_PORT_INSTANCE_SCALAR 16
set ::DboBaseObject_WIRE_SCALAR 20
set ::DboBaseObject_PORT 23
set ::DboBaseObject_WIRE_BUS 21
set ::DboBaseObject_GLOBAL_SYMBOL 33
set ::DboBaseObject_DBGLOBAL 37
set ::DboBaseObject_OFF_PAGE_CONNECTOR 38
set ::DboBaseObject_COMMENT_TEXT 46
set ::DboBaseObject_ALIAS 49
set ::DboBaseObject_GRAPHIC_BOX_INST 55
set ::DboBaseObject_GRAPHIC_LINE_INST 56
set ::DboBaseObject_GRAPHIC_ELLIPSE_INST 58
set ::DboBaseObject_TITLEBLOCK_INSTANCE 65
set ::DboBaseObject_GRAPHIC_COMMENTTEXT_INST 61
set ::IterDefs_INSTS 19
set ::IterDefs_PRIMITIVES 21
set ::IterDefs_ALL 0

proc ::DboBaseObject_GetObjectType {handle} {
    if {[info exists ::fx::occObjType($handle)]} {
        return $::fx::occObjType($handle)
    }
    if {[info exists ::fx::selObjType($handle)]} {
        return $::fx::selObjType($handle)
    }
    error "fake DboBaseObject_GetObjectType: handle $handle has no recorded object type"
}

proc ::DboBaseObject_GetName {handle cstr} {
    return [$handle GetName $cstr]
}

# -- occurrence family: DboOccurrence / DboInstOccurrence -----------------
#
# GetRootOccurrence and NewChildrenIter/NextOccurrence hand back a generic
# "occurrence" handle that must be downcast with
# DboOccurrenceToDboInstOccurrence before any type-specific InstOccurrence
# method -- GetReference, GetPathName, IsPrimitive, NewChildrenIter -- can be
# called on it. GetEffectivePropStringValue/SetEffectivePropStringValue are
# NOT in that list: they are DboBaseObject methods and work on the handle
# either way, downcast or not. The fixture models "type-specific method
# reached with a wrongly-typed handle" as a loud, distinguishable error and
# a bump of ::fx::unsafeInstOccurrenceDowncasts -- standing in for the real
# consequence, which is a Capture crash, not a Tcl error at all.

proc fx::makeOccurrence {reference value path children {isPrimitive 1}} {
    set handle [fx::makeHandle occ fx::occDispatch]
    set ::fx::occRef($handle) $reference
    set ::fx::occValue($handle) $value
    set ::fx::occPath($handle) $path
    set ::fx::occObjType($handle) $::DboBaseObject_INST_OCCURRENCE
    set ::fx::occIsPrimitive($handle) $isPrimitive
    set ::fx::occChildren($handle) $children
    set ::fx::occProps($handle,Value) $value
    set ::fx::occPartInst($handle) NULL
    return $handle
}

proc fx::setOccurrenceProperty {handle name value} {
    set ::fx::occProps($handle,$name) $value
}

# A write that Capture accepts (SetEffectivePropStringValue's status comes
# back OK) but that does not actually stick -- the value stays the old one.
# This exists so the write-suite examples' "read back and error if it did
# not take" behaviour has something to trip over.
proc fx::makeStubbornOccurrence {reference value path children} {
    set handle [fx::makeOccurrence $reference $value $path $children]
    set ::fx::occRejectWrite($handle) 1
    return $handle
}

# Marks a method on this occurrence to fail (return a not-OK status) the
# next time it is called, so a test can prove an example checks status and
# fails loudly instead of pressing on with a null/garbage result.
proc fx::forceOccFail {handle method} {
    set ::fx::occForceFail($handle,$method) 1
}

proc fx::occDispatch {handle method argsList} {
    switch -exact -- $method {
        GetReference {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            if {[fx::consumeForceFail occForceFail $handle GetReference]} {
                fx::failState $st 1 {forced failure: GetReference}
                return $st
            }
            fx::setCString $cstr $::fx::occRef($handle)
            return $st
        }
        GetPathName {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            if {[fx::consumeForceFail occForceFail $handle GetPathName]} {
                fx::failState $st 1 {forced failure: GetPathName}
                return $st
            }
            fx::setCString $cstr $::fx::occPath($handle)
            return $st
        }
        GetEffectivePropStringValue {
            set nameCstr [lindex $argsList 0]
            set valueCstr [lindex $argsList 1]
            set st [fx::makeState]
            if {[fx::consumeForceFail occForceFail $handle GetEffectivePropStringValue]} {
                fx::failState $st 1 {forced failure: GetEffectivePropStringValue}
                return $st
            }
            set propName [DboTclHelper_sGetConstCharPtr $nameCstr]
            if {![info exists ::fx::occProps($handle,$propName)]} {
                fx::failState $st 1021 {ERROR(ORDBDLL-1021): Object Not Found}
                return $st
            }
            fx::setCString $valueCstr $::fx::occProps($handle,$propName)
            return $st
        }
        SetEffectivePropStringValue {
            set nameCstr [lindex $argsList 0]
            set valueCstr [lindex $argsList 1]
            set st [fx::makeState]
            if {[fx::consumeForceFail occForceFail $handle SetEffectivePropStringValue]} {
                fx::failState $st 1 {forced failure: SetEffectivePropStringValue}
                return $st
            }
            set propName [DboTclHelper_sGetConstCharPtr $nameCstr]
            incr ::fx::setPropCalls
            if {![info exists ::fx::occRejectWrite($handle)] || !$::fx::occRejectWrite($handle)} {
                set newValue [DboTclHelper_sGetConstCharPtr $valueCstr]
                if {$propName eq {Value}} {
                    set ::fx::occValue($handle) $newValue
                }
                set ::fx::occProps($handle,$propName) $newValue
            }
            return $st
        }
        IsPrimitive {
            set st [lindex $argsList 0]
            fx::okState $st
            if {[fx::consumeForceFail occForceFail $handle IsPrimitive]} {
                fx::failState $st 1 {forced failure: IsPrimitive}
                return 0
            }
            return $::fx::occIsPrimitive($handle)
        }
        GetPartInst - GetInstance {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::occPartInst($handle)
        }
        GetPartInstId {
            set st [lindex $argsList 0]
            fx::okState $st
            set partInst $::fx::occPartInst($handle)
            if {$partInst eq {NULL}} { return 0 }
            return $::fx::selId($partInst)
        }
        NewChildrenIter {
            set st [lindex $argsList 0]
            fx::okState $st
            if {[fx::consumeForceFail occForceFail $handle NewChildrenIter]} {
                fx::failState $st 1 {forced failure: NewChildrenIter}
                return {}
            }
            return [fx::makeListIter occChildren $::fx::occChildren($handle)]
        }
        default { error "fake occurrence: unsupported method \"$method\"" }
    }
}

# Consumes (clears) a one-shot forced-failure flag if it was set, returning
# whether it fired. One-shot so a test can fail exactly one call in a walk
# without breaking every subsequent call on the same handle.
proc fx::consumeForceFail {arrayName handle method} {
    upvar #0 ::fx::$arrayName arr
    if {[info exists arr($handle,$method)] && $arr($handle,$method)} {
        set arr($handle,$method) 0
        return 1
    }
    return 0
}

proc ::DboOccurrenceToDboInstOccurrence {occHandle} {
    if {![info exists ::fx::occObjType($occHandle)] || \
            $::fx::occObjType($occHandle) != $::DboBaseObject_INST_OCCURRENCE} {
        incr ::fx::unsafeInstOccurrenceDowncasts
        error "fake DboOccurrenceToDboInstOccurrence: handle $occHandle is not a DboOccurrence -- this would crash real Capture, not raise a Tcl error"
    }
    return $occHandle
}

proc ::delete_DboOccurrenceChildrenIter {iterHandle} {
    fx::deleteIter $iterHandle occChildren
}

# -- selection family: page-level instances --------------------------------
#
# GetSelectedObjects hands back page-level instances -- a different object
# family from occurrences, per docs/capture-dbo-api-notes.md's "坑二". A
# selected component reports DRAWN_INSTANCE (12) or PLACED_INSTANCE (13),
# *not* PART_INSTANCE (11) -- capRotate.tcl and capPSpiceSourceApp.tcl both
# check 12 || 13. There is no DboObjectToDboPartInstance and no
# type-specific GetReference on these objects: refdes and value are both
# read/written purely through the base-class property calls
# (GetEffectivePropStringValue/SetEffectivePropStringValue with property
# names "Part Reference" and "Value"), so no downcast, and no crash risk,
# is involved on this path at all.

proc fx::makeSelObject {objType reference value} {
    set handle [fx::makeHandle sel fx::selDispatch]
    set ::fx::selObjType($handle) $objType
    # The property name "Part Reference" contains a space, which cannot be
    # embedded directly inside an array-index word: Tcl only brace-quotes a
    # word that starts with an open brace, and an open brace appearing
    # after a literal comma mid-word is not a quoted word, so its embedded
    # space would split the enclosing command into extra arguments.
    # Routing it through a variable first sidesteps that: substitution
    # results are never re-split on whitespace.
    set refPropName {Part Reference}
    set ::fx::selProps($handle,$refPropName) $reference
    set ::fx::selProps($handle,Value) $value
    set ::fx::selId($handle) [incr ::fx::selectionIdCounter]
    set ::fx::selName($handle) $reference
    set ::fx::selOwner($handle) $::fx::activePage
    set ::fx::selOccurrence($handle) NULL
    set ::fx::selTypeString($handle) "OBJECT_$objType"
    return $handle
}

proc fx::linkSelectionOccurrence {selection occurrence} {
    set ::fx::selOccurrence($selection) $occurrence
    set ::fx::occPartInst($occurrence) $selection
}

proc fx::setSelectionProperty {handle name value} {
    set ::fx::selProps($handle,$name) $value
}

proc fx::setSelectionName {handle name} { set ::fx::selName($handle) $name }
proc fx::setSelectionLocation {handle x y} {
    set ::fx::selLocation($handle) [list $x $y]
}
proc fx::setSelectionWire {handle net startX startY endX endY} {
    set ::fx::selNet($handle) $net
    set ::fx::selStart($handle) [list $startX $startY]
    set ::fx::selEnd($handle) [list $endX $endY]
}
proc fx::setSelectionPinType {handle pinType} {
    set ::fx::selPinType($handle) $pinType
}
proc fx::setSelectionPortDetails {handle net pinType locationX locationY hotX hotY} {
    set ::fx::selNet($handle) $net
    set ::fx::selPinType($handle) $pinType
    set ::fx::selLocation($handle) [list $locationX $locationY]
    set ::fx::selEnd($handle) [list $hotX $hotY]
}
proc fx::setSelectionPinDetails {handle owner net pinName pinNumber pinType pinPosition startX startY hotX hotY} {
    set ::fx::selOwner($handle) $owner
    set ::fx::selNet($handle) $net
    set ::fx::selPinName($handle) $pinName
    set ::fx::selPinNumber($handle) $pinNumber
    set ::fx::selPinType($handle) $pinType
    set ::fx::selPinPosition($handle) $pinPosition
    set ::fx::selStart($handle) [list $startX $startY]
    set ::fx::selEnd($handle) [list $hotX $hotY]
}
proc fx::setSelectionAlias {handle x y rotation} {
    set ::fx::selLocation($handle) [list $x $y]
    set ::fx::selRotation($handle) $rotation
}
proc fx::setSelectionGraphic {handle left top right bottom lineStyle lineWidth fillStyle hatchStyle} {
    set ::fx::selBounds($handle) [list $left $top $right $bottom]
    set ::fx::selStyles($handle) [list $lineStyle $lineWidth $fillStyle $hatchStyle]
}

proc fx::makeStubbornSelObject {objType reference value} {
    set handle [fx::makeSelObject $objType $reference $value]
    set ::fx::selRejectWrite($handle) 1
    return $handle
}

proc fx::forceSelFail {handle method} {
    set ::fx::selForceFail($handle,$method) 1
}

proc fx::selDispatch {handle method argsList} {
    switch -exact -- $method {
        GetId {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selId($handle)
        }
        GetOwner { return $::fx::selOwner($handle) }
        GetObjectOccurrence { return $::fx::selOccurrence($handle) }
        GetName {
            set cstr [lindex $argsList 0]
            fx::setCString $cstr $::fx::selName($handle)
            return {}
        }
        GetReference {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            set refPropName {Part Reference}
            fx::setCString $cstr $::fx::selProps($handle,$refPropName)
            return $st
        }
        GetPinName - GetPinNumber {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            set value [expr {$method eq "GetPinName" ? $::fx::selPinName($handle) : $::fx::selPinNumber($handle)}]
            fx::setCString $cstr $value
            return $st
        }
        GetTypeString {
            set cstr [lindex $argsList 0]
            fx::setCString $cstr $::fx::selTypeString($handle)
            return {}
        }
        GetLocation {
            set st [lindex $argsList 0]
            fx::okState $st
            if {[fx::consumeForceFail selForceFail $handle GetLocation]} {
                fx::failState $st 1 {forced failure: GetLocation}
            }
            return $::fx::selLocation($handle)
        }
        GetStartPoint {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selStart($handle)
        }
        GetEndPoint {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selEnd($handle)
        }
        GetOffsetStartPoint {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selStart($handle)
        }
        GetOffsetHotSpot {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selEnd($handle)
        }
        GetNet {
            set st [lindex $argsList 0]
            fx::okState $st
            if {[fx::consumeForceFail selForceFail $handle GetNet]} {
                fx::failState $st 1 {forced failure: GetNet}
            }
            return $::fx::selNet($handle)
        }
        GetNetName {
            if {[llength $argsList] != 1} {
                error "wrong # args: should be \"DboWire_GetNetName self name\""
            }
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            if {[fx::consumeForceFail selForceFail $handle GetNetName]} {
                fx::failState $st 1 {forced failure: GetNetName}
                return $st
            }
            fx::setCString $cstr $::fx::netName($::fx::selNet($handle))
            return $st
        }
        GetPinType {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selPinType($handle)
        }
        GetPinPosition {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::selPinPosition($handle)
        }
        GetEffectivePropStringValue {
            set nameCstr [lindex $argsList 0]
            set valueCstr [lindex $argsList 1]
            set st [fx::makeState]
            if {[fx::consumeForceFail selForceFail $handle GetEffectivePropStringValue]} {
                fx::failState $st 1 {forced failure: GetEffectivePropStringValue}
                return $st
            }
            set propName [DboTclHelper_sGetConstCharPtr $nameCstr]
            if {![info exists ::fx::selProps($handle,$propName)]} {
                error "fake selection object: unsupported property \"$propName\""
            }
            fx::setCString $valueCstr $::fx::selProps($handle,$propName)
            return $st
        }
        SetEffectivePropStringValue {
            set nameCstr [lindex $argsList 0]
            set valueCstr [lindex $argsList 1]
            set st [fx::makeState]
            if {[fx::consumeForceFail selForceFail $handle SetEffectivePropStringValue]} {
                fx::failState $st 1 {forced failure: SetEffectivePropStringValue}
                return $st
            }
            set propName [DboTclHelper_sGetConstCharPtr $nameCstr]
            if {![info exists ::fx::selProps($handle,$propName)]} {
                error "fake selection object: unsupported property \"$propName\""
            }
            incr ::fx::setPropCalls
            if {![info exists ::fx::selRejectWrite($handle)] || !$::fx::selRejectWrite($handle)} {
                set ::fx::selProps($handle,$propName) [DboTclHelper_sGetConstCharPtr $valueCstr]
            }
            return $st
        }
        default { error "fake selection object: unsupported method \"$method\"" }
    }
}

# ::GetSelectedObjects is a bare global command (no args, no DboState) that
# returns a plain Tcl list of handles -- confirmed in
# docs/capture-dbo-api-notes.md; there is no GetActivePMSelection.
proc ::GetSelectedObjects {} { return $::fx::selectionObjectsList }

proc ::DboBaseObject_GetId {handle st} { return [$handle GetId $st] }
proc ::DboTclHelper_sGetCPointX {point} { return [lindex $point 0] }
proc ::DboTclHelper_sGetCPointY {point} { return [lindex $point 1] }
proc ::DboAlias_sGetRotation {handle st} { fx::okState $st; return $::fx::selRotation($handle) }
proc ::DboGraphicInstanceToDboGraphicBoxInst {handle} { return $handle }
proc ::DboGraphicInstanceToDboGraphicLineInst {handle} { return $handle }
proc ::DboGraphicInstanceToDboGraphicEllipseInst {handle} { return $handle }
proc ::fx::graphicValue {handle st index} { fx::okState $st; return [lindex $::fx::selBounds($handle) $index] }
proc ::fx::styleValue {handle st index} { fx::okState $st; return [lindex $::fx::selStyles($handle) $index] }
proc ::DboGraphicBoxInst_sGetLeft {h st} { return [fx::graphicValue $h $st 0] }
proc ::DboGraphicBoxInst_sGetTop {h st} { return [fx::graphicValue $h $st 1] }
proc ::DboGraphicBoxInst_sGetRight {h st} { return [fx::graphicValue $h $st 2] }
proc ::DboGraphicBoxInst_sGetBottom {h st} { return [fx::graphicValue $h $st 3] }
proc ::DboGraphicBoxInst_sGetLineStyle {h st} { return [fx::styleValue $h $st 0] }
proc ::DboGraphicBoxInst_sGetLineWidth {h st} { return [fx::styleValue $h $st 1] }
proc ::DboGraphicBoxInst_sGetFillStyle {h st} { return [fx::styleValue $h $st 2] }
proc ::DboGraphicBoxInst_sGetHatchStyle {h st} { return [fx::styleValue $h $st 3] }
proc ::DboGraphicLineInst_sGetStartX {h st} { return [fx::graphicValue $h $st 0] }
proc ::DboGraphicLineInst_sGetStartY {h st} { return [fx::graphicValue $h $st 1] }
proc ::DboGraphicLineInst_sGetEndX {h st} { return [fx::graphicValue $h $st 2] }
proc ::DboGraphicLineInst_sGetEndY {h st} { return [fx::graphicValue $h $st 3] }
proc ::DboGraphicLineInst_sGetLineStyle {h st} { return [fx::styleValue $h $st 0] }
proc ::DboGraphicLineInst_sGetLineWidth {h st} { return [fx::styleValue $h $st 1] }
proc ::DboGraphicEllipseInst_sGetBoundingBoxLeft {h st} { return [fx::graphicValue $h $st 0] }
proc ::DboGraphicEllipseInst_sGetBoundingBoxTop {h st} { return [fx::graphicValue $h $st 1] }
proc ::DboGraphicEllipseInst_sGetBoundingBoxRight {h st} { return [fx::graphicValue $h $st 2] }
proc ::DboGraphicEllipseInst_sGetBoundingBoxBottom {h st} { return [fx::graphicValue $h $st 3] }
proc ::DboGraphicEllipseInst_sGetLineStyle {h st} { return [fx::styleValue $h $st 0] }
proc ::DboGraphicEllipseInst_sGetLineWidth {h st} { return [fx::styleValue $h $st 1] }
proc ::DboGraphicEllipseInst_sGetFillStyle {h st} { return [fx::styleValue $h $st 2] }
proc ::DboGraphicEllipseInst_sGetHatchStyle {h st} { return [fx::styleValue $h $st 3] }

proc fx::makePage {name} {
    set handle [fx::makeHandle page fx::pageDispatch]
    set ::fx::pageName($handle) $name
    return $handle
}

proc fx::pageDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName {
            set cstr [lindex $argsList 0]
            fx::setCString $cstr $::fx::pageName($handle)
            return {}
        }
        default { error "fake page: unsupported method \"$method\"" }
    }
}

proc ::GetActivePage {} { return $::fx::activePage }
proc ::GetInstanceOccurrence {} { return $::fx::instanceOccurrence }

# -- generic list-backed iterator ------------------------------------------
#
# Used for children/flat-nets/ports/net-occurrences alike. Each concrete
# iterator "kind" (occChildren, flatNets, ports, netOccs) gets its own
# Next<Type> dispatch and its own delete_Dbo...Iter free function -- real
# Capture does not share one Next/delete pair across iterator classes.

proc fx::makeListIter {kind items} {
    set handle [fx::makeHandle iter fx::iterDispatch]
    set ::fx::iterKind($handle) $kind
    set ::fx::iterItems($handle) $items
    set ::fx::iterIndex($handle) 0
    set ::fx::iterAlive($handle) 1
    return $handle
}

proc fx::iterAdvance {handle st} {
    if {![info exists ::fx::iterAlive($handle)] || !$::fx::iterAlive($handle)} {
        error "fake iterator $handle: Next called after delete"
    }
    set items $::fx::iterItems($handle)
    set idx $::fx::iterIndex($handle)
    if {$idx >= [llength $items]} {
        # Real Capture reports a *finished* iteration as a failure: the step
        # returns the NULL sentinel and simultaneously sets the status to
        # error 1022, "At normal end of iteration". A fixture that returned
        # NULL with an OK status would happily accept a status-before-
        # sentinel check and let it blow up only on real hardware -- which
        # is exactly what happened, on the very first real-Capture run.
        fx::failState $st 1022 {ERROR(ORDBDLL-1022): At normal end of iteration}
        return NULL
    }
    fx::okState $st
    if {[info exists ::fx::iterFailAllWith]} {
        lassign $::fx::iterFailAllWith code message
        fx::failState $st $code $message
    }
    if {[info exists ::fx::iterForceFail($handle)]} {
        # A genuine iterator error, i.e. one that reports failure while
        # still handing back a real handle. Testing the sentinel first must
        # not degenerate into never checking the status at all.
        lassign $::fx::iterForceFail($handle) code message
        fx::failState $st $code $message
    }
    set ::fx::iterIndex($handle) [expr {$idx + 1}]
    return [lindex $items $idx]
}

proc fx::forceIterFailure {handle code message} {
    set ::fx::iterForceFail($handle) [list $code $message]
}

proc fx::iterDispatch {handle method argsList} {
    switch -exact -- $method {
        Sort {
            set st [lindex $argsList 0]
            fx::okState $st
            return {}
        }
        NextOccurrence {
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::iterAdvance $handle $st]
        }
        NextFlatNet {
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::iterAdvance $handle $st]
        }
        NextPortOccurrence {
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::iterAdvance $handle $st]
        }
        NextNetOccurrence {
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::iterAdvance $handle $st]
        }
        default { error "fake iterator: unsupported method \"$method\"" }
    }
}

proc fx::deleteIter {handle expectedKind} {
    if {![info exists ::fx::iterAlive($handle)] || !$::fx::iterAlive($handle)} {
        error "fake iterator $handle: delete called twice"
    }
    if {$::fx::iterKind($handle) ne $expectedKind} {
        error "fake iterator $handle: freed with the wrong delete_Dbo...Iter function (kind $::fx::iterKind($handle), expected $expectedKind)"
    }
    set ::fx::iterAlive($handle) 0
    incr ::fx::iterDeleteCalls
    lappend ::fx::iterDeletedHandles $handle
    rename $handle {}
    return {}
}

# -- flat net / port occurrence / net occurrence -----------------------------
#
# NewFlatNetsIter/NextFlatNet/delete_DboDesignFlatNetsIter and
# NewPortOccurrencesIter/NextPortOccurrence/delete_DboFlatNetPortOccurrencesIter
# are all confirmed (capDesignPhysicalViewReader.tcl). The pin-level walk
# now IS confirmed too, in part: `info commands DboFlatNetNetOccurrences*`
# on real Capture returns DboFlatNetNetOccurrencesIter,
# DboFlatNetNetOccurrencesIter_GetKey, DboFlatNetNetOccurrencesIter_Next
# and DboFlatNetNetOccurrencesIter_NextNetOccurrence -- so NextNetOccurrence
# is real (an earlier draft of this project was told otherwise and dropped
# the walk entirely; that was wrong). What remains unconfirmed is what
# fields a net occurrence itself exposes, so extract_topology.tcl opens the
# iterator and steps it with NextNetOccurrence but never calls any method
# on a net occurrence handle. The fixture enforces that: fx::netOccDispatch
# errors loudly on *any* method call, so if a future edit accidentally
# reaches into a net occurrence before the real field API is confirmed, the
# test suite catches it immediately instead of silently "working" against a
# fixture that over-modelled the real, still-unconfirmed surface.
#
# The free function IS modelled, and freeing it is no longer optional: a
# wrongly-typed *handle* passed to a real type-specific method crashes
# Capture, but calling a Tcl *command name* that simply does not exist is
# an ordinary catchable error -- so extract_topology.tcl probes
# `info commands delete_DboFlatNetNetOccurrencesIter` at runtime and frees
# only if it is present. The fixture models both branches of that guard:
# normally the command exists (see delete_DboFlatNetNetOccurrencesIter
# below) and the iterator is freed like any other; suite_topology also
# renames it away for one run to prove the guarded call is a harmless no-op
# -- not a crash -- when the name turns out to be wrong.

proc fx::makeFlatNet {name ports netOccs} {
    set handle [fx::makeHandle net fx::netDispatch]
    set ::fx::netName($handle) $name
    set ::fx::netPorts($handle) $ports
    set ::fx::netNetOccs($handle) $netOccs
    return $handle
}

proc fx::netDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName - GetNetName {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            fx::setCString $cstr $::fx::netName($handle)
            return $st
        }
        NewPortOccurrencesIter {
            # Confirmed: "self status mode" -- takes a status and an
            # IterDefs mode.
            if {[llength $argsList] != 2} {
                error "Wrong # args.:DboFlatNet_NewPortOccurrencesIter self status mode"
            }
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::makeListIter ports $::fx::netPorts($handle)]
        }
        NewNetOccurrencesIter {
            # Confirmed: "DboFlatNet_NewNetOccurrencesIter self" -- NO
            # arguments, unlike its sibling right above. Enforcing the arity
            # here is what stops the two from being written alike again;
            # passing a status and a mode is what real Capture rejected.
            if {[llength $argsList] != 0} {
                error "Wrong # args.:DboFlatNet_NewNetOccurrencesIter self  argument 2"
            }
            return [fx::makeListIter netOccs $::fx::netNetOccs($handle)]
        }
        default { error "fake flat net: unsupported method \"$method\"" }
    }
}

proc ::delete_DboFlatNetPortOccurrencesIter {iterHandle} {
    fx::deleteIter $iterHandle ports
}

proc ::delete_DboFlatNetNetOccurrencesIter {iterHandle} {
    fx::deleteIter $iterHandle netOccs
}

proc fx::makePortInst {pinNumber pinName} {
    set handle [fx::makeHandle portinst fx::portInstDispatch]
    set ::fx::portInstNumber($handle) $pinNumber
    set ::fx::portInstName($handle) $pinName
    return $handle
}

proc fx::portInstDispatch {handle method argsList} {
    switch -exact -- $method {
        GetPinNumber - GetPinName {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            if {$method eq {GetPinNumber}} {
                fx::setCString $cstr $::fx::portInstNumber($handle)
            } else {
                fx::setCString $cstr $::fx::portInstName($handle)
            }
            return $st
        }
        default { error "fake port instance: unsupported method \"$method\"" }
    }
}

proc fx::makePortOccurrence {path {pinNumber {}} {pinName {}}} {
    set handle [fx::makeHandle port fx::portDispatch]
    set ::fx::portPath($handle) $path
    set ::fx::portInst($handle) [fx::makePortInst $pinNumber $pinName]
    return $handle
}

proc fx::portDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName {
            set cstr [lindex $argsList 0]
            set st [fx::makeState]
            fx::setCString $cstr $::fx::portPath($handle)
            return $st
        }
        GetPortInst {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::portInst($handle)
        }
        default { error "fake port occurrence: unsupported method \"$method\"" }
    }
}

proc ::DboPortOccurrence_sGetPathName {handle st} {
    fx::okState $st
    set cstr [DboTclHelper_sMakeCString]
    fx::setCString $cstr $::fx::portPath($handle)
    return $cstr
}

# A net occurrence's real field/method surface is not confirmed at all, so
# this fake exposes none: any method call on one is a test failure, proving
# extract_topology.tcl only ever counts net occurrences via NextNetOccurrence
# and never inspects one.
proc fx::makeNetOccurrence {} {
    return [fx::makeHandle netocc fx::netOccDispatch]
}

proc fx::netOccDispatch {handle method argsList} {
    error "fake net occurrence: method \"$method\" called on $handle -- extract_topology.tcl must not call any method on a net occurrence until docs/capture-dbo-api-notes.md confirms what one exposes"
}

# -- design -----------------------------------------------------------------

proc fx::makeDesign {root flatNets {name {C:/designs/test.dsn}}} {
    set handle [fx::makeHandle design fx::designDispatch]
    set ::fx::designRoot($handle) $root
    set ::fx::designFlatNets($handle) $flatNets
    set ::fx::designName($handle) $name
    return $handle
}

proc fx::designDispatch {handle method argsList} {
    switch -exact -- $method {
        GetRootOccurrence {
            set st [lindex $argsList 0]
            fx::okState $st
            return $::fx::designRoot($handle)
        }
        GetName {
            set cstr [lindex $argsList 0]
            fx::setCString $cstr $::fx::designName($handle)
            return {}
        }
        NewFlatNetsIter {
            set st [lindex $argsList 0]
            fx::okState $st
            return [fx::makeListIter flatNets $::fx::designFlatNets($handle)]
        }
        Save {
            incr ::fx::designSaveCalls
            return {}
        }
        default { error "fake design: unsupported method \"$method\"" }
    }
}

proc ::delete_DboDesignFlatNetsIter {iterHandle} {
    fx::deleteIter $iterHandle flatNets
}

# GetActivePMDesign is a bare global command, same as GetSelectedObjects.
proc ::GetActivePMDesign {} { return $::fx::activeDesign }

# RefreshParts and a bare Save are the two commands the write examples must
# never call (RefreshParts is a TCLBOM helper this project deliberately
# does not depend on; Save would silently commit an unreviewed edit to
# disk). Both a global Save and $design Save are wired to the same counter
# above so a script has nowhere to hide either spelling.
proc ::RefreshParts {} { incr ::fx::refreshPartsCalls; return {} }
proc ::Save {} { incr ::fx::designSaveCalls; return {} }

# --- suites --------------------------------------------------------------

# Runs an example file, capturing everything it [puts] and any error it
# raises, without ever touching the real stdout/stderr.
proc fx::runExample {name} {
    set path [file join $::examplesDir $name]
    if {![file exists $path]} {
        error "FIXTURE_MISSING_EXAMPLE: $path does not exist"
    }
    set ::fx::capturedOutput {}
    rename ::puts ::fx::realPuts
    proc ::puts {args} {
        # `puts $text` and `puts -nonewline $text` both land here; examples
        # only ever use the one-argument form, so anything else is a bug in
        # the example, not something this shim should silently accept.
        if {[llength $args] != 1} {
            error "fake puts: unsupported invocation: $args"
        }
        lappend ::fx::capturedOutput [lindex $args 0]
    }
    set code [catch {uplevel #0 [list source $path]} message]
    rename ::puts {}
    rename ::fx::realPuts ::puts
    return [list $code $message $::fx::capturedOutput]
}

proc suite_fixture {} {
    fx::resetAll

    set leaf [fx::makeOccurrence R9 10k /R9 {}]
    check {fixture: DboBaseObject_GetObjectType on an occurrence} \
        [DboBaseObject_GetObjectType $leaf] $::DboBaseObject_INST_OCCURRENCE
    set leafInstOcc [DboOccurrenceToDboInstOccurrence $leaf]
    check {fixture: downcast returns the same handle} $leafInstOcc $leaf

    set st [DboState]
    check {fixture: fresh DboState is OK} [$st OK] 1

    # Message is a CString out-parameter, not a plain return value -- the
    # method call itself returns nothing meaningful, and it must not be
    # called with too few arguments the way OK/Code/Severity can be.
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    check {fixture: DboState Message via CString out-param} \
        [DboTclHelper_sGetConstCharPtr $msgC] OK
    checkTrue {fixture: DboState Message rejects the old no-out-param call} \
        [catch {$st Message}]

    set refC [DboTclHelper_sMakeCString]
    set refSt [$leafInstOcc GetReference $refC]
    check {fixture: GetReference status is OK} [$refSt OK] 1
    check {fixture: GetReference fills the out-param} \
        [DboTclHelper_sGetConstCharPtr $refC] R9
    $refSt -delete

    set nameC [DboTclHelper_sMakeCString Value]
    set valueC [DboTclHelper_sMakeCString]
    set propSt [$leafInstOcc GetEffectivePropStringValue $nameC $valueC]
    check {fixture: GetEffectivePropStringValue reads Value} \
        [DboTclHelper_sGetConstCharPtr $valueC] 10k
    $propSt -delete

    # Base-class property calls need no downcast: the raw occurrence handle
    # (not the instOcc alias -- they are the same handle here, but the call
    # below is exactly what a script would do on a handle it never downcast)
    # answers GetEffectivePropStringValue/SetEffectivePropStringValue fine.
    set newValueC [DboTclHelper_sMakeCString 22k]
    set setSt [$leaf SetEffectivePropStringValue $nameC $newValueC]
    check {fixture: SetEffectivePropStringValue mutates and is counted} \
        [list [$setSt OK] $::fx::occValue($leaf) $::fx::setPropCalls] \
        [list 1 22k 1]
    $setSt -delete

    check {fixture: IsPrimitive on a leaf} [$leafInstOcc IsPrimitive $st] 1

    set root [fx::makeOccurrence {} {} / [list $leaf] 0]
    check {fixture: IsPrimitive on a block} \
        [$root IsPrimitive $st] 0
    set childrenIter [$root NewChildrenIter $st]
    set first [$childrenIter NextOccurrence $st]
    check {fixture: children iterator returns the child} $first $leaf
    check {fixture: children iterator exhausts to the NULL sentinel} \
        [$childrenIter NextOccurrence $st] NULL
    delete_DboOccurrenceChildrenIter $childrenIter
    check {fixture: iterator delete is counted} $::fx::iterDeleteCalls 1
    checkTrue {fixture: deleted iterator command is gone} \
        [expr {[llength [info commands $childrenIter]] == 0}]
    set doubleDeleteFailed [catch {delete_DboOccurrenceChildrenIter $childrenIter}]
    checkTrue {fixture: deleting an iterator twice errors} $doubleDeleteFailed

    set design [fx::makeDesign $root {}]
    check {fixture: design GetRootOccurrence} [$design GetRootOccurrence $st] $root
    set netsIter [$design NewFlatNetsIter $st]
    check {fixture: empty flat-nets iterator exhausts immediately} \
        [$netsIter NextFlatNet $st] NULL
    delete_DboDesignFlatNetsIter $netsIter

    set port [fx::makePortOccurrence IN]
    set portNameC [DboTclHelper_sMakeCString]
    $port GetName $portNameC
    check {fixture: port occurrence name} [DboTclHelper_sGetConstCharPtr $portNameC] IN

    set netOcc [fx::makeNetOccurrence]
    set net [fx::makeFlatNet N1 [list $port] [list $netOcc]]
    set netNameC [DboTclHelper_sMakeCString]
    $net GetName $netNameC
    check {fixture: flat net name} [DboTclHelper_sGetConstCharPtr $netNameC] N1
    set portsIter [$net NewPortOccurrencesIter $st $::IterDefs_PRIMITIVES]
    check {fixture: net port iterator yields the port} \
        [$portsIter NextPortOccurrence $st] $port
    delete_DboFlatNetPortOccurrencesIter $portsIter
    set netOccIter [$net NewNetOccurrencesIter]
    check {fixture: net-occurrence iterator yields the net occurrence} \
        [$netOccIter NextNetOccurrence $st] $netOcc
    checkTrue {fixture: a net occurrence rejects any method call} \
        [catch {$netOcc GetName {}}]
    delete_DboFlatNetNetOccurrencesIter $netOccIter

    # Selection-family object: DRAWN_INSTANCE/PLACED_INSTANCE, not
    # PART_INSTANCE, and no downcast at all -- refdes comes from the
    # base-class property "Part Reference", not a type-specific GetReference.
    set part [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE C5 100nF]
    check {fixture: DboBaseObject_GetObjectType on a selection object} \
        [DboBaseObject_GetObjectType $part] $::DboBaseObject_DRAWN_INSTANCE
    set selRefNameC [DboTclHelper_sMakeCString {Part Reference}]
    set selRefC [DboTclHelper_sMakeCString]
    $part GetEffectivePropStringValue $selRefNameC $selRefC
    check {fixture: selection Part Reference read} \
        [DboTclHelper_sGetConstCharPtr $selRefC] C5

    set ::fx::selectionObjectsList [list $part]
    check {fixture: GetSelectedObjects returns what was given} \
        [GetSelectedObjects] [list $part]

    set ::fx::activeDesign $design
    check {fixture: GetActivePMDesign returns the active design} [GetActivePMDesign] $design

    checkTrue {fixture: wrong-typed downcast is caught, not silently accepted} \
        [catch {DboOccurrenceToDboInstOccurrence $part}]
    check {fixture: wrong-typed occurrence downcast is counted} \
        $::fx::unsafeInstOccurrenceDowncasts 1

    $st -delete

    if {!$::fail} {
        puts {PASS: fixture}
    }
}

proc fx::buildDuplicateC3Tree {} {
    # root -> U1 -> {R1, C3} and root -> U2 -> {C3}: two components share
    # the refdes C3 under different hierarchical blocks. U1/U2 are blocks
    # (IsPrimitive == 0), not components, so list_components.tcl must not
    # print them, and get_component_value.tcl must report C3 as
    # COMPONENT_NOT_UNIQUE.
    set r1 [fx::makeOccurrence R1 10k /U1/R1 {}]
    set c3u1 [fx::makeOccurrence C3 100nF /U1/C3 {}]
    set u1 [fx::makeOccurrence {} {} /U1 [list $r1 $c3u1] 0]
    set c3u2 [fx::makeOccurrence C3 1uF /U2/C3 {}]
    set u2 [fx::makeOccurrence {} {} /U2 [list $c3u2] 0]
    set root [fx::makeOccurrence {} {} / [list $u1 $u2] 0]
    return [list $root $r1 $c3u1 $c3u2]
}

proc suite_no_design {} {
    fx::resetAll
    # Real Capture returns the string NULL from GetActivePMDesign when no
    # design is open. Without a guard the examples hand that to a Dbo call
    # and the operator gets "invalid command name NULL" instead of being
    # told the actual problem.
    set ::fx::activeDesign NULL
    foreach name {list_components.tcl get_component_value.tcl
                  set_component_value.tcl extract_topology.tcl} {
        lassign [fx::runExample $name] code message output
        check "$name fails when no design is open" $code 1
        checkTrue "$name says no design is open, not something cryptic" \
            [expr {[string first {NO_ACTIVE_DESIGN} $message] >= 0}]
        check "$name produces no output when no design is open" $output {}
    }
    if {!$::fail} {
        puts {PASS: no-design}
    }
}

proc suite_occurrence {} {
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] root r1 c3u1 c3u2
    set ::fx::activeDesign [fx::makeDesign $root {}]

    lassign [fx::runExample list_components.tcl] code message output
    check {list_components.tcl runs without error} $code 0
    check {list_components.tcl visits components depth-first} $output [list \
        [dict create refdes R1 value 10k path /U1/R1] \
        [dict create refdes C3 value 100nF path /U1/C3] \
        [dict create refdes C3 value 1uF path /U2/C3]]
    # Every occurrence in the tree (root, U1, U2, R1, C3, C3 = 6 nodes)
    # opens exactly one children iterator, whether or not it has children.
    check {list_components.tcl frees every children iterator exactly once} \
        $::fx::iterDeleteCalls 6
    check {list_components.tcl never mutates the design} $::fx::setPropCalls 0
    check {list_components.tcl never attempts an unsafe downcast} \
        $::fx::unsafeInstOccurrenceDowncasts 0

    # Testing the NULL sentinel before the status is what stops a *finished*
    # iterator (which reports error 1022) from looking like a failure. It
    # must not turn into "never check the step's status": a genuine iterator
    # error, one that reports failure while still handing back a real
    # handle, still has to surface.
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] root r1 c3u1 c3u2
    set ::fx::activeDesign [fx::makeDesign $root {}]
    set ::fx::iterFailAllWith [list 77 {forced iterator failure}]
    lassign [fx::runExample list_components.tcl] code message output
    check {a real iterator error still fails the walk} $code 1
    checkTrue {a real iterator error reports its own message} \
        [expr {[string first {forced iterator failure} $message] >= 0}]
    unset ::fx::iterFailAllWith

    # get_component_value.tcl hardcodes `set targetRefdes C3` at the top of
    # the script, so the three cases below vary the fixture instead of the
    # target: a tree with two C3s, one C3, and zero C3s.
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] root r1 c3u1 c3u2
    set ::fx::activeDesign [fx::makeDesign $root {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    checkTrue {get_component_value.tcl errors on a duplicate refdes} [expr {$code != 0}]
    checkTrue {get_component_value.tcl duplicate error says COMPONENT_NOT_UNIQUE} \
        [expr {[string first COMPONENT_NOT_UNIQUE $message] >= 0}]
    check {get_component_value.tcl does not mutate on a duplicate match} \
        $::fx::setPropCalls 0

    fx::resetAll
    set r1only [fx::makeOccurrence R1 10k /U1/R1 {}]
    set u1only [fx::makeOccurrence {} {} /U1 [list $r1only] 0]
    set c3only [fx::makeOccurrence C3 1uF /U2/C3 {}]
    set u2only [fx::makeOccurrence {} {} /U2 [list $c3only] 0]
    set rootUnique [fx::makeOccurrence {} {} / [list $u1only $u2only] 0]
    set ::fx::activeDesign [fx::makeDesign $rootUnique {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    check {get_component_value.tcl succeeds on a unique refdes} $code 0
    check {get_component_value.tcl prints refdes/value/path for the unique match} \
        $output [list [dict create refdes C3 value 1uF path /U2/C3]]

    fx::resetAll
    set r1none [fx::makeOccurrence R1 10k /U1/R1 {}]
    set u1none [fx::makeOccurrence {} {} /U1 [list $r1none] 0]
    set r2none [fx::makeOccurrence R2 4k7 /U2/R2 {}]
    set u2none [fx::makeOccurrence {} {} /U2 [list $r2none] 0]
    set rootNone [fx::makeOccurrence {} {} / [list $u1none $u2none] 0]
    set ::fx::activeDesign [fx::makeDesign $rootNone {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    checkTrue {get_component_value.tcl errors when nothing matches} [expr {$code != 0}]
    checkTrue {get_component_value.tcl no-match error says COMPONENT_NOT_FOUND} \
        [expr {[string first COMPONENT_NOT_FOUND $message] >= 0}]
    check {get_component_value.tcl does not mutate when nothing matches} \
        $::fx::setPropCalls 0

    if {!$::fail} {
        puts {PASS: occurrence}
    }
}

proc suite_selection {} {
    fx::resetAll

    # Two components (one selected twice as the same object, proving dedup
    # does not depend on refdes string equality alone) -- one reporting
    # DRAWN_INSTANCE, the other PLACED_INSTANCE, to prove the filter accepts
    # both, per capRotate.tcl's "12 || 13" check. A PART_INSTANCE (11)
    # object is included too: it must now be *excluded*, the opposite of an
    # earlier draft's (wrong) assumption that PART_INSTANCE was the
    # component type. Refdes values are chosen out of sorted order so the
    # test also exercises the final sort.
    set r2 [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R2 4k7]
    set c5 [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE C5 100nF]
    set notComponent [fx::makeSelObject $::DboBaseObject_PART_INSTANCE X1 {}]
    set ::fx::selectionObjectsList [list $c5 $r2 $r2 $notComponent]

    lassign [fx::runExample selected_refs.tcl] code message output
    check {selected_refs.tcl runs without error} $code 0
    check {selected_refs.tcl accepts DRAWN_INSTANCE/PLACED_INSTANCE, excludes PART_INSTANCE, dedupes and sorts} \
        $output {C5 R2}
    check {selected_refs.tcl never mutates the design} $::fx::setPropCalls 0

    if {!$::fail} {
        puts {PASS: selection}
    }
}

proc fx::countOpenNetOccIters {} {
    set openIters {}
    foreach iterHandle [array names ::fx::iterKind] {
        if {$::fx::iterKind($iterHandle) eq {netOccs} && $::fx::iterAlive($iterHandle)} {
            lappend openIters $iterHandle
        }
    }
    return [llength $openIters]
}

proc suite_topology {} {
    fx::resetAll

    set r1Pin [fx::makePortOccurrence R1/1 1 A]
    set u1Pin [fx::makePortOccurrence U1/3 3 IN]
    set n1 [fx::makeFlatNet N1 [list $r1Pin $u1Pin] {}]
    set root [fx::makeOccurrence {} {} / {} 0]
    set ::fx::activeDesign [fx::makeDesign $root [list $n1]]

    lassign [fx::runExample extract_topology.tcl] code message output
    check {extract_topology.tcl runs without error} $code 0
    check {extract_topology.tcl prints component-pin endpoints} $output [list         [dict create net N1]         [dict create net N1 refdes R1 pin 1 pinName A path R1/1]         [dict create net N1 refdes U1 pin 3 pinName IN path U1/3]]
    check {extract_topology.tcl frees every iterator exactly once}         $::fx::iterDeleteCalls 2
    check {extract_topology.tcl never mutates the design} $::fx::setPropCalls 0

    if {!$::fail} {
        puts {PASS: topology}
    }
}

proc fx::buildUniqueValueCollisionTree {} {
    # R1 and C3 share a Value ("10k") but have different refdes. Only C3 is
    # the write target, so a naive "find by value" implementation would
    # wrongly touch R1 too; this tree exists to catch that mistake.
    set r1 [fx::makeOccurrence R1 10k /U1/R1 {}]
    set u1 [fx::makeOccurrence {} {} /U1 [list $r1] 0]
    set c3 [fx::makeOccurrence C3 10k /U2/C3 {}]
    set u2 [fx::makeOccurrence {} {} /U2 [list $c3] 0]
    set root [fx::makeOccurrence {} {} / [list $u1 $u2] 0]
    return [list $root $r1 $c3]
}

proc fx::buildStubbornTargetTree {} {
    # C3's SetEffectivePropStringValue status comes back OK but the write
    # does not stick -- set_component_value.tcl must notice the mismatched
    # read-back and error instead of reporting success.
    set c3 [fx::makeStubbornOccurrence C3 10k /U1/C3 {}]
    set u1 [fx::makeOccurrence {} {} /U1 [list $c3] 0]
    set root [fx::makeOccurrence {} {} / [list $u1] 0]
    return [list $root $c3]
}

proc suite_write {} {
    # -- set_component_value.tcl ------------------------------------------

    # Unique match, with a same-valued sibling under a different refdes:
    # only the target occurrence changes.
    fx::resetAll
    lassign [fx::buildUniqueValueCollisionTree] root r1 c3
    set ::fx::activeDesign [fx::makeDesign $root {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    check {set_component_value.tcl succeeds on a unique refdes} $code 0
    check {set_component_value.tcl prints refdes/before/after} \
        $output [list [dict create refdes C3 before 10k after 100nF]]
    check {set_component_value.tcl mutates exactly one occurrence} \
        $::fx::setPropCalls 1
    check {set_component_value.tcl leaves the target changed} $::fx::occValue($c3) 100nF
    check {set_component_value.tcl leaves the same-value sibling untouched} \
        $::fx::occValue($r1) 10k

    # Duplicate matches: zero writes, error names COMPONENT_NOT_UNIQUE.
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] rootDup r1Dup c3u1Dup c3u2Dup
    set ::fx::activeDesign [fx::makeDesign $rootDup {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors on a duplicate refdes} [expr {$code != 0}]
    checkTrue {set_component_value.tcl duplicate error says COMPONENT_NOT_UNIQUE} \
        [expr {[string first COMPONENT_NOT_UNIQUE $message] >= 0}]
    check {set_component_value.tcl does not write on a duplicate match} \
        $::fx::setPropCalls 0

    # Zero matches: zero writes, error names COMPONENT_NOT_FOUND.
    fx::resetAll
    set r1None [fx::makeOccurrence R1 10k /U1/R1 {}]
    set u1None [fx::makeOccurrence {} {} /U1 [list $r1None] 0]
    set rootNone [fx::makeOccurrence {} {} / [list $u1None] 0]
    set ::fx::activeDesign [fx::makeDesign $rootNone {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors when nothing matches} [expr {$code != 0}]
    checkTrue {set_component_value.tcl no-match error says COMPONENT_NOT_FOUND} \
        [expr {[string first COMPONENT_NOT_FOUND $message] >= 0}]
    check {set_component_value.tcl does not write when nothing matches} \
        $::fx::setPropCalls 0

    # A write Capture accepts but that does not take must be caught by the
    # read-back check, not reported as success.
    fx::resetAll
    lassign [fx::buildStubbornTargetTree] rootStubborn c3Stubborn
    set ::fx::activeDesign [fx::makeDesign $rootStubborn {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors when the read-back does not match} \
        [expr {$code != 0}]
    check {set_component_value.tcl still attempted the write once} \
        $::fx::setPropCalls 1

    # A DboState that comes back not-OK must stop the script with a clear
    # error, not press on with a null/garbage handle.
    fx::resetAll
    lassign [fx::buildUniqueValueCollisionTree] rootFail r1Fail c3Fail
    set ::fx::activeDesign [fx::makeDesign $rootFail {}]
    fx::forceOccFail $c3Fail SetEffectivePropStringValue
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors when SetEffectivePropStringValue status is not OK} \
        [expr {$code != 0}]
    checkTrue {set_component_value.tcl reports a DBO_CALL_FAILED-style message} \
        [expr {[string first DBO_CALL_FAILED $message] >= 0}]
    # The regression this guards: Message is a CString out-parameter, not a
    # plain return value. Writing [$st Message] directly would make this
    # very error path throw its own Tcl arity error instead, so the
    # forced-failure's actual message text ("forced failure:
    # SetEffectivePropStringValue") would never reach here at all -- it
    # would be replaced by a confusing "wrong # args" complaint about
    # Message itself. Asserting the real text is present is the only way
    # to catch that class of bug, since it only ever fires on the failure
    # path.
    checkTrue {set_component_value.tcl's error carries the real status message text, not a masked arity error} \
        [expr {[string first {forced failure: SetEffectivePropStringValue} $message] >= 0}]
    checkTrue {set_component_value.tcl's error is not a masked Message arity error} \
        [expr {[string first {wrong # args} $message] < 0}]

    # -- mark_selected_suffix.tcl -------------------------------------------

    fx::resetAll
    set markA [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R1 10k]
    set markB [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE R2 22k*]
    set markNotComponent [fx::makeSelObject $::DboBaseObject_PART_INSTANCE X1 {}]
    set ::fx::selectionObjectsList [list $markA $markA $markB $markNotComponent]

    lassign [fx::runExample mark_selected_suffix.tcl] code message output
    check {mark_selected_suffix.tcl runs without error} $code 0
    check {mark_selected_suffix.tcl marks the unmarked component once} \
        [lindex $output 0] [dict create refdes R1 before 10k after 10k*]
    check {mark_selected_suffix.tcl reports changed/skipped} \
        [lindex $output 1] [dict create changed 1 skipped 1]
    check {mark_selected_suffix.tcl dedupes a doubly-selected object} \
        $::fx::setPropCalls 1
    check {mark_selected_suffix.tcl leaves an already-marked value alone} \
        $::fx::selProps($markB,Value) 22k*

    # Idempotency: a second run over the same (now-marked) selection must
    # not stack a second suffix on top of the first.
    lassign [fx::runExample mark_selected_suffix.tcl] code2 message2 output2
    check {mark_selected_suffix.tcl re-run makes no further writes} \
        $::fx::setPropCalls 1
    check {mark_selected_suffix.tcl re-run reports nothing changed} \
        [lindex $output2 0] [dict create changed 0 skipped 2]
    check {mark_selected_suffix.tcl re-run does not produce a double suffix} \
        $::fx::selProps($markA,Value) 10k*

    # -- remove_selected_suffix.tcl -----------------------------------------

    fx::resetAll
    set rmMarked [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R3 10k*]
    set rmMid [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R4 1*0k]
    set rmPlain [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE R5 4k7]
    set rmNotComponent [fx::makeSelObject $::DboBaseObject_PART_INSTANCE X1 {}]
    set ::fx::selectionObjectsList \
        [list $rmMarked $rmMarked $rmMid $rmPlain $rmNotComponent]

    lassign [fx::runExample remove_selected_suffix.tcl] code3 message3 output3
    check {remove_selected_suffix.tcl runs without error} $code3 0
    check {remove_selected_suffix.tcl strips exactly one trailing suffix} \
        [lindex $output3 0] [dict create refdes R3 before 10k* after 10k]
    check {remove_selected_suffix.tcl reports changed/skipped} \
        [lindex $output3 1] [dict create changed 1 skipped 2]
    check {remove_selected_suffix.tcl dedupes a doubly-selected object} \
        $::fx::setPropCalls 1
    check {remove_selected_suffix.tcl leaves a mid-string suffix alone} \
        $::fx::selProps($rmMid,Value) 1*0k
    check {remove_selected_suffix.tcl leaves an unsuffixed value alone} \
        $::fx::selProps($rmPlain,Value) 4k7

    # -- shared write-suite safety net --------------------------------------

    checkTrue {write suite never calls RefreshParts} [expr {$::fx::refreshPartsCalls == 0}]
    checkTrue {write suite never saves the design} [expr {$::fx::designSaveCalls == 0}]

    if {!$::fail} {
        puts {PASS: write}
    }
}

# Suite dedicated to the two safety rules every example must honour:
#   1. a not-OK DboState fails the script loudly instead of dereferencing a
#      null/garbage handle;
#   2. a handle of the wrong concrete type is rejected by the example's own
#      DboBaseObject_GetObjectType check before it ever reaches the one
#      checked downcast this project still performs
#      (DboOccurrenceToDboInstOccurrence, for the occurrence family) --
#      reaching it with a bad handle is exactly the crash this project is
#      trying to prevent, so every occurrence-walk case below asserts
#      ::fx::unsafeInstOccurrenceDowncasts stays at 0. Selection scripts
#      have no downcast to guard (see the comment above fx::makeSelObject),
#      so their safety case below instead proves a wrong-family object is
#      filtered out by DboBaseObject_GetObjectType before any base-class
#      property call is even attempted on it.
proc suite_safety {} {
    # -- occurrence-walk examples: a wrongly-typed child in the hierarchy --

    foreach exampleName {list_components.tcl get_component_value.tcl set_component_value.tcl} {
        fx::resetAll
        set r1 [fx::makeOccurrence R1 10k /U1/R1 {}]
        # A selection-family handle masquerading as a child occurrence:
        # DboBaseObject_GetObjectType reports DRAWN_INSTANCE, not
        # INST_OCCURRENCE, so a correct walker must refuse it before ever
        # calling DboOccurrenceToDboInstOccurrence.
        set badChild [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE BAD bad]
        set root [fx::makeOccurrence {} {} / [list $r1 $badChild] 0]
        set ::fx::activeDesign [fx::makeDesign $root {}]
        lassign [fx::runExample $exampleName] code message output
        checkTrue "$exampleName refuses a wrong-typed occurrence child" \
            [expr {$code != 0}]
        check "$exampleName never reaches the unsafe occurrence downcast" \
            $::fx::unsafeInstOccurrenceDowncasts 0
        checkTrue "$exampleName reports the type mismatch, not a raw crash message" \
            [expr {[string first UNEXPECTED_OBJECT_TYPE $message] >= 0}]
    }

    # -- occurrence-walk examples: a DboState that comes back not-OK -------
    #
    # Also the end-to-end regression test for the Message-out-param bug:
    # Message is a CString out-parameter, not a plain return value, so
    # writing [$st Message] directly (an earlier draft of every example did)
    # makes the error-reporting path itself throw a Tcl arity error the
    # instant a real Dbo call fails -- the actual diagnostic ("forced
    # failure: GetReference") never reaches the caller, replaced by a
    # confusing "wrong # args" complaint about Message. Only a failing-status
    # run exercises this at all, which is exactly why no happy-path test
    # caught it. Asserting the real message text is present, and that no
    # "wrong # args" text leaked through instead, is the regression test.

    foreach exampleName {list_components.tcl get_component_value.tcl} {
        fx::resetAll
        set r1 [fx::makeOccurrence R1 10k /U1/R1 {}]
        set root [fx::makeOccurrence {} {} / [list $r1] 0]
        fx::forceOccFail $r1 GetReference
        set ::fx::activeDesign [fx::makeDesign $root {}]
        lassign [fx::runExample $exampleName] code message output
        checkTrue "$exampleName errors when GetReference status is not OK" \
            [expr {$code != 0}]
        checkTrue "$exampleName reports a DBO_CALL_FAILED-style message" \
            [expr {[string first DBO_CALL_FAILED $message] >= 0}]
        checkTrue "$exampleName's error carries the real status message text, not a masked arity error" \
            [expr {[string first {forced failure: GetReference} $message] >= 0}]
        checkTrue "$exampleName's error is not a masked Message arity error" \
            [expr {[string first {wrong # args} $message] < 0}]
    }

    # -- occurrence-walk examples: NewChildrenIter itself comes back not-OK

    fx::resetAll
    set root [fx::makeOccurrence {} {} / {} 0]
    fx::forceOccFail $root NewChildrenIter
    set ::fx::activeDesign [fx::makeDesign $root {}]
    lassign [fx::runExample list_components.tcl] code message output
    checkTrue {list_components.tcl errors when NewChildrenIter status is not OK} \
        [expr {$code != 0}]
    checkTrue {list_components.tcl's error carries the real status message text, not a masked arity error} \
        [expr {[string first {forced failure: NewChildrenIter} $message] >= 0}]
    checkTrue {list_components.tcl does not press on with a bogus iterator handle} \
        [expr {[string first DBO_CALL_FAILED $message] >= 0}]

    # -- selection examples: a handle from the wrong object family ---------
    #
    # An occurrence-family handle sneaking into a selection list: real
    # Capture never hands one back from GetSelectedObjects, but a correct
    # example must still check DboBaseObject_GetObjectType (INST_OCCURRENCE
    # is neither DRAWN_INSTANCE nor PLACED_INSTANCE) and skip it, rather
    # than assuming every selected object is a component. If the filter did
    # not run, the next line would call GetEffectivePropStringValue("Part
    # Reference") on an occurrence handle, which the fixture's occDispatch
    # only recognises "Value" for -- so an unfiltered object surfaces here
    # as an uncontrolled "unsupported property" error, not a clean run.

    foreach exampleName {selected_refs.tcl mark_selected_suffix.tcl remove_selected_suffix.tcl} {
        fx::resetAll
        set r1 [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R1 10k]
        set badSelObj [fx::makeOccurrence BAD bad /BAD {}]
        set ::fx::selectionObjectsList [list $r1 $badSelObj]
        lassign [fx::runExample $exampleName] code message output
        checkTrue "$exampleName filters out a wrong-family selection handle instead of erroring on it" \
            [expr {$code == 0}]
    }

    if {!$::fail} {
        puts {PASS: safety}
    }
}

# --- driver ----------------------------------------------------------------

set allSuites {fixture occurrence selection topology write safety no-design}
set requestedSuite {}
if {[llength $argv] >= 1} {
    set requestedSuite [lindex $argv 0]
}

if {$requestedSuite eq {}} {
    set suitesToRun $allSuites
} elseif {[lsearch -exact $allSuites $requestedSuite] >= 0} {
    set suitesToRun [list $requestedSuite]
} else {
    puts stderr "unknown suite \"$requestedSuite\"; expected one of: $allSuites"
    exit 2
}

foreach suiteName $suitesToRun {
    switch -exact -- $suiteName {
        fixture    { suite_fixture }
        occurrence { suite_occurrence }
        selection  { suite_selection }
        topology   { suite_topology }
        write      { suite_write }
        safety     { suite_safety }
        no-design  { suite_no_design }
    }
}

if {$::fail} {
    puts stderr {SOME TESTS FAILED}
    exit 1
}
puts {PASS: capture AI bridge examples}
