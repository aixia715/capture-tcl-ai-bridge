# Reference designators of the components in the current selection.
#
# Self-contained and read-only: filters the current selection down to
# component occurrences (dropping wires, ports and other non-component
# graphics), maps each surviving occurrence to its reference designator,
# and prints the deduplicated, sorted list -- one refdes per line.
# Selecting the same occurrence twice, or several occurrences that happen
# to share a refdes, must not produce a duplicate line.

set selection [GetActivePMSelection]

set refdesList {}
foreach occurrence [$selection GetSelectedObjects] {
    if {[$occurrence GetObjectType] ne {occDbComponent}} {
        continue
    }
    lappend refdesList [$occurrence GetReference]
}

foreach refdes [lsort -unique $refdesList] {
    puts $refdes
}
