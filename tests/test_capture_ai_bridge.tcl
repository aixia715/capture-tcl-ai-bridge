# Headless tests for captureAiBridge.tcl.  Run with: tclsh tests/test_capture_ai_bridge.tcl

set repoRoot [file normalize [file join [file dirname [info script]] ..]]
set bridgeFile [file join $repoRoot captureAiBridge.tcl]
set ::fail 0
set oldCaptureAiBridgePythonPathExists [info exists ::CaptureAiBridgePythonPath]
if {$oldCaptureAiBridgePythonPathExists} {
    set oldCaptureAiBridgePythonPath $::CaptureAiBridgePythonPath
}
set ::CaptureAiBridgePythonPath $repoRoot

proc check {description actual expected} {
    if {$actual ne $expected} {
        if {[llength [info commands ::captureAiNativePuts]] > 0} {
            ::captureAiNativePuts stderr "FAIL: $description -> got '{$actual}', want '{$expected}'"
        } else {
            ::puts stderr "FAIL: $description -> got '{$actual}', want '{$expected}'"
        }
        set ::fail 1
    }
}

proc checkTrue {description value} {
    if {!$value} {
        if {[llength [info commands ::captureAiNativePuts]] > 0} {
            ::captureAiNativePuts stderr "FAIL: $description"
        } else {
            ::puts stderr "FAIL: $description"
        }
        set ::fail 1
    }
}

# lrepeat is Tcl 8.5+; this test builds oversized fixture lists with it below.
# The bridge under test never calls lrepeat, so this shim lives here rather
# than in captureAiBridge.tcl's compatibility section.
if {[llength [info commands ::lrepeat]] == 0} {
    proc ::lrepeat {count item} {
        set result {}
        for {set i 0} {$i < $count} {incr i} {
            lappend result $item
        }
        return $result
    }
}

# lsearch -index is Tcl 8.5+; this test only ever uses it to count captured
# request/call log entries whose Nth element matches a value, so a small
# counting helper replaces every such call below.
proc ::captureAiCountByIndex {list index value} {
    set count 0
    foreach entry $list {
        if {[lindex $entry $index] eq $value} {
            incr count
        }
    }
    return $count
}

set beforeAfter [after info]
source $bridgeFile
check {source preserves explicit Python path} $::CaptureAiBridgePythonPath $repoRoot
check {service name} $::CaptureAiBridgeService {capture-tcl-bridge}
check {software version} $::CaptureAiBridgeVersion {0.1.0-beta.2}
check {protocol version} $::CaptureAiBridgeProtocolVersion 1
check {port} $::CaptureAiBridgePort 8767
check {poll period} $::CaptureAiBridgePollMs 250
check {field limit} $::CaptureAiBridgeFieldLimit 4194304
set metadataLimitAtSource {<missing>}
if {[info exists ::CaptureAiBridgeMetadataLimit]} {
    set metadataLimitAtSource $::CaptureAiBridgeMetadataLimit
}
check {metadata limit} $metadataLimitAtSource 4194304
check {source leaves bridge inactive} $::CaptureAiBridgeActive 0
check {source leaves bridge disconnected} $::CaptureAiBridgeConnecting 0
check {source has no callback id} $::CaptureAiBridgeAfterId {}
check {source has no token} $::CaptureAiBridgeToken {}
check {source has no base url} $::CaptureAiBridgeBaseUrl {}
check {source defines stopping state} [info exists ::CaptureAiBridgeStopping] 1
check {source defines launch file state} [info exists ::CaptureAiBridgeLaunchFile] 1
check {source defines claim file state} [info exists ::CaptureAiBridgeClaimFile] 1
check {source defines cancel file state} [info exists ::CaptureAiBridgeCancelFile] 1
check {source defines ack file state} [info exists ::CaptureAiBridgeAckFile] 1
check {source defines launch nonce state} [info exists ::CaptureAiBridgeLaunchNonce] 1
check {source defines launch revocation state} [info exists ::CaptureAiBridgeLaunchRevoked] 1
check {source defines managed claim state} [info exists ::CaptureAiBridgeLaunchManaged] 1
check {source defines extra grace state} [info exists ::CaptureAiBridgeExtraGrace] 1
check {source defines pending result id state} [info exists ::CaptureAiBridgePendingResultId] 1
check {source defines pending result JSON state} [info exists ::CaptureAiBridgePendingResultJson] 1
check {source defines pending result generation state} [info exists ::CaptureAiBridgePendingResultGeneration] 1
check {source creates no after task} [after info] $beforeAfter
check {public lifecycle start proc exists} [llength [info commands CaptureAiBridgeStart]] 1
check {public lifecycle status proc exists} [llength [info commands CaptureAiBridgeStatus]] 1
check {public lifecycle stop proc exists} [llength [info commands CaptureAiBridgeStop]] 1

if {[llength [info commands ::_captureAiResolvePythonPath]] > 0} {
    set manifestRoot [file normalize [file join [pwd] capture-ai-install-manifest-[pid]]]
    file mkdir $manifestRoot
    set oldLocalAppDataExists [info exists ::env(LOCALAPPDATA)]
    if {$oldLocalAppDataExists} { set oldLocalAppData $::env(LOCALAPPDATA) }
    set ::env(LOCALAPPDATA) $manifestRoot
    set manifestPath [file join $manifestRoot capture-tcl-ai-bridge install.json]
    file mkdir [file dirname $manifestPath]
    set manifestChannel [open $manifestPath w]
    fconfigure $manifestChannel -encoding utf-8
    puts -nonewline $manifestChannel [format \
        {{"schemaVersion":1,"project":"capture-tcl-ai-bridge","pythonTarget":"%s"}} \
        [string map [list {\\} {/}] [file join $manifestRoot manifest-target]]]
    close $manifestChannel

    set ::CaptureAiBridgePythonPath [file join $manifestRoot explicit-target]
    check {explicit Python path wins over install manifest} \
        [_captureAiResolvePythonPath] [file normalize $::CaptureAiBridgePythonPath]
    unset ::CaptureAiBridgePythonPath
    check {install manifest path uses LOCALAPPDATA} \
        [_captureAiInstallManifestPath] [file normalize $manifestPath]
    check {valid install manifest supplies Python path} \
        [_captureAiResolvePythonPath] [file normalize [file join $manifestRoot manifest-target]]


    set manifestChannel [open $manifestPath w]
    fconfigure $manifestChannel -encoding utf-8
    puts -nonewline $manifestChannel {not JSON}
    close $manifestChannel
    check {malformed manifest falls back to standalone default} \
        [_captureAiResolvePythonPath] {C:/tclpython}

    set manifestChannel [open $manifestPath w]
    fconfigure $manifestChannel -encoding utf-8
    puts -nonewline $manifestChannel \
        {{"schemaVersion":1,"project":"capture-tcl-ai-bridge","pythonTarget":"relative/python"}}
    close $manifestChannel
    check {relative manifest Python path falls back to standalone default} \
        [_captureAiResolvePythonPath] {C:/tclpython}

    proc _captureAiWriteManifest {path body} {
        set channel [open $path w]
        fconfigure $channel -encoding utf-8
        puts -nonewline $channel $body
        close $channel
    }
    set bundledPython [file join $manifestRoot runtime python.exe]
    file mkdir [file dirname $bundledPython]
    set bundledChannel [open $bundledPython w]
    close $bundledChannel
    _captureAiWriteManifest $manifestPath [format \
        {{"schemaVersion":3,"project":"capture-tcl-ai-bridge","pythonTarget":"%s","pythonExecutable":"%s"}} \
        [string map [list {\\} {/}] [file join $manifestRoot manifest-target]] \
        [string map [list {\\} {/}] $bundledPython]]
    check {schema 3 manifest supplies bundled Python executable} \
        [_captureAiResolvePythonExecutable] [file normalize $bundledPython]
    file delete -force -- $bundledPython
    set missingRuntimeCode [catch {_captureAiResolvePythonExecutable} missingRuntimeMessage]
    check {missing bundled Python runtime is an explicit error} $missingRuntimeCode 1
    check {missing bundled Python runtime explains the repair} $missingRuntimeMessage \
        {bundled Python runtime is missing; re-run install.ps1 from the Release ZIP.}

    set manifestTarget [string map [list {\\} {/}] \
        [file join $manifestRoot manifest-target]]
    foreach {label body} [list \
        {manifest missing schemaVersion} \
            [format {{"project":"capture-tcl-ai-bridge","pythonTarget":"%s"}} \
                $manifestTarget] \
        {manifest missing project} \
            [format {{"schemaVersion":1,"pythonTarget":"%s"}} $manifestTarget] \
        {manifest missing pythonTarget} \
            {{"schemaVersion":1,"project":"capture-tcl-ai-bridge"}} \
        {manifest with unsupported schema version} \
            [format \
                {{"schemaVersion":4,"project":"capture-tcl-ai-bridge","pythonTarget":"%s"}} \
                $manifestTarget] \
        {manifest owned by another project} \
            [format {{"schemaVersion":1,"project":"tcl-bom","pythonTarget":"%s"}} \
                $manifestTarget] \
        ] {
        _captureAiWriteManifest $manifestPath $body
        check "$label falls back to standalone default" \
            [_captureAiResolvePythonPath] {C:/tclpython}
    }

    file delete -force -- $manifestPath
    check {absent manifest falls back to standalone default} \
        [_captureAiResolvePythonPath] {C:/tclpython}

    # A stale TCLBOM global must not influence the standalone bridge.
    set ::TclPythonPath [file join $manifestRoot legacy-target]
    check {legacy TclPythonPath is ignored} \
        [_captureAiResolvePythonPath] {C:/tclpython}
    unset ::TclPythonPath

    unset ::env(LOCALAPPDATA)
    check {absent LOCALAPPDATA yields no manifest path} \
        [_captureAiInstallManifestPath] {}
    check {absent LOCALAPPDATA falls back to standalone default} \
        [_captureAiResolvePythonPath] {C:/tclpython}
    set ::env(LOCALAPPDATA) $manifestRoot

    check {resolving the Python path starts nothing} \
        [list [after info] $::CaptureAiBridgeActive $::CaptureAiBridgeConnecting] \
        [list $beforeAfter 0 0]

    rename _captureAiWriteManifest {}
    file delete -force -- $manifestRoot
    if {$oldLocalAppDataExists} {
        set ::env(LOCALAPPDATA) $oldLocalAppData
    } else {
        unset ::env(LOCALAPPDATA)
    }
    set ::CaptureAiBridgePythonPath $repoRoot
} else {
    check {_captureAiResolvePythonPath exists} 0 1
}

set ::CaptureAiBridgeActive 1
set ::CaptureAiBridgeConnecting 1
set ::CaptureAiBridgeAfterId preserve-after
set ::CaptureAiBridgeToken preserve-token
set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
set ::CaptureAiBridgeGeneration 17
set ::CaptureAiBridgeOwnedPid 24680
set ::CaptureAiBridgeStopping 1
set ::CaptureAiBridgeLaunchFile preserve-launch-file
set ::CaptureAiBridgeClaimFile preserve-claim-file
set ::CaptureAiBridgeCancelFile preserve-cancel-file
set ::CaptureAiBridgeAckFile preserve-ack-file
set ::CaptureAiBridgeLaunchNonce preserve-launch-nonce
set ::CaptureAiBridgeLaunchRevoked 1
set ::CaptureAiBridgeLaunchManaged 1
set ::CaptureAiBridgeExtraGrace 1
set ::CaptureAiBridgeMetadataLimit 17
set ::CaptureAiBridgePendingResultId preserve-command
set ::CaptureAiBridgePendingResultJson {{"id":"preserve-command"}}
set ::CaptureAiBridgePendingResultGeneration 17
source $bridgeFile
check {hot source preserves active state} $::CaptureAiBridgeActive 1
check {hot source preserves connecting state} $::CaptureAiBridgeConnecting 1
check {hot source preserves callback id} $::CaptureAiBridgeAfterId preserve-after
check {hot source preserves token} $::CaptureAiBridgeToken preserve-token
check {hot source preserves base URL} $::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
check {hot source preserves lifecycle generation} $::CaptureAiBridgeGeneration 17
check {hot source preserves owned server PID} $::CaptureAiBridgeOwnedPid 24680
check {hot source preserves stopping state} $::CaptureAiBridgeStopping 1
check {hot source preserves launch file} $::CaptureAiBridgeLaunchFile preserve-launch-file
check {hot source preserves claim file} $::CaptureAiBridgeClaimFile preserve-claim-file
check {hot source preserves cancel file} $::CaptureAiBridgeCancelFile preserve-cancel-file
check {hot source preserves ack file} $::CaptureAiBridgeAckFile preserve-ack-file
check {hot source preserves launch nonce} $::CaptureAiBridgeLaunchNonce preserve-launch-nonce
check {hot source preserves launch revocation} $::CaptureAiBridgeLaunchRevoked 1
check {hot source preserves managed claim} $::CaptureAiBridgeLaunchManaged 1
check {hot source preserves extra grace} $::CaptureAiBridgeExtraGrace 1
check {hot source preserves metadata limit} $::CaptureAiBridgeMetadataLimit 17
check {hot source preserves pending result id} $::CaptureAiBridgePendingResultId preserve-command
check {hot source preserves pending result JSON} $::CaptureAiBridgePendingResultJson {{"id":"preserve-command"}}
check {hot source preserves pending result generation} $::CaptureAiBridgePendingResultGeneration 17
set ::CaptureAiBridgeActive 0
set ::CaptureAiBridgeConnecting 0
set ::CaptureAiBridgeAfterId {}
set ::CaptureAiBridgeToken {}
set ::CaptureAiBridgeBaseUrl {}
set ::CaptureAiBridgeGeneration 0
set ::CaptureAiBridgeOwnedPid {}
set ::CaptureAiBridgeStopping 0
set ::CaptureAiBridgeLaunchFile {}
set ::CaptureAiBridgeClaimFile {}
set ::CaptureAiBridgeCancelFile {}
set ::CaptureAiBridgeAckFile {}
set ::CaptureAiBridgeLaunchNonce {}
set ::CaptureAiBridgeLaunchRevoked 0
set ::CaptureAiBridgeLaunchManaged 0
set ::CaptureAiBridgeExtraGrace 0
set ::CaptureAiBridgeMetadataLimit 4194304
set ::CaptureAiBridgePendingResultId {}
set ::CaptureAiBridgePendingResultJson {}
set ::CaptureAiBridgePendingResultGeneration {}

