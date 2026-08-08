# Print the annotated reference designator for each selected component.
# Read-only. Unlike selected_refs.tcl, this resolves the page instance to
# its occurrence in the active hierarchy before reading the refdes.

set parentOccurrence [GetInstanceOccurrence]
if {$parentOccurrence == "NULL"} {
    error "NO_ACTIVE_INSTANCE_OCCURRENCE"
}

set found 0
foreach object [GetSelectedObjects] {
    set objectType [DboBaseObject_GetObjectType $object]
    if {$objectType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objectType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }

    set occurrence [$object GetObjectOccurrence $parentOccurrence]
    if {$occurrence == "NULL"} {
        continue
    }

    set occurrenceType [DboBaseObject_GetObjectType $occurrence]
    if {$occurrenceType != $::DboBaseObject_INST_OCCURRENCE} {
        error "UNEXPECTED_OCCURRENCE_TYPE: $occurrenceType"
    }

    set instanceOccurrence [DboOccurrenceToDboInstOccurrence $occurrence]
    set referenceCString [DboTclHelper_sMakeCString]
    $instanceOccurrence GetReferenceDesignator $referenceCString
    puts [DboTclHelper_sGetConstCharPtr $referenceCString]
    incr found
}

if {$found == 0} {
    error "NO_SELECTED_COMPONENT_OCCURRENCE"
}
