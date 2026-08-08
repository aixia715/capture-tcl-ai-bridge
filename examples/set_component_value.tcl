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
            _requireOk $st {NextOccurrence}
            if {$child eq {NULL}} { break }
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
