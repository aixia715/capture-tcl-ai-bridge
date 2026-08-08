# Reference designators of the components in the current selection.
#
# Self-contained and read-only: filters the current selection down to
# component instances (dropping wires and other non-component page
# objects), maps each surviving instance to its reference designator, and
# prints the deduplicated, sorted list -- one refdes per line. Selecting
# the same instance twice, or several instances that happen to share a
# refdes, must not produce a duplicate line.
#
# Selection objects are a different object family from occurrence objects
# (see list_components.tcl for that family): GetSelectedObjects hands back
# page-level instances, and a component placed on a page reports
# DRAWN_INSTANCE or PLACED_INSTANCE -- *not* PART_INSTANCE, despite the
# name; capRotate.tcl and capPSpiceSourceApp.tcl both check "12 || 13".
# There is no type-specific GetReference on these objects and no
# DboObjectToDboPartInstance downcast -- refdes is read the same way any
# other property is, through the DboBaseObject method
# GetEffectivePropStringValue with the property name "Part Reference". That
# means no downcast, and no crash risk, on this path at all: the type check
# below exists to correctly select components, not to guard against a
# type-specific call.

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

set refdesList {}
foreach obj [GetSelectedObjects] {
    set objType [DboBaseObject_GetObjectType $obj]
    if {$objType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    lappend refdesList [_getEffectiveProp $obj {Part Reference} {GetEffectivePropStringValue(Part Reference)}]
}

foreach refdes [lsort -unique $refdesList] {
    puts $refdes
}
