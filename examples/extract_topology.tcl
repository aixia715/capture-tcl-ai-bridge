# Flat-net topology of the active design: for every net, its hierarchical
# ports and the component pins it connects.
#
# Self-contained and read-only: walks Capture 17.4's flat-net view directly
# (NewFlatNetsIter) rather than any TCLBOM net-walking helper. A flat net
# collapses hierarchy, so a single N1 here may connect a pin inside one
# hierarchical block to a pin inside another -- the hierarchical ports on a
# net are exactly the boundary crossings that made that possible. Every
# iterator this script opens (nets, ports, pins) is freed exactly once,
# even when a later net is never reached because there are no more nets
# left to enumerate.

set design [GetActivePMDesign]
set netsIter [$design NewFlatNetsIter]
try {
    while {1} {
        set net [$netsIter Next]
        if {$net eq {}} { break }

        set netName [$net GetName]
        puts [dict create net $netName]

        set portsIter [$net NewPortOccurrencesIter]
        try {
            while {1} {
                set port [$portsIter Next]
                if {$port eq {}} { break }
                puts [dict create net $netName port [$port GetName]]
            }
        } finally {
            $portsIter delete
        }

        set pinsIter [$net NewPinOccurrencesIter]
        try {
            while {1} {
                set pin [$pinsIter Next]
                if {$pin eq {}} { break }
                set parent [$pin GetPartOccurrence]
                puts [dict create \
                    net $netName \
                    refdes [$parent GetReference] \
                    pin [$pin GetNumber] \
                    name [$pin GetName]]
            }
        } finally {
            $pinsIter delete
        }
    }
} finally {
    $netsIter delete
}
