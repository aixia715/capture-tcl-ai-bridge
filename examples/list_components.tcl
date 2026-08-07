# List every component occurrence in the active design, depth-first.
#
# Self-contained: Capture submits example scripts as-is through the bridge,
# so this script carries its own occurrence walker rather than depending on
# TCLBOM's shared depth-first-search walker helper. Read-only: it never
# writes a part value or saves the design, so it is safe to run against a
# design that is open for edit.
#
# Output: one line per component, `dict create refdes ... value ... path ...`.

proc _listComponentsWalk {occurrence} {
    if {[$occurrence GetObjectType] eq {occDbComponent}} {
        set refdes [$occurrence GetReference]
        set value [$occurrence GetPartValue]
        set hierarchyPath [$occurrence GetPath]
        puts [dict create refdes $refdes value $value path $hierarchyPath]
    }

    # Every occurrence, component or not, may have children -- a
    # hierarchical block's children are the components and blocks nested
    # inside it -- so the walker always descends and always frees the
    # iterator it opens, whether or not this node turned out to be a leaf.
    set childrenIter [$occurrence NewChildrenIter]
    try {
        while {1} {
            set child [$childrenIter Next]
            if {$child eq {}} { break }
            _listComponentsWalk $child
        }
    } finally {
        $childrenIter delete
    }
}

set design [GetActivePMDesign]
_listComponentsWalk [$design GetRootOccurrence]
