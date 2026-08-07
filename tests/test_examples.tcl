# Headless tests for the standalone examples/*.tcl scripts.
#
# Run with: tclsh tests/test_examples.tcl ?suite?
# where suite is one of: fixture, occurrence, selection, topology, write.
# With no argument, every suite runs.
#
# Capture 17.4's Dbo Tcl API hands out object handles that are themselves
# Tcl commands ("$occurrence GetReference" dispatches on the value of
# $occurrence). The fixture below reproduces exactly that surface with
# plain Tcl: fx::makeHandle mints a unique command name and installs a
# forwarding proc for it, and each object's real behaviour lives in a
# per-type dispatcher proc keyed off state stored in global fx:: arrays.
#
# This file must source the repo's captureAiBridge.tcl first so the Tcl 8.4
# shims for dict/lassign/try exist exactly as they do in production --
# examples are always submitted through the bridge, never run standalone.

set repoRoot [file normalize [file join [file dirname [info script]] ..]]
set bridgeFile [file join $repoRoot captureAiBridge.tcl]
set examplesDir [file join $repoRoot examples]
source $bridgeFile

set ::fail 0

proc check {description actual expected} {
    if {$actual ne $expected} {
        puts stderr "FAIL: $description -> got '{$actual}', want '{$expected}'"
        set ::fail 1
    }
}

proc checkTrue {description value} {
    if {!$value} {
        puts stderr "FAIL: $description"
        set ::fail 1
    }
}

# --- fake Dbo fixture --------------------------------------------------

namespace eval fx {
    variable counter 0
}

# Every fake object handle forwards "$handle Method ?arg ...?" to
# [$dispatcher $handle Method {arg ...}]. The handle name is baked into the
# proc body as a literal via string map (not substituted from a variable at
# call time), so the generated proc needs no closure support -- which
# matters because this fixture must stay portable to Tcl 8.4 too.
proc fx::makeHandle {prefix dispatcher} {
    variable counter
    set handle [format {::fxobj_%s%d} $prefix [incr counter]]
    proc $handle {method args} [string map [list %DISPATCH% $dispatcher %HANDLE% $handle] {
        return [%DISPATCH% {%HANDLE%} $method $args]
    }]
    return $handle
}

proc fx::resetAll {} {
    variable counter
    set counter 0
    foreach arrayName {occRef occValue occPath occType occChildren occRejectWrite \
            iterItems iterIndex iterAlive \
            netName netPins netPorts \
            pinName pinNumber pinParent \
            portName designRoot designFlatNets \
            selectionObjects} {
        if {[array exists ::fx::$arrayName]} {
            array unset ::fx::$arrayName
        }
    }
    set ::fx::setPartValueCalls 0
    set ::fx::iterDeleteCalls 0
    set ::fx::iterDeletedHandles {}
    set ::fx::activeDesign {}
    set ::fx::activeSelection {}
    # Write-suite safety counters: the read-only Task 7 examples never
    # touch these commands and the Task 8 write examples must not either.
    set ::fx::refreshPartsCalls 0
    set ::fx::designSaveCalls 0
}
fx::resetAll

# -- generic list-backed iterator, used for children/nets/pins/ports -----

proc fx::makeListIter {items} {
    set handle [fx::makeHandle iter fx::iterDispatch]
    set ::fx::iterItems($handle) $items
    set ::fx::iterIndex($handle) 0
    set ::fx::iterAlive($handle) 1
    return $handle
}

proc fx::iterDispatch {handle method argsList} {
    switch -exact -- $method {
        Next {
            if {![info exists ::fx::iterAlive($handle)] || !$::fx::iterAlive($handle)} {
                error "fake iterator $handle: Next called after delete"
            }
            set items $::fx::iterItems($handle)
            set idx $::fx::iterIndex($handle)
            if {$idx >= [llength $items]} { return {} }
            set ::fx::iterIndex($handle) [expr {$idx + 1}]
            return [lindex $items $idx]
        }
        delete {
            if {![info exists ::fx::iterAlive($handle)] || !$::fx::iterAlive($handle)} {
                error "fake iterator $handle: delete called twice"
            }
            set ::fx::iterAlive($handle) 0
            incr ::fx::iterDeleteCalls
            lappend ::fx::iterDeletedHandles $handle
            rename $handle {}
            return {}
        }
        default { error "fake iterator: unsupported method \"$method\"" }
    }
}

