"""Connectivity tool behavior through MCP, with a deterministic DBO fixture.

The Tcl fixture models two hierarchical instances with the same refdes, one
cross-hierarchy net, and an unconnected pin. It executes the actual generated
Tcl rather than substituting precomputed connectivity responses.
"""
from pathlib import Path

import pytest

import capture_mcp_server as mcp


DBO_FIXTURE = r'''
set ::DboBaseObject_INST_OCCURRENCE 10
set ::DboBaseObject_PORT_OCCURRENCE 11
set ::IterDefs_INSTS 20
set ::IterDefs_PORTS 21
set ::IterDefs_PRIMITIVES 22
proc DboState {} {return state}
proc state {method args} {
    switch $method {OK {return 1} -delete {return} default {error "unexpected state $method"}}
}
proc DboTclHelper_sMakeCString {args} {
    incr ::cstringIndex
    set key "cstring$::cstringIndex"
    set ::strings($key) [lindex $args 0]
    return $key
}
set ::cstringIndex 0
proc DboTclHelper_sGetConstCharPtr {key} {return $::strings($key)}
proc DboBaseObject_GetObjectType {obj} {
    if {[string match port* $obj]} {return 11}
    return 10
}
proc DboOccurrenceToDboInstOccurrence {obj} {return $obj}
proc DboOccurrenceToDboPortOccurrence {obj} {return $obj}
proc GetActivePMDesign {} {return design}
proc DboBaseObject_GetName {obj key} {set ::strings($key) {test.dsn}}
proc DboPortOccurrence_sGetPathName {obj st} {
    return [DboTclHelper_sMakeCString $obj]
}
proc iterator {items} {
    incr ::iterIndex
    set obj "iter$::iterIndex"
    set ::items($obj) $items
    interp alias {} $obj {} next $obj
    return $obj
}
set ::iterIndex 0
proc next {obj method args} {
    if {$method eq {Sort}} {return}
    set value [lindex $::items($obj) 0]
    set ::items($obj) [lrange $::items($obj) 1 end]
    if {$value eq {}} {return NULL}
    return $value
}
proc delete_DboOccurrenceChildrenIter {obj} {rename $obj {}; unset ::items($obj)}
proc delete_DboDesignFlatNetsIter {obj} {delete_DboOccurrenceChildrenIter $obj}
proc delete_DboFlatNetPortOccurrencesIter {obj} {delete_DboOccurrenceChildrenIter $obj}
proc design {method args} {
    switch $method {
        NewFlatNetsIter {return [iterator {net}]}
        GetRootOccurrence {return root}
        default {error "unexpected design $method"}
    }
}
proc net {method args} {
    switch $method {
        GetName {set ::strings([lindex $args 0]) {VCC}; return state}
        NewPortOccurrencesIter {return [iterator {portA1 portB1}]}
        default {error "unexpected net $method"}
    }
}
proc instance {obj method args} {
    switch $method {
        IsPrimitive {return [expr {$obj ne {root}}]}
        GetReference {set ::strings([lindex $args 0]) C3; return state}
        GetPathName {set ::strings([lindex $args 0]) "$obj/C3"; return state}
        NewChildrenIter {
            if {[lindex $args 1] == $::IterDefs_PORTS} {
                if {$obj eq {A}} {return [iterator {portA1 portA2}]}
                return [iterator {portB1}]
            }
            if {$obj eq {root}} {return [iterator {A B}]}
            return [iterator {}]
        }
        default {error "unexpected instance $method"}
    }
}
foreach obj {root A B} {interp alias {} $obj {} instance $obj}
proc port {obj method args} {
    switch $method {
        GetPortInst {return "pin$obj"}
        default {error "unexpected port $method"}
    }
}
proc pin {obj method args} {
    switch $method {
        GetPinNumber {set ::strings([lindex $args 0]) [string index $obj end]; return state}
        GetPinName {set ::strings([lindex $args 0]) {端子}; return state}
        default {error "unexpected pin $method"}
    }
}
foreach obj {portA1 portA2 portB1} {
    interp alias {} $obj {} port $obj
    interp alias {} pin$obj {} pin $obj
}
'''


