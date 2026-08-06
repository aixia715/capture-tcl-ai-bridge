# Authenticated localhost bridge for executing Tcl in Capture's interpreter.
# Sourcing this module is side-effect free; lifecycle is always explicit.

set ::CaptureAiBridgeService {capture-tcl-bridge}
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
            {\\} { append encoded {\\\\} }
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

proc _captureAiRestorePuts {original} {
    if {[llength [info commands ::puts]] > 0} {
        trace remove execution ::puts leave _captureAiTeePuts
        rename ::puts {}
    }
    if {[llength [info commands $original]] == 0} {
        error {unable to restore the original puts command}
    }
    rename $original ::puts
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
    set installCode [catch {
        if {[llength [info commands $original]] > 0} {
            error {capture puts staging command already exists}
        }
        rename ::puts $original
        set movedOriginal 1
        interp alias {} ::puts {} $original
        trace add execution ::puts leave _captureAiTeePuts
    } installResult installOptions]

    if {$installCode != 0} {
        set restoreCode [catch {
            if {$movedOriginal && [llength [info commands $original]] > 0} {
                if {[llength [info commands ::puts]] > 0} {
                    rename ::puts {}
                }
                rename $original ::puts
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
            [list catch $script $resultVariable $optionsVariable]]
        set result [set $resultVariable]
        set executionOptions [set $optionsVariable]
    } finally {
        unset -nocomplain $resultVariable $optionsVariable
    }
    set restoreCode [catch {_captureAiRestorePuts $original} restoreResult restoreOptions]

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
    return [expr {min($::CaptureAiBridgeMetadataLimit, 4194304)}]
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

proc _captureAiRequest {method path {payload {}}} {
    if {$::CaptureAiBridgeBaseUrl ne "http://127.0.0.1:$::CaptureAiBridgePort"} {
        error {Capture AI bridge URL is not the configured localhost service.}
    }
    if {$::CaptureAiBridgeToken eq {}} {
        error {Capture AI bridge token is unavailable.}
    }
    if {$method ni {GET POST} || ![string match {/*} $path]} {
        error {Invalid Capture AI bridge request.}
    }

    set headers [list \
        Authorization "Bearer $::CaptureAiBridgeToken" \
        X-Capture-Pid [pid]]
    set requestOptions [list \
        -headers $headers \
        -timeout 1500 \
        -binary true]
    if {$method eq "POST"} {
        lappend requestOptions \
            -method POST \
            -type {application/json; charset=utf-8} \
            -query [encoding convertto utf-8 $payload]
    } else {
        lappend requestOptions -method GET
    }

    set httpToken {}
    try {
        set httpToken [::http::geturl \
            "${::CaptureAiBridgeBaseUrl}${path}" {*}$requestOptions]
        if {[::http::status $httpToken] ne "ok"} {
            error {Capture AI bridge HTTP transport failed.}
        }
        set statusCode [::http::ncode $httpToken]
        if {$statusCode < 200 || $statusCode >= 300} {
            error "Capture AI bridge returned HTTP $statusCode."
        }
        set response [encoding convertfrom utf-8 [::http::data $httpToken]]
        if {$response eq {}} {
            return {}
        }
        return [::json::json2dict $response]
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

proc _captureAiScheduleTick {{generation {}}} {
    if {$generation eq {}} {
        set generation $::CaptureAiBridgeGeneration
    }
    if {[_captureAiLifecycleIsCurrent $generation Active]} {
        set ::CaptureAiBridgeAfterId \
            [after $::CaptureAiBridgePollMs [list _captureAiTick $generation]]
    }
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
                set pendingId $::CaptureAiBridgePendingResultId
                set pendingJson $::CaptureAiBridgePendingResultJson
                _captureAiRequest POST /internal/result $pendingJson
                if {[_captureAiLifecycleIsCurrent $generation Active] &&
                    $::CaptureAiBridgePendingResultId eq $pendingId &&
                    $::CaptureAiBridgePendingResultJson eq $pendingJson &&
                    $::CaptureAiBridgePendingResultGeneration eq $generation} {
                    _captureAiClearPendingResult
                }
                return
            }
        }
        set command [_captureAiRequest GET /internal/command]
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
            _captureAiRequest POST /internal/result $payload
            if {![_captureAiLifecycleIsCurrent $generation Active]} {
                return
            }
            if {$::CaptureAiBridgePendingResultId eq $commandId &&
                $::CaptureAiBridgePendingResultJson eq $payload &&
                $::CaptureAiBridgePendingResultGeneration eq $generation} {
                _captureAiClearPendingResult
            }
        }
    } on error {message options} {
        if {[_captureAiLifecycleIsCurrent $generation Active]} {
            puts stderr "Capture AI bridge poll failed: [_captureAiSafeError $message]"
        }
    } finally {
        _captureAiScheduleTick $generation
    }
}

proc _captureAiRuntimeFile {} {
    if {![info exists ::env(TEMP)] || $::env(TEMP) eq {}} {
        error {TEMP is unavailable; cannot locate Capture AI bridge descriptor.}
    }
    return [file join $::env(TEMP) capture_tcl_bridge.json]
}

proc _captureAiCreateLaunchSignals {generation} {
    set template [file join $::env(TEMP) \
        "capture_tcl_bridge_launch_[pid]_${generation}_XXXXXXXX"]
    set channel [file tempfile launchFile $template]
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
        puts stderr {Capture AI bridge received no stopped acknowledgement after managed launch revocation; releasing local lifecycle state}
        _captureAiCompleteStopped $generation 0
        return
    }
    if {$attempt >= 39 && $::CaptureAiBridgeLaunchManaged} {
        set revokeState [_captureAiRevokeManagedLaunch]
        if {$revokeState eq "retry"} {
            puts stderr "Capture AI bridge managed launch revocation is blocked; retrying: $::CaptureAiBridgeStopError"
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
        puts stderr {Capture AI bridge received no stopped acknowledgement after launch revocation; releasing local lifecycle state}
        _captureAiCompleteStopped $generation 0
        return
    }
    if {$attempt >= 19 &&
        !$::CaptureAiBridgeLaunchRevoked &&
        !$::CaptureAiBridgeLaunchManaged} {
        set revokeState [_captureAiRevokeLaunch]
        if {$revokeState eq "retry"} {
            puts stderr "Capture AI bridge launch revocation is blocked; retrying: $::CaptureAiBridgeStopError"
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
            puts stderr "Capture AI bridge polling stopped; still watching for late server acknowledgement: $::CaptureAiBridgeStopError"
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
    set descriptor [::json::json2dict $raw]
    foreach key {service protocolVersion baseUrl token capturePid serverPid} {
        if {![dict exists $descriptor $key]} {
            error "Capture AI bridge descriptor is missing $key."
        }
    }
    if {[dict get $descriptor service] ne $::CaptureAiBridgeService} {
        error {Capture AI bridge descriptor has the wrong service.}
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
        puts stderr "Capture AI bridge failed to start on 127.0.0.1:$::CaptureAiBridgePort (port conflict or server startup failure): $safeConnectError"
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
        puts stderr "Capture AI bridge requires Tcl http package: $packageError"
        return
    }
    if {[catch {package require json} packageError]} {
        puts stderr "Capture AI bridge requires Tcl json package: $packageError"
        return
    }
    if {[info exists ::TclPythonPath]} {
        set pythonRoot $::TclPythonPath
    } else {
        set pythonRoot {C:/tclpython}
    }
    set serverScript [file join $pythonRoot capture_tcl_bridge_server.py]
    if {![file exists $serverScript]} {
        puts stderr "Capture AI bridge server not found: $serverScript"
        return
    }

    set runtimeFile [_captureAiRuntimeFile]
    _captureAiClearPendingResult
    set generation [incr ::CaptureAiBridgeGeneration]
    if {[catch {
        set signals [_captureAiCreateLaunchSignals $generation]
    } signalError]} {
        puts stderr "Capture AI bridge could not create its launch signals: $signalError"
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
        exec python $serverScript \
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
        puts stderr "Capture AI bridge failed to launch: [_captureAiSafeError $launchResult]"
        return
    }
    set childPid [lindex $launchResult 0]
    if {![string is integer -strict $childPid] || $childPid <= 0} {
        set ::CaptureAiBridgeConnecting 0
        catch {_captureAiCreateCancelRequest $cancelFile $launchNonce}
        set ::CaptureAiBridgeStopping 1
        set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
            [list _captureAiFinishStop $generation 0]]
        puts stderr {Capture AI bridge launcher did not return a valid child PID.}
        return
    }
    set ::CaptureAiBridgeOwnedPid $childPid
    puts "Capture AI bridge starting on 127.0.0.1:$::CaptureAiBridgePort"
    set ::CaptureAiBridgeAfterId [after $::CaptureAiBridgePollMs \
        [list _captureAiConnect $generation 0]]
}

proc CaptureAiBridgeStatus {} {
    if {$::CaptureAiBridgeStopError ne {}} {
        puts stderr "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
    } elseif {$::CaptureAiBridgeStopping} {
        puts {Capture AI bridge stopping; waiting for server acknowledgement}
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
                puts stderr "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
            }
        } else {
            set ::CaptureAiBridgeStopError {launch control is unavailable}
            puts stderr "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
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
        puts stderr "Capture AI bridge polling stopped; server cleanup required: $::CaptureAiBridgeStopError"
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
            puts stderr "Capture AI bridge shutdown response was lost; waiting for launch cancellation: [_captureAiSafeError $shutdownError]"
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
