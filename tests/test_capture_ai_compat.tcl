# Tests for the Tcl 8.4 compatibility layer and the built-in JSON parser.
# Run with: tclsh tests/test_capture_ai_compat.tcl
#
# This suite must pass on both Tcl 8.4 (OrCAD Capture 16.6) and Tcl 8.6
# (OrCAD Capture 17.4). On 8.6 the shims stand down and the native dict,
# lassign and try are exercised instead, which is exactly the point: both
# interpreters must agree.

set repoRoot [file normalize [file join [file dirname [info script]] ..]]
source [file join $repoRoot captureAiBridge.tcl]

set ::fail 0

proc check {description actual expected} {
    if {$actual ne $expected} {
        puts stderr "FAIL: $description -> got '{$actual}', want '{$expected}'"
        set ::fail 1
    }
}

proc checkError {description script expected} {
    if {[catch {uplevel 1 $script} message] == 0} {
        puts stderr "FAIL: $description -> no error, want '$expected'"
        set ::fail 1
        return
    }
    if {![string match $expected $message]} {
        puts stderr "FAIL: $description -> got '$message', want '$expected'"
        set ::fail 1
    }
}

puts "interpreter: [info patchlevel]"

# --- dict ------------------------------------------------------------------

check {dict create builds a key/value list} [dict create a 1 b 2] {a 1 b 2}
check {dict create with no arguments is empty} [dict create] {}
checkError {dict create rejects an odd argument count} {dict create a} \
    {wrong # args*}

check {dict get reads a key} [dict get {a 1 b 2} b] 2
check {dict get with no key returns the dictionary} [dict get {a 1 b 2}] {a 1 b 2}
check {dict get walks nested keys} \
    [dict get {error {code X message m}} error code] X
check {dict get keeps the last duplicate} [dict get {a 1 a 2} a] 2
check {dict get preserves an empty value} [dict get {a {} b 2} a] {}
check {dict get preserves a value with spaces} \
    [dict get {a {two words} b 2} a] {two words}
checkError {dict get reports a missing key} {dict get {a 1} zz} \
    {key "zz" not known in dictionary}
checkError {dict get reports a missing nested key} \
    {dict get {a {b 1}} a zz} {key "zz" not known in dictionary}

check {dict exists finds a key} [dict exists {a 1 b 2} a] 1
check {dict exists rejects a missing key} [dict exists {a 1 b 2} zz] 0
check {dict exists walks nested keys} \
    [dict exists {error {code X}} error code] 1
check {dict exists rejects a missing nested key} \
    [dict exists {error {code X}} error zz] 0
check {dict exists rejects descending into a scalar} \
    [dict exists {a scalar} a b] 0
check {dict exists rejects a malformed dictionary} [dict exists {a 1 b} a] 0

check {dict keys lists keys in order} [dict keys {b 2 a 1}] {b a}
check {dict keys deduplicates} [dict keys {a 1 b 2 a 3}] {a b}
check {dict keys filters by pattern} [dict keys {alpha 1 beta 2} a*] {alpha}

check {dict replace overwrites an existing key} \
    [dict replace {a 1 b 2} b 9] {a 1 b 9}
check {dict replace appends a new key} \
    [dict replace {a 1} b 2] {a 1 b 2}
check {dict replace with no pairs is a copy} [dict replace {a 1 b 2}] {a 1 b 2}
checkError {dict replace rejects an odd argument count} \
    {dict replace {a 1} b} {wrong # args*}

# --- lassign ---------------------------------------------------------------

set first {}
set second {}
check {lassign returns the unassigned remainder} \
    [lassign {1 2 3 4} first second] {3 4}
check {lassign assigned the first variable} $first 1
check {lassign assigned the second variable} $second 2
set only {}
set missing preset
check {lassign returns nothing when the list is consumed} \
    [lassign {1} only missing] {}
check {lassign blanks a variable with no element} $missing {}

# --- try/finally -----------------------------------------------------------

set trace {}
try {
    lappend trace body
} finally {
    lappend trace cleanup
}
check {try runs the body then the finally script} $trace {body cleanup}

set trace {}
check {try propagates the body error} \
    [catch {
        try {
            lappend trace body
            error {boom}
        } finally {
            lappend trace cleanup
        }
    } message] 1
check {try reports the original error message} $message boom
check {try runs the finally script after an error} $trace {body cleanup}

proc captureAiTryReturns {traceVariable} {
    upvar 1 $traceVariable trace
    try {
        return early
    } finally {
        lappend trace cleanup
    }
    lappend trace unreachable
    return late
}
set trace {}
check {try lets the body return from its caller} [captureAiTryReturns trace] early
check {try runs the finally script on return} $trace cleanup

set trace {}
check {try evaluates the body in the caller's scope} \
    [expr {[catch {
        set captureAiScopeProbe visible
        try { set captureAiScopeProbe changed } finally { }
        expr {$captureAiScopeProbe eq "changed"}
    } scoped] == 0 && $scoped}] 1