set chinese "\u4E2D\u6587"
set ni "\u4F60"
set controls [format "\"\\\\\b\f\n\r\t%c%s" 1 $chinese]
# $controls carries two literal backslashes, so valid JSON escapes each of
# them: four backslash characters, not two.
set escapedControlPrefix {"\"\\\\\b\f\n\r\t\u0001}
set expectedControlJson "${escapedControlPrefix}${chinese}\""
check {JSON quote controls and unicode} [_captureAiJsonQuote $controls] $expectedControlJson
check {JSON quote empty} [_captureAiJsonQuote {}] {""}
check {JSON array string members} [_captureAiJsonArray [list {a"b} $chinese {}]] [format {["a\"b","%s",""]} $chinese]
set everyControl {}
set everyControlJson [format %c 34]
for {set controlCode 0} {$controlCode < 32} {incr controlCode} {
    append everyControl [format %c $controlCode]
    switch -- $controlCode {
        8  { append everyControlJson {\b} }
        9  { append everyControlJson {\t} }
        10 { append everyControlJson {\n} }
        12 { append everyControlJson {\f} }
        13 { append everyControlJson {\r} }
        default { append everyControlJson [format {\u%04X} $controlCode] }
    }
}
append everyControlJson [format %c 34]
check {JSON quotes every C0 control character} [_captureAiJsonQuote $everyControl] $everyControlJson

set multiResult [_captureAiExecuteScript {
    set ::captureAiTestGlobal changed
    set value "first line\nsecond line"
    set value
}]
check {script writes global scope} $::captureAiTestGlobal changed
check {script keeps multiline result} [dict get $multiResult result] "first line\nsecond line"
check {successful script return code} [dict get $multiResult returnCode] 0
check {successful script has empty stdout} [dict get $multiResult stdout] {}
check {execution result has exactly the protocol keys} [dict keys $multiResult] {returnCode result stdout stderr errorInfo errorCode errorLine stdoutTruncated stderrTruncated resultTruncated}
check {successful script has empty error line} [dict get $multiResult errorLine] {}

set nestedExecution [_captureAiExecuteScript {
    puts -nonewline before
    set ::captureAiNestedInner [_captureAiExecuteScript {puts -nonewline inner}]
    puts -nonewline after
    set value outer-finished
    set value
}]
check {direct nested execute leaves outer successful} [dict get $nestedExecution returnCode] 0
check {direct nested execute keeps outer stdout} [dict get $nestedExecution stdout] beforeafter
check {direct nested execute keeps outer result} [dict get $nestedExecution result] outer-finished
check {direct nested execute returns structured inner error} [dict get $::captureAiNestedInner returnCode] 1
check {direct nested execute has stable error code} [dict get $::captureAiNestedInner errorCode] {CAPTURE AI BRIDGE REENTRANT}
check {direct nested execute leaves no active guard} [info exists ::_captureAiBridgeExecuting] 0
check {direct nested execute restores puts} [llength [info procs ::puts]] 0

set ::captureAiAfterNestedInner {}
set afterNestedExecution [_captureAiExecuteScript {
    puts -nonewline before
    after 0 {set ::captureAiAfterNestedInner [_captureAiExecuteScript {puts -nonewline inner}]}
    update
    puts -nonewline after
    set value after-finished
    set value
}]
check {after callback nested execute leaves outer successful} [dict get $afterNestedExecution returnCode] 0
check {after callback nested execute keeps outer stdout} [dict get $afterNestedExecution stdout] beforeafter
check {after callback nested execute returns structured inner error} [dict get $::captureAiAfterNestedInner returnCode] 1
check {after callback nested execute has stable error code} [dict get $::captureAiAfterNestedInner errorCode] {CAPTURE AI BRIDGE REENTRANT}
check {after callback nested execute leaves no active guard} [info exists ::_captureAiBridgeExecuting] 0

set highSurrogate [format %c 0xD83D]
set lowSurrogate [format %c 0xDE00]
set face "${highSurrogate}${lowSurrogate}"
set replacement [format %c 0xFFFD]
check {surrogate pair JSON is explicit Unicode escapes} [_captureAiJsonQuote $face] {"\ud83d\ude00"}
lassign [_captureAiUtf8Prefix $face 3] pairPrefixThree pairTruncatedThree pairBytesThree
check {surrogate pair does not split at three bytes} $pairPrefixThree {}
check {surrogate pair three-byte prefix truncates} $pairTruncatedThree 1
check {surrogate pair three-byte prefix has zero accepted bytes} $pairBytesThree 0
lassign [_captureAiUtf8Prefix $face 4] pairPrefixFour pairTruncatedFour pairBytesFour
check {surrogate pair fits atomically at four bytes} $pairPrefixFour $face
check {surrogate pair exact limit does not truncate} $pairTruncatedFour 0
check {surrogate pair exact limit has four accepted bytes} $pairBytesFour 4
lassign [_captureAiUtf8Prefix "a$face" 4] pairBoundaryPrefix pairBoundaryTruncated pairBoundaryBytes
check {surrogate pair stays atomic after ASCII boundary} $pairBoundaryPrefix a
check {surrogate pair boundary truncates} $pairBoundaryTruncated 1
check {surrogate pair boundary byte count is ASCII only} $pairBoundaryBytes 1
foreach {lone label} [list $highSurrogate high $lowSurrogate low] {
    check "isolated $label surrogate JSON uses replacement" [_captureAiJsonQuote $lone] {"\ufffd"}
    lassign [_captureAiUtf8Prefix $lone 3] lonePrefix loneTruncated loneBytes
    check "isolated $label surrogate UTF-8 uses replacement" $lonePrefix $replacement
    check "isolated $label surrogate reports non-original content" $loneTruncated 1
    check "isolated $label surrogate uses three bytes" $loneBytes 3
}

rename ::puts ::captureAiNativePuts
proc ::captureAiAliasTarget {args} { return [concat [list alias-target] $args] }
interp alias {} ::puts {} ::captureAiAliasTarget
set savedAlias [interp alias {} ::puts]
set ::CaptureAiBridgeFieldLimit -1
set negativeLimitResult [_captureAiExecuteScript {puts must-not-run}]
check {negative field limit returns structured error} [dict get $negativeLimitResult returnCode] 1
check {negative field limit has stable error code} [dict get $negativeLimitResult errorCode] {CAPTURE AI BRIDGE INVALID FIELD LIMIT}
check {negative field limit preserves puts alias} [interp alias {} ::puts] $savedAlias
check {negative field limit preserves puts alias behavior} [puts stable] {alias-target stable}
check {negative field limit leaves no staging command} [llength [info commands ::_captureAiBridgeOriginalPuts]] 0
check {negative field limit leaves no active guard} [info exists ::_captureAiBridgeExecuting] 0
set ::CaptureAiBridgeFieldLimit 4194304
set ::CaptureAiBridgeFieldLimit 0
set zeroLimitResult [_captureAiExecuteScript {puts -nonewline x; puts -nonewline stderr y; set value z; set value}]
check {zero field limit clips all stdout} [dict get $zeroLimitResult stdout] {}
check {zero field limit clips all stderr} [dict get $zeroLimitResult stderr] {}
check {zero field limit clips result} [dict get $zeroLimitResult result] {}
check {zero field limit sets stdout flag} [dict get $zeroLimitResult stdoutTruncated] 1
check {zero field limit sets stderr flag} [dict get $zeroLimitResult stderrTruncated] 1
check {zero field limit sets result flag} [dict get $zeroLimitResult resultTruncated] 1
set ::CaptureAiBridgeFieldLimit 4194304
set aliasExecution [_captureAiExecuteScript {puts -nonewline aliased; set value okay; set value}]
check {persistent original puts alias is restored} [interp alias {} ::puts] $savedAlias
check {persistent original puts alias still works} [puts restored] {alias-target restored}
check {persistent original puts alias execution captures stdout} [dict get $aliasExecution stdout] aliased
rename ::puts {}
rename ::captureAiNativePuts ::puts

# Replace puts before execute.  The bridge must rename and restore this exact command,
# not assume that its source-time puts is the command installed at execution time.
rename ::puts ::captureAiNativePuts
proc ::captureAiTestSink {args} {
    lappend ::captureAiSinkCalls $args
    return sink-result
}
rename ::captureAiTestSink ::puts
set sinkBody [info body ::puts]
set ::captureAiSinkCalls {}
set teeResult [_captureAiExecuteScript {
    puts alpha
    puts stdout beta
    puts stderr gamma
    puts -nonewline tail
    puts -nonewline stderr err
    return done
}]
check {tee forwards every puts argument list} $::captureAiSinkCalls [list [list alpha] [list stdout beta] [list stderr gamma] [list -nonewline tail] [list -nonewline stderr err]]
check {tee captures stdout default explicit and nonewline} [dict get $teeResult stdout] "alpha\nbeta\ntail"
check {tee captures stderr and nonewline} [dict get $teeResult stderr] "gamma\nerr"
check {tee preserves return code} [dict get $teeResult returnCode] 2
check {tee restores custom puts after return} [info body ::puts] $sinkBody
check {tee has no original puts command after return} [llength [info commands ::_captureAiBridgeOriginalPuts]] 0
check {tee has no capture state after return} [info exists ::_captureAiBridgeStdout] 0
check {tee has no stdout stopped state after return} [info exists ::_captureAiBridgeStdoutStopped] 0
check {tee has no stderr stopped state after return} [info exists ::_captureAiBridgeStderrStopped] 0

foreach {script expectedCode label} {
    {error boom} 1 error
    {return returned} 2 return
    {break} 3 break
    {continue} 4 continue
} {
    set restoredResult [_captureAiExecuteScript $script]
    check "tee keeps code for $label" [dict get $restoredResult returnCode] $expectedCode
    check "tee restores custom puts after $label" [info body ::puts] $sinkBody
    check "tee removes original command after $label" [llength [info commands ::_captureAiBridgeOriginalPuts]] 0
}

set errorResult [_captureAiExecuteScript {error {specific failure} {detail line} {MY CODE}}]
check {error has Tcl code} [dict get $errorResult returnCode] 1
check {error preserves result} [dict get $errorResult result] {specific failure}
checkTrue {error preserves errorInfo} [expr {[string first {detail line} [dict get $errorResult errorInfo]] >= 0}]
check {error preserves errorCode Tcl list} [dict get $errorResult errorCode] {MY CODE}
# Tcl 8.4's catch has no options dictionary and therefore no -errorline, so
# Capture 16.6 reports a null errorLine. The design calls for extracting
# -errorline "when present", so assert whichever the interpreter can supply.
set haveErrorLine [expr {![catch {catch {} _captureAiLineProbeResult _captureAiLineProbeOptions}]}]
unset -nocomplain _captureAiLineProbeResult _captureAiLineProbeOptions
check {error records errorLine only where catch reports one} \
    [expr {[dict get $errorResult errorLine] ne {}}] $haveErrorLine
foreach {script expectedLine label} [list \
    "error first-line" 1 first \
    "set first 1\nerror second-line" 2 second \
    "set first 1\nset second 2\nerror third-line" 3 third] {
    if {!$haveErrorLine} { set expectedLine {} }
    set lineResult [_captureAiExecuteScript $script]
    check "global catch reports exact $label script error line" \
        [dict get $lineResult errorLine] $expectedLine
}
check {global catch temporary result variables are cleaned} \
    [llength [info globals _captureAiBridgeCatchResult_*]] 0
check {global catch temporary options variables are cleaned} \
    [llength [info globals _captureAiBridgeCatchOptions_*]] 0
set afterError [_captureAiExecuteScript {set value still-works; set value}]
check {script works after error} [dict get $afterError result] still-works

# Restore native puts so invalid syntax has the usual Tcl error and regular files can
# prove they are forwarded without becoming bridge output.
rename ::puts {}
rename ::captureAiNativePuts ::puts
set nativeInvalid [_captureAiExecuteScript {puts -nonewline stdout one two}]
check {invalid puts keeps original error code} [dict get $nativeInvalid returnCode] 1
checkTrue {invalid puts keeps original error text} [string match {wrong # args:*} [dict get $nativeInvalid result]]
check {invalid puts does not capture} [dict get $nativeInvalid stdout] {}
check {invalid puts restores native command} [llength [info procs ::puts]] 0

proc ::captureAiCompletionPuts {args} {
    switch -- $::captureAiCompletionMode {
        return { return -code return completion-return }
        break { return -code break completion-break }
        continue { return -code continue completion-continue }
        error { return -code error -errorcode {CAPTURE COMPLETION} -errorinfo {fixed completion error info} completion-error }
    }
}
proc ::captureAiRunCompletionDirect {} {
    uplevel #0 {
        set code [_captureAiCatch {puts completion} value options]
        list $code $value $options
    }
}
rename ::puts ::captureAiNativePuts
rename ::captureAiCompletionPuts ::puts
set completionChecks {}
foreach mode {return break continue error} {
    set ::captureAiCompletionMode $mode
    lassign [::captureAiRunCompletionDirect] directCode directValue directOptions
    set bridgedCompletion [_captureAiExecuteScript {
        set code [_captureAiCatch {puts completion} value options]
        list $code $value $options
    }]
    set bridgedValues [dict get $bridgedCompletion result]
    lappend completionChecks [list $mode [lindex $bridgedValues 0] $directCode [lindex $bridgedValues 1] $directValue [lindex $bridgedValues 2] $directOptions]
}
rename ::puts {}
rename ::captureAiNativePuts ::puts
rename ::captureAiRunCompletionDirect {}
foreach completionCheck $completionChecks {
    lassign $completionCheck mode bridgedCode directCode bridgedValue directValue bridgedOptions directOptions
    check "puts completion code is transparent for $mode" $bridgedCode $directCode
    check "puts completion result is transparent for $mode" $bridgedValue $directValue
    check "puts completion options are transparent for $mode" $bridgedOptions $directOptions
}

rename ::puts ::captureAiNativePuts
proc ::captureAiConflictPuts {args} { return [concat [list conflict] $args] }
rename ::captureAiConflictPuts ::puts
set conflictPutsBody [info body ::puts]
proc ::_captureAiBridgeOriginalPuts {} { return collision }
set conflictStageBody [info body ::_captureAiBridgeOriginalPuts]
set conflictResult [_captureAiExecuteScript {puts should-not-run}]
set conflictCurrentPutsBody [info body ::puts]
set conflictCurrentPutsCallCode [catch {puts unchanged} conflictCurrentPutsValue]
set conflictStageExists [llength [info commands ::_captureAiBridgeOriginalPuts]]
if {$conflictStageExists} {
    set conflictCurrentStageBody [info body ::_captureAiBridgeOriginalPuts]
    set conflictCurrentStageCallCode [catch {::_captureAiBridgeOriginalPuts} conflictCurrentStageValue]
}
rename ::puts {}
rename ::captureAiNativePuts ::puts
check {staging conflict returns structured error} [dict get $conflictResult returnCode] 1
check {staging conflict preserves current puts body} $conflictCurrentPutsBody $conflictPutsBody
check {staging conflict preserves current puts behavior} $conflictCurrentPutsCallCode 0
check {staging conflict preserves current puts result} $conflictCurrentPutsValue {conflict unchanged}
check {staging conflict preserves staging command} $conflictStageExists 1
if {$conflictStageExists} {
    check {staging conflict preserves staging command body} $conflictCurrentStageBody $conflictStageBody
    check {staging conflict preserves staging command behavior} $conflictCurrentStageCallCode 0
    check {staging conflict preserves staging command result} $conflictCurrentStageValue collision
    rename ::_captureAiBridgeOriginalPuts {}
}

set outputFile [file join [pwd] capture-ai-bridge-output.tmp]
set fileChannel [open $outputFile w]
set fileResult [_captureAiExecuteScript [list puts $fileChannel {only in file}]]
close $fileChannel
set readChannel [open $outputFile r]
set fileContents [read $readChannel]
close $readChannel
file delete -force $outputFile
check {ordinary file puts is forwarded} $fileContents "only in file\n"
check {ordinary file puts is not stdout capture} [dict get $fileResult stdout] {}
check {ordinary file puts is not stderr capture} [dict get $fileResult stderr] {}

# A small injected limit makes independent, incremental clipping observable without
# allocating three 4 MiB fixtures.
rename ::puts ::captureAiNativePuts
proc ::captureAiLimitSink {args} { return {} }
rename ::captureAiLimitSink ::puts
set ::CaptureAiBridgeFieldLimit 100
set ::captureAiHighForAppend $highSurrogate
set highAppendResult [_captureAiExecuteScript {
    puts -nonewline $::captureAiHighForAppend
    puts -nonewline abc
    set value okay
    set value
}]
check {isolated high stdout keeps later output} [dict get $highAppendResult stdout] "${replacement}abc"
check {isolated high stdout keeps protocol flag} [dict get $highAppendResult stdoutTruncated] 1
check {isolated high stdout does not set stderr flag} [dict get $highAppendResult stderrTruncated] 0
check {isolated high stdout does not set result flag} [dict get $highAppendResult resultTruncated] 0
lassign [_captureAiUtf8Prefix "${highSurrogate}abc" 100] highAppendPrefix highAppendFlag highAppendBytes
check {isolated high plus later output prefix is complete} $highAppendPrefix "${replacement}abc"
check {isolated high plus later output byte count} $highAppendBytes 6
check {isolated high plus later output retains protocol flag} $highAppendFlag 1

set ::captureAiLowForAppend $lowSurrogate
set lowAppendResult [_captureAiExecuteScript {
    puts -nonewline stderr $::captureAiLowForAppend
    puts -nonewline stderr abc
    set value okay
    set value
}]
check {isolated low stderr keeps later output} [dict get $lowAppendResult stderr] "${replacement}abc"
check {isolated low stderr keeps protocol flag} [dict get $lowAppendResult stderrTruncated] 1
check {isolated low stderr does not set stdout flag} [dict get $lowAppendResult stdoutTruncated] 0
check {isolated low stderr does not set result flag} [dict get $lowAppendResult resultTruncated] 0
lassign [_captureAiUtf8Prefix "${lowSurrogate}abc" 100] lowAppendPrefix lowAppendFlag lowAppendBytes
check {isolated low plus later output prefix is complete} $lowAppendPrefix "${replacement}abc"
check {isolated low plus later output byte count} $lowAppendBytes 6
check {isolated low plus later output retains protocol flag} $lowAppendFlag 1

set ::CaptureAiBridgeFieldLimit 4
set ::captureAiThreeByteCharacter $ni
set stdoutRealLimit [_captureAiExecuteScript {
    puts -nonewline "ab$::captureAiThreeByteCharacter"
    puts -nonewline cd
    set value okay
    set value
}]
check {real stdout limit keeps only first prefix} [dict get $stdoutRealLimit stdout] ab
check {real stdout limit stops later writes} [dict get $stdoutRealLimit stdout] ab
check {real stdout limit sets protocol flag} [dict get $stdoutRealLimit stdoutTruncated] 1
check {real stdout limit leaves stderr flag clear} [dict get $stdoutRealLimit stderrTruncated] 0
check {real stdout limit leaves result flag clear} [dict get $stdoutRealLimit resultTruncated] 0

set stderrRealLimit [_captureAiExecuteScript {
    puts -nonewline stderr "ab$::captureAiThreeByteCharacter"
    puts -nonewline stderr cd
    set value okay
    set value
}]
check {real stderr limit keeps only first prefix} [dict get $stderrRealLimit stderr] ab
check {real stderr limit stops later writes} [dict get $stderrRealLimit stderr] ab
check {real stderr limit sets protocol flag} [dict get $stderrRealLimit stderrTruncated] 1
check {real stderr limit leaves stdout flag clear} [dict get $stderrRealLimit stdoutTruncated] 0
check {real stderr limit leaves result flag clear} [dict get $stderrRealLimit resultTruncated] 0

set ::CaptureAiBridgeFieldLimit 5
set stdoutOnly [_captureAiExecuteScript {
    puts -nonewline abcdef
    puts -nonewline stderr 12
    set value okay
    set value
}]
check {stdout-only clipping keeps stdout prefix} [dict get $stdoutOnly stdout] abcde
check {stdout-only clipping keeps stderr} [dict get $stdoutOnly stderr] 12
check {stdout-only clipping keeps result} [dict get $stdoutOnly result] okay
check {stdout-only clipping sets stdout flag} [dict get $stdoutOnly stdoutTruncated] 1
check {stdout-only clipping leaves stderr flag clear} [dict get $stdoutOnly stderrTruncated] 0
check {stdout-only clipping leaves result flag clear} [dict get $stdoutOnly resultTruncated] 0

set stderrOnly [_captureAiExecuteScript {
    puts -nonewline 12
    puts -nonewline stderr abcdef
    set value okay
    set value
}]
check {stderr-only clipping keeps stdout} [dict get $stderrOnly stdout] 12
check {stderr-only clipping keeps stderr prefix} [dict get $stderrOnly stderr] abcde
check {stderr-only clipping keeps result} [dict get $stderrOnly result] okay
check {stderr-only clipping leaves stdout flag clear} [dict get $stderrOnly stdoutTruncated] 0
check {stderr-only clipping sets stderr flag} [dict get $stderrOnly stderrTruncated] 1
check {stderr-only clipping leaves result flag clear} [dict get $stderrOnly resultTruncated] 0

set resultOnly [_captureAiExecuteScript {
    puts -nonewline 12
    puts -nonewline stderr 34
    string repeat x 6
}]
check {result-only clipping keeps stdout} [dict get $resultOnly stdout] 12
check {result-only clipping keeps stderr} [dict get $resultOnly stderr] 34
check {result-only clipping keeps result prefix} [dict get $resultOnly result] xxxxx
check {result-only clipping leaves stdout flag clear} [dict get $resultOnly stdoutTruncated] 0
check {result-only clipping leaves stderr flag clear} [dict get $resultOnly stderrTruncated] 0
check {result-only clipping sets result flag} [dict get $resultOnly resultTruncated] 1

set clipped [_captureAiExecuteScript {
    puts -nonewline abc
    puts -nonewline def
    puts -nonewline stderr 123
    puts -nonewline stderr 456
    string repeat x 6
}]
check {incremental stdout keeps only limit bytes} [dict get $clipped stdout] abcde
check {incremental stderr keeps only limit bytes} [dict get $clipped stderr] 12345
check {result clips after execution} [dict get $clipped result] xxxxx
check {stdout truncation flag} [dict get $clipped stdoutTruncated] 1
check {stderr truncation flag} [dict get $clipped stderrTruncated] 1
check {result truncation flag} [dict get $clipped resultTruncated] 1

set ::CaptureAiBridgeFieldLimit 4
set utf8Clipped [_captureAiExecuteScript {
    puts -nonewline "a\u4F60b"
    puts -nonewline stderr "a\u4F60b"
    set x "a\u4F60b"
    set x
}]
check {UTF-8 stdout ends at character boundary} [dict get $utf8Clipped stdout] "a$ni"
check {UTF-8 stderr ends at character boundary} [dict get $utf8Clipped stderr] "a$ni"
check {UTF-8 result ends at character boundary} [dict get $utf8Clipped result] "a$ni"
check {UTF-8 stdout clips} [dict get $utf8Clipped stdoutTruncated] 1
check {UTF-8 stderr clips} [dict get $utf8Clipped stderrTruncated] 1
check {UTF-8 result clips} [dict get $utf8Clipped resultTruncated] 1

set exactUtf8 [_captureAiExecuteScript {
    puts -nonewline "a\u4F60"
    puts -nonewline stderr "a\u4F60"
    set x "a\u4F60"
    set x
}]
check {exact UTF-8 stdout limit does not clip} [dict get $exactUtf8 stdoutTruncated] 0
check {exact UTF-8 stderr limit does not clip} [dict get $exactUtf8 stderrTruncated] 0
check {exact UTF-8 result limit does not clip} [dict get $exactUtf8 resultTruncated] 0
set ::CaptureAiBridgeFieldLimit 4194304
rename ::puts {}
rename ::captureAiNativePuts ::puts

# Task 5: polling, authenticated transport, descriptor validation, and explicit
# lifecycle.  External effects are isolated behind replaceable Tcl commands.
if {[llength [info commands ::_captureAiResultJson]] > 0} {
    set resultJson [_captureAiResultJson cmd-json [dict create \
        returnCode 1 \
        result {bad "value"} \
        stdout "out\n" \
        stderr err \
        errorInfo trace \
        errorCode {TEST FAILURE} \
        errorLine {} \
        stdoutTruncated 1 \
        stderrTruncated 0 \
        resultTruncated 1]]
    checkTrue {result JSON contains id} [expr {[string first {"id":"cmd-json"} $resultJson] >= 0}]
    checkTrue {result JSON contains completion code} [expr {[string first {"returnCode":1} $resultJson] >= 0}]
    checkTrue {result JSON quotes strings} [expr {[string first {"result":"bad \"value\""} $resultJson] >= 0}]
    checkTrue {result JSON encodes error code array} [expr {[string first {"errorCode":["TEST","FAILURE"]} $resultJson] >= 0}]
    checkTrue {result JSON uses null error line} [expr {[string first {"errorLine":null} $resultJson] >= 0}]
    checkTrue {result JSON uses boolean literals} [expr {[string first {"stdoutTruncated":true} $resultJson] >= 0 && [string first {"stderrTruncated":false} $resultJson] >= 0}]

    set metadataResult [dict create \
        returnCode 1 result result stdout stdout stderr stderr \
        errorInfo "ab${ni}cde" errorCode [list ab $ni cdef tail] \
        errorLine 2 stdoutTruncated 1 stderrTruncated 0 resultTruncated 1]
    set ::CaptureAiBridgeMetadataLimit 7
    set metadataJson [_captureAiResultJson metadata-command $metadataResult]
    checkTrue {errorInfo uses scalar-safe UTF-8 metadata prefix} \
        [expr {[string first "\"errorInfo\":\"ab${ni}cd\"" $metadataJson] >= 0}]
    checkTrue {errorCode uses one aggregate UTF-8 budget} \
        [expr {[string first "\"errorCode\":\[\"ab\",\"${ni}\",\"cd\"\]" $metadataJson] >= 0}]
    checkTrue {metadata clipping leaves protocol truncation flags unchanged} \
        [expr {[string first {"stdoutTruncated":true} $metadataJson] >= 0 &&
            [string first {"stderrTruncated":false} $metadataJson] >= 0 &&
            [string first {"resultTruncated":true} $metadataJson] >= 0}]

    set emptyCodeJson [_captureAiResultJson empty-codes \
        [dict replace $metadataResult errorInfo {} errorCode [lrepeat 20 {}]]]
    checkTrue {empty errorCode items each consume one aggregate byte} \
        [expr {[string first {"errorCode":["","","","","","",""]} $emptyCodeJson] >= 0}]

    set oversizedCodeJson [_captureAiResultJson oversized-code \
        [dict replace $metadataResult errorInfo {} errorCode [list "${ni}${ni}${ni}" tail]]]
    checkTrue {truncated errorCode item stops the list prefix} \
        [expr {[string first "\"errorCode\":\[\"${ni}${ni}\"\]" $oversizedCodeJson] >= 0}]
    checkTrue {truncated errorCode item omits all later items} \
        [expr {[string first tail $oversizedCodeJson] < 0}]

    set ::CaptureAiBridgeMetadataLimit 3
    set surrogateMetadataJson [_captureAiResultJson surrogate-metadata \
        [dict replace $metadataResult \
            errorInfo "${highSurrogate}x" \
            errorCode [list $highSurrogate x]]]
    checkTrue {isolated surrogate in errorInfo becomes safe replacement} \
        [expr {[string first "\"errorInfo\":\"${replacement}\"" $surrogateMetadataJson] >= 0 &&
            [string first "\"errorInfo\":\"${replacement}x\"" $surrogateMetadataJson] < 0}]
    checkTrue {isolated surrogate replacement is charged by UTF-8 bytes} \
        [expr {[string first "\"errorCode\":\[\"${replacement}\"\]" $surrogateMetadataJson] >= 0}]

    set ::CaptureAiBridgeMetadataLimit -1
    set invalidLimitCode [catch {
        _captureAiResultJson invalid-metadata-limit $metadataResult
    } invalidLimitJson]
    check {invalid metadata limit uses fixed safe behavior} $invalidLimitCode 0
    checkTrue {invalid metadata limit emits empty bounded metadata} \
        [expr {[string first {"errorInfo":""} $invalidLimitJson] >= 0 &&
            [string first {"errorCode":[]} $invalidLimitJson] >= 0}]

    set ::CaptureAiBridgeMetadataLimit 7
    set hugeMetadataJson [_captureAiResultJson huge-metadata \
        [dict replace $metadataResult \
            errorInfo [string repeat [format %c 1] 10000] \
            errorCode [lrepeat 10000 {}]]]
    checkTrue {huge metadata produces a bounded retryable result payload} \
        [expr {[string length [encoding convertto utf-8 $hugeMetadataJson]] < 1000}]
    set derivedWorstCaseJsonBytes [expr {
        ($::CaptureAiBridgeFieldLimit * 3 + 4194304 * 2) * 6 + 4096}]
    checkTrue {default Tcl result JSON bound stays below server body limit} \
        [expr {$derivedWorstCaseJsonBytes < 160 * 1048576}]
    set ::CaptureAiBridgeMetadataLimit 4194304
} else {
    check {_captureAiResultJson exists} 0 1
}

if {[llength [info commands ::_captureAiTick]] > 0} {
    rename ::_captureAiRequest ::captureAiRealRequest
    proc ::_captureAiRequest {method path {payload {}} {extraHeaders {}}} {
        lappend ::captureAiRequests [list $method $path $payload $extraHeaders]
        if {$method eq "GET"} {
            if {$::captureAiPollMode eq "error"} {
                error {poll failed without secret-token}
            }
            if {$::captureAiPollMode eq "command"} {
                set ::captureAiPollMode empty
                return [dict create id cmd-1 script {puts bridge; expr {8 * 8}}]
            }
            if {$::captureAiPollMode eq "unreachable-result-command"} {
                set ::captureAiPollMode empty
                return [dict create id cmd-unreachable script {
                    incr ::captureAiUnreachableExecutions
                    return unreachable-done
                }]
            }
            if {$::captureAiPollMode eq "lost-response-command"} {
                set ::captureAiPollMode empty
                return [dict create id cmd-response-lost script {
                    incr ::captureAiLostResponseExecutions
                    return response-lost-done
                }]
            }
            if {$::captureAiPollMode eq "stop-command"} {
                set ::captureAiPollMode shutdown
                CaptureAiBridgeStop
                return [dict create id stopped-command script {set ::captureAiUnexpectedExecution 1}]
            }
            if {$::captureAiPollMode eq "restart-command"} {
                set ::captureAiPollMode shutdown
                CaptureAiBridgeStop
                incr ::CaptureAiBridgeGeneration
                set ::CaptureAiBridgeActive 1
                set ::CaptureAiBridgeToken new-session-token
                set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
                return [dict create id old-command script {set ::captureAiOldSessionExecuted 1}]
            }
            if {$::captureAiPollMode eq "script-stop"} {
                set ::captureAiPollMode shutdown
                return [dict create id script-stop-command script {
                    CaptureAiBridgeStop
                    set ::captureAiScriptContinuedAfterStop 1
                }]
            }
            if {$::captureAiPollMode eq "stop-result"} {
                set ::captureAiPollMode result-post
                return [dict create id result-stop-command script {
                    set ::captureAiResultStopExecuted 1
                }]
            }
        }
        if {$path eq "/internal/result" &&
            $::captureAiPollMode eq "result-post"} {
            set ::captureAiPollMode shutdown
            CaptureAiBridgeStop
        }
        if {$path eq "/internal/result" &&
            [info exists ::captureAiResultPostFailures] &&
            $::captureAiResultPostFailures > 0} {
            incr ::captureAiResultPostFailures -1
            if {[info exists ::captureAiSimulateDeliveredBeforeFailure] &&
                $::captureAiSimulateDeliveredBeforeFailure} {
                lappend ::captureAiDeliveredResultPayloads $payload
            }
            error {simulated result POST transport failure}
        }
        return {}
    }
    rename ::after ::captureAiRealAfter
    proc ::after {args} {
        lappend ::captureAiAfterCalls $args
        return after-test-[llength $::captureAiAfterCalls]
    }

    set ::CaptureAiBridgeActive 1
    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode command
    _captureAiTick
    check {tick claims before posting} [lrange [lindex $::captureAiRequests 0] 0 1] {GET /internal/command}
    check {tick posts one matching result} [lrange [lindex $::captureAiRequests 1] 0 1] {POST /internal/result}
    set postedPayload [lindex [lindex $::captureAiRequests 1] 2]
    check {normal result post binds pending command id header} \
        [lindex [lindex $::captureAiRequests 1] 3] \
        {X-Capture-Command-Id cmd-1}
    checkTrue {posted result keeps command id} [expr {[string first {"id":"cmd-1"} $postedPayload] >= 0}]
    checkTrue {posted result contains Tcl result} [expr {[string first {"result":"64"} $postedPayload] >= 0}]
    checkTrue {posted result contains captured stdout} [expr {[string first {"stdout":"bridge\n"} $postedPayload] >= 0}]
    check {tick schedules one generation-bound 250 ms callback} [lindex $::captureAiAfterCalls 0] [list $::CaptureAiBridgePollMs [list _captureAiTick 0]]

    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode empty
    _captureAiTick
    check {empty poll makes one request} [llength $::captureAiRequests] 1
    check {empty poll does not post} [lrange [lindex $::captureAiRequests 0] 0 1] {GET /internal/command}
    check {empty poll still schedules} [lindex $::captureAiAfterCalls 0] [list $::CaptureAiBridgePollMs [list _captureAiTick 0]]

    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode unreachable-result-command
    set ::captureAiResultPostFailures 1
    set ::captureAiSimulateDeliveredBeforeFailure 0
    set ::captureAiUnreachableExecutions 0
    _captureAiTick
    check {unreachable POST executes command once} $::captureAiUnreachableExecutions 1
    check {unreachable POST retains pending id} $::CaptureAiBridgePendingResultId cmd-unreachable
    checkTrue {unreachable POST retains pending JSON} [expr {[string first {"id":"cmd-unreachable"} $::CaptureAiBridgePendingResultJson] >= 0}]
    set firstUnreachablePayload $::CaptureAiBridgePendingResultJson
    set ::captureAiRequests {}
    _captureAiTick
    check {pending retry does not GET or re-execute} $::captureAiUnreachableExecutions 1
    check {pending retry makes only one request} [llength $::captureAiRequests] 1
    check {pending retry is a result POST} [lrange [lindex $::captureAiRequests 0] 0 1] {POST /internal/result}
    check {pending retry uses identical JSON} [lindex [lindex $::captureAiRequests 0] 2] $firstUnreachablePayload
    check {pending result post binds retained pending command id header} \
        [lindex [lindex $::captureAiRequests 0] 3] \
        {X-Capture-Command-Id cmd-unreachable}
    check {successful pending retry clears id} $::CaptureAiBridgePendingResultId {}
    check {successful pending retry clears JSON} $::CaptureAiBridgePendingResultJson {}

    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode lost-response-command
    set ::captureAiResultPostFailures 1
    set ::captureAiSimulateDeliveredBeforeFailure 1
    set ::captureAiDeliveredResultPayloads {}
    set ::captureAiLostResponseExecutions 0
    _captureAiTick
    check {lost response executes command once} $::captureAiLostResponseExecutions 1
    check {lost response retains pending id} $::CaptureAiBridgePendingResultId cmd-response-lost
    set lostResponsePayload $::CaptureAiBridgePendingResultJson
    set ::captureAiRequests {}
    _captureAiTick
    check {lost response retry does not re-execute} $::captureAiLostResponseExecutions 1
    check {lost response retry does not GET} [::captureAiCountByIndex $::captureAiRequests 0 GET] 0
    check {lost response retry POSTs identical JSON} [lindex [lindex $::captureAiRequests 0] 2] $lostResponsePayload
    check {lost response retry clears pending after acknowledgement} $::CaptureAiBridgePendingResultId {}
    unset -nocomplain ::captureAiResultPostFailures ::captureAiSimulateDeliveredBeforeFailure

    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode error
    set ::CaptureAiBridgeToken secret-token
    rename ::puts ::captureAiRealPuts
    proc ::puts {args} { lappend ::captureAiPollLogs $args }
    set ::captureAiPollLogs {}
    set pollErrorCode [catch {_captureAiTick} pollError]
    rename ::puts {}
    rename ::captureAiRealPuts ::puts
    check {poll error is contained} $pollErrorCode 0
    check {poll error still schedules} [lindex $::captureAiAfterCalls 0] [list $::CaptureAiBridgePollMs [list _captureAiTick 0]]
    checkTrue {poll log redacts bearer token} [expr {[string first secret-token $::captureAiPollLogs] < 0 && [string first {<redacted>} $::captureAiPollLogs] >= 0}]

    set ::CaptureAiBridgeGeneration 30
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeToken stop-during-claim-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeStopError {}
    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode stop-command
    unset -nocomplain ::captureAiUnexpectedExecution
    set stoppedTickCode [catch {_captureAiTick 30} stoppedTickError]
    check {stop during claim is contained} $stoppedTickCode 0
    check {stop during claim does not execute script} [info exists ::captureAiUnexpectedExecution] 0
    check {stop during claim does not post result} [::captureAiCountByIndex $::captureAiRequests 1 /internal/result] 0
    check {stop during claim does not reschedule old tick} [llength $::captureAiAfterCalls] 0

    set ::CaptureAiBridgeGeneration 40
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeToken old-session-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeStopError {}
    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode restart-command
    unset -nocomplain ::captureAiOldSessionExecuted
    set restartedTickCode [catch {_captureAiTick 40} restartedTickError]
    check {restart during claim is contained} $restartedTickCode 0
    check {old session does not execute after restart} [info exists ::captureAiOldSessionExecuted] 0
    check {old session does not post after restart} [::captureAiCountByIndex $::captureAiRequests 1 /internal/result] 0
    check {old session does not schedule into new lifecycle} [llength $::captureAiAfterCalls] 0

    set ::CaptureAiBridgeGeneration 45
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeToken script-stop-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeStopError {}
    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode script-stop
    unset -nocomplain ::captureAiScriptContinuedAfterStop
    _captureAiTick 45
    check {script can complete locally after stopping bridge} [info exists ::captureAiScriptContinuedAfterStop] 1
    check {script-triggered stop prevents result POST} [::captureAiCountByIndex $::captureAiRequests 1 /internal/result] 0
    check {script-triggered stop prevents reschedule} [llength $::captureAiAfterCalls] 0

    set ::CaptureAiBridgeGeneration 47
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeToken result-stop-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeStopError {}
    set ::captureAiRequests {}
    set ::captureAiAfterCalls {}
    set ::captureAiPollMode stop-result
    unset -nocomplain ::captureAiResultStopExecuted
    _captureAiTick 47
    check {result-stop script executes once} $::captureAiResultStopExecuted 1
    check {result is posted exactly once before reentrant stop} [::captureAiCountByIndex $::captureAiRequests 1 /internal/result] 1
    check {stop during result POST prevents reschedule} [llength $::captureAiAfterCalls] 0
    check {stop during result POST clears pending id} $::CaptureAiBridgePendingResultId {}
    check {stop during result POST clears pending JSON} $::CaptureAiBridgePendingResultJson {}

    rename ::after {}
    rename ::captureAiRealAfter ::after
    rename ::_captureAiRequest {}
    rename ::captureAiRealRequest ::_captureAiRequest
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeStopError {}
} else {
    check {_captureAiTick exists} 0 1
}

# Poll recovery is exercised through the request seam.  The resulting error
# codes mirror the JSON error envelopes returned by the local bridge.
if {[llength [info commands ::_captureAiTick]] > 0} {
    rename ::_captureAiRequest ::captureAiRecoveryRealRequest
    proc ::_captureAiRequest {method path {payload {}} {extraHeaders {}}} {
        lappend ::captureAiRecoveryRequests [list $method $path $payload $extraHeaders]
        switch -- $::captureAiRecoveryMode {
            pending-transport {
                return -code error -errorcode {CAPTURE_AI_BRIDGE TRANSPORT} {offline}
            }
            pending-500 {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 500 SERVER_ERROR {} {}} {server error}
            }
            pending-invalid {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 400 INVALID_RESULT pending-1 completed} {invalid result}
            }
            pending-too-large {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 413 REQUEST_TOO_LARGE pending-1 completed} {result too large}
            }
            pending-stale {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 409 COMMAND_ID_MISMATCH {} {}} {stale result}
            }
            pending-auth {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 401 UNAUTHORIZED {} {}} {not authorized}
            }
            pending-pid-mismatch {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 409 CAPTURE_PID_MISMATCH {} {}} {capture pid mismatch}
            }
            command-transport {
                return -code error -errorcode {CAPTURE_AI_BRIDGE TRANSPORT} {offline}
            }
            command-500 {
                return -code error -errorcode {CAPTURE_AI_BRIDGE HTTP 500 SERVER_ERROR {} {}} {server error}
            }
            default { return {} }
        }
    }
    rename ::after ::captureAiRecoveryRealAfter
    proc ::after {args} {
        lappend ::captureAiRecoveryAfterCalls $args
        return recovery-after-[llength $::captureAiRecoveryAfterCalls]
    }

    set ::CaptureAiBridgeGeneration 200
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeAfterId {}
    set ::CaptureAiBridgeToken recovery-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgePendingResultId pending-1
    set ::CaptureAiBridgePendingResultJson {"id":"pending-1"}
    set ::CaptureAiBridgePendingResultGeneration 200
    set ::captureAiRecoveryRequests {}
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-transport
    _captureAiTick 200
    check {transport retains pending result} $::CaptureAiBridgePendingResultId pending-1
    check {transport retry begins at 250 ms} [lindex [lindex $::captureAiRecoveryAfterCalls 0] 0] 250
    check {pending post carries exact retained id header} [lindex [lindex $::captureAiRecoveryRequests 0] 3] {X-Capture-Command-Id pending-1}

    set retryDelays [list]
    foreach expectedDelay {500 1000 2000 4000 5000 5000} {
        set ::captureAiRecoveryAfterCalls {}
        set ::captureAiRecoveryMode pending-500
        _captureAiTick 200
        lappend retryDelays [lindex [lindex $::captureAiRecoveryAfterCalls 0] 0]
    }
    check {transport and 5xx retry with capped exponential backoff} $retryDelays {500 1000 2000 4000 5000 5000}
    check {5xx retains pending result} $::CaptureAiBridgePendingResultId pending-1

    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-invalid
    _captureAiTick 200
    check {confirmed invalid completed result is discarded} $::CaptureAiBridgePendingResultId {}
    check {confirmed invalid result continues polling} [lindex [lindex $::captureAiRecoveryAfterCalls 0] 0] 250

    _captureAiStorePendingResult 200 pending-1 {"id":"pending-1"}
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-too-large
    _captureAiTick 200
    check {confirmed oversized completed result is discarded} $::CaptureAiBridgePendingResultId {}

    _captureAiStorePendingResult 200 pending-1 {"id":"pending-1"}
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-stale
    _captureAiTick 200
    check {command id mismatch discards stale pending result} $::CaptureAiBridgePendingResultId {}

    _captureAiStorePendingResult 200 pending-1 {"id":"pending-1"}
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-auth
    _captureAiTick 200
    check {unconfirmed 4xx halts polling} $::CaptureAiBridgePollingHalted 1
    checkTrue {unconfirmed 4xx retains protocol error} [expr {$::CaptureAiBridgeProtocolError ne {}}]
    check {halted poll schedules nothing} [llength $::captureAiRecoveryAfterCalls] 0
    check {halted poll retains pending result} $::CaptureAiBridgePendingResultId pending-1

    _captureAiResetPollRecoveryState
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode pending-pid-mismatch
    _captureAiTick 200
    check {capture pid mismatch halts polling} $::CaptureAiBridgePollingHalted 1
    check {capture pid mismatch schedules nothing} [llength $::captureAiRecoveryAfterCalls] 0

    _captureAiResetPollRecoveryState
    _captureAiClearPendingResult
    set ::CaptureAiBridgeActive 1
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode command-transport
    _captureAiTick 200
    check {command transport uses retry delay} [lindex [lindex $::captureAiRecoveryAfterCalls 0] 0] 250
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode command-500
    _captureAiTick 200
    check {command 5xx advances retry delay} [lindex [lindex $::captureAiRecoveryAfterCalls 0] 0] 500
    set ::captureAiRecoveryAfterCalls {}
    set ::captureAiRecoveryMode empty
    _captureAiTick 200
    check {successful command poll resets retry delay} $::CaptureAiBridgeRetryDelayMs 250

    set dumpPath [file join [pwd] capture-ai-pending-dump.json]
    _captureAiStorePendingResult 200 dump-id {"id":"dump-id"}
    CaptureAiBridgeDumpPendingResult $dumpPath
    # Tcl 8.4's open rejects the combined "rb" access mode Tcl 8.5+ allows;
    # -translation binary below already does what the "b" suffix would.
    set dumpChannel [open $dumpPath r]
    fconfigure $dumpChannel -encoding utf-8 -translation binary
    set dumpText [read $dumpChannel]
    close $dumpChannel
    check {explicit dump writes exact pending JSON} $dumpText {"id":"dump-id"}
    checkTrue {explicit dump never writes bearer token} [expr {[string first recovery-token $dumpText] < 0}]
    _captureAiClearPendingResult
    check {dump without pending result errors} [catch {CaptureAiBridgeDumpPendingResult $dumpPath}] 1
    file delete -force $dumpPath

    rename ::after {}
    rename ::captureAiRecoveryRealAfter ::after
    rename ::_captureAiRequest {}
    rename ::captureAiRecoveryRealRequest ::_captureAiRequest
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
} else {
    check {poll recovery helpers exist} 0 1
}

