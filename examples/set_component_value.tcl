# Set one component's value by reference designator, after confirming the
# refdes is unique in the design.

# Edit this before sending:
set targetRefdes C3
set newValue 100nF

# Self-contained: carries its own occurrence walker and the same
# whole-design uniqueness check as get_component_value.tcl, because
# writing a value to the wrong occurrence -- one of several sharing a
# refdes -- would be worse than refusing to write at all. Never forces a
# part-values refresh and never saves the design; the caller decides
# when, and whether, to save.

proc _findComponentByRefdes {occurrence targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    if {[$occurrence GetObjectType] eq {occDbComponent} &&
        [$occurrence GetReference] eq $targetRefdes} {
        lappend matches $occurrence
    }

    set childrenIter [$occurrence NewChildrenIter]
    try {
        while {1} {
            set child [$childrenIter Next]
            if {$child eq {}} { break }
            _findComponentByRefdes $child $targetRefdes matches
        }
    } finally {
        $childrenIter delete
    }
}

set design [GetActivePMDesign]
set matches {}
_findComponentByRefdes [$design GetRootOccurrence] $targetRefdes matches

set matchCount [llength $matches]
if {$matchCount == 0} {
    error "COMPONENT_NOT_FOUND: no component with reference designator \"$targetRefdes\""
}
if {$matchCount > 1} {
    error "COMPONENT_NOT_UNIQUE: $matchCount components with reference designator \"$targetRefdes\" -- disambiguate by hierarchical path"
}

set targetOccurrence [lindex $matches 0]
set before [$targetOccurrence GetPartValue]
$targetOccurrence SetPartValue $newValue
set after [$targetOccurrence GetPartValue]
if {$after ne $newValue} {
    error "VALUE_WRITE_FAILED: readback \"$after\" does not match requested \"$newValue\" for $targetRefdes"
}
puts [dict create refdes $targetRefdes before $before after $after]
