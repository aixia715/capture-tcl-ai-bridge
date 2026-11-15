# Change the first capacitor occurrence in a DSN without starting Capture GUI.
# Usage: tclsh headless_set_first_capacitor_value.tcl design.dsn newValue

if {$argc != 2} {
    puts stderr "Usage: tclsh headless_set_first_capacitor_value.tcl design.dsn newValue"
    exit 2
}

proc statusMessage {status} {
    set message [DboTclHelper_sMakeCString]
    $status Message $message
    return [DboTclHelper_sGetConstCharPtr $message]
}

proc requireOk {status operation} {
    if {![$status OK]} {
        error "$operation failed: [statusMessage $status] (code [$status Code])"
    }
}

proc stringOut {object method} {
    set output [DboTclHelper_sMakeCString]
    set status [$object $method $output]
    requireOk $status $method
    set value [DboTclHelper_sGetConstCharPtr $output]
    $status -delete
    return $value
}

proc getProperty {object propertyName} {
    set name [DboTclHelper_sMakeCString $propertyName]
    set output [DboTclHelper_sMakeCString]
    set status [$object GetEffectivePropStringValue $name $output]
    requireOk $status "GetEffectivePropStringValue($propertyName)"
    set value [DboTclHelper_sGetConstCharPtr $output]
    $status -delete
    return $value
}

proc setProperty {object propertyName propertyValue} {
    set name [DboTclHelper_sMakeCString $propertyName]
    set value [DboTclHelper_sMakeCString $propertyValue]
    set status [$object SetEffectivePropStringValue $name $value]
    requireOk $status "SetEffectivePropStringValue($propertyName)"
    $status -delete
}

proc findFirstCapacitor {occurrence status resultName} {
    upvar $resultName result
    if {$result != "NULL"} { return }
    if {[DboBaseObject_GetObjectType $occurrence] != $::DboBaseObject_INST_OCCURRENCE} {
        error "Unexpected occurrence type"
    }
    set instance [DboOccurrenceToDboInstOccurrence $occurrence]
    set primitive [$instance IsPrimitive $status]
    requireOk $status IsPrimitive
    if {$primitive} {
        set reference [string trim [stringOut $instance GetReference]]
        if {[string match {C[0-9]*} $reference]} {
            set result $instance
            return
        }
    }
    set iterator [$instance NewChildrenIter $status $::IterDefs_INSTS]
    requireOk $status NewChildrenIter
    $iterator Sort $status
    requireOk $status Sort
    set code [catch {
        set child [$iterator NextOccurrence $status]
        while {$child != "NULL" && $result == "NULL"} {
            requireOk $status NextOccurrence
            findFirstCapacitor $child $status result
            set child [$iterator NextOccurrence $status]
        }
    } message]
    catch {delete_DboOccurrenceChildrenIter $iterator}
    if {$code} { error $message }
}

set designPath [file normalize [lindex $argv 0]]
set newValue [lindex $argv 1]
set installPath [exec cds_root cds_root]
load [file normalize [file join $installPath tools capture orDb_Dll_TCL]] DboTclWriteBasic

set status [DboState]
set session [DboTclHelper_sCreateSession]
set design "NULL"
set code [catch {
    set pathString [DboTclHelper_sMakeCString $designPath]
    set design [$session GetDesignAndSchematics $pathString $status]
    if {$design == "NULL"} { error "Could not open $designPath" }
    requireOk $status GetDesignAndSchematics
    set root [$design GetRootOccurrence $status]
    requireOk $status GetRootOccurrence
    set capacitor "NULL"
    findFirstCapacitor $root $status capacitor
    if {$capacitor == "NULL"} { error "No capacitor occurrence found" }
    set reference [string trim [stringOut $capacitor GetReference]]
    set before [getProperty $capacitor Value]
    setProperty $capacitor Value $newValue
    set after [getProperty $capacitor Value]
    if {$after != $newValue} { error "Readback failed before save" }
    set saveStatus [$session SaveDesign $design]
    requireOk $saveStatus SaveDesign
    $saveStatus -delete
    puts "REFDES=$reference"
    puts "BEFORE=$before"
    puts "AFTER=$after"
} message]

if {$design != "NULL"} { catch {$session RemoveLib $design} }
catch {DboTclHelper_sDeleteSession $session}
catch {$status -delete}
if {$code} {
    puts stderr "HEADLESS_WRITE_FAILED=$message"
    exit 1
}
