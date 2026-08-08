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
# on DboFlatNet (info commands *PinOccurrence* is completely empty on real
# Capture) and that NewNetOccurrencesIter/NextNetOccurrence are the
# confirmed replacement -- an earlier draft of this script dropped the
# net-occurrence walk entirely on a (wrong) report that NextNetOccurrence
# did not exist; it does. What is still NOT confirmed is what
# fields/methods a net occurrence itself exposes (refdes, pin name/number,
# owning component -- none of it verified): guessing a type-specific
# method name is a crash risk (a wrong type-specific method call on a real
# object does not raise a Tcl error, it crashes Capture), so this script
# stops at counting how many net occurrences a net has, never calling any
# method on a net occurrence handle.
#
# The free function for the DboFlatNetNetOccurrencesIter this opens is
# also not confirmed by name, but freeing is a different risk category
# from calling a type-specific method: passing a wrongly-typed *handle* to
# a real method crashes Capture, but calling a Tcl *command name* that
# simply does not exist is an ordinary catchable error. So the
# conventional delete_<ClassName> name (every other iterator in this API
# follows it, and DboFlatNetNetOccurrencesIter is confirmed to exist as a
# class) is probed at runtime with `info commands` rather than called
# blindly -- free if present, leave open if not, either way no crash.
# UNCONFIRMED -- probe on real Capture to turn this from "probably right,
# guarded" into "confirmed, unconditional":
#   info commands delete_DboFlatNetNetOccurrencesIter
#   info commands DboFlatNetNetOccurrencesIter_GetKey
#   catch {$lNetOcc SomeGuessAtAMethod} probeResult
# and inspect what a SWIG wrong-number-of-args error (or success) reveals
# about the real field-access API before reading anything off a net
# occurrence for real.
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
proc _freeNetOccurrencesIterIfPossible {iterHandle} {
    if {[llength [info commands delete_DboFlatNetNetOccurrencesIter]] > 0} {
        delete_DboFlatNetNetOccurrencesIter $iterHandle
    }
}

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
            set netOccIter [$net NewNetOccurrencesIter $st $::IterDefs_PRIMITIVES]
            _requireOk $st {NewNetOccurrencesIter}
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
                _freeNetOccurrencesIterIfPossible $netOccIter
            }
        }
    } finally {
        delete_DboDesignFlatNetsIter $netsIter
    }
} finally {
    $st -delete
}
