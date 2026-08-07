# Remove one trailing marker suffix from the Value of every selected
# component, undoing mark_selected_suffix.tcl.

# Edit this before sending:
set suffix *

# Self-contained; never forces a part-values refresh and never saves the
# design. Only a suffix at the very end of the value is removed -- a `*`
# sitting in the middle of a value is left alone -- and only one trailing
# suffix is stripped per run, the mirror image of mark_selected_suffix.tcl
# appending exactly one.

proc _endsWithSuffix {value suffix} {
    set suffixLen [string length $suffix]
    if {[string length $value] < $suffixLen} {
        return 0
    }
    return [string equal [string range $value end-[expr {$suffixLen - 1}] end] $suffix]
}

set selection [GetActivePMSelection]

# Dedupe before mutating: the same occurrence can appear more than once in
# a selection, and each occurrence must be touched at most once.
set seen {}
set targets {}
foreach occurrence [$selection GetSelectedObjects] {
    if {[$occurrence GetObjectType] ne {occDbComponent}} {
        continue
    }
    if {[lsearch -exact $seen $occurrence] >= 0} {
        continue
    }
    lappend seen $occurrence
    lappend targets $occurrence
}

set changed 0
set skipped 0
foreach occurrence $targets {
    set before [$occurrence GetPartValue]
    if {![_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want [string range $before 0 end-[string length $suffix]]
    $occurrence SetPartValue $want
    set after [$occurrence GetPartValue]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for [$occurrence GetReference]"
    }
    puts [dict create refdes [$occurrence GetReference] before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