# --- JSON parsing ----------------------------------------------------------

check {parses an object into a dictionary} \
    [_captureAiJsonParse {{"a":1,"b":"two"}}] {a 1 b two}
check {parses an empty object} [_captureAiJsonParse {{}}] {}
check {parses a nested object} \
    [_captureAiJsonParse {{"error":{"code":"BUSY","message":"m"}}}] \
    {error {code BUSY message m}}
check {parses an array into a list} \
    [_captureAiJsonParse {[1,"two",{"k":"v"}]}] {1 two {k v}}
check {parses an empty array} [_captureAiJsonParse {[]}] {}
check {parses literals the way tcllib does} \
    [_captureAiJsonParse {{"t":true,"f":false,"n":null}}] {t true f false n null}
check {preserves number formatting} \
    [_captureAiJsonParse {{"i":1,"f":1.5,"e":1e3,"neg":-2,"z":0}}] \
    {i 1 f 1.5 e 1e3 neg -2 z 0}
check {parses a plain string} [_captureAiJsonParse {"hello"}] hello
check {parses an empty string} [_captureAiJsonParse {""}] {}
check {tolerates insignificant whitespace} \
    [_captureAiJsonParse "  {\n  \"a\" : \t 1\r\n}  "] {a 1}

check {unescapes the two-character escapes} \
    [_captureAiJsonParse {"q\"b\\s\/f\bf\ff\nf\rf\t"}] \
    "q\"b\\s/f\bf\ff\nf\rf\t"
check {unescapes a BMP \\u escape} [_captureAiJsonParse {"\u00e9"}] \u00e9
check {unescapes a CJK \\u escape} [_captureAiJsonParse {"\u4e2d\u6587"}] \u4e2d\u6587
check {unescapes an uppercase \\u escape} [_captureAiJsonParse {"\u00E9"}] \u00e9
check {keeps raw non-ASCII text} [_captureAiJsonParse "\"\u4e2d\""] \u4e2d
check {keeps a brace inside a string from breaking the list} \
    [dict get [_captureAiJsonParse {{"script":"if {1} { puts hi }"}}] script] \
    {if {1} { puts hi }}
# Written with quoting rather than braces because the JSON itself carries an
# unbalanced brace, which is precisely the case that must survive parsing.
check {keeps an unbalanced brace inside a string intact} \
    [dict get [_captureAiJsonParse "{\"script\":\"puts \\\"{\\\"\"}"] script] \
    "puts \"{\""
check {keeps a backslash inside a string intact} \
    [dict get [_captureAiJsonParse {{"script":"puts \\\\"}}] script] \
    {puts \\}

checkError {rejects a truncated object} {_captureAiJsonParse "\{"} *
checkError {rejects a bare unquoted word} {_captureAiJsonParse {oops}} *
checkError {rejects an unterminated string} {_captureAiJsonParse {"abc}} *
checkError {rejects a trailing comma} {_captureAiJsonParse {{"a":1,}}} *
checkError {rejects trailing content} {_captureAiJsonParse {{"a":1} junk}} *
checkError {rejects a missing colon} {_captureAiJsonParse {{"a" 1}}} *
checkError {rejects an invalid escape} {_captureAiJsonParse {"\x"}} *
checkError {rejects a short \\u escape} {_captureAiJsonParse {"\u12"}} *
checkError {rejects an empty document} {_captureAiJsonParse {}} *

# --- JSON quoting ----------------------------------------------------------

check {quotes a plain string} [_captureAiJsonQuote {hello}] {"hello"}
check {escapes a double quote} [_captureAiJsonQuote {say "hi"}] {"say \"hi\""}
check {escapes a single backslash} [_captureAiJsonQuote {a\b}] {"a\\b"}
check {escapes a Windows path} \
    [_captureAiJsonQuote {C:\tclpython\x.py}] {"C:\\tclpython\\x.py"}
check {escapes a doubled backslash} [_captureAiJsonQuote {a\\b}] {"a\\\\b"}
check {escapes a trailing backslash} [_captureAiJsonQuote "a\\"] {"a\\"}
check {escapes the whitespace controls} \
    [_captureAiJsonQuote "a\tb\nc\rd"] {"a\tb\nc\rd"}

# A round trip through the module's own writer must survive its own reader.
set awkward "tab\there \"quoted\" \\ back\nnewline \u4e2d"
set roundTrip [_captureAiJsonParse "{\"s\":[_captureAiJsonQuote $awkward]}"]
check {round trips the module's own quoting} [dict get $roundTrip s] $awkward

if {$::fail} {
    puts stderr {FAIL: capture AI bridge Tcl compatibility layer}
    exit 1
}
puts {PASS: capture AI bridge Tcl compatibility layer}
