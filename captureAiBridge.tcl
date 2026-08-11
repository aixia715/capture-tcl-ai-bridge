# Authenticated localhost bridge for executing Tcl in Capture's interpreter.
# Sourcing this module is side-effect free; lifecycle is always explicit.

set ::CaptureAiBridgeService {capture-tcl-bridge}
set ::CaptureAiBridgeVersion {0.1.0-beta.2}
set ::CaptureAiBridgeProtocolVersion 1
set ::CaptureAiBridgePort 8767
set ::CaptureAiBridgePollMs 250
set ::CaptureAiBridgeFieldLimit 4194304
if {![info exists ::CaptureAiBridgeMetadataLimit]} { set ::CaptureAiBridgeMetadataLimit 4194304 }
if {![info exists ::CaptureAiBridgeActive]} { set ::CaptureAiBridgeActive 0 }
if {![info exists ::CaptureAiBridgeConnecting]} { set ::CaptureAiBridgeConnecting 0 }
if {![info exists ::CaptureAiBridgeAfterId]} { set ::CaptureAiBridgeAfterId {} }
if {![info exists ::CaptureAiBridgeToken]} { set ::CaptureAiBridgeToken {} }
if {![info exists ::CaptureAiBridgeBaseUrl]} { set ::CaptureAiBridgeBaseUrl {} }
if {![info exists ::CaptureAiBridgeGeneration]} { set ::CaptureAiBridgeGeneration 0 }
if {![info exists ::CaptureAiBridgeOwnedPid]} { set ::CaptureAiBridgeOwnedPid {} }
if {![info exists ::CaptureAiBridgeStopError]} { set ::CaptureAiBridgeStopError {} }
if {![info exists ::CaptureAiBridgeStopping]} { set ::CaptureAiBridgeStopping 0 }
if {![info exists ::CaptureAiBridgeLaunchFile]} { set ::CaptureAiBridgeLaunchFile {} }
if {![info exists ::CaptureAiBridgeClaimFile]} { set ::CaptureAiBridgeClaimFile {} }
if {![info exists ::CaptureAiBridgeCancelFile]} { set ::CaptureAiBridgeCancelFile {} }
if {![info exists ::CaptureAiBridgeAckFile]} { set ::CaptureAiBridgeAckFile {} }
if {![info exists ::CaptureAiBridgeLaunchNonce]} { set ::CaptureAiBridgeLaunchNonce {} }
if {![info exists ::CaptureAiBridgeLaunchRevoked]} { set ::CaptureAiBridgeLaunchRevoked 0 }
if {![info exists ::CaptureAiBridgeLaunchManaged]} { set ::CaptureAiBridgeLaunchManaged 0 }
if {![info exists ::CaptureAiBridgeExtraGrace]} { set ::CaptureAiBridgeExtraGrace 0 }
if {![info exists ::CaptureAiBridgePendingResultId]} { set ::CaptureAiBridgePendingResultId {} }
if {![info exists ::CaptureAiBridgePendingResultJson]} { set ::CaptureAiBridgePendingResultJson {} }
if {![info exists ::CaptureAiBridgePendingResultGeneration]} { set ::CaptureAiBridgePendingResultGeneration {} }
if {![info exists ::CaptureAiBridgeRetryDelayMs]} { set ::CaptureAiBridgeRetryDelayMs 250 }
if {![info exists ::CaptureAiBridgeRetryMaxMs]} { set ::CaptureAiBridgeRetryMaxMs 5000 }
if {![info exists ::CaptureAiBridgeLastPollError]} { set ::CaptureAiBridgeLastPollError {} }
if {![info exists ::CaptureAiBridgePollingHalted]} { set ::CaptureAiBridgePollingHalted 0 }
if {![info exists ::CaptureAiBridgeProtocolError]} { set ::CaptureAiBridgeProtocolError {} }
if {![info exists ::CaptureAiBridgePythonPath]} { set ::CaptureAiBridgePythonPath {} }

if {![info exists ::CaptureAiBridgeLogFile]} { set ::CaptureAiBridgeLogFile {} }
if {![info exists ::CaptureAiBridgeLogLimitBytes]} {
    set ::CaptureAiBridgeLogLimitBytes 20971520
}

# --- Tcl 8.4 compatibility -------------------------------------------------
#
# OrCAD Capture 16.6 embeds Tcl 8.4.15, which has no dict, no lassign and no
# try. Capture 17.4 embeds 8.6, which has all three. Each shim is defined only
# when the interpreter lacks the command, so on 17.4 the native implementations
# are used untouched and both versions run the same bridge source.
#
# The dict shim covers only the subcommands this module and its examples use.
# It relies on a Tcl dictionary being, at the value level, a list of alternating
# keys and values, so the shim's results interchange with native dictionaries.

