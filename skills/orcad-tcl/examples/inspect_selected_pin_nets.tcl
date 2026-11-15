# Print pin-to-net connectivity for selected component page instances.
# Read-only. Net names may be generated IDs when the schematic has no alias.

proc cstringValue {pointer} {
    return [DboTclHelper_sGetConstCharPtr $pointer]
}

set status [DboState]
set parent [GetInstanceOccurrence]
foreach object [GetSelectedObjects] {
    set objectType [DboBaseObject_GetObjectType $object]
    if {$objectType != $::DboBaseObject_DRAWN_INSTANCE &&
        $objectType != $::DboBaseObject_PLACED_INSTANCE} {
        continue
    }

    set refdes "?"
    set occurrence [$object GetObjectOccurrence $parent]
    if {$occurrence != "NULL" &&
        [DboBaseObject_GetObjectType $occurrence] == $::DboBaseObject_INST_OCCURRENCE} {
        set instanceOccurrence [DboOccurrenceToDboInstOccurrence $occurrence]
        set reference [DboTclHelper_sMakeCString]
        $instanceOccurrence GetReferenceDesignator $reference
        set refdes [cstringValue $reference]
    }

    set iterator [$object NewPinsIter $status]
    if {$iterator == "NULL" || [$status OK] != 1} {
        continue
    }
    set pin [$iterator NextPin $status]
    while {$pin != "NULL"} {
        set pinNumber [cstringValue [DboPortInst_sGetPinNumber $pin $status]]
        set pinName [cstringValue [DboPortInst_sGetPinName $pin $status]]
        set netName [cstringValue [DboPortInst_sGetNetName $pin $status]]
        puts [list refdes $refdes pin $pinNumber pinName $pinName net $netName]
        set pin [$iterator NextPin $status]
    }
    delete_DboPartInstPinsIter $iterator
}
$status -delete
