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
        + "\nset mcpScript [encoding convertfrom utf-8 [binary format H* "
        + script.encode("utf-8").hex()
        + "]]\n"
        + "set mcpCode [catch {uplevel #0 $mcpScript} mcpResult]\n"
        + "puts [list MCP_RESULT $mcpCode $mcpResult $::fx::setPropCalls]\n"
    )
    return subprocess.run(
        [tclsh],
        input=program,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )


def test_generated_tcl_is_complete_and_arguments_cannot_become_code():
    attack = 'C3]; error "injected"; #\n$env(PATH) {x}'
    read_script = mcp.build_read_script(
        attack, "/ROOT/[bad]", ["Value", attack], 10
    )
    set_script = mcp.build_set_script(attack, "/ROOT/[bad]", attack, attack)

    for script in (read_script, set_script):
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
set first [fx::makeOccurrence R1 10k /U1/R1 {}]
set second [fx::makeOccurrence C3 100nF /U2/C3 {}]
set root [fx::makeOccurrence {} {} / [list $first $second] 0]
set ::fx::activeDesign [fx::makeDesign $root {}]
"""
    result = _run_against_dbo_fixture(
        mcp.build_read_script(None, None, ["Value"], 1), setup
    )

    assert result.returncode == 0, result.stderr
    assert "MCP_RESULT 0" in result.stdout
    assert "CAPTURE_MCP_META_V1\t1\t1" in result.stdout
    assert _hex("R1") in result.stdout
    assert _hex("10k") in result.stdout
    assert result.stdout.rstrip().endswith(" 0")


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
    assert "CAPTURE_MCP_SET_V1" in result.stdout
    assert _hex("100n") in result.stdout
    assert _hex(new_value) in result.stdout
    assert result.stdout.rstrip().endswith(" 1")


def test_parse_read_result_preserves_unicode_and_property_order():
    raw = "\n".join(
        [
            "CAPTURE_MCP_META_V1\t1\t0",
            "\t".join(
                [
                    "CAPTURE_MCP_V1",
                    _hex("R1"),
                    _hex("/根/页1/R1"),
                    _hex("Value"),
                    _hex("10 kΩ"),
                    _hex("制造商"),
                    _hex("示例公司"),
                ]
            ),
        ]
    )

    value = mcp._parse_read_result(raw, ["Value", "制造商"])

    assert value == {
        "components": [
            {
                "refdes": "R1",
                "path": "/根/页1/R1",
                "properties": {"Value": "10 kΩ", "制造商": "示例公司"},
            }
        ],
        "count": 1,
        "truncated": False,
    }


def test_parse_read_result_rejects_inconsistent_count():
    with pytest.raises(mcp.ToolExecutionError, match="inconsistent"):
        mcp._parse_read_result("CAPTURE_MCP_META_V1\t1\t0", ["Value"])


def test_read_tool_uses_defaults_and_returns_structured_data(monkeypatch, tmp_path):
    fields = ["CAPTURE_MCP_V1", _hex("C3"), _hex("/C3")]
    for name, value in zip(mcp.DEFAULT_PROPERTIES, ("100n", "C3", "CAP", "0603")):
        fields.extend((_hex(name), _hex(value)))
    raw = "CAPTURE_MCP_META_V1\t1\t0\n" + "\t".join(fields)
    captured = {}

    def fake_execute(runtime_file, script):
        captured["runtime_file"] = runtime_file
        captured["script"] = script
        return raw

    monkeypatch.setattr(mcp, "_execute_capture_script", fake_execute)
    runtime_file = tmp_path / "runtime.json"

    result = mcp.read_component_properties(runtime_file, {})

    assert result["components"][0]["properties"]["Value"] == "100n"
    assert captured["runtime_file"] == runtime_file
    assert all(_hex(name) in captured["script"] for name in mcp.DEFAULT_PROPERTIES)


def test_set_tool_allows_empty_value_and_parses_readback(monkeypatch, tmp_path):
    raw = "\t".join(
        [
            "CAPTURE_MCP_SET_V1",
            _hex("R1"),
            _hex("/R1"),
            _hex("Value"),
            _hex("10k"),
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
        "before": "10k",
        "after": "",
    }
    assert mcp._utf8_hex("") in scripts[0]


@pytest.mark.parametrize(
    "arguments, message",
    [
        ({"property_names": []}, "non-empty array"),
        ({"max_results": True}, "integer"),
        ({"unknown": 1}, "Unknown argument"),
        ({"property_names": ["Value", "Value"]}, "Duplicate"),
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
        "capture_read_component_properties",
        "capture_set_component_property",
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
