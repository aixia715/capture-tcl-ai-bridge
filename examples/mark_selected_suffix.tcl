# Append a marker suffix to the Value of every selected component -- e.g.
# flagging a batch of parts for review.

# Edit this before sending:
set suffix *

# Self-contained; never forces a part-values refresh and never saves the
# design. Idempotent: running it twice on the same selection changes
# nothing the second time, because a value that already ends with the
# suffix is skipped rather than getting a second suffix appended.

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
    if {[_endsWithSuffix $before $suffix]} {
        incr skipped
        continue
    }
    set want "$before$suffix"
    $occurrence SetPartValue $want
    set after [$occurrence GetPartValue]
    if {$after ne $want} {
        error "SUFFIX_WRITE_FAILED: readback \"$after\" does not match \"$want\" for [$occurrence GetReference]"
    }
    puts [dict create refdes [$occurrence GetReference] before $before after $after]
    incr changed
}

puts [dict create changed $changed skipped $skipped]
