# Flat-net topology of the active design: for every net, its name and the
# hierarchical ports connected to it.
#
# Self-contained and read-only: walks the design's flat-net view directly
# (NewFlatNetsIter) rather than any TCLBOM net-walking helper. A flat net
# collapses hierarchy, so a single N1 here may connect a pin inside one
# hierarchical block to a pin inside another -- the hierarchical ports on a
# net are exactly the boundary crossings that made that possible. Every
# iterator this script opens (nets, ports) is freed exactly once, even when
# a later net is never reached because there are no more nets left to
# enumerate.
#
# Deliberately does NOT walk from a net down to the component pins it
# connects. docs/capture-dbo-api-notes.md confirms there is no
# NewPinOccurrencesIter and names NewNetOccurrencesIter as the available
# alternative, but does not confirm how to step or free the iterator it
# returns, or how to get from one of its results back to the owning
# component -- an earlier draft of this script guessed NextNetOccurrence,
# delete_DboFlatNetNetOccurrencesIter and GetPartOccurrence for that, and
# all three turned out to have zero hits in Cadence's own scripts. Guessing
# a type-specific Dbo method name is not a syntax risk here, it is a crash
# risk, so this script stops at the confirmed net/port level.
# UNCONFIRMED -- probe on real Capture before extending this script:
#   set lNetOccIter [$net NewNetOccurrencesIter $st $::IterDefs_PRIMITIVES]
#   catch {$lNetOccIter SomeGuessAtANextMethod $st} probeResult
# and inspect what the SWIG wrong-number-of-args error (or success) reveals
# about the real step/free/parent-lookup API before calling it for real.
#
# Two safety rules from docs/capture-dbo-api-notes.md drive the shape below:
#   1. Every call that takes a DboState can fail, and an unchecked failure
#      hands back a null/garbage handle rather than raising a Tcl error, so
#      every such call's status is checked immediately.
#   2. GetName (on both a flat net and a port occurrence) is a
#      DboBaseObject method -- safe on any handle, no downcast needed -- so
#      this script performs no downcast at all; nothing here reaches a
#      type-specific method.

proc _requireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [$st Message] (code [$st Code])"
    }
}

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
        }
    } finally {
        delete_DboDesignFlatNetsIter $netsIter
    }
} finally {
    $st -delete
}
