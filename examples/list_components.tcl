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

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [$st Message] (code [$st Code])"
    }
}

# Calls a Convention-A Dbo method (one C-string out-parameter, the call
# itself returns a fresh DboState) and returns the decoded string, freeing
# both the out-parameter's status and itself.
proc _stringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [$st Message] (code [$st Code])"
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
        set msg "DBO_CALL_FAILED: $what: [$st Message] (code [$st Code])"
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
            _requireOk $st {NextOccurrence}
            if {$child eq {NULL}} { break }
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
