# Look up one component's value and hierarchical path by reference
# designator.

# Edit this before sending:
set targetRefdes C3

# Self-contained and read-only: carries its own occurrence walker (see
# list_components.tcl for the sibling script that lists everything instead
# of one refdes) because a schematic can legally contain more than one
# occurrence with the same reference designator -- e.g. two components
# under different hierarchical blocks that happen to share a refdes -- and
# the caller needs to know that before trusting a value.

proc _findComponentByRefdes {occurrence targetRefdes matchesVar} {
    upvar 1 $matchesVar matches

    if {[$occurrence GetObjectType] eq {occDbComponent} &&
        [$occurrence GetReference] eq $targetRefdes} {
        lappend matches [list \
            [$occurrence GetReference] \
            [$occurrence GetPartValue] \
            [$occurrence GetPath]]
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

lassign [lindex $matches 0] refdes value hierarchyPath
puts [dict create refdes $refdes value $value path $hierarchyPath]
