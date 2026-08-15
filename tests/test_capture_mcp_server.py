from __future__ import annotations

from io import BytesIO
import json
from pathlib import Path
import shutil
import subprocess

import pytest

import capture_mcp_server as mcp


def _hex(value: str) -> str:
    return value.encode("utf-8").hex()


def _completed(result: str, *, ok: bool = True) -> dict:
    return {
        "id": "command-1",
        "state": "completed",
        "ok": ok,
        "returnCode": 0 if ok else 1,
        "result": result,
        "stdout": "",
        "stderr": "",
        "errorInfo": "" if ok else "trace",
        "errorCode": [],
        "errorLine": None,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "resultTruncated": False,
    }


def _component_record(fields: list[tuple[str, str]]) -> str:
    values = ["CAPTURE_MCP_COMPONENT_V2", str(len(fields))]
    for name, value in fields:
        values.extend((_hex(name), _hex(value)))
    return "\t".join(values)


def _set_record(
    refdes: str,
    path: str,
    property_name: str,
    before: str | None,
    after: str,
) -> str:
    return "\t".join(
        [
            "CAPTURE_MCP_SET_V2",
            _hex(refdes),
            _hex(path),
            _hex(property_name),
            "0" if before is None else "1",
            _hex(before or ""),
            "1",
            _hex(after),
        ]
    )


def _modern_params(**values):
    return {
        **values,
        "_meta": {
            mcp.PROTOCOL_VERSION_META_KEY: mcp.MODERN_PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientInfo": {
                "name": "test-client",
                "version": "1",
            },
            "io.modelcontextprotocol/clientCapabilities": {},
        },
    }


def _run_against_dbo_fixture(script: str, setup: str) -> subprocess.CompletedProcess[str]:
    tclsh = shutil.which("tclsh")
    if tclsh is None:
        pytest.skip("tclsh is unavailable")
    fixture = (Path(__file__).with_name("test_examples.tcl")).read_text(
        encoding="utf-8"
    )
    fixture_prelude = fixture.split("# --- suites", 1)[0]
    root = Path(__file__).resolve().parents[1].as_posix()
    fixture_prelude = fixture_prelude.replace(
        "set repoRoot [file normalize [file join [file dirname [info script]] ..]]",
        f"set repoRoot {{{root}}}",
        1,
    )
    program = (
        fixture_prelude
        + "\n"
        + setup
        + "\nfconfigure stdout -encoding utf-8\n"
        + "\nset mcpScript [encoding convertfrom utf-8 [binary format H* "
        + script.encode("utf-8").hex()
        + "]]\n"
        + "set mcpCode [catch {uplevel #0 $mcpScript} mcpResult]\n"
        + "puts [list MCP_RESULT $mcpCode $mcpResult $::fx::setPropCalls]\n"
        + "binary scan [encoding convertto utf-8 $mcpResult] H* mcpResultHex\n"
        + "puts [list MCP_RESULT_HEX $mcpCode $mcpResultHex $::fx::setPropCalls $::fx::iterDeleteCalls]\n"
    )
    return subprocess.run(
        [tclsh],
        input=program,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )


def _bridge_fixture_executor(setup: str, expected_set_calls: int = 0):
    def execute(runtime_file: Path, script: str) -> str:
        result = _run_against_dbo_fixture(script, setup)
        assert result.returncode == 0, result.stderr
        marker = "MCP_RESULT_HEX "
        line = next(
            (line for line in result.stdout.splitlines() if line.startswith(marker)),
            None,
        )
        assert line is not None, (result.stdout, result.stderr)
        code, payload = line[len(marker) :].split(" ", 1)
        encoded, set_calls, _delete_calls = payload.rsplit(" ", 2)
        assert set_calls == str(expected_set_calls), line
        decoded = bytes.fromhex(encoded).decode("utf-8")
        if code != "0":
            raise mcp.ToolExecutionError(decoded)
        return decoded

    return execute


def test_generated_tcl_is_complete_and_arguments_cannot_become_code():
    attack = 'C3]; error "injected"; #\n$env(PATH) {x}'
    read_script = mcp.build_read_script(
        attack, "/ROOT/[bad]", ["Value", attack], 10
    )
    set_script = mcp.build_set_script(attack, "/ROOT/[bad]", attack, attack)
    inspect_script = mcp.build_inspect_selection_script(["Value", attack], 10)

    for script in (read_script, set_script, inspect_script):
        assert attack not in script
        assert _hex(attack) in script
        tclsh = shutil.which("tclsh")
        if tclsh is None:
            continue
        probe = (
            "set candidate [encoding convertfrom utf-8 [binary format H* "
            f"{script.encode('utf-8').hex()}]]\n"
            "puts [info complete $candidate]\n"
        )
        result = subprocess.run(
            [tclsh], input=probe, capture_output=True, text=True, timeout=30
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "1"


def test_generated_read_tcl_executes_against_dbo_fixture_and_limits_results():
    setup = """
fx::resetAll
set ::fx::activePage [fx::makePage {PAGE 1}]
set first [fx::makeOccurrence R1 10k /U1/R1 {}]
set second [fx::makeOccurrence C3 100nF /U2/C3 {}]
set firstPage [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE R1 10k]
set secondPage [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE C3 100nF]
fx::linkSelectionOccurrence $firstPage $first
fx::linkSelectionOccurrence $secondPage $second
set root [fx::makeOccurrence {} {} / [list $first $second] 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    result = _run_against_dbo_fixture(
        mcp.build_read_script(None, None, ["Value"], 1), setup
    )

    assert result.returncode == 0, result.stderr
    assert "MCP_RESULT 0" in result.stdout
    assert "CAPTURE_MCP_META_V1\t1\t1" in result.stdout
    assert "CAPTURE_MCP_COMPONENT_V2" in result.stdout
    assert _hex("R1") in result.stdout
    assert _hex("10k") in result.stdout
    raw_output = result.stdout.split("MCP_RESULT_HEX", 1)[0].rstrip()
    assert raw_output.endswith(" 0")


def test_generated_set_tcl_executes_exact_path_write_and_readback():
    setup = """
fx::resetAll
set first [fx::makeOccurrence C3 10n /U1/C3 {}]
set target [fx::makeOccurrence C3 100n /U2/C3 {}]
set root [fx::makeOccurrence {} {} / [list $first $target] 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    new_value = "22k]; error injected; #"
    result = _run_against_dbo_fixture(
        mcp.build_set_script("C3", "/U2/C3", "Value", new_value), setup
    )

    assert result.returncode == 0, result.stderr
    assert "MCP_RESULT 0" in result.stdout
    assert "CAPTURE_MCP_SET_V2" in result.stdout
    assert _hex("100n") in result.stdout
    assert _hex(new_value) in result.stdout
    raw_output = result.stdout.split("MCP_RESULT_HEX", 1)[0].rstrip()
    assert raw_output.endswith(" 1")


def test_parse_read_result_preserves_unicode_and_property_order():
    raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", "C:/设计/示例.dsn"),
                    ("occurrence.refdes", "R1"),
                    ("occurrence.path", "/根/页1/R1"),
                    ("page_instance.page", "页1"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Value", "1"),
                    ("property_value:Value", "10 kΩ"),
                    ("property_present:制造商", "1"),
                    ("property_value:制造商", "示例公司"),
                ]
            ),
        ]
    )

    value = mcp._parse_read_result(raw, ["Value", "制造商"])

    assert value == {
        "components": [
            {
                "kind": "component",
                "design": "C:/设计/示例.dsn",
                "occurrence": {"refdes": "R1", "path": "/根/页1/R1"},
                "page_instance": {"page": "页1", "object_id": 42},
                "properties": {
                    "Value": {"present": True, "value": "10 kΩ"},
                    "制造商": {"present": True, "value": "示例公司"},
                },
            }
        ],
        "count": 1,
        "truncated": False,
    }


