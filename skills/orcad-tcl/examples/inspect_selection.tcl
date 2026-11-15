# Describe every object in the current Capture selection. Read-only.

set typeCString [DboTclHelper_sMakeCString]
set nameCString [DboTclHelper_sMakeCString]
set parentOccurrence [GetInstanceOccurrence]
set selected [GetSelectedObjects]

puts "selection-count: [llength $selected]"
set index 0
foreach object $selected {
    incr index
    $object GetTypeString $typeCString
    set typeName [DboTclHelper_sGetConstCharPtr $typeCString]

    set name ""
    if {![catch {$object GetName $nameCString}]} {
        set name [DboTclHelper_sGetConstCharPtr $nameCString]
    }

    set fields [list index $index type $typeName name $name]
    set objectType [DboBaseObject_GetObjectType $object]
    if {$parentOccurrence != "NULL" &&
        ($objectType == $::DboBaseObject_DRAWN_INSTANCE ||
         $objectType == $::DboBaseObject_PLACED_INSTANCE)} {
        set occurrence [$object GetObjectOccurrence $parentOccurrence]
        if {$occurrence != "NULL" &&
            [DboBaseObject_GetObjectType $occurrence] == $::DboBaseObject_INST_OCCURRENCE} {
            set instanceOccurrence [DboOccurrenceToDboInstOccurrence $occurrence]
            set primitiveStatus [DboState]
            lappend fields primitive [$instanceOccurrence IsPrimitive $primitiveStatus]
            $primitiveStatus -delete
            set referenceCString [DboTclHelper_sMakeCString]
            $instanceOccurrence GetReferenceDesignator $referenceCString
            lappend fields refdes [DboTclHelper_sGetConstCharPtr $referenceCString]
        }
    }
    puts $fields
}
