# Read useful properties from selected component occurrences. Read-only.

proc readProp {object propertyName} {
    set name [DboTclHelper_sMakeCString $propertyName]
    set value [DboTclHelper_sMakeCString]
    set status [$object GetEffectivePropStringValue $name $value]
    if {[$status OK] != 1} {
        $status -delete
        return ""
    }
    set result [DboTclHelper_sGetConstCharPtr $value]
    $status -delete
    return $result
}

set parent [GetInstanceOccurrence]
foreach object [GetSelectedObjects] {
    set type [DboBaseObject_GetObjectType $object]
    if {$type != $::DboBaseObject_DRAWN_INSTANCE &&
        $type != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }
    set occurrence [$object GetObjectOccurrence $parent]
    if {$occurrence == "NULL" ||
        [DboBaseObject_GetObjectType $occurrence] != $::DboBaseObject_INST_OCCURRENCE} {
        continue
    }
    set instance [DboOccurrenceToDboInstOccurrence $occurrence]
    set reference [DboTclHelper_sMakeCString]
    set path [DboTclHelper_sMakeCString]
    $instance GetReferenceDesignator $reference
    set pathStatus [$instance GetPathName $path]
    set fields [list \
        refdes [DboTclHelper_sGetConstCharPtr $reference] \
        value [readProp $occurrence Value] \
        part [readProp $occurrence {Part Name}] \
        package [readProp $occurrence {Source Package}] \
        footprint [readProp $occurrence {PCB Footprint}]]
    if {[$pathStatus OK] == 1} {
        lappend fields path [DboTclHelper_sGetConstCharPtr $path]
    }
    $pathStatus -delete
    puts $fields
}