def test_parse_read_result_rejects_inconsistent_count():
    with pytest.raises(mcp.ToolExecutionError, match="inconsistent"):
        mcp._parse_read_result("CAPTURE_MCP_META_V1\t1\t0", ["Value"])


def test_read_tool_uses_defaults_and_returns_structured_data(monkeypatch, tmp_path):
    fields = [
        ("design", "C:/designs/test.dsn"),
        ("occurrence.refdes", "C3"),
        ("occurrence.path", "/C3"),
        ("page_instance.page", "PAGE 1"),
        ("page_instance.object_id", "7"),
        ("property_present:Value", "1"),
        ("property_value:Value", "100n"),
        ("property_present:PCB Footprint", "1"),
        ("property_value:PCB Footprint", "0603"),
    ]
    raw = "CAPTURE_MCP_META_V1\t1\t0\n" + _component_record(fields)
    captured = {}

    def fake_execute(runtime_file, script):
        captured["runtime_file"] = runtime_file
        captured["script"] = script
        return raw

    monkeypatch.setattr(mcp, "_execute_capture_script", fake_execute)
    runtime_file = tmp_path / "runtime.json"

    result = mcp.read_component_properties(runtime_file, {})

    assert result["components"][0]["properties"]["Value"] == {
        "present": True,
        "value": "100n",
    }
    assert captured["runtime_file"] == runtime_file
    assert all(_hex(name) in captured["script"] for name in mcp.DEFAULT_PROPERTIES)


def test_set_tool_allows_empty_value_and_parses_readback(monkeypatch, tmp_path):
    raw = "\t".join(
        [
            "CAPTURE_MCP_SET_V2",
            _hex("R1"),
            _hex("/R1"),
            _hex("Value"),
            "1",
            _hex("10k"),
            "1",
            _hex(""),
        ]
    )
    scripts = []
    monkeypatch.setattr(
        mcp,
        "_execute_capture_script",
        lambda runtime_file, script: scripts.append(script) or raw,
    )

    result = mcp.set_component_property(
        tmp_path / "runtime.json",
        {"refdes": "R1", "property_name": "Value", "value": ""},
    )

    assert result == {
        "refdes": "R1",
        "path": "/R1",
        "property": "Value",
        "before": {"present": True, "value": "10k"},
        "after": {"present": True, "value": ""},
    }
    assert mcp._utf8_hex("") in scripts[0]


