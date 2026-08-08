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
# iterator this script *can* safely free (nets, ports) is freed exactly
# once, even when a later net is never reached because there are no more
# nets left to enumerate; see the net-occurrence iterator note below for
# the one exception.
#
# docs/capture-dbo-api-notes.md confirms there is no NewPinOccurrencesIter
# on DboFlatNet (info commands *PinOccurrence* is completely empty on real
# Capture) and that NewNetOccurrencesIter/NextNetOccurrence are the
# confirmed replacement -- an earlier draft of this script dropped the
# net-occurrence walk entirely on a (wrong) report that NextNetOccurrence
# did not exist; it does. What is still NOT confirmed is (a) the free
# function for the DboFlatNetNetOccurrencesIter this opens, and (b) what
# fields/methods a net occurrence itself exposes (refdes, pin name/number,
# owning component -- none of it verified). Guessing either is a crash
# risk (a wrong type-specific method call on a real object does not raise
# a Tcl error, it crashes Capture), not a syntax risk, so this script
# stops at counting how many net occurrences a net has -- it opens the
# iterator and steps it with the confirmed NextNetOccurrence, but never
# calls any method on a net occurrence handle and never frees the
# iterator, because the free function has zero confirmed hits anywhere.
# UNCONFIRMED -- probe on real Capture, then fold the answers in as a
# small edit right at the two "UNCONFIRMED" markers below:
#   info commands delete_DboFlatNetNetOccurrencesIter*
#   info commands DboFlatNetNetOccurrencesIter_GetKey
#   catch {$lNetOcc SomeGuessAtAMethod} probeResult
# and inspect what a SWIG wrong-number-of-args error (or success) reveals
# about the real free/field-access API before calling either for real.
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

set st [DboState]
try {
    set design [GetActivePMDesign]
    set netsIter [$design NewFlatNetsIter $st]
    _requireOk $st {NewFlatNetsIter}
    try {
        while {1} {
            set net [$netsIter NextFlatNet $st]
            _requireOk $st {NextFlatNet}
            if {$net eq {NULL}} { break }

            set netName [_stringOut $net GetName {GetName(net)}]
            puts [dict create net $netName]

            set portsIter [$net NewPortOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewPortOccurrencesIter}
            try {
                while {1} {
                    set port [$portsIter NextPortOccurrence $st]
                    _requireOk $st {NextPortOccurrence}
                    if {$port eq {NULL}} { break }
                    set portName [_stringOut $port GetName {GetName(port)}]
                    puts [dict create net $netName port $portName]
                }
            } finally {
                delete_DboFlatNetPortOccurrencesIter $portsIter
            }

            # Net occurrences: the confirmed pin-level equivalent. Counted,
            # not inspected -- see the file header for exactly what is and
            # is not confirmed here.
            set netOccIter [$net NewNetOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewNetOccurrencesIter}
            set netOccurrenceCount 0
            while {1} {
                set netOcc [$netOccIter NextNetOccurrence $st]
                _requireOk $st {NextNetOccurrence}
                if {$netOcc eq {NULL}} { break }
                incr netOccurrenceCount
                # UNCONFIRMED: no field of a net occurrence (refdes, pin
                # name, pin number, owning component) is confirmed, so
                # nothing is read off $netOcc beyond the fact that it
                # exists.
            }
            puts [dict create net $netName netOccurrenceCount $netOccurrenceCount]
            # UNCONFIRMED: the free function for $netOccIter has zero
            # confirmed hits, so it is deliberately left open rather than
            # guessed at. Once docs/capture-dbo-api-notes.md confirms it,
            # add a `finally { delete_Dbo... $netOccIter }` around the
            # while loop above, matching the ports iterator right above it.
        }
    } finally {
        delete_DboDesignFlatNetsIter $netsIter
    }
} finally {
    $st -delete
}
