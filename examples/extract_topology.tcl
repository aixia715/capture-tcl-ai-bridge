# Flat-net topology of the active design: for every net, its name, the
# hierarchical ports connected to it, and how many net occurrences (the
# flat net's equivalent of pin-level connections -- there is no pin API on
# a flat net at all) it has.
#
# Self-contained and read-only: walks the design's flat-net view directly
# (NewFlatNetsIter) rather than any TCLBOM net-walking helper. A flat net
# collapses hierarchy, so a single N1 here may connect a pin inside one
# hierarchical block to a pin inside another -- the hierarchical ports on a
# net are exactly the boundary crossings that made that possible. Every
# iterator this script opens (nets, ports, net occurrences) is freed
# exactly once, even when a later net is never reached because there are
# no more nets left to enumerate.
#
# docs/capture-dbo-api-notes.md confirms there is no NewPinOccurrencesIter
# on DboFlatNet -- info commands *PinOccurrence* is completely empty on
# real Capture -- and that NewNetOccurrencesIter/NextNetOccurrence are the
# replacement, with delete_DboFlatNetNetOccurrencesIter to free the
# iterator. All three are confirmed to exist on real Capture.
#
# Note the two iterator constructors do NOT take the same arguments:
# NewPortOccurrencesIter is "self status mode", NewNetOccurrencesIter is
# "self" and rejects any argument at all. Sibling methods on one class are
# not safe to write alike.
#
# What is still NOT confirmed is what fields a net occurrence itself
# exposes -- refdes, pin name, pin number, owning component: none of it
# verified. Guessing a type-specific method name is a crash risk, because
# a wrong call on a real object does not raise a Tcl error, it takes
# Capture down. So this script stops at counting how many net occurrences
# a net has and never calls a method on a net-occurrence handle. To go
# further, probe first:
#   catch {DboNetOccurrence_GetName} probeResult   ;# zero args: safe
# and read the signature out of the SWIG error before calling anything.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately.
#   2. GetName (on both a flat net and a port occurrence) is a
#      DboBaseObject method -- safe on any handle, no downcast needed -- so
#      this script performs no downcast at all; nothing here reaches a
#      type-specific method.

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

# Frees a DboFlatNetNetOccurrencesIter if (and only if) the conventional
# delete_<ClassName> name actually exists in this Capture session -- see
# the file header for why probing a command name is safe where probing a
# handle's type is not.

set st [DboState]
try {
    set design [GetActivePMDesign]
    set netsIter [$design NewFlatNetsIter $st]
    _requireOk $st {NewFlatNetsIter}
    try {
        while {1} {
            set net [$netsIter NextFlatNet $st]
            # A finished iterator returns NULL and at the same time sets the
            # status to error 1022 ("At normal end of iteration"), so the
            # sentinel has to be tested before the status -- checking status
            # first turns every completed walk into a reported failure.
            if {$net eq {NULL}} { break }
            _requireOk $st {NextFlatNet}

            set netName [_stringOut $net GetName {GetName(net)}]
            puts [dict create net $netName]

            set portsIter [$net NewPortOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewPortOccurrencesIter}
            try {
                while {1} {
                    set port [$portsIter NextPortOccurrence $st]
                    # A finished iterator returns NULL and at the same time sets the
                    # status to error 1022 ("At normal end of iteration"), so the
                    # sentinel has to be tested before the status -- checking status
                    # first turns every completed walk into a reported failure.
                    if {$port eq {NULL}} { break }
                    _requireOk $st {NextPortOccurrence}
                    set portName [_stringOut $port GetName {GetName(port)}]
                    puts [dict create net $netName port $portName]
                }
            } finally {
                delete_DboFlatNetPortOccurrencesIter $portsIter
            }

            # Net occurrences: the confirmed pin-level equivalent. Counted,
            # not inspected -- see the file header for exactly what is and
            # is not confirmed here.
            # NewNetOccurrencesIter takes NO arguments -- confirmed
            # signature "DboFlatNet_NewNetOccurrencesIter self". Its sibling
            # NewPortOccurrencesIter above does take a status and an
            # IterDefs mode, so the two cannot be written alike.
            set netOccIter [$net NewNetOccurrencesIter]
            try {
                set netOccurrenceCount 0
                while {1} {
                    set netOcc [$netOccIter NextNetOccurrence $st]
                    # A finished iterator returns NULL and at the same time sets the
                    # status to error 1022 ("At normal end of iteration"), so the
                    # sentinel has to be tested before the status -- checking status
                    # first turns every completed walk into a reported failure.
                    if {$netOcc eq {NULL}} { break }
                    _requireOk $st {NextNetOccurrence}
                    incr netOccurrenceCount
                    # UNCONFIRMED: no field of a net occurrence (refdes,
                    # pin name, pin number, owning component) is
                    # confirmed, so nothing is read off $netOcc beyond the
                    # fact that it exists.
                }
                puts [dict create net $netName netOccurrenceCount $netOccurrenceCount]
            } finally {
                delete_DboFlatNetNetOccurrencesIter $netOccIter
            }
        }
    } finally {
        delete_DboDesignFlatNetsIter $netsIter
    }
} finally {
    $st -delete
}