def test_set_tool_upserts_a_completely_missing_occurrence_property(monkeypatch, tmp_path):
    setup = """
fx::resetAll
set target [fx::makeOccurrence C3 100n /C3 {}]
set root [fx::makeOccurrence {} {} / [list $target] 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    monkeypatch.setattr(
        mcp, "_execute_capture_script", _bridge_fixture_executor(setup, 1)
    )

    result = mcp.set_component_property(
        tmp_path / "runtime.json",
        {"refdes": "C3", "property_name": "Manufacturer", "value": "Acme"},
    )

    assert result == {
        "refdes": "C3",
        "path": "/C3",
        "property": "Manufacturer",
        "before": {"present": False},
        "after": {"present": True, "value": "Acme"},
    }


@pytest.mark.parametrize(
    "arguments, message",
    [
        ({"property_names": []}, "non-empty array"),
        (
            {"property_names": ["Value", {"item": "PCB Footprint"}]},
            r"property_names\[1\] must be a string",
        ),
        ({"max_results": True}, "integer"),
        ({"unknown": 1}, "Unknown argument"),
    ],
)
def test_read_tool_rejects_invalid_arguments(arguments, message, tmp_path):
    with pytest.raises(mcp.InvalidToolArguments, match=message):
        mcp.read_component_properties(tmp_path / "runtime.json", arguments)


def test_execute_capture_script_uses_existing_authenticated_client(monkeypatch, tmp_path):
    descriptor = {"token": "secret-token"}
    monkeypatch.setattr(mcp, "load_descriptor", lambda path: descriptor)
    calls = []

    def fake_request(actual_descriptor, method, path, payload):
        calls.append((actual_descriptor, method, path, payload))
        return _completed("done")

    monkeypatch.setattr(mcp, "request_json", fake_request)

    assert mcp._execute_capture_script(tmp_path / "runtime.json", "expr 1") == "done"
    assert calls == [
        (descriptor, "POST", "/v1/execute", {"script": "expr 1"})
    ]


def test_capture_error_redacts_runtime_token(monkeypatch, tmp_path):
    descriptor = {"token": "secret-token"}
    monkeypatch.setattr(mcp, "load_descriptor", lambda path: descriptor)
    monkeypatch.setattr(
        mcp,
        "request_json",
        lambda *args, **kwargs: _completed("failure secret-token", ok=False),
    )

    with pytest.raises(mcp.ToolExecutionError) as caught:
        mcp._execute_capture_script(tmp_path / "runtime.json", "bad")
    assert "secret-token" not in str(caught.value)
    assert "[redacted]" in str(caught.value)


def test_legacy_initialize_and_tool_listing(tmp_path):
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    initialized = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "client", "version": "1"},
            },
        }
    )
    listed = server.handle(
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
    )

    assert initialized["result"]["protocolVersion"] == "2025-06-18"
    assert initialized["result"]["capabilities"] == {
        "tools": {"listChanged": False}
    }
    assert [tool["name"] for tool in listed["result"]["tools"]] == [
        "capture_inspect_selection",
        "capture_read_component_properties",
        "capture_set_component_property",
        "capture_read_dsn_component_properties",
        "capture_set_dsn_component_property",
    ]
    assert "resultType" not in listed["result"]


def test_modern_discovery_and_tool_listing_include_required_envelope(tmp_path):
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    discovered = server.handle(
        {
            "jsonrpc": "2.0",
            "id": "d",
            "method": "server/discover",
            "params": _modern_params(),
        }
    )
    listed = server.handle(
        {
            "jsonrpc": "2.0",
            "id": "l",
            "method": "tools/list",
            "params": _modern_params(),
        }
    )

    assert discovered["result"]["supportedVersions"] == ["2026-07-28"]
    assert discovered["result"]["resultType"] == "complete"
    assert discovered["result"]["ttlMs"] >= 0
    assert listed["result"]["resultType"] == "complete"
    assert listed["result"]["cacheScope"] == "public"
    assert listed["result"]["_meta"][mcp.SERVER_INFO_META_KEY]["name"] == mcp.SERVER_NAME
    assert [tool["name"] for tool in listed["result"]["tools"]] == [
        "capture_inspect_selection",
        "capture_read_component_properties",
        "capture_set_component_property",
        "capture_read_dsn_component_properties",
        "capture_set_dsn_component_property",
    ]


def test_offline_tools_are_available_through_mcp_without_the_gui_bridge(tmp_path):
    component = {
        "kind": "component",
        "design": "C:/designs/offline.dsn",
        "occurrence": {"refdes": "C5", "path": "FNC-QQ/C5"},
        "page_instance": {"page": "MAIN", "object_id": 42},
        "properties": {"Value": {"present": True, "value": "1uF"}},
    }

    class FakeOfflineAdapter:
        def __init__(self):
            self.calls = []

        def read_component_properties(self, arguments):
            self.calls.append(("read", arguments))
            return {"components": [component], "count": 1, "truncated": False}

        def set_component_property(self, arguments):
            self.calls.append(("set", arguments))
            return {
                "dsn_path": "C:/designs/offline.dsn",
                "output_path": "C:/designs/changed.dsn",
                "source_locked": False,
                "refdes": "C5",
                "path": "FNC-QQ/C5",
                "property": "Manufacturer",
                "before": {"present": False},
                "after": {"present": True, "value": "Acme"},
            }

    adapter = FakeOfflineAdapter()
    server = mcp.CaptureMcpServer(
        tmp_path / "missing-runtime.json", offline_adapter=adapter
    )
    read_arguments = {
        "dsn_path": "C:/designs/offline.dsn",
        "refdes": "C5",
        "property_names": ["Value"],
    }
    set_arguments = {
        "dsn_path": "C:/designs/offline.dsn",
        "output_path": "C:/designs/changed.dsn",
        "refdes": "C5",
        "path": "FNC-QQ/C5",
        "property_name": "Manufacturer",
        "value": "Acme",
    }

    read_response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": {
                "name": "capture_read_dsn_component_properties",
                "arguments": read_arguments,
            },
        }
    )
    set_response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 21,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": set_arguments,
            },
        }
    )

    assert read_response["result"]["structuredContent"]["components"] == [component]
    assert set_response["result"]["structuredContent"]["after"] == {
        "present": True,
        "value": "Acme",
    }
    assert adapter.calls == [("read", read_arguments), ("set", set_arguments)]


def test_offline_set_uses_staging_then_fresh_verification_before_publishing(
    tmp_path,
):
    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    source = tmp_path / "source.DSN"
    output = tmp_path / "changed.DSN"
    source.write_bytes(b"original design bytes")
    Path(f"{source}lck").write_bytes(b"Capture lock")
    calls = []

    read_raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", source.as_posix()),
                    ("occurrence.refdes", "C5"),
                    ("occurrence.path", "FNC-QQ/C5"),
                    ("page_instance.page", "MAIN"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Manufacturer", "1"),
                    ("property_value:Manufacturer", "Acme"),
                ]
            ),
        ]
    )

    def execute(actual_tclsh, script, timeout):
        calls.append((actual_tclsh, script, timeout))
        if len(calls) == 1:
            return _set_record("C5", "FNC-QQ/C5", "Manufacturer", None, "Acme")
        return read_raw

    adapter = mcp.OfflineDesignAdapter(cadence_root=cadence_root, executor=execute)
    server = mcp.CaptureMcpServer(
        tmp_path / "missing-runtime.json", offline_adapter=adapter
    )

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "output_path": str(output),
                    "refdes": "C5",
                    "path": "FNC-QQ/C5",
                    "property_name": "Manufacturer",
                    "value": "Acme",
                },
            },
        }
    )

    result = response["result"]["structuredContent"]
    assert result["before"] == {"present": False}
    assert result["after"] == {"present": True, "value": "Acme"}
    assert result["source_locked"] is True
    assert result["output_path"] == output.resolve().as_posix()
    assert output.read_bytes() == b"original design bytes"
    assert len(calls) == 2
    assert all(call[0] == tclsh for call in calls)
    assert "SaveDesign" in calls[0][1]
    assert "SaveDesign" not in calls[1][1]
    assert not list(tmp_path.glob(".capture-ai-offline-*"))


def test_offline_set_rejects_in_place_when_capture_lock_exists(tmp_path):
    source = tmp_path / "locked.DSN"
    source.write_bytes(b"original")
    Path(f"{source}lck").write_bytes(b"lock")

    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    calls = []
    adapter = mcp.OfflineDesignAdapter(
        cadence_root=cadence_root,
        executor=lambda *args: calls.append(args),
    )
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json", offline_adapter=adapter)

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 23,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "in_place": True,
                    "refdes": "C5",
                    "property_name": "Value",
                    "value": "2uF",
                },
            },
        }
    )

    assert response["result"]["isError"] is True
    assert "DESIGN_LOCKED" in response["result"]["content"][0]["text"]
    assert calls == []
    assert source.read_bytes() == b"original"


def test_offline_set_does_not_publish_failed_fresh_process_verification(tmp_path):
    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    source = tmp_path / "source.DSN"
    output = tmp_path / "must-not-exist.DSN"
    source.write_bytes(b"original")
    calls = []
    stale_read = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", source.as_posix()),
                    ("occurrence.refdes", "C5"),
                    ("occurrence.path", "FNC-QQ/C5"),
                    ("page_instance.page", "MAIN"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Value", "1"),
                    ("property_value:Value", "old"),
                ]
            ),
        ]
    )

    def execute(actual_tclsh, script, timeout):
        calls.append(script)
        if len(calls) == 1:
            return _set_record("C5", "FNC-QQ/C5", "Value", "old", "new")
        return stale_read

    adapter = mcp.OfflineDesignAdapter(cadence_root=cadence_root, executor=execute)
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json", offline_adapter=adapter)

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 24,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "output_path": str(output),
                    "refdes": "C5",
                    "path": "FNC-QQ/C5",
                    "property_name": "Value",
                    "value": "new",
                },
            },
        }
    )

    assert response["result"]["isError"] is True
    assert "PROPERTY_PERSISTENCE_FAILED" in response["result"]["content"][0]["text"]
    assert not output.exists()
    assert source.read_bytes() == b"original"
    assert not list(tmp_path.glob(".capture-ai-offline-*"))


def test_offline_output_does_not_overwrite_a_concurrently_created_destination(
    monkeypatch, tmp_path
):
    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    source = tmp_path / "source.DSN"
    output = tmp_path / "raced.DSN"
    source.write_bytes(b"original")
    calls = []
    read_raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", source.as_posix()),
                    ("occurrence.refdes", "C5"),
                    ("occurrence.path", "C5"),
                    ("page_instance.page", "MAIN"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Value", "1"),
                    ("property_value:Value", "new"),
                ]
            ),
        ]
    )

    def execute(actual_tclsh, script, timeout):
        calls.append(script)
        if len(calls) == 1:
            return _set_record("C5", "C5", "Value", "old", "new")
        return read_raw

    original_link = mcp.os.link

    def race_link(source_path, destination_path):
        Path(destination_path).write_bytes(b"concurrent owner")
        return original_link(source_path, destination_path)

    monkeypatch.setattr(mcp.os, "link", race_link)
    adapter = mcp.OfflineDesignAdapter(cadence_root=cadence_root, executor=execute)
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json", offline_adapter=adapter)

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 25,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "output_path": str(output),
                    "refdes": "C5",
                    "property_name": "Value",
                    "value": "new",
                },
            },
        }
    )

    assert response["result"]["isError"] is True
    assert output.read_bytes() == b"concurrent owner"


def test_offline_output_rejects_a_source_change_during_verification(tmp_path):
    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    source = tmp_path / "source.DSN"
    output = tmp_path / "changed.DSN"
    source.write_bytes(b"original")
    calls = []
    read_raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", source.as_posix()),
                    ("occurrence.refdes", "C5"),
                    ("occurrence.path", "C5"),
                    ("page_instance.page", "MAIN"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Value", "1"),
                    ("property_value:Value", "new"),
                ]
            ),
        ]
    )

    def execute(actual_tclsh, script, timeout):
        calls.append(script)
        if len(calls) == 1:
            return _set_record("C5", "C5", "Value", "old", "new")
        source.write_bytes(b"concurrent update")
        return read_raw

    adapter = mcp.OfflineDesignAdapter(cadence_root=cadence_root, executor=execute)
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json", offline_adapter=adapter)

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 26,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "output_path": str(output),
                    "refdes": "C5",
                    "property_name": "Value",
                    "value": "new",
                },
            },
        }
    )

    assert response["result"]["isError"] is True
    assert "source DSN changed" in response["result"]["content"][0]["text"]
    assert source.read_bytes() == b"concurrent update"
    assert not output.exists()


def test_offline_in_place_restores_original_when_backup_cleanup_fails(
    monkeypatch, tmp_path
):
    cadence_root = tmp_path / "Cadence" / "SPB_16.6"
    tclsh = cadence_root / "tools" / "tcl84" / "bin" / "tclsh.exe"
    dbo = cadence_root / "tools" / "capture" / "orDb_Dll_TCL.dll"
    tclsh.parent.mkdir(parents=True)
    dbo.parent.mkdir(parents=True)
    tclsh.write_bytes(b"")
    dbo.write_bytes(b"")
    source = tmp_path / "source.DSN"
    source.write_bytes(b"original")
    calls = []
    read_raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            _component_record(
                [
                    ("design", source.as_posix()),
                    ("occurrence.refdes", "C5"),
                    ("occurrence.path", "C5"),
                    ("page_instance.page", "MAIN"),
                    ("page_instance.object_id", "42"),
                    ("property_present:Value", "1"),
                    ("property_value:Value", "new"),
                ]
            ),
        ]
    )

    def execute(actual_tclsh, script, timeout):
        calls.append(script)
        if len(calls) == 1:
            staging = next(tmp_path.glob(".capture-ai-offline-*/working.DSN"))
            staging.write_bytes(b"verified changed design")
            return _set_record("C5", "C5", "Value", "old", "new")
        return read_raw

    original_unlink = Path.unlink

    def fail_backup_unlink(path, *args, **kwargs):
        if "capture-ai-backup" in path.name:
            raise PermissionError("injected backup cleanup failure")
        return original_unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", fail_backup_unlink)
    adapter = mcp.OfflineDesignAdapter(cadence_root=cadence_root, executor=execute)
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json", offline_adapter=adapter)

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 27,
            "method": "tools/call",
            "params": {
                "name": "capture_set_dsn_component_property",
                "arguments": {
                    "dsn_path": str(source),
                    "in_place": True,
                    "refdes": "C5",
                    "property_name": "Value",
                    "value": "new",
                },
            },
        }
    )

    assert response["result"]["isError"] is True
    assert "original was restored" in response["result"]["content"][0]["text"]
    assert source.read_bytes() == b"original"
    assert not list(tmp_path.glob(".*.capture-ai-backup-*.DSN"))


def test_offline_child_environment_recovers_persistent_license_settings(monkeypatch):
    monkeypatch.delenv("CDS_LIC_FILE", raising=False)
    monkeypatch.delenv("LM_LICENSE_FILE", raising=False)
    persistent = {
        "CDS_LIC_FILE": r"C:\Cadence\LicenseManager\license.dat",
        "LM_LICENSE_FILE": None,
    }
    monkeypatch.setattr(
        mcp,
        "_persistent_windows_environment",
        lambda name: persistent[name],
    )

    environment = mcp._offline_child_environment()

    assert environment["CDS_LIC_FILE"] == persistent["CDS_LIC_FILE"]
    assert "LM_LICENSE_FILE" not in environment


def test_offline_child_environment_preserves_inherited_license_settings(monkeypatch):
    monkeypatch.setenv("CDS_LIC_FILE", "5280@license.example")
    queried = []
    monkeypatch.setattr(
        mcp,
        "_persistent_windows_environment",
        lambda name: queried.append(name) or None,
    )

    environment = mcp._offline_child_environment()

    assert environment["CDS_LIC_FILE"] == "5280@license.example"
    assert "CDS_LIC_FILE" not in queried


def test_selection_tool_schema_exposes_only_bounded_read_options():
    assert mcp.INSPECT_SELECTION_TOOL["inputSchema"] == {
        "type": "object",
        "properties": {
            "property_names": {
                "type": "array",
                "minItems": 1,
                "maxItems": mcp.MAX_PROPERTIES_PER_READ,
                "items": {"type": "string", "minLength": 1},
                "default": ["Value", "PCB Footprint"],
            },
            "max_results": {
                "type": "integer",
                "minimum": 1,
                "maximum": 1000,
                "default": 100,
            },
        },
        "additionalProperties": False,
    }
    assert mcp.INSPECT_SELECTION_TOOL["annotations"]["readOnlyHint"] is True


def test_selection_tool_returns_empty_current_selection_through_mcp(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set ::fx::activePage [fx::makePage {PAGE 1}]
set ::fx::instanceOccurrence $root
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {
                "name": "capture_inspect_selection",
                "arguments": {},
            },
        }
    )

    assert response["result"]["structuredContent"] == {
        "objects": [],
        "selection_count": 0,
        "returned_count": 0,
        "truncated": False,
    }


def test_selection_tool_returns_component_with_dual_locator_through_mcp(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {} {C:/designs/hier.dsn}]
set ::fx::activePage [fx::makePage {POWER}]
set ::fx::instanceOccurrence $root
set selected [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE {C?} 100nF]
set occurrence [fx::makeOccurrence C209 100nF /TOP/POWER/C209 {}]
fx::setOccurrenceProperty $occurrence {PCB Footprint} 0603
fx::linkSelectionOccurrence $selected $occurrence
set ::fx::selectionObjectsList [list $selected]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 8,
            "method": "tools/call",
            "params": {
                "name": "capture_inspect_selection",
                "arguments": {},
            },
        }
    )

    assert response["result"]["structuredContent"] == {
        "objects": [
            {
                "selection_index": 0,
                "kind": "component",
                "raw_capture_type": 13,
                "supported": True,
                "design": "C:/designs/hier.dsn",
                "occurrence": {"refdes": "C209", "path": "/TOP/POWER/C209"},
                "page_instance": {"page": "POWER", "object_id": 1001},
                "properties": {
                    "Value": {"present": True, "value": "100nF"},
                    "PCB Footprint": {"present": True, "value": "0603"},
                },
            }
        ],
        "selection_count": 1,
        "returned_count": 1,
        "truncated": False,
    }


def test_selection_properties_replace_defaults_dedupe_and_preserve_absence(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set ::fx::activePage [fx::makePage {PAGE 1}]
set ::fx::instanceOccurrence $root
set selected [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE R1 10k]
set occurrence [fx::makeOccurrence R1 10k /R1 {}]
fx::setOccurrenceProperty $occurrence Empty {}
fx::linkSelectionOccurrence $selected $occurrence
set ::fx::selectionObjectsList [list $selected]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": {
                "name": "capture_inspect_selection",
                "arguments": {"property_names": ["Empty", "Missing", "Empty"]},
            },
        }
    )

    properties = response["result"]["structuredContent"]["objects"][0]["properties"]
    assert properties == {
        "Empty": {"present": True, "value": ""},
        "Missing": {"present": False},
    }
    assert "Value" not in properties


def test_selection_properties_preserve_unicode_and_cannot_inject_tcl(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set pageName [encoding convertfrom utf-8 [binary format H* e794b5e6ba90e9a1b5]]
set ::fx::activePage [fx::makePage $pageName]
set ::fx::instanceOccurrence $root
set selected [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE U1 part]
set path [encoding convertfrom utf-8 [binary format H* 2fe9a1b6e5b1822f5531]]
set propertyName [encoding convertfrom utf-8 [binary format H* e4b8ade69687e5b19ee680a7cea9]]
set propertyValue [encoding convertfrom utf-8 [binary format H* e580bce29c93]]
set occurrence [fx::makeOccurrence U1 part $path {}]
fx::setOccurrenceProperty $occurrence $propertyName $propertyValue
fx::linkSelectionOccurrence $selected $occurrence
set ::fx::selectionObjectsList [list $selected]
    """
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    attack = 'x]; error "injected"; #'

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 18,
            "method": "tools/call",
            "params": {
                "name": "capture_inspect_selection",
                "arguments": {"property_names": ["中文属性Ω", attack]},
            },
        }
    )

    component = response["result"]["structuredContent"]["objects"][0]
    assert component["occurrence"]["path"] == "/顶层/U1"
    assert component["page_instance"]["page"] == "电源页"
    assert component["properties"] == {
        "中文属性Ω": {"present": True, "value": "值✓"},
        attack: {"present": False},
    }