# -- occurrence: design hierarchy nodes (pages/blocks and components) ----

proc fx::makeOccurrence {reference value path type children} {
    set handle [fx::makeHandle occ fx::occDispatch]
    set ::fx::occRef($handle) $reference
    set ::fx::occValue($handle) $value
    set ::fx::occPath($handle) $path
    set ::fx::occType($handle) $type
    set ::fx::occChildren($handle) $children
    return $handle
}

# A write that Capture accepts (SetPartValue returns normally) but that
# does not actually stick -- the value stays the old one. This exists so
# the write-suite examples' "read back and error if it did not take"
# behaviour has something to trip over.
proc fx::makeStubbornOccurrence {reference value path type children} {
    set handle [fx::makeOccurrence $reference $value $path $type $children]
    set ::fx::occRejectWrite($handle) 1
    return $handle
}

proc fx::occDispatch {handle method argsList} {
    switch -exact -- $method {
        GetReference    { return $::fx::occRef($handle) }
        GetPartValue    { return $::fx::occValue($handle) }
        GetPath         { return $::fx::occPath($handle) }
        GetObjectType   { return $::fx::occType($handle) }
        NewChildrenIter { return [fx::makeListIter $::fx::occChildren($handle)] }
        SetPartValue {
            incr ::fx::setPartValueCalls
            if {![info exists ::fx::occRejectWrite($handle)] || !$::fx::occRejectWrite($handle)} {
                set ::fx::occValue($handle) [lindex $argsList 0]
            }
            return {}
        }
        default { error "fake occurrence: unsupported method \"$method\"" }
    }
}

# -- pin/port occurrences on a flat net -----------------------------------

proc fx::makePinOccurrence {name number parent} {
    set handle [fx::makeHandle pin fx::pinDispatch]
    set ::fx::pinName($handle) $name
    set ::fx::pinNumber($handle) $number
    set ::fx::pinParent($handle) $parent
    return $handle
}

proc fx::pinDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName           { return $::fx::pinName($handle) }
        GetNumber         { return $::fx::pinNumber($handle) }
        GetPartOccurrence { return $::fx::pinParent($handle) }
        default { error "fake pin occurrence: unsupported method \"$method\"" }
    }
}

proc fx::makePortOccurrence {name} {
    set handle [fx::makeHandle port fx::portDispatch]
    set ::fx::portName($handle) $name
    return $handle
}

proc fx::portDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName           { return $::fx::portName($handle) }
        GetNumber         { return {} }
        GetPartOccurrence { return {} }
        default { error "fake port occurrence: unsupported method \"$method\"" }
    }
}

# -- flat net --------------------------------------------------------------

proc fx::makeFlatNet {name pins ports} {
    set handle [fx::makeHandle net fx::netDispatch]
    set ::fx::netName($handle) $name
    set ::fx::netPins($handle) $pins
    set ::fx::netPorts($handle) $ports
    return $handle
}

proc fx::netDispatch {handle method argsList} {
    switch -exact -- $method {
        GetName                 { return $::fx::netName($handle) }
        NewPinOccurrencesIter   { return [fx::makeListIter $::fx::netPins($handle)] }
        NewPortOccurrencesIter  { return [fx::makeListIter $::fx::netPorts($handle)] }
        default { error "fake flat net: unsupported method \"$method\"" }
    }
}

# -- design and selection ---------------------------------------------------

proc fx::makeDesign {root flatNets} {
    set handle [fx::makeHandle design fx::designDispatch]
    set ::fx::designRoot($handle) $root
    set ::fx::designFlatNets($handle) $flatNets
    return $handle
}

proc fx::designDispatch {handle method argsList} {
    switch -exact -- $method {
        GetRootOccurrence { return $::fx::designRoot($handle) }
        NewFlatNetsIter   { return [fx::makeListIter $::fx::designFlatNets($handle)] }
        Save {
            incr ::fx::designSaveCalls
            return {}
        }
        default { error "fake design: unsupported method \"$method\"" }
    }
}