if {[llength [info commands ::dict]] == 0} {
    proc ::dict {subcommand args} {
        switch -exact -- $subcommand {
            create {
                if {[llength $args] % 2 != 0} {
                    return -code error \
                        {wrong # args: should be "dict create ?key value ...?"}
                }
                return $args
            }
            get {
                if {[llength $args] < 1} {
                    return -code error \
                        {wrong # args: should be "dict get dictionary ?key ...?"}
                }
                set value [lindex $args 0]
                foreach key [lrange $args 1 end] {
                    if {[llength $value] % 2 != 0} {
                        return -code error \
                            {missing value to go with key}
                    }
                    set found 0
                    # A dictionary keeps the last value written for a key.
                    foreach {candidate candidateValue} $value {
                        if {$candidate eq $key} {
                            set next $candidateValue
                            set found 1
                        }
                    }
                    if {!$found} {
                        return -code error "key \"$key\" not known in dictionary"
                    }
                    set value $next
                }
                return $value
            }
            exists {
                if {[llength $args] < 2} {
                    return -code error \
                        {wrong # args: should be "dict exists dictionary key ?key ...?"}
                }
                set value [lindex $args 0]
                foreach key [lrange $args 1 end] {
                    if {[catch {llength $value} length] || $length % 2 != 0} {
                        return 0
                    }
                    set found 0
                    foreach {candidate candidateValue} $value {
                        if {$candidate eq $key} {
                            set next $candidateValue
                            set found 1
                        }
                    }
                    if {!$found} { return 0 }
                    set value $next
                }
                return 1
            }
            keys {
                if {[llength $args] < 1 || [llength $args] > 2} {
                    return -code error \
                        {wrong # args: should be "dict keys dictionary ?pattern?"}
                }
                set pattern *
                if {[llength $args] == 2} { set pattern [lindex $args 1] }
                set keys {}
                foreach {candidate candidateValue} [lindex $args 0] {
                    if {[lsearch -exact $keys $candidate] < 0 &&
                        [string match $pattern $candidate]} {
                        lappend keys $candidate
                    }
                }
                return $keys
            }
            replace {
                set pairs [lrange $args 1 end]
                if {[llength $pairs] % 2 != 0} {
                    return -code error \
                        {wrong # args: should be "dict replace dictionary ?key value ...?"}
                }
                set result [lindex $args 0]
                foreach {key value} $pairs {
                    set replaced 0
                    set rebuilt {}
                    foreach {candidate candidateValue} $result {
                        if {$candidate eq $key} {
                            lappend rebuilt $candidate $value
                            set replaced 1
                        } else {
                            lappend rebuilt $candidate $candidateValue
                        }
                    }
                    if {!$replaced} { lappend rebuilt $key $value }
                    set result $rebuilt
                }
                return $result
            }
            default {
                return -code error \
                    "unsupported dict subcommand \"$subcommand\" in the Tcl 8.4 shim"
            }
        }
    }
}

if {[llength [info commands ::lassign]] == 0} {
    proc ::lassign {values args} {
        set index 0
        foreach name $args {
            uplevel 1 [list set $name [lindex $values $index]]
            incr index
        }
        return [lrange $values $index end]
    }
}

# Tcl 8.5 added the options-dictionary form of catch. Rather than lose the
# structured -errorinfo/-errorcode the bridge reports, wrap both forms behind
# one helper. On 8.4 the options dictionary is rebuilt from the global error
# variables; -errorline simply does not exist there, so a Capture 16.6 result
# reports a null errorLine.
if {[catch {catch {} _captureAiProbeResult _captureAiProbeOptions}]} {
    proc _captureAiCatch {script resultName optionsName} {
        upvar 1 $resultName result
        upvar 1 $optionsName options
        set code [catch {uplevel 1 $script} result]
        set options [list -code $code -level 0]
        if {$code == 1} {
            lappend options -errorinfo $::errorInfo -errorcode $::errorCode
        }
        return $code
    }
    # Evaluating the submitted script needs the raw command, not this wrapper:
    # an extra stack frame would make -errorline relative to the wrapper.
    set ::CaptureAiBridgeCatchCommand _captureAiCatch
} else {
    proc _captureAiCatch {script resultName optionsName} {
        upvar 1 $resultName result
        upvar 1 $optionsName options
        return [catch {uplevel 1 $script} result options]
    }
    set ::CaptureAiBridgeCatchCommand catch
}
unset -nocomplain _captureAiProbeResult _captureAiProbeOptions

if {[llength [info commands ::try]] == 0} {
    # Only "try BODY finally SCRIPT" and "try BODY on error {resultVar
    # optionsVar} SCRIPT finally SCRIPT" are shimmed; those are the two forms
    # this module uses (_captureAiTick needs the on-error clause to decide
    # whether a poll failure is retryable), and guessing at trap or multiple
    # on/on-error handlers would be worse than refusing them.
    proc ::try {body args} {
        set haveOnError 0
        set onErrorVars {}
        set onErrorScript {}
        set rest $args
        if {[llength $rest] >= 4 && [lindex $rest 0] eq {on} && [lindex $rest 1] eq {error}} {
            set haveOnError 1
            set onErrorVars [lindex $rest 2]
            set onErrorScript [lindex $rest 3]
            set rest [lrange $rest 4 end]
        }
        set finallyScript {}
        if {[llength $rest] == 2 && [lindex $rest 0] eq {finally}} {
            set finallyScript [lindex $rest 1]
        } elseif {[llength $rest] != 0} {
            return -code error \
                {the Tcl 8.4 try shim supports only: try BODY ?on error {resultVar optionsVar} SCRIPT? ?finally SCRIPT?}
        }
        set code [catch {uplevel 1 $body} result]
        set savedInfo $::errorInfo
        set savedCode $::errorCode
        if {$code == 1 && $haveOnError} {
            if {[llength $onErrorVars] >= 1} {
                uplevel 1 [list set [lindex $onErrorVars 0] $result]
            }
            if {[llength $onErrorVars] >= 2} {
                uplevel 1 [list set [lindex $onErrorVars 1] \
                    [list -code error -level 0 -errorinfo $savedInfo -errorcode $savedCode]]
            }
            set code [catch {uplevel 1 $onErrorScript} result]
            if {$code == 1} {
                set savedInfo $::errorInfo
                set savedCode $::errorCode
            }
        }
        set finallyCode [catch {uplevel 1 $finallyScript} finallyResult]
        if {$finallyCode != 0} {
            # A failing cleanup replaces the original outcome, matching 8.6.
            return -code $finallyCode $finallyResult
        }
        if {$code == 1} {
            return -code error -errorinfo $savedInfo -errorcode $savedCode $result
        }
        return -code $code $result
    }
}

# --- JSON ------------------------------------------------------------------
#
# The module parses JSON itself rather than requiring tcllib's json package.
# That package needs a "dict" package on 8.4 which OrCAD does not ship, and it
# needs TCLLIBPATH pointing into the Cadence tree, so depending on it would make
# the bridge fail to start on a stock Capture install. Values map exactly the
# way tcllib's json2dict maps them: objects to dictionaries, arrays to lists,
# true/false/null to those literal words, and numbers to their source text.

proc _captureAiJsonSkipSpace {text indexName} {
    upvar 1 $indexName index
    set length [string length $text]
    while {$index < $length} {
        switch -exact -- [string index $text $index] {
            { } - "\t" - "\n" - "\r" { incr index }
            default { return }
        }
    }
}

proc _captureAiJsonParseString {text indexName} {
    upvar 1 $indexName index
    set length [string length $text]
    if {[string index $text $index] ne "\""} {
        error {Capture AI bridge JSON expected a string.}
    }
    incr index
    set decoded {}
    while {1} {
        if {$index >= $length} {
            error {Capture AI bridge JSON has an unterminated string.}
        }
        set char [string index $text $index]
        if {$char eq "\""} {
            incr index
            return $decoded
        }
        if {$char ne "\\"} {
            append decoded $char
            incr index
            continue
        }
        incr index
        if {$index >= $length} {
            error {Capture AI bridge JSON has an unterminated escape.}
        }
        set escape [string index $text $index]
        incr index
        switch -exact -- $escape {
            "\"" { append decoded "\"" }
            "\\" { append decoded "\\" }
            "/"  { append decoded "/" }
            b    { append decoded "\b" }
            f    { append decoded "\f" }
            n    { append decoded "\n" }
            r    { append decoded "\r" }
            t    { append decoded "\t" }
            u {
                set hex [string range $text $index [expr {$index + 3}]]
                if {![regexp {^[0-9a-fA-F]{4}$} $hex]} {
                    error {Capture AI bridge JSON has an invalid \u escape.}
                }
                incr index 4
                append decoded [format %c [scan $hex %x]]
            }
            default {
                error "Capture AI bridge JSON has an invalid escape \"\\$escape\"."
            }
        }
    }
}

proc _captureAiJsonParseNumber {text indexName} {
    upvar 1 $indexName index
    set length [string length $text]
    set start $index
    while {$index < $length &&
           [string first [string index $text $index] {-+.0123456789eE}] >= 0} {
        incr index
    }
    set token [string range $text $start [expr {$index - 1}]]
    if {![regexp {^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$} $token]} {
        error {Capture AI bridge JSON has an invalid value.}
    }
    return $token
}

proc _captureAiJsonParseValue {text indexName} {
    upvar 1 $indexName index
    _captureAiJsonSkipSpace $text index
    if {$index >= [string length $text]} {
        error {Capture AI bridge JSON ended unexpectedly.}
    }
    set char [string index $text $index]
    if {$char eq "\{"} { return [_captureAiJsonParseObject $text index] }
    if {$char eq "\["} { return [_captureAiJsonParseArray $text index] }
    if {$char eq "\""} { return [_captureAiJsonParseString $text index] }
    foreach literal {true false null} {
        set stop [expr {$index + [string length $literal] - 1}]
        if {[string range $text $index $stop] eq $literal} {
            set index [expr {$stop + 1}]
            return $literal
        }
    }
    return [_captureAiJsonParseNumber $text index]
}

proc _captureAiJsonParseObject {text indexName} {
    upvar 1 $indexName index
    incr index
    set result {}
    _captureAiJsonSkipSpace $text index
    if {[string index $text $index] eq "\}"} {
        incr index
        return $result
    }
    while {1} {
        _captureAiJsonSkipSpace $text index
        set key [_captureAiJsonParseString $text index]
        _captureAiJsonSkipSpace $text index
        if {[string index $text $index] ne ":"} {
            error {Capture AI bridge JSON object is missing a colon.}
        }
        incr index
        lappend result $key [_captureAiJsonParseValue $text index]
        _captureAiJsonSkipSpace $text index
        set char [string index $text $index]
        if {$char eq ","} {
            incr index
            continue
        }
        if {$char eq "\}"} {
            incr index
            return $result
        }
        error {Capture AI bridge JSON object is malformed.}
    }
}

proc _captureAiJsonParseArray {text indexName} {
    upvar 1 $indexName index
    incr index
    set result {}
    _captureAiJsonSkipSpace $text index
    if {[string index $text $index] eq "\]"} {
        incr index
        return $result
    }
    while {1} {
        lappend result [_captureAiJsonParseValue $text index]
        _captureAiJsonSkipSpace $text index
        set char [string index $text $index]
        if {$char eq ","} {
            incr index
            continue
        }
        if {$char eq "\]"} {
            incr index
            return $result
        }
        error {Capture AI bridge JSON array is malformed.}
    }
}

proc _captureAiJsonParse {text} {
    set index 0
    set value [_captureAiJsonParseValue $text index]
    _captureAiJsonSkipSpace $text index
    if {$index != [string length $text]} {
        error {Capture AI bridge JSON has trailing content.}
    }
    return $value
}

proc _captureAiJsonQuote {value} {
    set encoded {"}
    set length [string length $value]
    for {set index 0} {$index < $length} {incr index} {
        lassign [_captureAiNextScalar $value $index] scalar byteCount consumed kind changed codePoint
        incr index [expr {$consumed - 1}]
        if {$changed} {
            append encoded {\ufffd}
            continue
        }
        if {$kind eq "pair"} {
            scan [string index $scalar 0] %c highSurrogate
            scan [string index $scalar 1] %c lowSurrogate
            append encoded [format {\u%04x\u%04x} $highSurrogate $lowSurrogate]
            continue
        }
        if {$codePoint > 0xFFFF} {
            set adjusted [expr {$codePoint - 0x10000}]
            set highSurrogate [expr {0xD800 + ($adjusted >> 10)}]
            set lowSurrogate [expr {0xDC00 + ($adjusted & 0x3FF)}]
            append encoded [format {\u%04x\u%04x} $highSurrogate $lowSurrogate]
            continue
        }
        switch -- $scalar {
            {"}  { append encoded {\"} }
            \\   { append encoded {\\} }
            \b   { append encoded {\b} }
            \f   { append encoded {\f} }
            \n   { append encoded {\n} }
            \r   { append encoded {\r} }
            \t   { append encoded {\t} }
            default {
                if {$codePoint < 32} {
                    append encoded [format {\u%04X} $codePoint]
                } else {
                    append encoded $scalar
                }
            }
        }
    }
    append encoded {"}
    return $encoded
}

proc _captureAiJsonArray {values} {
    set members {}
    foreach value $values {
        lappend members [_captureAiJsonQuote $value]
    }
    return "\[[join $members ,]\]"
}

# Return {prefix protocolTruncated utf8ByteCount contentChanged limitTruncated}.
# A surrogate pair is one scalar and is either retained whole or omitted.
# Isolated surrogate code units are replaced with U+FFFD, never emitted as
# invalid UTF-8.
proc _captureAiNextScalar {value index} {
    set character [string index $value $index]
    scan $character %c codePoint
    set length [string length $value]
    if {$codePoint >= 0xD800 && $codePoint <= 0xDBFF} {
        if {$index + 1 < $length} {
            set nextCharacter [string index $value [expr {$index + 1}]]
            scan $nextCharacter %c nextCodePoint
            if {$nextCodePoint >= 0xDC00 && $nextCodePoint <= 0xDFFF} {
                return [list "${character}${nextCharacter}" 4 2 pair 0 $codePoint]
            }
        }
        return [list [format %c 0xFFFD] 3 1 replacement 1 0xFFFD]
    }
    if {$codePoint >= 0xDC00 && $codePoint <= 0xDFFF} {
        return [list [format %c 0xFFFD] 3 1 replacement 1 0xFFFD]
    }
    if {$codePoint <= 0x7F} {
        set byteCount 1
    } elseif {$codePoint <= 0x7FF} {
        set byteCount 2
    } elseif {$codePoint <= 0xFFFF} {
        set byteCount 3
    } else {
        set byteCount 4
    }
    return [list $character $byteCount 1 scalar 0 $codePoint]
}

proc _captureAiUtf8Prefix {value byteLimit} {
    set prefix {}
    set byteCount 0
    set contentChanged 0
    set length [string length $value]
    for {set index 0} {$index < $length} {incr index $consumed} {
        lassign [_captureAiNextScalar $value $index] scalar scalarBytes consumed kind changed ignoredCodePoint
        set nextByteCount [expr {$byteCount + $scalarBytes}]
        if {$nextByteCount > $byteLimit} {
            return [list $prefix 1 $byteCount $contentChanged 1]
        }
        append prefix $scalar
        set byteCount $nextByteCount
        if {$changed} {
            set contentChanged 1
        }
    }
    return [list $prefix $contentChanged $byteCount $contentChanged 0]
}

# Add text to one live capture field without ever retaining content past its
# UTF-8 byte cap.  The field's byte count avoids re-encoding accumulated output.
proc _captureAiAppendLimited {field text} {
    switch -- $field {
        stdout {
            set valueVariable ::_captureAiBridgeStdout
            set bytesVariable ::_captureAiBridgeStdoutBytes
            set truncatedVariable ::_captureAiBridgeStdoutTruncated
            set stoppedVariable ::_captureAiBridgeStdoutStopped
        }
        stderr {
            set valueVariable ::_captureAiBridgeStderr
            set bytesVariable ::_captureAiBridgeStderrBytes
            set truncatedVariable ::_captureAiBridgeStderrTruncated
            set stoppedVariable ::_captureAiBridgeStderrStopped
        }
        default {
            error "unknown capture field: $field"
        }
    }
    upvar #0 $valueVariable value $bytesVariable byteCount $truncatedVariable truncated $stoppedVariable stopped
    if {$stopped} {
        return
    }
    set remaining [expr {$::CaptureAiBridgeFieldLimit - $byteCount}]
    lassign [_captureAiUtf8Prefix $text $remaining] accepted protocolTruncated acceptedBytes contentChanged limitTruncated
    append value $accepted
    incr byteCount $acceptedBytes
    if {$protocolTruncated} {
        set truncated 1
    }
    if {$limitTruncated} {
        set stopped 1
    }
}

# Runs as a leave trace after the puts alias returns.  Because the alias itself
# forwards to the saved command, every Tcl completion code and its options pass
# through untouched; only a successful write reaches the capture logic.
proc _captureAiTeePuts {command code value operation} {
    if {$code != 0} {
        return
    }
    set args [lrange $command 1 end]
    set nonewline 0
    set remaining $args
    if {[llength $remaining] > 0 && [lindex $remaining 0] eq "-nonewline"} {
        set nonewline 1
        set remaining [lrange $remaining 1 end]
    }
    if {[llength $remaining] == 1} {
        set channel stdout
        set text [lindex $remaining 0]
    } elseif {[llength $remaining] == 2} {
        set channel [lindex $remaining 0]
        set text [lindex $remaining 1]
    } else {
        return
    }
    if {$channel eq "stdout" || $channel eq "stderr"} {
        if {!$nonewline} {
            append text "\n"
        }
        _captureAiAppendLimited $channel $text
    }
}

proc _captureAiResultDict {returnCode result stdout stderr errorInfo errorCode errorLine stdoutTruncated stderrTruncated resultTruncated} {
    return [dict create \
        returnCode $returnCode \
        result $result \
        stdout $stdout \
        stderr $stderr \
        errorInfo $errorInfo \
        errorCode $errorCode \
        errorLine $errorLine \
        stdoutTruncated $stdoutTruncated \
        stderrTruncated $stderrTruncated \
        resultTruncated $resultTruncated]
}

proc _captureAiResetCaptureState {} {
    set ::_captureAiBridgeStdout {}
    set ::_captureAiBridgeStderr {}
    set ::_captureAiBridgeStdoutBytes 0
    set ::_captureAiBridgeStderrBytes 0
    set ::_captureAiBridgeStdoutTruncated 0
    set ::_captureAiBridgeStderrTruncated 0
    set ::_captureAiBridgeStdoutStopped 0
    set ::_captureAiBridgeStderrStopped 0
}

proc _captureAiClearCaptureState {} {
    unset -nocomplain \
        ::_captureAiBridgeStdout \
        ::_captureAiBridgeStderr \
        ::_captureAiBridgeStdoutBytes \
        ::_captureAiBridgeStderrBytes \
        ::_captureAiBridgeStdoutTruncated \
        ::_captureAiBridgeStderrTruncated \
        ::_captureAiBridgeStdoutStopped \
        ::_captureAiBridgeStderrStopped
}

# Tcl 8.4's `rename` does not carry a command's interp-alias binding to its
# new name: the renamed command survives in `info commands` but can no
# longer be invoked, and `interp alias` no longer reports it. Tcl 8.6 renames
# aliases correctly. Route every puts-shuffling rename through these helpers
# so an aliased puts (as Capture may install, or as tests simulate) survives
# on both interpreters.
proc _captureAiMoveCommand {from to} {
    set aliasTarget [interp alias {} $from]
    if {$aliasTarget ne {}} {
        interp alias {} $from {}
        interp alias {} $to {} $aliasTarget
    } else {
        rename $from $to
    }
}

proc _captureAiDeleteCommand {name} {
    if {[interp alias {} $name] ne {}} {
        interp alias {} $name {}
    } else {
        rename $name {}
    }
}

proc _captureAiRestorePuts {original} {
    if {[llength [info commands ::puts]] > 0} {
        trace remove execution ::puts leave _captureAiTeePuts
        _captureAiDeleteCommand ::puts
    }
    if {[llength [info commands $original]] == 0} {
        error {unable to restore the original puts command}
    }
    _captureAiMoveCommand $original ::puts
}

proc _captureAiExecuteScript {script} {
    if {[info exists ::_captureAiBridgeExecuting] && $::_captureAiBridgeExecuting} {
        return [_captureAiResultDict 1 \
            {Capture AI bridge execution is already active.} \
            {} {} {} {CAPTURE AI BRIDGE REENTRANT} {} 0 0 0]
    }
    set ::_captureAiBridgeExecuting 1
    try {
        if {![string is integer -strict $::CaptureAiBridgeFieldLimit] || $::CaptureAiBridgeFieldLimit < 0} {
            return [_captureAiResultDict 1 \
                {CaptureAiBridgeFieldLimit must be a non-negative integer.} \
                {} {} {} {CAPTURE AI BRIDGE INVALID FIELD LIMIT} {} 0 0 0]
        }
    set original ::_captureAiBridgeOriginalPuts
    _captureAiResetCaptureState
    set movedOriginal 0
    set installCode [_captureAiCatch {
        if {[llength [info commands $original]] > 0} {
            error {capture puts staging command already exists}
        }
        _captureAiMoveCommand ::puts $original
        set movedOriginal 1
        interp alias {} ::puts {} $original
        trace add execution ::puts leave _captureAiTeePuts
    } installResult installOptions]

    if {$installCode != 0} {
        set restoreCode [_captureAiCatch {
            if {$movedOriginal && [llength [info commands $original]] > 0} {
                if {[llength [info commands ::puts]] > 0} {
                    _captureAiDeleteCommand ::puts
                }
                _captureAiMoveCommand $original ::puts
            }
        } restoreResult restoreOptions]
        _captureAiClearCaptureState
        if {$restoreCode != 0} {
            append installResult "; restore failed: $restoreResult"
        }
        set errorInfo {}
        set errorCode {}
        set errorLine {}
        if {[dict exists $installOptions -errorinfo]} { set errorInfo [dict get $installOptions -errorinfo] }
        if {[dict exists $installOptions -errorcode]} { set errorCode [dict get $installOptions -errorcode] }
        if {[dict exists $installOptions -errorline]} { set errorLine [dict get $installOptions -errorline] }
        return [_captureAiResultDict 1 $installResult {} {} $errorInfo $errorCode $errorLine 0 0 0]
    }

    if {![info exists ::_captureAiBridgeCatchSerial]} {
        set ::_captureAiBridgeCatchSerial 0
    }
    set catchSuffix "[pid]_[incr ::_captureAiBridgeCatchSerial]"
    set resultVariable "::_captureAiBridgeCatchResult_$catchSuffix"
    set optionsVariable "::_captureAiBridgeCatchOptions_$catchSuffix"
    try {
        # Evaluate catch itself at global level.  This makes -errorline relative
        # to the submitted script rather than this bridge procedure's body.
        set returnCode [uplevel #0 \
            [list $::CaptureAiBridgeCatchCommand $script $resultVariable \
                $optionsVariable]]
        set result [set $resultVariable]
        set executionOptions [set $optionsVariable]
    } finally {
        unset -nocomplain $resultVariable $optionsVariable
    }
    set restoreCode [_captureAiCatch {_captureAiRestorePuts $original} \
        restoreResult restoreOptions]

    set stdout $::_captureAiBridgeStdout
    set stderr $::_captureAiBridgeStderr
    set stdoutTruncated $::_captureAiBridgeStdoutTruncated
    set stderrTruncated $::_captureAiBridgeStderrTruncated
    _captureAiClearCaptureState

    if {$restoreCode != 0} {
        set returnCode 1
        set result "puts restoration failed: $restoreResult"
        set executionOptions $restoreOptions
    }

    lassign [_captureAiUtf8Prefix $result $::CaptureAiBridgeFieldLimit] result resultTruncated ignoredBytes contentChanged limitTruncated
    set errorInfo {}
    set errorCode {}
    set errorLine {}
    if {[dict exists $executionOptions -errorinfo]} { set errorInfo [dict get $executionOptions -errorinfo] }
    if {[dict exists $executionOptions -errorcode]} { set errorCode [dict get $executionOptions -errorcode] }
    if {[dict exists $executionOptions -errorline]} { set errorLine [dict get $executionOptions -errorline] }
    return [_captureAiResultDict $returnCode $result $stdout $stderr $errorInfo $errorCode $errorLine $stdoutTruncated $stderrTruncated $resultTruncated]
    } finally {
        unset -nocomplain ::_captureAiBridgeExecuting
    }
}

proc _captureAiJsonBoolean {value} {
    if {$value} {
        return true
    }
    return false
}

proc _captureAiEffectiveMetadataLimit {} {
    if {![string is integer -strict $::CaptureAiBridgeMetadataLimit] ||
        $::CaptureAiBridgeMetadataLimit < 0} {
        return 0
    }
    # Keep the JSON request safely below the server's 160 MiB body limit even
    # if a hot-sourced session retained an unexpectedly large configuration.
    # expr's min()/max() are Tcl 8.5+; Tcl 8.4 needs the ternary spelled out.
    set limit $::CaptureAiBridgeMetadataLimit
    return [expr {$limit < 4194304 ? $limit : 4194304}]
}

proc _captureAiUtf8ListPrefix {values byteLimit} {
    set bounded {}
    set remaining $byteLimit
    foreach value $values {
        if {$remaining == 0} {
            break
        }
        if {$value eq {}} {
            lappend bounded {}
            incr remaining -1
            continue
        }
        lassign [_captureAiUtf8Prefix $value $remaining] \
            prefix protocolTruncated prefixBytes contentChanged limitTruncated
        if {$prefix ne {}} {
            lappend bounded $prefix
            incr remaining -$prefixBytes
        }
        if {$limitTruncated} {
            break
        }
    }
    return $bounded
}

proc _captureAiResultJson {commandId result} {
    set metadataLimit [_captureAiEffectiveMetadataLimit]
    lassign [_captureAiUtf8Prefix \
        [dict get $result errorInfo] $metadataLimit] \
        boundedErrorInfo ignoredMetadataTruncated ignoredMetadataBytes \
        ignoredMetadataChanged ignoredMetadataLimitTruncated
    set boundedErrorCode [_captureAiUtf8ListPrefix \
        [dict get $result errorCode] $metadataLimit]
    set errorLine null
    if {[dict exists $result errorLine] &&
        [string is integer -strict [dict get $result errorLine]]} {
        set errorLine [dict get $result errorLine]
    }
    set members [list \
        "\"id\":[_captureAiJsonQuote $commandId]" \
        "\"returnCode\":[dict get $result returnCode]" \
        "\"result\":[_captureAiJsonQuote [dict get $result result]]" \
        "\"stdout\":[_captureAiJsonQuote [dict get $result stdout]]" \
        "\"stderr\":[_captureAiJsonQuote [dict get $result stderr]]" \
        "\"errorInfo\":[_captureAiJsonQuote $boundedErrorInfo]" \
        "\"errorCode\":[_captureAiJsonArray $boundedErrorCode]" \
        "\"errorLine\":$errorLine" \
        "\"stdoutTruncated\":[_captureAiJsonBoolean [dict get $result stdoutTruncated]]" \
        "\"stderrTruncated\":[_captureAiJsonBoolean [dict get $result stderrTruncated]]" \
        "\"resultTruncated\":[_captureAiJsonBoolean [dict get $result resultTruncated]]"]
    return "\{[join $members ,]\}"
}

proc _captureAiSafeError {message} {
    if {$::CaptureAiBridgeToken ne {}} {
        return [string map [list $::CaptureAiBridgeToken {<redacted>}] $message]
    }
    return $message
}

proc _captureAiRequest {method path {payload {}} {extraHeaders {}}} {
    if {$::CaptureAiBridgeBaseUrl ne "http://127.0.0.1:$::CaptureAiBridgePort"} {
        error {Capture AI bridge URL is not the configured localhost service.}
    }
    if {$::CaptureAiBridgeToken eq {}} {
        error {Capture AI bridge token is unavailable.}
    }
    if {[lsearch -exact {GET POST} $method] < 0 || ![string match {/*} $path]} {
        error {Invalid Capture AI bridge request.}
    }

    set headers [list \
        Authorization "Bearer $::CaptureAiBridgeToken" \
        X-Capture-Pid [pid]]
    if {[llength $extraHeaders] % 2 != 0} {
        error {Invalid Capture AI bridge request headers.}
    }
    foreach {headerName headerValue} $extraHeaders {
        if {[lsearch -exact {authorization x-capture-pid host} \
                [string tolower $headerName]] >= 0} {
            error {Capture AI bridge request cannot override protected headers.}
        }
        lappend headers $headerName $headerValue
    }
    set requestOptions [list \
        -headers $headers \
        -timeout 1500 \
        -binary true]
    # http 2.5.3 (Tcl 8.4, Capture 16.6) has no -method option; it selects POST
    # from the presence of -query and GET otherwise, which is all this bridge
    # needs. Newer http packages behave the same way for these two verbs.
    if {$method eq "POST"} {
        lappend requestOptions \
            -type {application/json; charset=utf-8} \
            -query [encoding convertto utf-8 $payload]
    }

    set httpToken {}
    try {
        # `return -code error` defaults to a deferred (-level 1) return: it
        # only becomes a real error once it crosses an actual `proc` call
        # boundary. On Tcl 8.4 the try shim runs this body via `uplevel`, not
        # a proc call, so a deferred return here would surface as a plain
        # TCL_RETURN and this whole request would look like it "succeeded"
        # with the error message as its result. `error` raises immediately
        # on every Tcl version and survives uplevel/catch cleanly, so it is
        # used instead everywhere in this function's try body.
        set getCode [catch {
            eval [linsert $requestOptions 0 ::http::geturl \
                "${::CaptureAiBridgeBaseUrl}${path}"]
        } requestToken]
        if {$getCode != 0} {
            error [_captureAiSafeError $requestToken] {} {CAPTURE_AI_BRIDGE TRANSPORT}
        }
        set httpToken $requestToken
        if {[catch {::http::status $httpToken} transportStatus] ||
            $transportStatus ne "ok"} {
            error {Capture AI bridge HTTP transport failed.} {} {CAPTURE_AI_BRIDGE TRANSPORT}
        }
        if {[catch {::http::ncode $httpToken} statusCode] ||
            [catch {::http::data $httpToken} responseBytes]} {
            error {Capture AI bridge HTTP transport failed.} {} {CAPTURE_AI_BRIDGE TRANSPORT}
        }
        set response [encoding convertfrom utf-8 $responseBytes]
        if {$statusCode < 200 || $statusCode >= 300} {
            set remoteCode HTTP_ERROR
            set responseId {}
            set responseState {}
            set remoteMessage "Capture AI bridge returned HTTP $statusCode."
            if {![catch {_captureAiJsonParse $response} errorBody]} {
                if {[dict exists $errorBody error code]} {
                    set remoteCode [dict get $errorBody error code]
                }
                if {[dict exists $errorBody error message]} {
                    set remoteMessage [dict get $errorBody error message]
                }
                if {[dict exists $errorBody id]} {
                    set responseId [dict get $errorBody id]
                }
                if {[dict exists $errorBody state]} {
                    set responseState [dict get $errorBody state]
                }
            }
            error [_captureAiSafeError $remoteMessage] {} \
                [list CAPTURE_AI_BRIDGE HTTP $statusCode $remoteCode $responseId $responseState]
        }
        if {$response eq {}} {
            return {}
        }
        return [_captureAiJsonParse $response]
    } finally {
        if {$httpToken ne {}} {
            ::http::cleanup $httpToken
        }
    }
}

proc _captureAiLifecycleIsCurrent {generation state} {
    if {$generation != $::CaptureAiBridgeGeneration} {
        return 0
    }
    return [set ::CaptureAiBridge$state]
}

proc _captureAiResetPollRecoveryState {} {
    set ::CaptureAiBridgeRetryDelayMs 250
    set ::CaptureAiBridgeLastPollError {}
    set ::CaptureAiBridgePollingHalted 0
    set ::CaptureAiBridgeProtocolError {}
}

proc _captureAiScheduleTick {{generation {}} {delay {}}} {
    if {$generation eq {}} {
        set generation $::CaptureAiBridgeGeneration
    }
    if {$delay eq {}} {
        set delay $::CaptureAiBridgeRetryDelayMs
    }
    if {[_captureAiLifecycleIsCurrent $generation Active] &&
        !$::CaptureAiBridgePollingHalted &&
        $::CaptureAiBridgeAfterId eq {}} {
        set ::CaptureAiBridgeAfterId \
            [after $delay [list _captureAiTick $generation]]
    }
}

proc _captureAiSchedulePollRetry {generation} {
    set delay $::CaptureAiBridgeRetryDelayMs
    _captureAiScheduleTick $generation $delay
    # expr's min() is Tcl 8.5+; Tcl 8.4 needs the ternary spelled out.
    set doubled [expr {$delay * 2}]
    set retryMax $::CaptureAiBridgeRetryMaxMs
    set ::CaptureAiBridgeRetryDelayMs \
        [expr {$retryMax < $doubled ? $retryMax : $doubled}]
}

# --- console reporting ------------------------------------------------------
#
# Everything the bridge tells the operator goes through here. It always
# writes to the Capture console, exactly as before; when
# ::CaptureAiBridgeLogFile names a path it also appends a timestamped copy,
# which is the only way to inspect these messages from outside Capture --
# they never reach a submitted script, so nothing else can observe whether a
# repeated failure was reported once or flooded the console.
#
# Messages reaching here are already sanitized by _captureAiSafeError; the
# log is a mirror, not a second formatting path, so it cannot leak more than
# the console already shows.

proc _captureAiConsole {message} {
    puts stderr $message
    if {$::CaptureAiBridgeLogFile eq {}} { return }
    # A broken or unwritable log destination must never take down the bridge
    # or a running command, so every failure here is swallowed deliberately.
    catch {
        set path $::CaptureAiBridgeLogFile
        set limit $::CaptureAiBridgeLogLimitBytes
        set truncated 0
        if {[string is integer -strict $limit] && $limit > 0 &&
            [file exists $path] && [file size $path] >= $limit} {
            # Keep the newest output rather than refusing to log or growing
            # without bound: recent events are what a diagnosis needs.
            set channel [open $path w]
            close $channel
            set truncated 1
        }
        set channel [open $path a]
        try {
            fconfigure $channel -encoding utf-8
            # The console is transient; this file is not. Callers already
            # sanitize through _captureAiSafeError, but a persisted artifact
            # deserves a second, unconditional scrub of the one secret the
            # bridge holds.
            set safe $message
            if {$::CaptureAiBridgeToken ne {}} {
                set safe [string map \
                    [list $::CaptureAiBridgeToken {<token redacted>}] $safe]
            }
            set stamp [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]
            if {$truncated} {
                puts $channel "\[$stamp\] --- earlier log content truncated at ${limit} bytes ---"
            }
            puts $channel "\[$stamp\] $safe"
        } finally {
            close $channel
        }
    }
}

proc _captureAiReportPollError {fingerprint message} {
    if {$::CaptureAiBridgeLastPollError ne $fingerprint} {
        _captureAiConsole "Capture AI bridge poll failed: [_captureAiSafeError $message]"
        set ::CaptureAiBridgeLastPollError $fingerprint
    }
}

proc _captureAiPollErrorDisposition {message options} {
    set errorCode {}
    if {[dict exists $options -errorcode]} {
        set errorCode [dict get $options -errorcode]
    }
    if {[llength $errorCode] >= 2 &&
        [lindex $errorCode 0] eq "CAPTURE_AI_BRIDGE" &&
        [lindex $errorCode 1] eq "HTTP"} {
        set statusCode [lindex $errorCode 2]
        set remoteCode [lindex $errorCode 3]
        set fingerprint "HTTP:$statusCode:$remoteCode"
        _captureAiReportPollError $fingerprint $message
        if {[string is integer -strict $statusCode] &&
            $statusCode >= 400 && $statusCode < 500} {
            set ::CaptureAiBridgePollingHalted 1
            set ::CaptureAiBridgeProtocolError [_captureAiSafeError $message]
            return halt
        }
        return retry
    }
    _captureAiReportPollError TRANSPORT $message
    return retry
}

proc _captureAiClearPendingResult {} {
    set ::CaptureAiBridgePendingResultId {}
    set ::CaptureAiBridgePendingResultJson {}
    set ::CaptureAiBridgePendingResultGeneration {}
}

proc _captureAiStorePendingResult {generation commandId payload} {
    set ::CaptureAiBridgePendingResultId $commandId
    set ::CaptureAiBridgePendingResultJson $payload
    set ::CaptureAiBridgePendingResultGeneration $generation
}

proc _captureAiPendingResultIsCurrent {generation} {
    return [expr {
        $::CaptureAiBridgePendingResultId ne {} &&
        $::CaptureAiBridgePendingResultJson ne {} &&
        $::CaptureAiBridgePendingResultGeneration ne {} &&
        $::CaptureAiBridgePendingResultGeneration eq $generation}]
}

proc _captureAiPostPendingResult {generation} {
    set pendingId $::CaptureAiBridgePendingResultId
    set pendingJson $::CaptureAiBridgePendingResultJson
    set postCode [_captureAiCatch {
        _captureAiRequest POST /internal/result $pendingJson \
            [list X-Capture-Command-Id $::CaptureAiBridgePendingResultId]
    } postMessage postOptions]
    if {$postCode == 0} {
        if {[_captureAiLifecycleIsCurrent $generation Active] &&
            $::CaptureAiBridgePendingResultId eq $pendingId &&
            $::CaptureAiBridgePendingResultJson eq $pendingJson &&
            $::CaptureAiBridgePendingResultGeneration eq $generation} {
            _captureAiClearPendingResult
        }
        set ::CaptureAiBridgeRetryDelayMs 250
        set ::CaptureAiBridgeLastPollError {}
        return posted
    }

    set errorCode {}
    if {[dict exists $postOptions -errorcode]} {
        set errorCode [dict get $postOptions -errorcode]
    }
    if {[llength $errorCode] >= 5 &&
        [lindex $errorCode 0] eq "CAPTURE_AI_BRIDGE" &&
        [lindex $errorCode 1] eq "HTTP"} {
        set statusCode [lindex $errorCode 2]
        set remoteCode [lindex $errorCode 3]
        set responseId [lindex $errorCode 4]
        set responseState [lindex $errorCode 5]
        set fingerprint "HTTP:$statusCode:$remoteCode"
        if {[lsearch -exact {400 413} $statusCode] >= 0 &&
            [lsearch -exact {INVALID_RESULT REQUEST_TOO_LARGE} $remoteCode] >= 0 &&
            $responseId eq $pendingId && $responseState eq "completed"} {
            _captureAiReportPollError $fingerprint $postMessage
            _captureAiClearPendingResult
            set ::CaptureAiBridgeRetryDelayMs 250
            return discarded
        }
        if {$statusCode == 409 && $remoteCode eq "COMMAND_ID_MISMATCH"} {
            _captureAiReportPollError $fingerprint $postMessage
            _captureAiClearPendingResult
            set ::CaptureAiBridgeRetryDelayMs 250
            return discarded
        }
    }
    return [_captureAiPollErrorDisposition $postMessage $postOptions]
}

proc _captureAiTick {{generation {}}} {
    if {$generation eq {}} {
        set generation $::CaptureAiBridgeGeneration
    }
    if {$generation != $::CaptureAiBridgeGeneration} {
        return
    }
    set ::CaptureAiBridgeAfterId {}
    if {![_captureAiLifecycleIsCurrent $generation Active]} {
        return
    }
    set retryPoll 0
    try {
        if {$::CaptureAiBridgePendingResultGeneration ne {} &&
            $::CaptureAiBridgePendingResultGeneration ne $generation} {
            _captureAiClearPendingResult
        }
        if {$::CaptureAiBridgePendingResultId ne {} ||
            $::CaptureAiBridgePendingResultJson ne {} ||
            $::CaptureAiBridgePendingResultGeneration ne {}} {
            if {![_captureAiPendingResultIsCurrent $generation]} {
                _captureAiClearPendingResult
            } else {
                set postDisposition [_captureAiPostPendingResult $generation]
                if {$postDisposition eq "retry"} {
                    set retryPoll 1
                }
                return
            }
        }
        set commandCode [_captureAiCatch {
            _captureAiRequest GET /internal/command
        } command commandOptions]
        if {$commandCode != 0} {
            if {[_captureAiPollErrorDisposition $command $commandOptions] eq "retry"} {
                set retryPoll 1
            }
            return
        }
        set ::CaptureAiBridgeRetryDelayMs 250
        set ::CaptureAiBridgeLastPollError {}
        if {![_captureAiLifecycleIsCurrent $generation Active]} {
            return
        }
        if {$command ne {} && [dict exists $command id] &&
            [dict exists $command script]} {
            set commandId [dict get $command id]
            if {![_captureAiLifecycleIsCurrent $generation Active]} {
                return
            }
            set result [_captureAiExecuteScript [dict get $command script]]
            if {![_captureAiLifecycleIsCurrent $generation Active]} {
                return
            }
            set payload [_captureAiResultJson $commandId $result]
            if {![_captureAiLifecycleIsCurrent $generation Active]} {
                return
            }
            _captureAiStorePendingResult $generation $commandId $payload
            set postDisposition [_captureAiPostPendingResult $generation]
            if {$postDisposition eq "retry"} {
                set retryPoll 1
            }
        }
    } on error {message options} {
        if {[_captureAiLifecycleIsCurrent $generation Active]} {
            if {[_captureAiPollErrorDisposition $message $options] eq "retry"} {
                set retryPoll 1
            }
        }
    } finally {
        if {$retryPoll} {
            _captureAiSchedulePollRetry $generation
        } else {
            _captureAiScheduleTick $generation
        }
    }
}

proc CaptureAiBridgeDumpPendingResult {path} {
    if {$::CaptureAiBridgePendingResultId eq {} ||
        $::CaptureAiBridgePendingResultJson eq {}} {
        error {Capture AI bridge has no pending result to dump.}
    }
    # Tcl 8.4's `open` rejects the combined "wb" access mode Tcl 8.5+ allows;
    # -translation binary below already does what the "b" suffix would.
    set channel [open $path w]
    try {
        fconfigure $channel -encoding utf-8 -translation binary
        puts -nonewline $channel $::CaptureAiBridgePendingResultJson
    } finally {
        close $channel
    }
}

proc _captureAiRuntimeFile {} {
    if {![info exists ::env(TEMP)] || $::env(TEMP) eq {}} {
        error {TEMP is unavailable; cannot locate Capture AI bridge descriptor.}
    }
    return [file join $::env(TEMP) capture_tcl_bridge.json]
}

proc _captureAiInstallManifestPath {} {
    if {![info exists ::env(LOCALAPPDATA)] || $::env(LOCALAPPDATA) eq {}} {
        return {}
    }
    return [file join $::env(LOCALAPPDATA) capture-tcl-ai-bridge install.json]
}

proc _captureAiReadInstallManifest {path} {
    if {$path eq {} || [catch {file isfile $path} isFile] || !$isFile} {
        return {}
    }
    set parseCode [catch {
        set channel [open $path r]
        try {
            fconfigure $channel -encoding utf-8
            set raw [read $channel]
        } finally {
            close $channel
        }
        set manifest [_captureAiJsonParse $raw]
        foreach key {schemaVersion project pythonTarget} {
            if {![dict exists $manifest $key]} {
                error "install manifest is missing $key"
            }
        }
        if {![string is integer -strict [dict get $manifest schemaVersion]] ||
            ([dict get $manifest schemaVersion] != 1 &&
             [dict get $manifest schemaVersion] != 2 &&
             [dict get $manifest schemaVersion] != 3)} {
            error {install manifest has an unsupported schema version}
        }
        if {[dict get $manifest project] ne {capture-tcl-ai-bridge}} {
            error {install manifest belongs to another project}
        }
        set pythonTarget [dict get $manifest pythonTarget]
        if {[file pathtype $pythonTarget] ne {absolute}} {
            error {install manifest Python target is not absolute}
        }
        file normalize $pythonTarget
    } pythonTarget]
    if {$parseCode != 0} {
        return {}
    }
    return $pythonTarget
}

proc _captureAiResolvePythonPath {} {
    if {[info exists ::CaptureAiBridgePythonPath] &&
        $::CaptureAiBridgePythonPath ne {}} {
        return [file normalize $::CaptureAiBridgePythonPath]
    }
    set pythonTarget [_captureAiReadInstallManifest [_captureAiInstallManifestPath]]
    if {$pythonTarget ne {}} {
        return $pythonTarget
    }
    return {C:/tclpython}
}

proc _captureAiResolvePythonExecutable {} {
    if {[info exists ::CaptureAiBridgePythonExecutable] &&
        $::CaptureAiBridgePythonExecutable ne {}} {
        return [file normalize $::CaptureAiBridgePythonExecutable]
    }

    set missingRuntimeMessage {bundled Python runtime is missing; re-run install.ps1 from the Release ZIP.}
    set parseCode [catch {
        set path [_captureAiInstallManifestPath]
        if {$path eq {} || ![file isfile $path]} { return {} }
        set channel [open $path r]
        try {
            fconfigure $channel -encoding utf-8
            set manifest [_captureAiJsonParse [read $channel]]
        } finally {
            close $channel
        }
        if {[dict get $manifest schemaVersion] != 3 ||
            [dict get $manifest project] ne {capture-tcl-ai-bridge} ||
            ![dict exists $manifest pythonExecutable]} {
            return {}
        }
        set executable [dict get $manifest pythonExecutable]
        if {[file pathtype $executable] ne {absolute} || ![file isfile $executable]} {
            error $missingRuntimeMessage
        }
        file normalize $executable
    } executable]
    if {$parseCode == 0 && $executable ne {}} { return $executable }
    if {$parseCode == 1} {
        if {$executable eq $missingRuntimeMessage} {
            error $executable
        }
        return python
    }
    return python
}

proc _captureAiCreateLaunchSignals {generation} {
    # Tcl 8.4 has no [file tempfile], so create the file with an exclusive open
    # and retry on the unlikely name collision. O_EXCL is what makes this safe;
    # a name that already exists is never reused.
    set launchFile {}
    set channel {}
    for {set attempt 0} {$attempt < 64} {incr attempt} {
        set candidate [file join $::env(TEMP) \
            [format "capture_tcl_bridge_launch_%d_%s_%08x" \
                [pid] $generation [expr {int(rand() * 0x7fffffff)}]]]
        if {![catch {open $candidate {WRONLY CREAT EXCL}} opened]} {
            set launchFile $candidate
            set channel $opened
            break
        }
    }
    if {$channel eq {}} {
        error {Capture AI bridge could not create its launch signal file.}
    }
    set noncePart [format %08x [expr {int(rand() * 0x7fffffff)}]]
    set nonce "${noncePart}-[clock clicks]"
    try {
        if {$::tcl_platform(platform) ne "windows"} {
            file attributes $launchFile -permissions 0600
        }
        fconfigure $channel -encoding binary -translation binary
        puts -nonewline $channel "launch $nonce\n"
        flush $channel
    } finally {
        close $channel
    }
    return [dict create \
        launchFile $launchFile \
        claimFile "${launchFile}.claimed" \
        cancelFile "${launchFile}.cancel" \
        ackFile "${launchFile}.stopped" \
        nonce $nonce]
}

proc _captureAiCreateCancelRequest {path nonce} {
    if {$path eq {} || $nonce eq {}} {
        error {Capture AI bridge cancellation signal is unavailable.}
    }
    if {[catch {set channel [open $path {WRONLY CREAT EXCL}]} openError]} {
        if {[file exists $path]} {
            return exists
        }
        error $openError
    }
    try {
        if {$::tcl_platform(platform) ne "windows"} {
            file attributes $path -permissions 0600
        }
        fconfigure $channel -encoding binary -translation binary
        puts -nonewline $channel "cancel $nonce\n"
        flush $channel
    } finally {
        close $channel
    }
    return created
}

proc _captureAiReadStoppedAck {path nonce} {
    if {$path eq {}} {
        return missing
    }
    if {[catch {file lstat $path metadata}]} {
        return missing
    }
    if {$metadata(type) ne "file" || $metadata(size) > 64} {
        error {Capture AI bridge stopped acknowledgement is not a small regular file.}
    }
    if {[catch {set channel [open $path r]} openError]} {
        if {![file exists $path]} {
            return missing
        }
        error $openError
    }
    try {
        fconfigure $channel -encoding binary -translation binary
        set value [read $channel 65]
    } finally {
        close $channel
    }
    if {$value eq "stopped $nonce\n"} { return stopped }
    error {Capture AI bridge stopped acknowledgement has invalid content.}
}

proc _captureAiReadLaunchClaim {path nonce} {
    if {$path eq {}} { return missing }
    if {[catch {file lstat $path metadata}]} { return missing }
    if {$metadata(type) ne "file" || $metadata(size) > 64} {
        error {Capture AI bridge launch claim is not a small regular file.}
    }
    set channel [open $path r]
    try {
        fconfigure $channel -encoding binary -translation binary
        set value [read $channel 65]
    } finally {
        close $channel
    }
    if {$value eq "claimed $nonce\n"} { return claimed }
    return untrusted
}

proc _captureAiCleanupSignals {} {
    foreach path [list \
        $::CaptureAiBridgeLaunchFile \
        $::CaptureAiBridgeClaimFile \
        $::CaptureAiBridgeCancelFile \
        $::CaptureAiBridgeAckFile] {
        if {$path ne {}} {
            catch {file delete -- $path}
        }
    }
}

proc _captureAiRevokeLaunch {} {
    set claimCode [catch {
        _captureAiReadLaunchClaim \
            $::CaptureAiBridgeClaimFile $::CaptureAiBridgeLaunchNonce
    } claimState]
    if {$claimCode == 0 &&
        ($claimState eq "claimed" || $claimState eq "untrusted")} {
        set ::CaptureAiBridgeLaunchRevoked 0
        set ::CaptureAiBridgeLaunchManaged 1
        set ::CaptureAiBridgeExtraGrace 0
        return managed
    }
    if {$claimCode != 0} {
        set ::CaptureAiBridgeStopError $claimState
        set ::CaptureAiBridgeLaunchManaged 0
        return retry
    }
    if {$::CaptureAiBridgeLaunchFile ne {} &&
        [catch {file delete -- $::CaptureAiBridgeLaunchFile} deleteError]} {
        set ::CaptureAiBridgeStopError \
            "could not revoke launch: [_captureAiSafeError $deleteError]"
        set ::CaptureAiBridgeLaunchRevoked 0
        set ::CaptureAiBridgeLaunchManaged 0
        return retry
    }
    set claimCode [catch {
        _captureAiReadLaunchClaim \
            $::CaptureAiBridgeClaimFile $::CaptureAiBridgeLaunchNonce
    } claimState]
    if {$claimCode == 0 &&
        ($claimState eq "claimed" || $claimState eq "untrusted")} {
        set ::CaptureAiBridgeLaunchRevoked 0
        set ::CaptureAiBridgeLaunchManaged 1
        set ::CaptureAiBridgeExtraGrace 0
        return managed
    }
    if {$claimCode != 0} {
        set ::CaptureAiBridgeStopError $claimState
        set ::CaptureAiBridgeLaunchManaged 0
        return retry
    }
    set ::CaptureAiBridgeLaunchRevoked 1
    set ::CaptureAiBridgeLaunchManaged 0
    set ::CaptureAiBridgeExtraGrace 0
    return revoked
}

proc _captureAiRevokeManagedLaunch {} {
    if {$::CaptureAiBridgeLaunchFile ne {} &&
        [catch {file delete -- $::CaptureAiBridgeLaunchFile} deleteError]} {
        set ::CaptureAiBridgeStopError \
            "could not revoke managed launch: [_captureAiSafeError $deleteError]"
        return retry
    }
    set ::CaptureAiBridgeLaunchManaged 0
    set ::CaptureAiBridgeExtraGrace 0
    set ::CaptureAiBridgeLaunchRevoked 1
    set ::CaptureAiBridgeExtraGrace 1
    return revoked
}

proc _captureAiCompleteStopped {generation {announce 1}} {
    if {$generation != $::CaptureAiBridgeGeneration} {
        return
    }
    _captureAiCleanupSignals
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeClaimFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}
    set ::CaptureAiBridgeLaunchRevoked 0
    set ::CaptureAiBridgeLaunchManaged 0
    set ::CaptureAiBridgeExtraGrace 0
    set ::CaptureAiBridgeStopError {}
    _captureAiClearPendingResult
    if {$announce} {
        puts {Capture AI bridge stopped}
    }
}

proc _captureAiFinishStop {generation attempt} {
    if {$generation != $::CaptureAiBridgeGeneration ||
        !$::CaptureAiBridgeStopping} {
        return
    }
    set ::CaptureAiBridgeAfterId {}
    set controlCode [catch {
        _captureAiReadStoppedAck \
            $::CaptureAiBridgeAckFile $::CaptureAiBridgeLaunchNonce
    } controlState]
    if {$controlCode == 0 && $controlState eq "stopped"} {
        _captureAiCompleteStopped $generation
        return
    }
    if {$attempt >= 59 &&
        $::CaptureAiBridgeLaunchRevoked && $::CaptureAiBridgeExtraGrace} {
        _captureAiConsole {Capture AI bridge received no stopped acknowledgement after managed launch revocation; releasing local lifecycle state}
        _captureAiCompleteStopped $generation 0
        return
    }
    if {$attempt >= 39 && $::CaptureAiBridgeLaunchManaged} {
        set revokeState [_captureAiRevokeManagedLaunch]
        if {$revokeState eq "retry"} {
            _captureAiConsole "Capture AI bridge managed launch revocation is blocked; retrying: $::CaptureAiBridgeStopError"
            set ::CaptureAiBridgeAfterId [after 1000 \
                [list _captureAiFinishStop $generation 39]]
            return
        }
        set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
            [list _captureAiFinishStop $generation 40]]
        return
    }
    if {$attempt >= 39 &&
        $::CaptureAiBridgeLaunchRevoked && !$::CaptureAiBridgeExtraGrace} {
        _captureAiConsole {Capture AI bridge received no stopped acknowledgement after launch revocation; releasing local lifecycle state}
        _captureAiCompleteStopped $generation 0
        return
    }
    if {$attempt >= 19 &&
        !$::CaptureAiBridgeLaunchRevoked &&
        !$::CaptureAiBridgeLaunchManaged} {
        set revokeState [_captureAiRevokeLaunch]
        if {$revokeState eq "retry"} {
            _captureAiConsole "Capture AI bridge launch revocation is blocked; retrying: $::CaptureAiBridgeStopError"
            set ::CaptureAiBridgeAfterId [after 1000 \
                [list _captureAiFinishStop $generation 19]]
            return
        }
        if {$::CaptureAiBridgeStopError eq {}} {
            if {$controlCode != 0} {
                set ::CaptureAiBridgeStopError $controlState
            } else {
                set ::CaptureAiBridgeStopError \
                    {server has not yet written its stopped acknowledgement}
            }
            _captureAiConsole "Capture AI bridge polling stopped; still watching for late server acknowledgement: $::CaptureAiBridgeStopError"
        }
        set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
            [list _captureAiFinishStop $generation 20]]
        return
    }
    set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
        [list _captureAiFinishStop $generation [expr {$attempt + 1}]]]
}

proc _captureAiLoadDescriptor {{path {}}} {
    if {$path eq {}} {
        set path [_captureAiRuntimeFile]
    }
    set channel [open $path r]
    try {
        fconfigure $channel -encoding utf-8
        set raw [read $channel]
    } finally {
        close $channel
    }
    set descriptor [_captureAiJsonParse $raw]
    foreach key {service version protocolVersion baseUrl token capturePid serverPid} {
        if {![dict exists $descriptor $key]} {
            error "Capture AI bridge descriptor is missing $key."
        }
    }
    if {[dict get $descriptor service] ne $::CaptureAiBridgeService} {
        error {Capture AI bridge descriptor has the wrong service.}
    }
    if {[dict get $descriptor version] ne $::CaptureAiBridgeVersion} {
        error {Capture AI bridge descriptor has the wrong software version.}
    }
    if {![string is integer -strict [dict get $descriptor protocolVersion]] ||
        [dict get $descriptor protocolVersion] != $::CaptureAiBridgeProtocolVersion} {
        error {Capture AI bridge descriptor has the wrong protocol version.}
    }
    if {![string is integer -strict [dict get $descriptor capturePid]] ||
        [dict get $descriptor capturePid] != [pid]} {
        error {Capture AI bridge descriptor belongs to another Capture process.}
    }
    if {[dict get $descriptor baseUrl] ne
        "http://127.0.0.1:$::CaptureAiBridgePort"} {
        error {Capture AI bridge descriptor URL is not the configured localhost service.}
    }
    if {[dict get $descriptor token] eq {}} {
        error {Capture AI bridge descriptor token is empty.}
    }
    if {![string is integer -strict [dict get $descriptor serverPid]] ||
        [dict get $descriptor serverPid] <= 0} {
        error {Capture AI bridge descriptor has an invalid server PID.}
    }
    return $descriptor
}

proc _captureAiConnect {generation {attempt {}}} {
    if {$attempt eq {}} {
        set attempt $generation
        set generation $::CaptureAiBridgeGeneration
    }
    if {![_captureAiLifecycleIsCurrent $generation Connecting]} {
        return
    }
    set ::CaptureAiBridgeAfterId {}
    set connectCode [catch {
        set descriptor [_captureAiLoadDescriptor]
        if {$::CaptureAiBridgeOwnedPid ne {} &&
            [dict get $descriptor serverPid] != $::CaptureAiBridgeOwnedPid} {
            error {Capture AI bridge descriptor belongs to another server launch.}
        }
        set ::CaptureAiBridgeToken [dict get $descriptor token]
        set ::CaptureAiBridgeBaseUrl [dict get $descriptor baseUrl]
        set health [_captureAiRequest GET /v1/health]
        if {![_captureAiLifecycleIsCurrent $generation Connecting]} {
            return
        }
        if {![dict exists $health service] ||
            [dict get $health service] ne $::CaptureAiBridgeService ||
            ![dict exists $health version] ||
            [dict get $health version] ne $::CaptureAiBridgeVersion ||
            ![dict exists $health protocolVersion] ||
            [dict get $health protocolVersion] != $::CaptureAiBridgeProtocolVersion ||
            ![dict exists $health capturePid] ||
            [dict get $health capturePid] != [pid]} {
            error {Capture AI bridge health identity does not match.}
        }
    } connectError]
    if {![_captureAiLifecycleIsCurrent $generation Connecting]} {
        return
    }
    if {$connectCode == 0} {
        set ::CaptureAiBridgeConnecting 0
        set ::CaptureAiBridgeActive 1
        puts "Capture AI bridge running at $::CaptureAiBridgeBaseUrl"
        _captureAiScheduleTick $generation
        return
    }

    set safeConnectError [_captureAiSafeError $connectError]
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
    if {$attempt >= 19} {
        set ::CaptureAiBridgeConnecting 0
        _captureAiConsole "Capture AI bridge failed to start on 127.0.0.1:$::CaptureAiBridgePort (port conflict or server startup failure): $safeConnectError"
        set ackCode [catch {
            _captureAiReadStoppedAck \
                $::CaptureAiBridgeAckFile $::CaptureAiBridgeLaunchNonce
        } ackState]
        if {$ackCode == 0 && $ackState eq "stopped"} {
            _captureAiCompleteStopped $generation
        } else {
            CaptureAiBridgeStop
            if {$::CaptureAiBridgeStopping} {
                set revokeState [_captureAiRevokeLaunch]
                if {$::CaptureAiBridgeAfterId ne {}} {
                    catch {after cancel $::CaptureAiBridgeAfterId}
                }
                set drainAttempt [expr {$revokeState eq "retry" ? 19 : 20}]
                set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
                    [list _captureAiFinishStop \
                        $::CaptureAiBridgeGeneration $drainAttempt]]
            }
        }
        return
    }
    set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
        [list _captureAiConnect $generation [expr {$attempt + 1}]]]
}

proc CaptureAiBridgeStart {} {
    if {$::CaptureAiBridgeStopping} {
        set reconcileCode [catch {
            _captureAiReadStoppedAck \
                $::CaptureAiBridgeAckFile $::CaptureAiBridgeLaunchNonce
        } reconcileState]
        if {$reconcileCode == 0 && $reconcileState eq "stopped"} {
            _captureAiCompleteStopped $::CaptureAiBridgeGeneration 0
        }
    }
    if {$::CaptureAiBridgeActive || $::CaptureAiBridgeConnecting ||
        $::CaptureAiBridgeStopping ||
        $::CaptureAiBridgeOwnedPid ne {} ||
        $::CaptureAiBridgeStopError ne {}} {
        CaptureAiBridgeStatus
        return
    }
    if {[catch {package require http} packageError]} {
        _captureAiConsole "Capture AI bridge requires Tcl http package: $packageError"
        return
    }
    set pythonRoot [_captureAiResolvePythonPath]
    set serverScript [file join $pythonRoot capture_tcl_bridge_server.py]
    if {![file exists $serverScript]} {
        _captureAiConsole "Capture AI bridge server not found: $serverScript"
        return
    }

    set runtimeFile [_captureAiRuntimeFile]
    _captureAiResetPollRecoveryState
    _captureAiClearPendingResult
    set generation [incr ::CaptureAiBridgeGeneration]
    if {[catch {
        set signals [_captureAiCreateLaunchSignals $generation]
    } signalError]} {
        _captureAiConsole "Capture AI bridge could not create its launch signals: $signalError"
        return
    }
    set launchFile [dict get $signals launchFile]
    set claimFile [dict get $signals claimFile]
    set cancelFile [dict get $signals cancelFile]
    set ackFile [dict get $signals ackFile]
    set launchNonce [dict get $signals nonce]
    set ::CaptureAiBridgeConnecting 1
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeLaunchFile $launchFile
    set ::CaptureAiBridgeClaimFile $claimFile
    set ::CaptureAiBridgeCancelFile $cancelFile
    set ::CaptureAiBridgeAckFile $ackFile
    set ::CaptureAiBridgeLaunchNonce $launchNonce
    set ::CaptureAiBridgeLaunchRevoked 0
    set ::CaptureAiBridgeLaunchManaged 0
    set ::CaptureAiBridgeExtraGrace 0
    set ::CaptureAiBridgeStopError {}
    set launchCode [catch {
        exec [_captureAiResolvePythonExecutable] $serverScript \
            --host 127.0.0.1 \
            --port $::CaptureAiBridgePort \
            --parent-pid [pid] \
            --runtime-file $runtimeFile \
            --launch-file $launchFile \
            --claim-file $claimFile \
            --cancel-file $cancelFile \
            --ack-file $ackFile &
    } launchResult]
    if {$launchCode != 0} {
        set ::CaptureAiBridgeConnecting 0
        _captureAiCleanupSignals
        set ::CaptureAiBridgeLaunchFile {}
        set ::CaptureAiBridgeClaimFile {}
        set ::CaptureAiBridgeCancelFile {}
        set ::CaptureAiBridgeAckFile {}
        set ::CaptureAiBridgeLaunchNonce {}
        set ::CaptureAiBridgeLaunchRevoked 0
        set ::CaptureAiBridgeLaunchManaged 0
        set ::CaptureAiBridgeExtraGrace 0
        _captureAiConsole "Capture AI bridge failed to launch: [_captureAiSafeError $launchResult]"
        return
    }
    set childPid [lindex $launchResult 0]
    if {![string is integer -strict $childPid] || $childPid <= 0} {
        set ::CaptureAiBridgeConnecting 0
        catch {_captureAiCreateCancelRequest $cancelFile $launchNonce}
        set ::CaptureAiBridgeStopping 1
        set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
            [list _captureAiFinishStop $generation 0]]
        _captureAiConsole {Capture AI bridge launcher did not return a valid child PID.}
        return
    }
    set ::CaptureAiBridgeOwnedPid $childPid
    puts "Capture AI bridge starting on 127.0.0.1:$::CaptureAiBridgePort"
    set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
        [list _captureAiConnect $generation 0]]
}

proc CaptureAiBridgeStatus {} {
    puts "Capture Tcl AI Bridge v$::CaptureAiBridgeVersion"
    if {$::CaptureAiBridgeStopError ne {}} {
        _captureAiConsole "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
    } elseif {$::CaptureAiBridgeStopping} {
        puts {Capture AI bridge stopping; waiting for server acknowledgement}
    } elseif {$::CaptureAiBridgePollingHalted} {
        _captureAiConsole "Capture AI bridge polling halted by protocol error: $::CaptureAiBridgeProtocolError"
    } elseif {$::CaptureAiBridgeActive} {
        puts "Capture AI bridge running at $::CaptureAiBridgeBaseUrl"
    } elseif {$::CaptureAiBridgeConnecting} {
        puts "Capture AI bridge starting on 127.0.0.1:$::CaptureAiBridgePort"
    } else {
        puts {Capture AI bridge stopped}
    }
}

proc CaptureAiBridgeStop {} {
    set stopGeneration [incr ::CaptureAiBridgeGeneration]
    _captureAiResetPollRecoveryState
    _captureAiClearPendingResult
    set wasActive $::CaptureAiBridgeActive
    set wasConnecting $::CaptureAiBridgeConnecting
    set wasStopping $::CaptureAiBridgeStopping
    set priorStopError $::CaptureAiBridgeStopError
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeStopError {}
    if {$::CaptureAiBridgeAfterId ne {}} {
        catch {after cancel $::CaptureAiBridgeAfterId}
    }
    set ::CaptureAiBridgeAfterId {}

    if {!$wasActive && !$wasConnecting && !$wasStopping &&
        $::CaptureAiBridgeOwnedPid eq {} &&
        $::CaptureAiBridgeLaunchFile eq {} &&
        $::CaptureAiBridgeClaimFile eq {} &&
        $::CaptureAiBridgeCancelFile eq {} &&
        $::CaptureAiBridgeAckFile eq {} &&
        $priorStopError eq {} &&
        $::CaptureAiBridgeToken eq {} &&
        $::CaptureAiBridgeBaseUrl eq {}} {
        _captureAiCompleteStopped $stopGeneration
        return
    }

    set canRequestShutdown [expr {
        $::CaptureAiBridgeToken ne {} &&
        $::CaptureAiBridgeBaseUrl ne {} &&
        ($wasActive || $wasConnecting || $::CaptureAiBridgeOwnedPid ne {} ||
            $priorStopError ne {})}]
    if {$::CaptureAiBridgeLaunchFile eq {} &&
        $::CaptureAiBridgeClaimFile eq {} &&
        $::CaptureAiBridgeCancelFile eq {} &&
        $::CaptureAiBridgeAckFile eq {}} {
        if {$canRequestShutdown} {
            set shutdownCode [catch {
                _captureAiRequest POST /internal/shutdown {{}}
            } shutdownError]
            if {$stopGeneration != $::CaptureAiBridgeGeneration} {
                return
            }
            if {$shutdownCode == 0} {
                _captureAiCompleteStopped $stopGeneration
            } else {
                set safeShutdownError [_captureAiSafeError $shutdownError]
                set ::CaptureAiBridgeStopError \
                    "legacy authenticated shutdown failed: $safeShutdownError"
                _captureAiConsole "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
            }
        } else {
            set ::CaptureAiBridgeStopError {launch control is unavailable}
            _captureAiConsole "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
        }
        return
    }

    set ackCode [catch {
        _captureAiReadStoppedAck \
            $::CaptureAiBridgeAckFile $::CaptureAiBridgeLaunchNonce
    } ackState]
    if {$ackCode == 0 && $ackState eq "stopped"} {
        _captureAiCompleteStopped $stopGeneration
        return
    }
    set markerCode [catch {
        _captureAiCreateCancelRequest \
            $::CaptureAiBridgeCancelFile $::CaptureAiBridgeLaunchNonce
    } markerState]
    if {$markerCode != 0} {
        set ::CaptureAiBridgeToken {}
        set ::CaptureAiBridgeBaseUrl {}
        set ::CaptureAiBridgeStopError \
            "could not create launch cancellation request: [_captureAiSafeError $markerState]"
        _captureAiConsole "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
        return
    }
    set ::CaptureAiBridgeStopping 1
    if {$canRequestShutdown} {
        set shutdownCode [catch {
            _captureAiRequest POST /internal/shutdown {{}}
        } shutdownError]
        if {$stopGeneration != $::CaptureAiBridgeGeneration} {
            return
        }
        if {$shutdownCode != 0} {
            _captureAiConsole "Capture AI bridge shutdown response was lost; waiting for launch cancellation: [_captureAiSafeError $shutdownError]"
        }
    }
    if {$stopGeneration != $::CaptureAiBridgeGeneration} {
        return
    }
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
    puts {Capture AI bridge stopping; waiting for server acknowledgement}
    set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
        [list _captureAiFinishStop $stopGeneration 0]]
}