def test_design_read_returns_same_component_information_through_mcp(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set page [fx::makePage {MAIN}]
set ::fx::activePage $page
set selected [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE U3 LT1028]
set occurrence [fx::makeOccurrence U3 LT1028 /U3 {}]
fx::setOccurrenceProperty $occurrence {PCB Footprint} SOIC8
fx::linkSelectionOccurrence $selected $occurrence
set root [fx::makeOccurrence {} {} / [list $occurrence] 0]
set ::fx::activeDesign [fx::makeDesign $root {} {C:/designs/flat.dsn}]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "capture_read_component_properties",
                "arguments": {"refdes": "U3"},
            },
        }
    )

    assert response["result"]["structuredContent"] == {
        "components": [
            {
                "kind": "component",
                "design": "C:/designs/flat.dsn",
                "occurrence": {"refdes": "U3", "path": "/U3"},
                "page_instance": {"page": "MAIN", "object_id": 1001},
                "properties": {
                    "Value": {"present": True, "value": "LT1028"},
                    "PCB Footprint": {"present": True, "value": "SOIC8"},
                },
            }
        ],
        "count": 1,
        "truncated": False,
    }


def test_design_read_shares_custom_property_presence_and_deduplication(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set ::fx::activePage [fx::makePage {MAIN}]
set pageObject [fx::makeSelObject $::DboBaseObject_PLACED_INSTANCE R1 10k]
set occurrence [fx::makeOccurrence R1 10k /R1 {}]
fx::setOccurrenceProperty $occurrence Empty {}
fx::linkSelectionOccurrence $pageObject $occurrence
set root [fx::makeOccurrence {} {} / [list $occurrence] 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 15,
            "method": "tools/call",
            "params": {
                "name": "capture_read_component_properties",
                "arguments": {
                    "refdes": "R1",
                    "property_names": ["Empty", "Missing", "Empty"],
                },
            },
        }
    )

    assert response["result"]["structuredContent"]["components"][0][
        "properties"
    ] == {
        "Empty": {"present": True, "value": ""},
        "Missing": {"present": False},
    }