proc fx::makeSelection {objects} {
    set handle [fx::makeHandle sel fx::selectionDispatch]
    set ::fx::selectionObjects($handle) $objects
    return $handle
}

proc fx::selectionDispatch {handle method argsList} {
    switch -exact -- $method {
        GetSelectedObjects { return $::fx::selectionObjects($handle) }
        default { error "fake selection: unsupported method \"$method\"" }
    }
}

# GetActivePMDesign/GetActivePMSelection are bare global commands in the
# real API (an example calls them unqualified, not through another
# object), so the fixture installs them at global scope too.
proc ::GetActivePMDesign {} { return $::fx::activeDesign }
proc ::GetActivePMSelection {} { return $::fx::activeSelection }

# RefreshParts and a bare Save are the two commands the write examples must
# never call (RefreshParts is a TCLBOM helper this project deliberately
# does not depend on; Save would silently commit an unreviewed edit to
# disk). Both a global Save and $design Save are wired to the same counter
# above so a script has nowhere to hide either spelling.
proc ::RefreshParts {} { incr ::fx::refreshPartsCalls; return {} }
proc ::Save {} { incr ::fx::designSaveCalls; return {} }

# --- suites --------------------------------------------------------------

# Runs an example file, capturing everything it [puts] and any error it
# raises, without ever touching the real stdout/stderr.
proc fx::runExample {name} {
    set path [file join $::examplesDir $name]
    if {![file exists $path]} {
        error "FIXTURE_MISSING_EXAMPLE: $path does not exist"
    }
    set ::fx::capturedOutput {}
    rename ::puts ::fx::realPuts
    proc ::puts {args} {
        # `puts $text` and `puts -nonewline $text` both land here; examples
        # only ever use the one-argument form, so anything else is a bug in
        # the example, not something this shim should silently accept.
        if {[llength $args] != 1} {
            error "fake puts: unsupported invocation: $args"
        }
        lappend ::fx::capturedOutput [lindex $args 0]
    }
    set code [catch {uplevel #0 [list source $path]} message]
    rename ::puts {}
    rename ::fx::realPuts ::puts
    return [list $code $message $::fx::capturedOutput]
}

proc suite_fixture {} {
    fx::resetAll

    set leaf [fx::makeOccurrence R9 10k /R9 occDbComponent {}]
    check {fixture: occurrence dispatch answers GetReference} [$leaf GetReference] R9
    check {fixture: occurrence dispatch answers GetPartValue} [$leaf GetPartValue] 10k
    check {fixture: occurrence dispatch answers GetPath} [$leaf GetPath] /R9
    check {fixture: occurrence dispatch answers GetObjectType} [$leaf GetObjectType] occDbComponent

    check {fixture: SetPartValue mutates and is counted} \
        [list [$leaf SetPartValue 22k] [$leaf GetPartValue] $::fx::setPartValueCalls] \
        [list {} 22k 1]

    set root [fx::makeOccurrence {} {} / occDbPage [list $leaf]]
    set childrenIter [$root NewChildrenIter]
    set first [$childrenIter Next]
    check {fixture: children iterator returns the child} $first $leaf
    check {fixture: children iterator exhausts to empty string} [$childrenIter Next] {}
    $childrenIter delete
    check {fixture: iterator delete is counted} $::fx::iterDeleteCalls 1
    checkTrue {fixture: deleted iterator command is gone} \
        [expr {[llength [info commands $childrenIter]] == 0}]
    set doubleDeleteFailed [catch {$childrenIter delete}]
    checkTrue {fixture: deleting an iterator twice errors} $doubleDeleteFailed

    set design [fx::makeDesign $root {}]
    check {fixture: design GetRootOccurrence} [$design GetRootOccurrence] $root
    set netsIter [$design NewFlatNetsIter]
    check {fixture: empty flat-nets iterator exhausts immediately} [$netsIter Next] {}
    $netsIter delete

    set pin [fx::makePinOccurrence A1 1 $leaf]
    check {fixture: pin occurrence name} [$pin GetName] A1
    check {fixture: pin occurrence number} [$pin GetNumber] 1
    check {fixture: pin occurrence parent} [$pin GetPartOccurrence] $leaf

    set port [fx::makePortOccurrence IN]
    check {fixture: port occurrence name} [$port GetName] IN

    set net [fx::makeFlatNet N1 [list $pin] [list $port]]
    check {fixture: flat net name} [$net GetName] N1
    set pinsIter [$net NewPinOccurrencesIter]
    check {fixture: net pin iterator yields the pin} [$pinsIter Next] $pin
    $pinsIter delete
    set portsIter [$net NewPortOccurrencesIter]
    check {fixture: net port iterator yields the port} [$portsIter Next] $port
    $portsIter delete

    set selection [fx::makeSelection [list $leaf $pin]]
    check {fixture: selection returns the objects it was given} \
        [$selection GetSelectedObjects] [list $leaf $pin]

    set ::fx::activeDesign $design
    check {fixture: GetActivePMDesign returns the active design} [GetActivePMDesign] $design
    set ::fx::activeSelection $selection
    check {fixture: GetActivePMSelection returns the active selection} \
        [GetActivePMSelection] $selection

    if {!$::fail} {
        puts {PASS: fixture}
    }
}

proc fx::buildDuplicateC3Tree {} {
    # root -> U1 -> {R1, C3} and root -> U2 -> {C3}: two components share
    # the refdes C3 under different hierarchical blocks. U1/U2 are blocks,
    # not components, so list_components.tcl must not print them, and
    # get_component_value.tcl must report C3 as COMPONENT_NOT_UNIQUE.
    set r1 [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set c3u1 [fx::makeOccurrence C3 100nF /U1/C3 occDbComponent {}]
    set u1 [fx::makeOccurrence {} {} /U1 occDbPage [list $r1 $c3u1]]
    set c3u2 [fx::makeOccurrence C3 1uF /U2/C3 occDbComponent {}]
    set u2 [fx::makeOccurrence {} {} /U2 occDbPage [list $c3u2]]
    set root [fx::makeOccurrence {} {} / occDbPage [list $u1 $u2]]
    return [list $root $r1 $c3u1 $c3u2]
}

proc suite_occurrence {} {
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] root r1 c3u1 c3u2
    set ::fx::activeDesign [fx::makeDesign $root {}]

    lassign [fx::runExample list_components.tcl] code message output
    check {list_components.tcl runs without error} $code 0
    check {list_components.tcl visits components depth-first} $output [list \
        [dict create refdes R1 value 10k path /U1/R1] \
        [dict create refdes C3 value 100nF path /U1/C3] \
        [dict create refdes C3 value 1uF path /U2/C3]]
    # Every occurrence in the tree (root, U1, U2, R1, C3, C3 = 6 nodes)
    # opens exactly one children iterator, whether or not it has children.
    check {list_components.tcl frees every children iterator exactly once} \
        $::fx::iterDeleteCalls 6
    check {list_components.tcl never mutates the design} $::fx::setPartValueCalls 0

    # get_component_value.tcl hardcodes `set targetRefdes C3` at the top of
    # the script, so the three cases below vary the fixture instead of the
    # target: a tree with two C3s, one C3, and zero C3s.
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] root r1 c3u1 c3u2
    set ::fx::activeDesign [fx::makeDesign $root {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    checkTrue {get_component_value.tcl errors on a duplicate refdes} [expr {$code != 0}]
    checkTrue {get_component_value.tcl duplicate error says COMPONENT_NOT_UNIQUE} \
        [expr {[string first COMPONENT_NOT_UNIQUE $message] >= 0}]
    check {get_component_value.tcl does not mutate on a duplicate match} \
        $::fx::setPartValueCalls 0

    fx::resetAll
    set r1only [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set u1only [fx::makeOccurrence {} {} /U1 occDbPage [list $r1only]]
    set c3only [fx::makeOccurrence C3 1uF /U2/C3 occDbComponent {}]
    set u2only [fx::makeOccurrence {} {} /U2 occDbPage [list $c3only]]
    set rootUnique [fx::makeOccurrence {} {} / occDbPage [list $u1only $u2only]]
    set ::fx::activeDesign [fx::makeDesign $rootUnique {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    check {get_component_value.tcl succeeds on a unique refdes} $code 0
    check {get_component_value.tcl prints refdes/value/path for the unique match} \
        $output [list [dict create refdes C3 value 1uF path /U2/C3]]

    fx::resetAll
    set r1none [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set u1none [fx::makeOccurrence {} {} /U1 occDbPage [list $r1none]]
    set r2none [fx::makeOccurrence R2 4k7 /U2/R2 occDbComponent {}]
    set u2none [fx::makeOccurrence {} {} /U2 occDbPage [list $r2none]]
    set rootNone [fx::makeOccurrence {} {} / occDbPage [list $u1none $u2none]]
    set ::fx::activeDesign [fx::makeDesign $rootNone {}]
    lassign [fx::runExample get_component_value.tcl] code message output
    checkTrue {get_component_value.tcl errors when nothing matches} [expr {$code != 0}]
    checkTrue {get_component_value.tcl no-match error says COMPONENT_NOT_FOUND} \
        [expr {[string first COMPONENT_NOT_FOUND $message] >= 0}]
    check {get_component_value.tcl does not mutate when nothing matches} \
        $::fx::setPartValueCalls 0

    if {!$::fail} {
        puts {PASS: occurrence}
    }
}

proc suite_selection {} {
    fx::resetAll

    # Two components (one selected twice as the same occurrence, proving
    # dedup does not depend on refdes string equality alone), one
    # non-component graphic that must be dropped, and refdes values chosen
    # out of sorted order so the test also exercises the final sort.
    set r2 [fx::makeOccurrence R2 4k7 /R2 occDbComponent {}]
    set c5 [fx::makeOccurrence C5 100nF /C5 occDbComponent {}]
    set wire [fx::makeOccurrence {} {} /wire1 occDbGraphic {}]
    set ::fx::activeSelection [fx::makeSelection [list $c5 $r2 $r2 $wire]]

    lassign [fx::runExample selected_refs.tcl] code message output
    check {selected_refs.tcl runs without error} $code 0
    check {selected_refs.tcl drops graphics, dedupes and sorts} $output {C5 R2}
    check {selected_refs.tcl never mutates the design} $::fx::setPartValueCalls 0

    if {!$::fail} {
        puts {PASS: selection}
    }
}

proc suite_topology {} {
    fx::resetAll

    # A minimal standalone net fixture -- independent of the occurrence
    # suite's hierarchy tree, since a flat net's pin occurrences only need
    # to answer GetPartOccurrence with something that answers GetReference.
    set r1 [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set u1 [fx::makeOccurrence U1 74LS04 /U1 occDbComponent {}]
    set pinR1_1 [fx::makePinOccurrence A1 1 $r1]
    set pinU1_3 [fx::makePinOccurrence D3 3 $u1]
    set portIn [fx::makePortOccurrence IN]
    set n1 [fx::makeFlatNet N1 [list $pinR1_1 $pinU1_3] [list $portIn]]
    set root [fx::makeOccurrence {} {} / occDbPage {}]
    set ::fx::activeDesign [fx::makeDesign $root [list $n1]]

    lassign [fx::runExample extract_topology.tcl] code message output
    check {extract_topology.tcl runs without error} $code 0
    check {extract_topology.tcl prints the net, its port and its pins} $output [list \
        [dict create net N1] \
        [dict create net N1 port IN] \
        [dict create net N1 refdes R1 pin 1 name A1] \
        [dict create net N1 refdes U1 pin 3 name D3]]
    # nets iterator (1) + ports iterator (1) + pins iterator (1) for the
    # single net N1, each opened and freed exactly once.
    check {extract_topology.tcl frees every iterator exactly once} \
        $::fx::iterDeleteCalls 3
    check {extract_topology.tcl never mutates the design} $::fx::setPartValueCalls 0

    if {!$::fail} {
        puts {PASS: topology}
    }
}

proc fx::buildUniqueValueCollisionTree {} {
    # R1 and C3 share a Value ("10k") but have different refdes. Only C3 is
    # the write target, so a naive "find by value" implementation would
    # wrongly touch R1 too; this tree exists to catch that mistake.
    set r1 [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set u1 [fx::makeOccurrence {} {} /U1 occDbPage [list $r1]]
    set c3 [fx::makeOccurrence C3 10k /U2/C3 occDbComponent {}]
    set u2 [fx::makeOccurrence {} {} /U2 occDbPage [list $c3]]
    set root [fx::makeOccurrence {} {} / occDbPage [list $u1 $u2]]
    return [list $root $r1 $c3]
}

proc fx::buildStubbornTargetTree {} {
    # C3's SetPartValue is accepted but silently does not stick --
    # set_component_value.tcl must notice the mismatched read-back and
    # error instead of reporting success.
    set c3 [fx::makeStubbornOccurrence C3 10k /U1/C3 occDbComponent {}]
    set u1 [fx::makeOccurrence {} {} /U1 occDbPage [list $c3]]
    set root [fx::makeOccurrence {} {} / occDbPage [list $u1]]
    return [list $root $c3]
}

proc suite_write {} {
    # -- set_component_value.tcl ------------------------------------------

    # Unique match, with a same-valued sibling under a different refdes:
    # only the target occurrence changes.
    fx::resetAll
    lassign [fx::buildUniqueValueCollisionTree] root r1 c3
    set ::fx::activeDesign [fx::makeDesign $root {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    check {set_component_value.tcl succeeds on a unique refdes} $code 0
    check {set_component_value.tcl prints refdes/before/after} \
        $output [list [dict create refdes C3 before 10k after 100nF]]
    check {set_component_value.tcl mutates exactly one occurrence} \
        $::fx::setPartValueCalls 1
    check {set_component_value.tcl leaves the target changed} [$c3 GetPartValue] 100nF
    check {set_component_value.tcl leaves the same-value sibling untouched} \
        [$r1 GetPartValue] 10k

    # Duplicate matches: zero writes, error names COMPONENT_NOT_UNIQUE.
    fx::resetAll
    lassign [fx::buildDuplicateC3Tree] rootDup r1Dup c3u1Dup c3u2Dup
    set ::fx::activeDesign [fx::makeDesign $rootDup {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors on a duplicate refdes} [expr {$code != 0}]
    checkTrue {set_component_value.tcl duplicate error says COMPONENT_NOT_UNIQUE} \
        [expr {[string first COMPONENT_NOT_UNIQUE $message] >= 0}]
    check {set_component_value.tcl does not write on a duplicate match} \
        $::fx::setPartValueCalls 0

    # Zero matches: zero writes, error names COMPONENT_NOT_FOUND.
    fx::resetAll
    set r1None [fx::makeOccurrence R1 10k /U1/R1 occDbComponent {}]
    set u1None [fx::makeOccurrence {} {} /U1 occDbPage [list $r1None]]
    set rootNone [fx::makeOccurrence {} {} / occDbPage [list $u1None]]
    set ::fx::activeDesign [fx::makeDesign $rootNone {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors when nothing matches} [expr {$code != 0}]
    checkTrue {set_component_value.tcl no-match error says COMPONENT_NOT_FOUND} \
        [expr {[string first COMPONENT_NOT_FOUND $message] >= 0}]
    check {set_component_value.tcl does not write when nothing matches} \
        $::fx::setPartValueCalls 0

    # A write Capture accepts but that does not take must be caught by the
    # read-back check, not reported as success.
    fx::resetAll
    lassign [fx::buildStubbornTargetTree] rootStubborn c3Stubborn
    set ::fx::activeDesign [fx::makeDesign $rootStubborn {}]
    lassign [fx::runExample set_component_value.tcl] code message output
    checkTrue {set_component_value.tcl errors when the read-back does not match} \
        [expr {$code != 0}]
    check {set_component_value.tcl still attempted the write once} \
        $::fx::setPartValueCalls 1

    # -- mark_selected_suffix.tcl -------------------------------------------

    fx::resetAll
    set markA [fx::makeOccurrence R1 10k /R1 occDbComponent {}]
    set markB [fx::makeOccurrence R2 22k* /R2 occDbComponent {}]
    set markGraphic [fx::makeOccurrence {} {} /wire1 occDbGraphic {}]
    set ::fx::activeSelection [fx::makeSelection [list $markA $markA $markB $markGraphic]]

    lassign [fx::runExample mark_selected_suffix.tcl] code message output
    check {mark_selected_suffix.tcl runs without error} $code 0
    check {mark_selected_suffix.tcl marks the unmarked component once} \
        [lindex $output 0] [dict create refdes R1 before 10k after 10k*]
    check {mark_selected_suffix.tcl reports changed/skipped} \
        [lindex $output 1] [dict create changed 1 skipped 1]
    check {mark_selected_suffix.tcl dedupes a doubly-selected occurrence} \
        $::fx::setPartValueCalls 1
    check {mark_selected_suffix.tcl leaves an already-marked value alone} \
        [$markB GetPartValue] 22k*

    # Idempotency: a second run over the same (now-marked) selection must
    # not stack a second suffix on top of the first.
    lassign [fx::runExample mark_selected_suffix.tcl] code2 message2 output2
    check {mark_selected_suffix.tcl re-run makes no further writes} \
        $::fx::setPartValueCalls 1
    check {mark_selected_suffix.tcl re-run reports nothing changed} \
        [lindex $output2 0] [dict create changed 0 skipped 2]
    check {mark_selected_suffix.tcl re-run does not produce a double suffix} \
        [$markA GetPartValue] 10k*

    # -- remove_selected_suffix.tcl -----------------------------------------

    fx::resetAll
    set rmMarked [fx::makeOccurrence R3 10k* /R3 occDbComponent {}]
    set rmMid [fx::makeOccurrence R4 1*0k /R4 occDbComponent {}]
    set rmPlain [fx::makeOccurrence R5 4k7 /R5 occDbComponent {}]
    set rmGraphic [fx::makeOccurrence {} {} /wire2 occDbGraphic {}]
    set ::fx::activeSelection [fx::makeSelection \
        [list $rmMarked $rmMarked $rmMid $rmPlain $rmGraphic]]

    lassign [fx::runExample remove_selected_suffix.tcl] code3 message3 output3
    check {remove_selected_suffix.tcl runs without error} $code3 0
    check {remove_selected_suffix.tcl strips exactly one trailing suffix} \
        [lindex $output3 0] [dict create refdes R3 before 10k* after 10k]
    check {remove_selected_suffix.tcl reports changed/skipped} \
        [lindex $output3 1] [dict create changed 1 skipped 2]
    check {remove_selected_suffix.tcl dedupes a doubly-selected occurrence} \
        $::fx::setPartValueCalls 1
    check {remove_selected_suffix.tcl leaves a mid-string suffix alone} \
        [$rmMid GetPartValue] 1*0k
    check {remove_selected_suffix.tcl leaves an unsuffixed value alone} \
        [$rmPlain GetPartValue] 4k7

    # -- shared write-suite safety net --------------------------------------

    checkTrue {write suite never calls RefreshParts} [expr {$::fx::refreshPartsCalls == 0}]
    checkTrue {write suite never saves the design} [expr {$::fx::designSaveCalls == 0}]

    if {!$::fail} {
        puts {PASS: write}
    }
}

# --- driver ----------------------------------------------------------------

set allSuites {fixture occurrence selection topology write}
set requestedSuite {}
if {[llength $argv] >= 1} {
    set requestedSuite [lindex $argv 0]
}

if {$requestedSuite eq {}} {
    set suitesToRun $allSuites
} elseif {[lsearch -exact $allSuites $requestedSuite] >= 0} {
    set suitesToRun [list $requestedSuite]
} else {
    puts stderr "unknown suite \"$requestedSuite\"; expected one of: $allSuites"
    exit 2
}

foreach suiteName $suitesToRun {
    switch -exact -- $suiteName {
        fixture    { suite_fixture }
        occurrence { suite_occurrence }
        selection  { suite_selection }
        topology   { suite_topology }
        write      { suite_write }
    }
}

if {$::fail} {
    puts stderr {SOME TESTS FAILED}
    exit 1
}
puts {PASS: capture AI bridge examples}