if {[llength [info commands ::_captureAiLoadDescriptor]] > 0} {
    set descriptorFile [file join [pwd] capture-ai-bridge-descriptor.tmp]
    set descriptorChannel [open $descriptorFile w]
    fconfigure $descriptorChannel -encoding utf-8
    puts -nonewline $descriptorChannel [format \
        {{"service":"capture-tcl-bridge","version":"0.1.0-beta.2","protocolVersion":1,"baseUrl":"http://127.0.0.1:8767","token":"descriptor-token","capturePid":%d,"serverPid":1234}} \
        [pid]]
    close $descriptorChannel
    set descriptor [_captureAiLoadDescriptor $descriptorFile]
    check {descriptor accepts matching service} [dict get $descriptor service] $::CaptureAiBridgeService
    check {descriptor accepts localhost URL} [dict get $descriptor baseUrl] {http://127.0.0.1:8767}

    proc captureAiDescriptorJson {value} {
        return [format \
            {{"service":%s,"version":%s,"protocolVersion":%s,"baseUrl":%s,"token":%s,"capturePid":%s,"serverPid":%s}} \
            [_captureAiJsonQuote [dict get $value service]] \
            [_captureAiJsonQuote [dict get $value version]] \
            [dict get $value protocolVersion] \
            [_captureAiJsonQuote [dict get $value baseUrl]] \
            [_captureAiJsonQuote [dict get $value token]] \
            [dict get $value capturePid] \
            [dict get $value serverPid]]
    }

    foreach {field badValue} {
        service wrong-service
        version wrong-version
        protocolVersion 2
        capturePid 999999
        baseUrl http://localhost:8767
        token {}
        serverPid 0
    } {
        set bad [dict replace $descriptor $field $badValue]
        set descriptorChannel [open $descriptorFile w]
        fconfigure $descriptorChannel -encoding utf-8
        puts -nonewline $descriptorChannel [captureAiDescriptorJson $bad]
        close $descriptorChannel
        check "descriptor rejects mismatched $field" [catch {_captureAiLoadDescriptor $descriptorFile}] 1
    }
    set descriptorChannel [open $descriptorFile w]
    puts -nonewline $descriptorChannel {partial JSON}
    close $descriptorChannel
    check {descriptor rejects partial JSON} [catch {_captureAiLoadDescriptor $descriptorFile}] 1
    rename captureAiDescriptorJson {}
    file delete -force $descriptorFile
} else {
    check {_captureAiLoadDescriptor exists} 0 1
}

if {[llength [info commands ::_captureAiRequest]] > 0} {
    package require http
    foreach command {geturl status ncode data cleanup} {
        # This Tcl 8.4 build registers the http package through the old
        # tclPkgSetup autoloader: the commands don't exist until first
        # referenced, so `rename` finds nothing without forcing the load
        # first. auto_load is a harmless no-op on 8.6, where they already
        # exist eagerly.
        catch {auto_load ::http::$command}
        rename ::http::$command ::http::captureAiReal[string totitle $command]
    }
    proc ::http::geturl {url args} {
        set ::captureAiHttpUrl $url
        set ::captureAiHttpOptions $args
        return ::http::capture-ai-test-token
    }
    proc ::http::status {token} { return $::captureAiHttpTransportStatus }
    proc ::http::ncode {token} { return $::captureAiHttpStatus }
    proc ::http::data {token} { return $::captureAiHttpData }
    proc ::http::cleanup {token} { lappend ::captureAiHttpCleanups $token }
    set ::CaptureAiBridgeToken request-secret
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::captureAiHttpStatus 200
    set ::captureAiHttpTransportStatus ok
    set ::captureAiHttpData [encoding convertto utf-8 \
        "{\"answer\":42,\"text\":\"\u4E2D\u6587\"}"]
    set ::captureAiHttpCleanups {}
    set requestResult [_captureAiRequest GET /v1/health]
    check {HTTP request parses JSON response} [dict get $requestResult answer] 42
    check {HTTP request decodes UTF-8 JSON} [dict get $requestResult text] "\u4E2D\u6587"
    check {HTTP request uses localhost URL} $::captureAiHttpUrl {http://127.0.0.1:8767/v1/health}
    set headerIndex [lsearch -exact $::captureAiHttpOptions -headers]
    set sentHeaders [lindex $::captureAiHttpOptions [expr {$headerIndex + 1}]]
    checkTrue {HTTP request sends bearer token} [expr {[lsearch -exact $sentHeaders {Bearer request-secret}] >= 0}]
    checkTrue {HTTP request sends Capture PID} [expr {[lsearch -exact $sentHeaders [pid]] >= 0}]
    checkTrue {HTTP request uses 1500 ms timeout} [expr {[lsearch -exact $::captureAiHttpOptions 1500] >= 0}]
    checkTrue {HTTP request receives raw bytes} [expr {[lsearch -exact $::captureAiHttpOptions -binary] >= 0}]
    check {HTTP success cleans transaction} [llength $::captureAiHttpCleanups] 1

    set ::captureAiHttpData {}
    _captureAiRequest POST /internal/result {{"id":"one"}} {X-Capture-Command-Id one}
    checkTrue {HTTP POST uses JSON content type} [expr {[lsearch -glob $::captureAiHttpOptions {application/json*}] >= 0}]
    checkTrue {HTTP POST sends payload} [expr {[lsearch -exact $::captureAiHttpOptions -query] >= 0}]
    set headerIndex [lsearch -exact $::captureAiHttpOptions -headers]
    set sentHeaders [lindex $::captureAiHttpOptions [expr {$headerIndex + 1}]]
    checkTrue {HTTP POST sends supplied command id header} \
        [expr {[lsearch -exact $sentHeaders X-Capture-Command-Id] >= 0 && [lsearch -exact $sentHeaders one] >= 0}]
    foreach protectedHeader {Authorization X-Capture-Pid Host} {
        check "HTTP request forbids override of $protectedHeader" \
            [catch [list _captureAiRequest POST /internal/result {{"id":"one"}} [list $protectedHeader override]]] 1
    }
    check {HTTP request forbids case-insensitive authorization override} \
        [catch {_captureAiRequest POST /internal/result {{"id":"one"}} {authorization override}}] 1
    check {HTTP POST cleans transaction} [llength $::captureAiHttpCleanups] 2

    set ::captureAiHttpStatus 500
    set ::captureAiHttpData [encoding convertto utf-8 \
        {{"ok":false,"error":{"code":"SERVER_ERROR","message":"server failed"},"id":"cmd-http","state":"completed"}}]
    # The 3-arg options-dict form of catch is Tcl 8.5+; the bridge's own
    # _captureAiCatch shim (native catch on 8.5+, hand-built options on 8.4)
    # already covers both interpreters.
    set non2xxCode [_captureAiCatch {_captureAiRequest GET /v1/health} non2xxMessage non2xxOptions]
    check {HTTP non-2xx is an error} $non2xxCode 1
    check {HTTP non-2xx exposes typed remote error code} \
        [dict get $non2xxOptions -errorcode] \
        {CAPTURE_AI_BRIDGE HTTP 500 SERVER_ERROR cmd-http completed}
    check {HTTP non-2xx cleans transaction} [llength $::captureAiHttpCleanups] 3

    set ::captureAiHttpStatus 200
    set ::captureAiHttpData [encoding convertto utf-8 "\{malformed json"]
    check {malformed JSON is an error} [catch {_captureAiRequest GET /v1/health}] 1
    check {malformed JSON cleans transaction} [llength $::captureAiHttpCleanups] 4

    set ::captureAiHttpTransportStatus timeout
    check {HTTP transport failure is an error} [catch {_captureAiRequest GET /v1/health}] 1
    check {HTTP transport failure cleans transaction} [llength $::captureAiHttpCleanups] 5

    rename ::http::geturl ::http::captureAiWorkingGeturl
    proc ::http::geturl {url args} { error {simulated connection failure} }
    set geturlFailureCode [_captureAiCatch {_captureAiRequest GET /v1/health} \
        geturlFailure geturlFailureOptions]
    rename ::http::geturl {}
    rename ::http::captureAiWorkingGeturl ::http::geturl
    check {HTTP transport exception is an error} $geturlFailureCode 1
    check {HTTP transport exception has stable error code} \
        [dict get $geturlFailureOptions -errorcode] {CAPTURE_AI_BRIDGE TRANSPORT}

    foreach command {geturl status ncode data cleanup} {
        rename ::http::$command {}
        rename ::http::captureAiReal[string totitle $command] ::http::$command
    }
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
} else {
    check {_captureAiRequest exists} 0 1
}

if {[llength [info commands ::CaptureAiBridgeStart]] > 0} {
    rename ::exec ::captureAiRealExec
    proc ::exec {args} {
        lappend ::captureAiExecCalls $args
        return 4321
    }
    rename ::after ::captureAiRealAfter
    proc ::after {args} {
        if {[lindex $args 0] eq "cancel"} {
            lappend ::captureAiLifecycleAfterCancels [lindex $args 1]
            return
        }
        lappend ::captureAiLifecycleAfterCalls $args
        return lifecycle-after-[llength $::captureAiLifecycleAfterCalls]
    }
    set ::CaptureAiBridgePythonPath $repoRoot
    set oldTempExists [info exists ::env(TEMP)]
    if {$oldTempExists} { set oldTemp $::env(TEMP) }
    set ::env(TEMP) [pwd]
    set ::captureAiExecCalls {}
    set ::captureAiLifecycleAfterCalls {}
    set ::captureAiLifecycleAfterCancels {}
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    CaptureAiBridgeStart
    CaptureAiBridgeStart
    check {duplicate start launches one server} [llength $::captureAiExecCalls] 1
    set launchArgs [lindex $::captureAiExecCalls 0]
    check {launch uses resolved Python path} [lindex $launchArgs 1] \
        [file join $repoRoot capture_tcl_bridge_server.py]
    checkTrue {launch binds localhost} [expr {[lsearch -exact $launchArgs 127.0.0.1] >= 0}]
    checkTrue {launch passes parent pid} [expr {[lsearch -exact $launchArgs --parent-pid] >= 0 && [lindex $launchArgs [expr {[lsearch -exact $launchArgs --parent-pid] + 1}]] == [pid]}]
    checkTrue {launch passes runtime file} [expr {[lsearch -exact $launchArgs --runtime-file] >= 0 && [file tail [lindex $launchArgs [expr {[lsearch -exact $launchArgs --runtime-file] + 1}]]] eq "capture_tcl_bridge.json"}]
    checkTrue {launch passes immutable launch file} [expr {[lsearch -exact $launchArgs --launch-file] >= 0}]
    checkTrue {launch passes server claim file} [expr {[lsearch -exact $launchArgs --claim-file] >= 0}]
    checkTrue {launch passes cancel file} [expr {[lsearch -exact $launchArgs --cancel-file] >= 0}]
    checkTrue {launch passes stopped ack file} [expr {[lsearch -exact $launchArgs --ack-file] >= 0}]
    if {[lsearch -exact $launchArgs --launch-file] >= 0} {
        set firstLaunchFile [lindex $launchArgs [expr {[lsearch -exact $launchArgs --launch-file] + 1}]]
        set firstClaimFile [lindex $launchArgs [expr {[lsearch -exact $launchArgs --claim-file] + 1}]]
        set firstCancelFile [lindex $launchArgs [expr {[lsearch -exact $launchArgs --cancel-file] + 1}]]
        set firstAckFile [lindex $launchArgs [expr {[lsearch -exact $launchArgs --ack-file] + 1}]]
        set firstNonce $::CaptureAiBridgeLaunchNonce
        checkTrue {launch file is launch scoped} [expr {[string match {capture_tcl_bridge_launch_*} [file tail $firstLaunchFile]]}]
        check {cancel path derives from launch} $firstCancelFile "${firstLaunchFile}.cancel"
        check {claim path derives from launch} $firstClaimFile "${firstLaunchFile}.claimed"
        check {ack path derives from launch} $firstAckFile "${firstLaunchFile}.stopped"
        check {immutable launch file contains nonce} [read [set launchChannel [open $firstLaunchFile r]]] "launch $firstNonce\n"
        close $launchChannel
        check {cancel request is initially absent} [file exists $firstCancelFile] 0
        check {stopped acknowledgement is initially absent} [file exists $firstAckFile] 0
    } else {
        set firstLaunchFile {}
        set firstCancelFile {}
        set firstAckFile {}
        set firstNonce {}
    }
    check {start records owned child PID} $::CaptureAiBridgeOwnedPid 4321
    check {status is callable while starting} [catch {CaptureAiBridgeStatus}] 0

    if {[llength [info commands ::_captureAiConnect]] > 0} {
        rename ::_captureAiLoadDescriptor ::captureAiRealLoadDescriptor
        proc ::_captureAiLoadDescriptor {args} { error {descriptor unavailable} }
        if {$firstAckFile ne {}} {
            set ackChannel [open $firstAckFile {WRONLY CREAT EXCL}]
            fconfigure $ackChannel -encoding binary -translation binary
            puts -nonewline $ackChannel "stopped $firstNonce\n"
            close $ackChannel
        }
        set ::CaptureAiBridgeConnecting 1
        set ::CaptureAiBridgeActive 0
        set beforeRetrySchedules [llength $::captureAiLifecycleAfterCalls]
        check {twentieth connection attempt is contained} [catch {_captureAiConnect 19}] 0
        check {twentieth connection attempt stops connecting} $::CaptureAiBridgeConnecting 0
        check {twentieth connection attempt stays inactive} $::CaptureAiBridgeActive 0
        check {twentieth connection attempt does not reschedule} [llength $::captureAiLifecycleAfterCalls] $beforeRetrySchedules
        check {naturally exited server clears owned PID} $::CaptureAiBridgeOwnedPid {}
        check {naturally exited server clears launch path} $::CaptureAiBridgeLaunchFile {}
        check {naturally exited server clears cancel path} $::CaptureAiBridgeCancelFile {}
        check {naturally exited server allows restart} $::CaptureAiBridgeStopError {}
        rename ::_captureAiLoadDescriptor {}
        rename ::captureAiRealLoadDescriptor ::_captureAiLoadDescriptor

        rename ::_captureAiLoadDescriptor ::captureAiRealLoadDescriptor
        proc ::_captureAiLoadDescriptor {args} {
            return [dict create \
                service capture-tcl-bridge \
                version $::CaptureAiBridgeVersion \
                protocolVersion 1 \
                baseUrl http://127.0.0.1:8767 \
                token connect-stop-token \
                capturePid [pid] \
                serverPid 4321]
        }
        rename ::_captureAiRequest ::captureAiRealRequestForConnect
        proc ::_captureAiRequest {method path {payload {}}} {
            if {$path eq "/v1/health"} {
                CaptureAiBridgeStop
                return [dict create \
                    service capture-tcl-bridge \
                    version $::CaptureAiBridgeVersion \
                    protocolVersion 1 \
                    capturePid [pid]]
            }
            return {}
        }
        set ::CaptureAiBridgeGeneration 50
        set ::CaptureAiBridgeConnecting 1
        set ::CaptureAiBridgeActive 0
        set ::CaptureAiBridgeOwnedPid {}
        set ::CaptureAiBridgeStopError {}
        set ::captureAiLifecycleAfterCalls {}
        set stoppedConnectCode [catch {_captureAiConnect 50 0} stoppedConnectError]
        check {stop during health request is contained} $stoppedConnectCode 0
        check {stop during health request stays inactive} $::CaptureAiBridgeActive 0
        check {stop during health request stays disconnected} $::CaptureAiBridgeConnecting 0
        check {stop during health request does not schedule} [::captureAiCountByIndex $::captureAiLifecycleAfterCalls 0 $::CaptureAiBridgePollMs] 0
        rename ::_captureAiRequest {}
        rename ::captureAiRealRequestForConnect ::_captureAiRequest
        rename ::_captureAiLoadDescriptor {}
        rename ::captureAiRealLoadDescriptor ::_captureAiLoadDescriptor

        rename ::_captureAiLoadDescriptor ::captureAiRealLoadDescriptor
        proc ::_captureAiLoadDescriptor {args} {
            return [dict create \
                service capture-tcl-bridge \
                version $::CaptureAiBridgeVersion \
                protocolVersion 1 \
                baseUrl http://127.0.0.1:8767 \
                token connection-secret \
                capturePid [pid] \
                serverPid 1234]
        }
        rename ::_captureAiRequest ::captureAiRealRequestForConnect
        proc ::_captureAiRequest {args} { error {health exposed connection-secret} }
        rename ::puts ::captureAiRealPuts
        proc ::puts {args} { lappend ::captureAiConnectLogs $args }
        set ::captureAiConnectLogs {}
        set ::CaptureAiBridgeConnecting 1
        _captureAiConnect 19
        rename ::puts {}
        rename ::captureAiRealPuts ::puts
        checkTrue {connection log redacts descriptor token} [expr {[string first connection-secret $::captureAiConnectLogs] < 0 && [string first {<redacted>} $::captureAiConnectLogs] >= 0}]
        rename ::_captureAiRequest {}
        rename ::captureAiRealRequestForConnect ::_captureAiRequest

        rename ::_captureAiRequest ::captureAiRealRequestForConnect
        proc ::_captureAiRequest {method path {payload {}}} {
            return [dict create \
                service capture-tcl-bridge \
                version $::CaptureAiBridgeVersion \
                protocolVersion 1 \
                capturePid [pid]]
        }
        set ::CaptureAiBridgeConnecting 1
        set ::CaptureAiBridgeActive 0
        set beforeConnectedSchedules [llength $::captureAiLifecycleAfterCalls]
        _captureAiConnect 0
        check {valid health completes connection} $::CaptureAiBridgeActive 1
        check {valid health clears connecting state} $::CaptureAiBridgeConnecting 0
        check {valid health retains descriptor token} $::CaptureAiBridgeToken connection-secret
        check {valid health schedules polling} [lindex $::captureAiLifecycleAfterCalls $beforeConnectedSchedules] [list $::CaptureAiBridgePollMs [list _captureAiTick $::CaptureAiBridgeGeneration]]
        rename ::_captureAiRequest {}
        rename ::captureAiRealRequestForConnect ::_captureAiRequest
        rename ::_captureAiLoadDescriptor {}
        rename ::captureAiRealLoadDescriptor ::_captureAiLoadDescriptor
    } else {
        check {_captureAiConnect exists} 0 1
    }

    proc ::captureAiInstallSignals {generation} {
        set signals [_captureAiCreateLaunchSignals $generation]
        set ::CaptureAiBridgeLaunchFile [dict get $signals launchFile]
        set ::CaptureAiBridgeClaimFile [dict get $signals claimFile]
        set ::CaptureAiBridgeCancelFile [dict get $signals cancelFile]
        set ::CaptureAiBridgeAckFile [dict get $signals ackFile]
        set ::CaptureAiBridgeLaunchNonce [dict get $signals nonce]
    }
    proc ::captureAiWriteStoppedAck {} {
        set channel [open $::CaptureAiBridgeAckFile {WRONLY CREAT EXCL}]
        fconfigure $channel -encoding binary -translation binary
        puts -nonewline $channel "stopped $::CaptureAiBridgeLaunchNonce\n"
        close $channel
    }

    rename ::_captureAiRequest ::captureAiRealRequest
    proc ::_captureAiRequest {method path {payload {}}} {
        lappend ::captureAiStopRequests [list $method $path $payload]
        return {}
    }
    set ::captureAiStopRequests {}
    set ::CaptureAiBridgeGeneration 60
    captureAiInstallSignals 60
    set launchBefore [read [set channel [open $::CaptureAiBridgeLaunchFile r]]]
    close $channel
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeAfterId active-after
    set ::CaptureAiBridgeToken secret-stop-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeOwnedPid 4321
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeStopError {}
    CaptureAiBridgeStop
    check {active stop requests shutdown} [lrange [lindex $::captureAiStopRequests 0] 0 1] {POST /internal/shutdown}
    check {cancel request uses exclusive separate file} [read [set channel [open $::CaptureAiBridgeCancelFile r]]] "cancel $::CaptureAiBridgeLaunchNonce\n"
    close $channel
    check {stop never modifies immutable launch file} [read [set channel [open $::CaptureAiBridgeLaunchFile r]]] $launchBefore
    close $channel
    check {stop waits for authoritative ack} $::CaptureAiBridgeOwnedPid 4321
    file mtime $::CaptureAiBridgeCancelFile 1000000000
    CaptureAiBridgeStop
    check {second stop never rewrites cancel request} [file mtime $::CaptureAiBridgeCancelFile] 1000000000
    captureAiWriteStoppedAck
    _captureAiFinishStop $::CaptureAiBridgeGeneration 0
    check {valid stopped ack clears identity} $::CaptureAiBridgeOwnedPid {}

    captureAiInstallSignals 64
    set ::CaptureAiBridgeGeneration 64
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeOwnedPid 6464
    set ::CaptureAiBridgeToken missing-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    file delete -- $::CaptureAiBridgeLaunchFile
    CaptureAiBridgeStop
    check {missing launch is never treated as stopped ack} $::CaptureAiBridgeOwnedPid 6464
    check {missing launch still requests cancellation} [file exists $::CaptureAiBridgeCancelFile] 1
    captureAiWriteStoppedAck
    _captureAiFinishStop $::CaptureAiBridgeGeneration 0

    set hardlinkSignals [_captureAiCreateLaunchSignals 66]
    set hardCancel [dict get $hardlinkSignals cancelFile]
    set victim [file join [pwd] capture_ai_cancel_victim.txt]
    set channel [open $victim w]
    puts -nonewline $channel victim
    close $channel
    if {![catch {file link -hard $hardCancel $victim}]} {
        check {existing hardlink is only treated as already requested} \
            [_captureAiCreateCancelRequest $hardCancel [dict get $hardlinkSignals nonce]] exists
        check {hardlink target is never modified} [read [set channel [open $victim r]]] victim
        close $channel
        file delete -- $hardCancel
    }
    file delete -force -- [dict get $hardlinkSignals launchFile] $victim

    rename ::_captureAiRequest {}
    set ::captureAiLegacyAttempts 0
    proc ::_captureAiRequest {method path {payload {}}} {
        incr ::captureAiLegacyAttempts
        if {$::captureAiLegacyAttempts <= 2} { error {legacy shutdown failure} }
        return {}
    }
    set ::CaptureAiBridgeGeneration 70
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}
    set ::CaptureAiBridgeToken legacy-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgeStopError {}
    CaptureAiBridgeStop
    check {first legacy stop attempts authenticated shutdown} $::captureAiLegacyAttempts 1
    checkTrue {first legacy failure remains cleanup-required} [expr {$::CaptureAiBridgeStopError ne {}}]
    check {first legacy failure preserves token} $::CaptureAiBridgeToken legacy-token
    CaptureAiBridgeStop
    check {second legacy stop retries shutdown} $::captureAiLegacyAttempts 2
    checkTrue {second legacy failure remains cleanup-required} [expr {$::CaptureAiBridgeStopError ne {}}]
    check {second legacy failure preserves base URL} $::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    CaptureAiBridgeStop
    check {third legacy stop retries shutdown} $::captureAiLegacyAttempts 3
    check {third legacy shutdown success clears identity} $::CaptureAiBridgeOwnedPid {}
    check {third legacy shutdown success clears error} $::CaptureAiBridgeStopError {}

    rename ::_captureAiRequest {}
    rename ::captureAiRealRequest ::_captureAiRequest
    rename ::captureAiInstallSignals {}
    rename ::captureAiWriteStoppedAck {}

    set bridgeSourceChannel [open $bridgeFile r]
    set bridgeSourceText [read $bridgeSourceChannel]
    close $bridgeSourceChannel
    check {bridge source never invokes taskkill} [string first taskkill $bridgeSourceText] -1
    check {bridge source never invokes POSIX kill} [string first {exec kill} $bridgeSourceText] -1

    check {three-signal cancel creation helper exists} \
        [llength [info commands ::_captureAiCreateCancelRequest]] 1
    check {three-signal stopped acknowledgement reader exists} \
        [llength [info commands ::_captureAiReadStoppedAck]] 1
    check {launch claim reader exists} \
        [llength [info commands ::_captureAiReadLaunchClaim]] 1

    set revokeSignals [_captureAiCreateLaunchSignals 73]
    set ::CaptureAiBridgeLaunchFile [dict get $revokeSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $revokeSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $revokeSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $revokeSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $revokeSignals nonce]
    set ::CaptureAiBridgeLaunchRevoked 0
    set ::CaptureAiBridgeLaunchManaged 0
    _captureAiCreateCancelRequest \
        $::CaptureAiBridgeCancelFile $::CaptureAiBridgeLaunchNonce
    set ::captureAiFailDeletePath $::CaptureAiBridgeLaunchFile
    rename ::file ::captureAiRealFile
    proc ::file {subcommand args} {
        if {$subcommand eq "delete" &&
            [lindex $args end] eq $::captureAiFailDeletePath} {
            error {injected unlink failure}
        }
        return [uplevel 1 [concat [list ::captureAiRealFile $subcommand] $args]]
    }
    check {unlink failure keeps revocation in retry state} \
        [_captureAiRevokeLaunch] retry
    check {unlink failure never marks launch revoked} \
        $::CaptureAiBridgeLaunchRevoked 0
    check {unlink failure preserves cancel request} \
        [::captureAiRealFile exists $::CaptureAiBridgeCancelFile] 1
    check {repeated unlink failure remains blocked} \
        [_captureAiRevokeLaunch] retry
    rename ::file {}
    rename ::captureAiRealFile ::file
    _captureAiCleanupSignals

    set managedSignals [_captureAiCreateLaunchSignals 74]
    set ::CaptureAiBridgeLaunchFile [dict get $managedSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $managedSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $managedSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $managedSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $managedSignals nonce]
    set channel [open $::CaptureAiBridgeClaimFile {WRONLY CREAT EXCL}]
    fconfigure $channel -encoding binary -translation binary
    puts -nonewline $channel "claimed $::CaptureAiBridgeLaunchNonce\n"
    close $channel
    check {claim-first launch is managed} [_captureAiRevokeLaunch] managed
    check {claim-first launch is not marked revoked} \
        $::CaptureAiBridgeLaunchRevoked 0
    check {claim-first keeps immutable launch for managed shutdown} \
        [file exists $::CaptureAiBridgeLaunchFile] 1
    _captureAiCreateCancelRequest \
        $::CaptureAiBridgeCancelFile $::CaptureAiBridgeLaunchNonce
    set ::CaptureAiBridgeGeneration 74
    set ::CaptureAiBridgeStopping 1
    set ::CaptureAiBridgeOwnedPid 7474
    set ::captureAiFailDeletePath $::CaptureAiBridgeLaunchFile
    rename ::file ::captureAiRealFile
    proc ::file {subcommand args} {
        if {$subcommand eq "delete" &&
            [lindex $args end] eq $::captureAiFailDeletePath} {
            error {injected managed unlink failure}
        }
        return [uplevel 1 [concat [list ::captureAiRealFile $subcommand] $args]]
    }
    _captureAiFinishStop 74 39
    check {managed unlink failure stays blocked} $::CaptureAiBridgeStopping 1
    check {managed unlink failure preserves identity} $::CaptureAiBridgeOwnedPid 7474
    check {managed unlink failure preserves cancel} \
        [::captureAiRealFile exists $::CaptureAiBridgeCancelFile] 1
    check {managed unlink failure preserves claim} \
        [::captureAiRealFile exists $::CaptureAiBridgeClaimFile] 1
    rename ::file {}
    rename ::captureAiRealFile ::file
    _captureAiFinishStop 74 39
    check {managed revoke success enters extra grace} \
        $::CaptureAiBridgeExtraGrace 1
    check {managed revoke success still waits} $::CaptureAiBridgeStopping 1
    _captureAiFinishStop 74 59
    check {managed extra grace eventually recovers} $::CaptureAiBridgeStopping 0
    check {managed extra grace clears identity} $::CaptureAiBridgeOwnedPid {}

    set partialSignals [_captureAiCreateLaunchSignals 74]
    set ::CaptureAiBridgeLaunchFile [dict get $partialSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $partialSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $partialSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $partialSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $partialSignals nonce]
    close [open $::CaptureAiBridgeClaimFile {WRONLY CREAT EXCL}]
    check {empty ordinary claim enters managed recovery} \
        [_captureAiRevokeLaunch] managed
    _captureAiCleanupSignals

    set racedSignals [_captureAiCreateLaunchSignals 74]
    set ::CaptureAiBridgeLaunchFile [dict get $racedSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $racedSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $racedSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $racedSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $racedSignals nonce]
    set ::captureAiClaimReads 0
    rename ::_captureAiReadLaunchClaim ::captureAiRealReadLaunchClaim
    proc ::_captureAiReadLaunchClaim {path nonce} {
        incr ::captureAiClaimReads
        return [expr {$::captureAiClaimReads == 1 ? "missing" : "claimed"}]
    }
    check {claim racing after unlink is recognized as managed} \
        [_captureAiRevokeLaunch] managed
    check {post-unlink claim prevents unmanaged revocation state} \
        $::CaptureAiBridgeLaunchRevoked 0
    rename ::_captureAiReadLaunchClaim {}
    rename ::captureAiRealReadLaunchClaim ::_captureAiReadLaunchClaim
    _captureAiCleanupSignals

    set abandonedSignals [_captureAiCreateLaunchSignals 75]
    set abandonedLaunch [dict get $abandonedSignals launchFile]
    set ::CaptureAiBridgeLaunchFile $abandonedLaunch
    set ::CaptureAiBridgeClaimFile [dict get $abandonedSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $abandonedSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $abandonedSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $abandonedSignals nonce]
    set ::CaptureAiBridgeGeneration 75
    set ::CaptureAiBridgeConnecting 1
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeOwnedPid 7575
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
    set ::CaptureAiBridgeStopError {}
    _captureAiConnect 75 19
    check {failed startup revokes immutable launch after final retry} \
        [file exists $abandonedLaunch] 0
    set abandonedStopGeneration $::CaptureAiBridgeGeneration
    _captureAiFinishStop $abandonedStopGeneration 39
    check {startup without ack leaves finite stopping state} $::CaptureAiBridgeStopping 0
    check {startup without ack releases owned identity} $::CaptureAiBridgeOwnedPid {}
    set launchesBeforeRecovery [llength $::captureAiExecCalls]
    CaptureAiBridgeStart
    check {startup without ack permits a new isolated start} \
        [llength $::captureAiExecCalls] [expr {$launchesBeforeRecovery + 1}]
    set recoveredLaunch $::CaptureAiBridgeLaunchFile
    checkTrue {recovery start uses a new launch path} \
        [expr {$recoveredLaunch ne $abandonedLaunch}]
    _captureAiCleanupSignals
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeClaimFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}

    set blockedAckSignals [_captureAiCreateLaunchSignals 78]
    set ::CaptureAiBridgeLaunchFile [dict get $blockedAckSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $blockedAckSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $blockedAckSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $blockedAckSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $blockedAckSignals nonce]
    set channel [open $::CaptureAiBridgeAckFile {WRONLY CREAT EXCL}]
    fconfigure $channel -encoding binary -translation binary
    puts -nonewline $channel {preoccupied}
    close $channel
    set ::CaptureAiBridgeGeneration 78
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeOwnedPid 7878
    set ::CaptureAiBridgeToken {}
    set ::CaptureAiBridgeBaseUrl {}
    set ::CaptureAiBridgeStopError {}
    CaptureAiBridgeStop
    _captureAiFinishStop $::CaptureAiBridgeGeneration 19
    check {active stop with unusable ack revokes launch} \
        [file exists $::CaptureAiBridgeLaunchFile] 0
    _captureAiFinishStop $::CaptureAiBridgeGeneration 39
    check {active stop with unusable ack has finite blocking} \
        $::CaptureAiBridgeStopping 0
    check {active stop grace release clears owned identity} \
        $::CaptureAiBridgeOwnedPid {}

    set lateSignals [_captureAiCreateLaunchSignals 80]
    set ::CaptureAiBridgeLaunchFile [dict get $lateSignals launchFile]
    set ::CaptureAiBridgeClaimFile [dict get $lateSignals claimFile]
    set ::CaptureAiBridgeCancelFile [dict get $lateSignals cancelFile]
    set ::CaptureAiBridgeAckFile [dict get $lateSignals ackFile]
    set ::CaptureAiBridgeLaunchNonce [dict get $lateSignals nonce]
    _captureAiCreateCancelRequest \
        $::CaptureAiBridgeCancelFile $::CaptureAiBridgeLaunchNonce
    set ::captureAiExecCalls {}
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 1
    set ::CaptureAiBridgeGeneration 80
    set ::CaptureAiBridgeOwnedPid 8080
    set ::CaptureAiBridgeStopError {}
    _captureAiFinishStop 80 19
    check {stop timeout keeps watching} $::CaptureAiBridgeStopping 1
    checkTrue {stop timeout records one diagnostic} [expr {$::CaptureAiBridgeStopError ne {}}]
    set channel [open $::CaptureAiBridgeAckFile {WRONLY CREAT EXCL}]
    fconfigure $channel -encoding binary -translation binary
    puts -nonewline $channel "stopped $::CaptureAiBridgeLaunchNonce\n"
    close $channel
    CaptureAiBridgeStart
    check {late acknowledgement lets Start clear old error} $::CaptureAiBridgeStopError {}
    set restartArgs [lindex $::captureAiExecCalls 0]
    set restartLaunchFile [lindex $restartArgs [expr {[lsearch -exact $restartArgs --launch-file] + 1}]]
    checkTrue {new start uses signals isolated from old lifecycle} [expr {$restartLaunchFile ne $firstLaunchFile}]
    _captureAiCleanupSignals
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeClaimFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}

    # Stop must cancel its current poll timer, and a subsequent Start must
    # discard all poll-recovery diagnostics before accepting another command.
    rename ::_captureAiRequest ::captureAiRealRequestForRecoveryLifecycle
    proc ::_captureAiRequest {method path {payload {}} {extraHeaders {}}} {
        if {$path eq "/v1/health"} {
            return [dict create \
                service capture-tcl-bridge \
                version $::CaptureAiBridgeVersion \
                protocolVersion 1 \
                capturePid [pid]]
        }
        if {$path eq "/internal/command"} {
            if {$::captureAiRecoveryLifecycleCommandAvailable} {
                set ::captureAiRecoveryLifecycleCommandAvailable 0
                return [dict create id recovery-command script {
                    set ::captureAiRecoveryLifecycleExecuted 1
                }]
            }
            return {}
        }
        if {$path eq "/internal/result"} {
            incr ::captureAiRecoveryLifecyclePosts
        }
        return {}
    }
    rename ::_captureAiLoadDescriptor ::captureAiRealLoadDescriptorForRecoveryLifecycle
    proc ::_captureAiLoadDescriptor {args} {
        return [dict create \
            service capture-tcl-bridge \
            version $::CaptureAiBridgeVersion \
            protocolVersion 1 \
            baseUrl http://127.0.0.1:8767 \
            token recovery-lifecycle-token \
            capturePid [pid] \
            serverPid 4321]
    }
    set ::CaptureAiBridgeGeneration 90
    set ::CaptureAiBridgeActive 1
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeStopping 0
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeClaimFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}
    set ::CaptureAiBridgeToken recovery-lifecycle-token
    set ::CaptureAiBridgeBaseUrl http://127.0.0.1:8767
    set ::CaptureAiBridgePollingHalted 0
    set ::CaptureAiBridgeProtocolError {}
    set ::CaptureAiBridgeLastPollError {}
    set ::CaptureAiBridgeRetryDelayMs 250
    set ::CaptureAiBridgeAfterId {}
    set ::captureAiLifecycleAfterCalls {}
    set ::captureAiLifecycleAfterCancels {}
    _captureAiScheduleTick 90
    set scheduledPollTimer $::CaptureAiBridgeAfterId
    _captureAiScheduleTick 90
    check {scheduled poll is not duplicated} [llength $::captureAiLifecycleAfterCalls] 1
    set ::CaptureAiBridgePollingHalted 1
    set ::CaptureAiBridgeProtocolError {stale protocol error}
    set ::CaptureAiBridgeLastPollError {HTTP:401:UNAUTHORIZED}
    set ::CaptureAiBridgeRetryDelayMs 5000
    CaptureAiBridgeStop
    check {Stop cancels its scheduled poll timer} $::captureAiLifecycleAfterCancels [list $scheduledPollTimer]
    check {Stop clears halted recovery state} $::CaptureAiBridgePollingHalted 0
    check {Stop clears protocol error} $::CaptureAiBridgeProtocolError {}
    check {Stop clears last poll error} $::CaptureAiBridgeLastPollError {}
    check {Stop resets retry delay} $::CaptureAiBridgeRetryDelayMs 250

    set ::captureAiExecCalls {}
    CaptureAiBridgeStart
    check {Start clears halted recovery state} $::CaptureAiBridgePollingHalted 0
    check {Start clears protocol error} $::CaptureAiBridgeProtocolError {}
    check {Start clears last poll error} $::CaptureAiBridgeLastPollError {}
    check {Start resets retry delay} $::CaptureAiBridgeRetryDelayMs 250
    _captureAiConnect $::CaptureAiBridgeGeneration 0
    set ::CaptureAiBridgeAfterId {}
    set ::captureAiRecoveryLifecycleCommandAvailable 1
    set ::captureAiRecoveryLifecyclePosts 0
    unset -nocomplain ::captureAiRecoveryLifecycleExecuted
    _captureAiTick $::CaptureAiBridgeGeneration
    check {restart accepts and executes next command} $::captureAiRecoveryLifecycleExecuted 1
    check {restart posts next command completion} $::captureAiRecoveryLifecyclePosts 1
    _captureAiCleanupSignals
    set ::CaptureAiBridgeActive 0
    set ::CaptureAiBridgeConnecting 0
    set ::CaptureAiBridgeOwnedPid {}
    set ::CaptureAiBridgeLaunchFile {}
    set ::CaptureAiBridgeClaimFile {}
    set ::CaptureAiBridgeCancelFile {}
    set ::CaptureAiBridgeAckFile {}
    set ::CaptureAiBridgeLaunchNonce {}
    rename ::_captureAiLoadDescriptor {}
    rename ::captureAiRealLoadDescriptorForRecoveryLifecycle ::_captureAiLoadDescriptor
    rename ::_captureAiRequest {}
    rename ::captureAiRealRequestForRecoveryLifecycle ::_captureAiRequest

    rename ::after {}
    rename ::captureAiRealAfter ::after
    rename ::exec {}
    rename ::captureAiRealExec ::exec
    if {$oldCaptureAiBridgePythonPathExists} {
        set ::CaptureAiBridgePythonPath $oldCaptureAiBridgePythonPath
    } else {
        unset ::CaptureAiBridgePythonPath
    }
    if {$oldTempExists} {
        set ::env(TEMP) $oldTemp
    } else {
        unset ::env(TEMP)
    }
} else {
    check {CaptureAiBridgeStart callable} 0 1
}

if {$::fail} {
    ::puts stderr {SOME TESTS FAILED}
    exit 1
}
::puts {PASS: capture AI bridge execution helpers}