def test_server_instructions_prevent_guessing_between_current_and_prior_selection(
    tmp_path,
):
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    instructions = server._instructions()

    assert "current, newly selected, or just-selected" in instructions
    assert "capture_inspect_selection" in instructions
    assert "earlier locator" in instructions
    assert "never guess" in instructions
    assert "does not inspect the GUI selection" in mcp.SET_TOOL["description"]


def test_selection_tool_returns_supported_mixed_kinds_and_unknown_through_mcp(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {} {C:/designs/mixed.dsn}]
set ::fx::activePage [fx::makePage {PAGE 2}]
set ::fx::instanceOccurrence $root

set block [fx::makeSelObject $::DboBaseObject_DRAWN_INSTANCE HB1 {}]
set blockOcc [fx::makeOccurrence HB1 {} /TOP/HB1 {} 0]
fx::setOccurrenceProperty $blockOcc {Implementation Type} Schematic
fx::linkSelectionOccurrence $block $blockOcc
set net [fx::makeFlatNet DATA0 {} {}]
set scalar [fx::makeSelObject $::DboBaseObject_WIRE_SCALAR {} {}]
fx::setSelectionWire $scalar $net 10 20 30 40
fx::forceSelFail $scalar GetNet
set bus [fx::makeSelObject $::DboBaseObject_WIRE_BUS {} {}]
fx::setSelectionWire $bus $net 50 60 70 80
fx::forceSelFail $bus GetNet
set global [fx::makeSelObject $::DboBaseObject_DBGLOBAL VCC {}]
fx::setSelectionPinType $global 3
set offpage [fx::makeSelObject $::DboBaseObject_OFF_PAGE_CONNECTOR NEXT {}]
fx::setSelectionLocation $offpage 100 200
set comment [fx::makeSelObject $::DboBaseObject_GRAPHIC_COMMENTTEXT_INST {Check bias} {}]
set port [fx::makeSelObject $::DboBaseObject_PORT INPUT {}]
fx::setSelectionPortDetails $port $net 1 100 300 110 300
set pin [fx::makeSelObject $::DboBaseObject_PORT_INSTANCE_SCALAR {} {}]
fx::setSelectionPinDetails $pin $block $net CLK 7 2 5 200 300 230 300
set alias [fx::makeSelObject $::DboBaseObject_ALIAS DATA0 {}]
fx::setSelectionAlias $alias 300 400 1
set box [fx::makeSelObject $::DboBaseObject_GRAPHIC_BOX_INST {} {}]
fx::setSelectionGraphic $box 10 20 30 40 1 2 3 4
set line [fx::makeSelObject $::DboBaseObject_GRAPHIC_LINE_INST {} {}]
fx::setSelectionGraphic $line 50 60 70 80 5 6 0 0
set ellipse [fx::makeSelObject $::DboBaseObject_GRAPHIC_ELLIPSE_INST {} {}]
fx::setSelectionGraphic $ellipse 90 100 110 120 7 8 9 10
set title [fx::makeSelObject $::DboBaseObject_TITLEBLOCK_INSTANCE {} {}]
set unknown [fx::makeSelObject 85 JUNCTION {}]
set ::fx::selectionObjectsList [list $block $scalar $bus $global $offpage $comment $port $pin $alias $box $line $ellipse $title $unknown]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {"name": "capture_inspect_selection", "arguments": {}},
        }
    )

    value = response["result"]["structuredContent"]
    assert value["selection_count"] == value["returned_count"] == 14
    assert value["truncated"] is False
    assert [(item["selection_index"], item["kind"]) for item in value["objects"]] == [
        (0, "hierarchical_block"),
        (1, "wire"),
        (2, "wire"),
        (3, "global"),
        (4, "off_page_connector"),
        (5, "comment_text"),
        (6, "port"),
        (7, "pin"),
        (8, "net_alias"),
        (9, "graphic_box"),
        (10, "graphic_line"),
        (11, "graphic_ellipse"),
        (12, "title_block"),
        (13, "unknown"),
    ]
    common_locator = {"design": "C:/designs/mixed.dsn", "page": "PAGE 2"}
    assert value["objects"][0] == {
        "selection_index": 0,
        "kind": "hierarchical_block",
        "raw_capture_type": 12,
        "supported": True,
        "locator": {**common_locator, "kind": "hierarchical_block", "object_id": 1001},
        "name": "HB1",
        "path": "/TOP/HB1",
        "implementation_type": "Schematic",
    }
    assert value["objects"][1]["wire_kind"] == "scalar"
    assert value["objects"][1]["net"] == "DATA0"
    assert value["objects"][1]["start"] == {"x": 10, "y": 20}
    assert value["objects"][1]["end"] == {"x": 30, "y": 40}
    assert value["objects"][2]["wire_kind"] == "bus"
    assert value["objects"][3]["raw_capture_type"] == 37
    assert value["objects"][3]["name"] == "VCC"
    assert value["objects"][3]["pin_type"] == 3
    assert value["objects"][4]["location"] == {"x": 100, "y": 200}
    assert value["objects"][5]["text"] == "Check bias"
    assert value["objects"][6] | {
        "selection_index": 6,
        "kind": "port",
        "raw_capture_type": 23,
        "supported": True,
        "locator": value["objects"][6]["locator"],
    } == {
        **value["objects"][6],
        "name": "INPUT",
        "pin_type": 1,
        "connected": True,
        "net": "DATA0",
        "location": {"x": 100, "y": 300},
        "connection_point": {"x": 110, "y": 300},
    }
    assert value["objects"][7]["component_refdes"] == "HB1"
    assert value["objects"][7]["pin_name"] == "CLK"
    assert value["objects"][7]["pin_number"] == "7"
    assert value["objects"][7]["pin_type"] == 2
    assert value["objects"][7]["pin_position"] == 5
    assert value["objects"][7]["connected"] is True
    assert value["objects"][7]["net"] == "DATA0"
    assert value["objects"][7]["start"] == {"x": 200, "y": 300}
    assert value["objects"][7]["connection_point"] == {"x": 230, "y": 300}
    assert value["objects"][8]["name"] == "DATA0"
    assert value["objects"][8]["location"] == {"x": 300, "y": 400}
    assert value["objects"][8]["rotation"] == 1
    assert value["objects"][9]["bounds"] == {
        "left": 10,
        "top": 20,
        "right": 30,
        "bottom": 40,
    }
    assert value["objects"][9]["line_style"] == 1
    assert value["objects"][9]["line_width"] == 2
    assert value["objects"][9]["fill_style"] == 3
    assert value["objects"][9]["hatch_style"] == 4
    assert value["objects"][10]["start"] == {"x": 50, "y": 60}
    assert value["objects"][10]["end"] == {"x": 70, "y": 80}
    assert value["objects"][10]["line_style"] == 5
    assert value["objects"][10]["line_width"] == 6
    assert value["objects"][11]["bounds"] == {
        "left": 90,
        "top": 100,
        "right": 110,
        "bottom": 120,
    }
    assert value["objects"][11]["fill_style"] == 9
    assert value["objects"][11]["hatch_style"] == 10
    assert value["objects"][12]["page_name"] == "PAGE 2"
    assert value["objects"][13] == {
        "selection_index": 13,
        "kind": "unknown",
        "raw_capture_type": 85,
        "supported": False,
    }
    for item in value["objects"][1:13]:
        assert item["locator"] == {
            **common_locator,
            "kind": item["kind"],
            "object_id": 1001 + item["selection_index"],
        }
    assert "locator" not in value["objects"][13]


