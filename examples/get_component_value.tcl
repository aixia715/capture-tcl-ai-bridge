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