@pytest.fixture
def call_tool(monkeypatch):
    tkinter = pytest.importorskip("tkinter")

    tcl = tkinter.Tcl()
    tcl.eval(DBO_FIXTURE)

    def execute(runtime, script):
        try:
            return tcl.eval(script)
        except tkinter.TclError as error:
            raise mcp.ToolExecutionError(str(error)) from error
        finally:
            assert tcl.eval("array size ::items") == "0", "native iterators must be released"

    monkeypatch.setattr(mcp, "_execute_capture_script", execute)
    server = mcp.CaptureMcpServer(Path("unused.json"))
    server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "test", "version": "1"}}})

    def call(name, arguments):
        response = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                  "params": {"name": name, "arguments": arguments}})
        return response["result"]

    call.configure_dbo = tcl.eval
    return call


def test_component_pins_include_disconnected_and_unicode_names(call_tool):
    result = call_tool("capture_get_component_pins", {"refdes": "C3", "path": "A/C3"})
    assert not result.get("isError")
    data = result["structuredContent"]
    assert data["count"] == 2
    assert data["truncated"] is False
    assert [p["pin_number"] for p in data["pins"]] == ["1", "2"]
    assert data["pins"][0]["pin_name"] == "端子"
    assert data["pins"][0]["net"] == {"design": "test.dsn", "name": "VCC"}
    assert data["pins"][1]["net"] is None
    assert data["pins"][1]["connected"] is False


def test_pin_net_and_net_pins_round_trip_across_hierarchy(call_tool):
    result = call_tool("capture_get_pin_net", {"refdes": "C3", "path": "A/C3", "pin_number": "1"})
    assert not result.get("isError")
    net = result["structuredContent"]["pin"]["net"]
    result = call_tool("capture_get_net_pins", {"net_name": net["name"]})
    pins = result["structuredContent"]["pins"]
    assert [(p["occurrence"]["path"], p["pin_number"]) for p in pins] == [("A/C3", "1"), ("B/C3", "1")]


def test_unconnected_pin_is_success(call_tool):
    result = call_tool("capture_get_pin_net", {"refdes": "C3", "path": "A/C3", "pin_number": "2"})
    assert not result.get("isError")
    assert result["structuredContent"]["pin"]["net"] is None


@pytest.mark.parametrize("name,args,code", [
    ("capture_get_component_pins", {"refdes": "C3"}, "COMPONENT_NOT_UNIQUE"),
    ("capture_get_component_pins", {"refdes": "X"}, "COMPONENT_NOT_FOUND"),
    ("capture_get_pin_net", {"refdes": "C3", "path": "A/C3", "pin_number": "99"}, "PIN_NOT_FOUND"),
    ("capture_get_net_pins", {"net_name": "missing"}, "NET_NOT_FOUND"),
    ("capture_get_net_pins", {"net_name": "VCC", "max_results": True}, "max_results"),
    ("capture_get_pin_net", {"refdes": "C3", "pin_number": 1}, "pin_number"),
    ("capture_get_component_pins", {"refdes": "C3", "extra": 1}, "Unknown argument"),
    ("capture_get_component_pins", {"refdes": "C3; [error injected]"}, "COMPONENT_NOT_FOUND"),
])
def test_query_errors_are_actionable(call_tool, name, args, code):
    result = call_tool(name, args)
    assert result["isError"] is True
    assert code in result["content"][0]["text"]


def test_net_pin_limit_reports_truncation(call_tool):
    result = call_tool("capture_get_net_pins", {"net_name": "VCC", "max_results": 1})
    data = result["structuredContent"]
    assert data["count"] == 1
    assert data["truncated"] is True


def test_dbo_failure_releases_iterators_and_does_not_return_partial_success(call_tool):
    call_tool.configure_dbo(r'''
        rename pin original_pin
        proc pin {obj method args} {
            if {$method eq {GetPinName}} {error "DBO_CALL_FAILED: injected pin read failure"}
            return [original_pin $obj $method {*}$args]
        }
    ''')
    result = call_tool("capture_get_component_pins", {"refdes": "C3", "path": "A/C3"})
    assert result["isError"] is True
    assert "DBO_CALL_FAILED" in result["content"][0]["text"]


def test_duplicate_flat_net_names_are_rejected(call_tool):
    call_tool.configure_dbo(r'''
        rename design original_design
        proc design {method args} {
            if {$method eq {NewFlatNetsIter}} {return [iterator {net net}]}
            return [original_design $method {*}$args]
        }
    ''')
    result = call_tool("capture_get_net_pins", {"net_name": "VCC"})
    assert result["isError"] is True
    assert "NET_NOT_UNIQUE" in result["content"][0]["text"]