def test_selection_tool_isolates_one_object_failure_through_mcp(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set ::fx::activePage [fx::makePage {PAGE 1}]
set ::fx::instanceOccurrence $root
set before [fx::makeSelObject $::DboBaseObject_COMMENT_TEXT before {}]
set broken [fx::makeSelObject $::DboBaseObject_OFF_PAGE_CONNECTOR BROKEN {}]
fx::setSelectionLocation $broken 1 2
fx::forceSelFail $broken GetLocation
set after [fx::makeSelObject $::DboBaseObject_TITLEBLOCK_INSTANCE {} {}]
set ::fx::selectionObjectsList [list $before $broken $after]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": {"name": "capture_inspect_selection", "arguments": {}},
        }
    )

    objects = response["result"]["structuredContent"]["objects"]
    assert [item["kind"] for item in objects] == [
        "comment_text",
        "off_page_connector",
        "title_block",
    ]
    assert objects[1] == {
        "selection_index": 1,
        "kind": "off_page_connector",
        "raw_capture_type": 38,
        "supported": True,
        "error": {
            "code": "DBO_CALL_FAILED",
            "message": "DBO_CALL_FAILED: GetLocation: forced failure: GetLocation (code 1)",
        },
    }


def test_selection_tool_isolates_type_failure_and_rejects_wrong_family(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set ::fx::activePage [fx::makePage {PAGE 1}]
set ::fx::instanceOccurrence $root
set before [fx::makeSelObject $::DboBaseObject_COMMENT_TEXT before {}]
set wrongFamily [fx::makeOccurrence BAD bad /BAD {}]
set after [fx::makeSelObject $::DboBaseObject_TITLEBLOCK_INSTANCE {} {}]
set ::fx::selectionObjectsList [list $before missing-selection-handle $wrongFamily $after]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 16,
            "method": "tools/call",
            "params": {"name": "capture_inspect_selection", "arguments": {}},
        }
    )

    objects = response["result"]["structuredContent"]["objects"]
    assert [item["kind"] for item in objects] == [
        "comment_text",
        "unknown",
        "unknown",
        "title_block",
    ]
    assert objects[1] == {
        "selection_index": 1,
        "kind": "unknown",
        "raw_capture_type": -1,
        "supported": False,
        "error": {
            "code": "OBJECT_INSPECTION_FAILED",
            "message": (
                "fake DboBaseObject_GetObjectType: handle "
                "missing-selection-handle has no recorded object type"
            ),
        },
    }
    assert objects[2] == {
        "selection_index": 2,
        "kind": "unknown",
        "raw_capture_type": 66,
        "supported": False,
    }


