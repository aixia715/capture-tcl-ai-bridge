# Flat-net topology of the active design: for every net, its name and every
# connected component pin. Each endpoint includes the annotated reference
# designator, pin number, pin name, and occurrence path.
#
# Self-contained and read-only. Every iterator is freed exactly once.
#
# Real Capture 16.6 confirms that each DboPortOccurrence supplies both the
# hierarchy-safe endpoint path (DboPortOccurrence_sGetPathName) and its
# DboPortInst (GetPortInst). The former returns values such as R377/1; the
# latter supplies GetPinNumber/GetPinName. This remains correct across
# hierarchy because it does not map through whichever page is active.
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
    if {$design eq {NULL}} {
        error "NO_ACTIVE_DESIGN: open a design in Capture before running this script"
    }
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
                    set pathC [DboPortOccurrence_sGetPathName $port $st]
                    _requireOk $st {DboPortOccurrence_sGetPathName}
                    set path [DboTclHelper_sGetConstCharPtr $pathC]
                    set pathParts [split [string trim $path /] /]
                    if {[llength $pathParts] < 2} {
                        error "INVALID_PORT_PATH: expected refdes/pin, got \"$path\""
                    }
                    set refdes [lindex $pathParts end-1]

                    set portInst [$port GetPortInst $st]
                    _requireOk $st {GetPortInst}
                    if {$portInst eq {NULL}} {
                        error "NULL_PORT_INSTANCE: $path"
                    }
                    set pin [_stringOut $portInst GetPinNumber {GetPinNumber(port)}]
                    set pinName [_stringOut $portInst GetPinName {GetPinName(port)}]
                    puts [dict create net $netName refdes $refdes pin $pin pinName $pinName path $path]
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
