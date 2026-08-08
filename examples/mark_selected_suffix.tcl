# Append a marker suffix to the Value of every selected component -- e.g.
# flagging a batch of parts for review.

# Edit this before sending:
set suffix *

# Self-contained; never forces a part-values refresh and never saves the
# design. Idempotent: running it twice on the same selection changes
# nothing the second time, because a value that already ends with the
# suffix is skipped rather than getting a second suffix appended.
#
# Selection objects are a different object family from occurrence objects
# (see list_components.tcl for that family): GetSelectedObjects hands back
# page-level instances, and a component placed on a page reports
# DRAWN_INSTANCE or PLACED_INSTANCE -- *not* PART_INSTANCE, despite the
# name; capRotate.tcl and capPSpiceSourceApp.tcl both check "12 || 13".
# There is no type-specific GetReference/SetPartValue on these objects and
# no DboObjectToDboPartInstance downcast -- both refdes and Value are read
# and written the same way, through the DboBaseObject methods
# GetEffectivePropStringValue/SetEffectivePropStringValue with property
# names "Part Reference" and "Value". That means no downcast, and no crash
# risk, on this path at all: the type check below exists to correctly
# select components, not to guard against a type-specific call.

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

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

# Dedupe before mutating: the same instance can appear more than once in a
# selection, and each instance must be touched at most once.
set seen {}
set targets {}
foreach obj [GetSelectedObjects] {
    set objType [DboBaseObject_GetObjectType $obj]
    if {$objType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    if {[lsearch -exact $seen $obj] >= 0} {
        continue
    }
    lappend seen $obj
    lappend targets $obj
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value)}]
    if {[_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want "$before$suffix"
    _setProp $occurrence Value $want {SetEffectivePropStringValue(Value)}
    set after [_getEffectiveProp $occurrence Value {GetEffectivePropStringValue(Value) readback}]
    set refdes [_getEffectiveProp $occurrence {Part Reference} {GetEffectivePropStringValue(Part Reference)}]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for $refdes"
    }
    puts [dict create refdes $refdes before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