def test_design_read_releases_children_iterator_when_sort_fails(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
rename ::fx::iterDispatch ::fx::workingIterDispatch
proc ::fx::iterDispatch {handle method argsList} {
    if {$method eq {Sort}} {
        set st [lindex $argsList 0]
        fx::failState $st 1 {forced failure: Sort}
        return {}
    }
    return [::fx::workingIterDispatch $handle $method $argsList]
}
"""

    def execute(_runtime_file, script):
        result = _run_against_dbo_fixture(script, setup)
        assert result.returncode == 0, result.stderr
        marker = "MCP_RESULT_HEX "
        line = next(
            line for line in result.stdout.splitlines() if line.startswith(marker)
        )
        code, payload = line[len(marker) :].split(" ", 1)
        encoded, set_calls, delete_calls = payload.rsplit(" ", 2)
        assert set_calls == "0"
        assert delete_calls == "1"
        decoded = bytes.fromhex(encoded).decode("utf-8")
        if code != "0":
            raise mcp.ToolExecutionError(decoded)
        return decoded

    monkeypatch.setattr(mcp, "_execute_capture_script", execute)
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 17,
            "method": "tools/call",
            "params": {
                "name": "capture_read_component_properties",
                "arguments": {},
            },
        }
    )

    assert response["result"]["isError"] is True
    assert "forced failure: Sort" in response["result"]["content"][0]["text"]


def test_selection_tool_requires_schematic_view_through_mcp(monkeypatch, tmp_path):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": {"name": "capture_inspect_selection", "arguments": {}},
        }
    )

    assert response["result"]["isError"] is True
    assert "SCHEMATIC_VIEW_REQUIRED" in response["result"]["content"][0]["text"]


def test_selection_tool_limits_without_deduplicating_or_reordering(
    monkeypatch, tmp_path
):
    setup = """
fx::resetAll
set root [fx::makeOccurrence {} {} / {} 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
set ::fx::activePage [fx::makePage {PAGE 1}]
set ::fx::instanceOccurrence $root
set repeated [fx::makeSelObject $::DboBaseObject_COMMENT_TEXT repeated {}]
set other [fx::makeSelObject $::DboBaseObject_COMMENT_TEXT other {}]
set ::fx::selectionObjectsList [list $repeated $repeated $other]
"""
    monkeypatch.setattr(mcp, "_execute_capture_script", _bridge_fixture_executor(setup))
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 14,
            "method": "tools/call",
            "params": {
                "name": "capture_inspect_selection",
                "arguments": {"max_results": 2},
            },
        }
    )

    value = response["result"]["structuredContent"]
    assert value["selection_count"] == 3
    assert value["returned_count"] == 2
    assert value["truncated"] is True
    assert [item["text"] for item in value["objects"]] == ["repeated", "repeated"]
    assert [item["selection_index"] for item in value["objects"]] == [0, 1]


@pytest.mark.parametrize(
    "arguments, message",
    [
        ({"property_names": []}, "non-empty array"),
        (
            {"property_names": [{"item": "Value"}]},
            r"property_names\[0\] must be a string",
        ),
        ({"max_results": True}, "integer"),
        ({"max_results": 1001}, "1 through 1000"),
        ({"unknown": 1}, "Unknown argument"),
    ],
)
def test_selection_tool_rejects_invalid_arguments(arguments, message, tmp_path):
    with pytest.raises(mcp.InvalidToolArguments, match=message):
        mcp.inspect_selection(tmp_path / "runtime.json", arguments)


def test_unknown_per_request_protocol_version_is_rejected(tmp_path):
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    params = _modern_params()
    params["_meta"][mcp.PROTOCOL_VERSION_META_KEY] = "2027-01-01"

    response = server.handle(
        {"jsonrpc": "2.0", "id": 9, "method": "tools/list", "params": params}
    )

    assert response["error"]["code"] == -32022


def test_tool_execution_failures_are_visible_to_the_model(monkeypatch, tmp_path):
    server = mcp.CaptureMcpServer(tmp_path / "runtime.json")
    monkeypatch.setattr(
        mcp,
        "read_component_properties",
        lambda runtime, arguments: (_ for _ in ()).throw(
            mcp.ToolExecutionError("NO_ACTIVE_DESIGN")
        ),
    )

    response = server.handle(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": mcp.READ_TOOL["name"], "arguments": {}},
        }
    )

    assert response["result"]["isError"] is True
    assert response["result"]["content"][0]["text"] == "NO_ACTIVE_DESIGN"


def test_stdio_uses_one_json_rpc_message_per_line(tmp_path):
    incoming = BytesIO(
        b'{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n'
        b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
    )
    outgoing = BytesIO()

    exit_code = mcp.serve_stdio(
        mcp.CaptureMcpServer(tmp_path / "runtime.json"), incoming, outgoing
    )

    assert exit_code == 0
    messages = [json.loads(line) for line in outgoing.getvalue().splitlines()]
    assert messages == [{"jsonrpc": "2.0", "id": 1, "result": {}}]


def test_stdio_reports_parse_error_and_continues(tmp_path):
    incoming = BytesIO(b"not-json\n" b'{"jsonrpc":"2.0","id":1,"method":"ping"}\n')
    outgoing = BytesIO()

    mcp.serve_stdio(mcp.CaptureMcpServer(tmp_path / "runtime.json"), incoming, outgoing)

    messages = [json.loads(line) for line in outgoing.getvalue().splitlines()]
    assert messages[0]["error"]["code"] == -32700
    assert messages[1]["result"] == {}
