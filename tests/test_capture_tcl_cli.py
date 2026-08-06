"""Contract tests for the human Capture Tcl bridge client."""

from __future__ import annotations

import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import sys
import threading
import urllib.error

import pytest

import capture_tcl_cli as cli


TOKEN = "runtime-secret-token"


def descriptor(**overrides):
    value = {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "baseUrl": "http://127.0.0.1:8767",
        "token": TOKEN,
        "capturePid": 4242,
        "serverPid": 4343,
    }
    value.update(overrides)
    return value


def completed(ok=True):
    return {
        "id": "cmd-1",
        "state": "completed",
        "ok": ok,
        "returnCode": 0 if ok else 1,
        "result": "42" if ok else "bad call",
        "stdout": "hello\n",
        "stderr": "" if ok else "warning\n",
        "errorInfo": "" if ok else "stack line",
        "errorCode": [],
        "errorLine": None if ok else 1,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "resultTruncated": False,
    }


def write_descriptor(path: Path, value=None):
    path.write_text(
        json.dumps(descriptor() if value is None else value),
        encoding="utf-8",
    )


class FakeResponse:
    def __init__(self, value, status=200):
        self.value = value
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, size=-1):
        body = json.dumps(self.value, ensure_ascii=False).encode("utf-8")
        return body if size < 0 else body[:size]


class TtyInput(io.StringIO):
    def isatty(self):
        return True


class EncodingWriter:
    def __init__(self, encoding):
        self.encoding = encoding
        self.writes = []

    def write(self, value):
        value.encode(self.encoding, errors="strict")
        self.writes.append(value)
        return len(value)

    def flush(self):
        pass


class ReconfigurableEncodingWriter(EncodingWriter):
    def __init__(self, encoding):
        super().__init__(encoding)
        self.reconfigurations = []

    def reconfigure(self, **options):
        self.reconfigurations.append(options)
        self.encoding = options.get("encoding", self.encoding)


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"service": "other"}, "service"),
        ({"service": 1}, "service"),
        ({"protocolVersion": 2}, "protocol"),
        ({"protocolVersion": True}, "protocol"),
        ({"token": ""}, "token"),
        ({"token": 12}, "token"),
        ({"token": "bad\r\nheader"}, "token"),
        ({"baseUrl": "https://127.0.0.1:8767"}, "baseUrl"),
        ({"baseUrl": "http://localhost:8767"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.2:8767"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:not-a-port"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:0"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:08767"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:8767/"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:8767?"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:8767#"}, "baseUrl"),
        ({"baseUrl": "http://127.0.0.1:8767/path"}, "baseUrl"),
        ({"baseUrl": "http://user@127.0.0.1:8767"}, "baseUrl"),
        ({"capturePid": "4242"}, "capturePid"),
        ({"capturePid": True}, "capturePid"),
        ({"capturePid": 0}, "capturePid"),
        ({"serverPid": 4343.0}, "serverPid"),
        ({"serverPid": False}, "serverPid"),
        ({"serverPid": -1}, "serverPid"),
    ],
)
def test_load_descriptor_strictly_rejects_invalid_metadata(tmp_path, changes, message):
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    write_descriptor(runtime_file, descriptor(**changes))

    with pytest.raises(cli.BridgeClientError, match=message):
        cli.load_descriptor(runtime_file)


@pytest.mark.parametrize(
    "contents",
    ["not json", "[]", json.dumps({"service": "capture-tcl-bridge"})],
)
def test_load_descriptor_rejects_corrupt_or_incomplete_json(tmp_path, contents):
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    runtime_file.write_text(contents, encoding="utf-8")

    with pytest.raises(cli.BridgeClientError):
        cli.load_descriptor(runtime_file)


def test_load_descriptor_accepts_the_exact_local_runtime_identity(tmp_path):
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    expected = descriptor()
    write_descriptor(runtime_file, expected)

    assert cli.load_descriptor(runtime_file) == expected


def test_default_runtime_file_uses_temp_and_the_protocol_filename(monkeypatch, tmp_path):
    monkeypatch.setenv("TEMP", str(tmp_path))

    assert cli.default_runtime_file() == tmp_path / "capture_tcl_bridge.json"


def test_request_json_sends_bearer_utf8_json_and_35_second_timeout(monkeypatch):
    observed = {}

    def fake_urlopen(request, timeout):
        observed["request"] = request
        observed["timeout"] = timeout
        return FakeResponse({"ok": True})

    monkeypatch.setattr(cli, "_open_url", fake_urlopen)

    result = cli.request_json(
        descriptor(),
        "POST",
        "/v1/execute",
        {"script": "puts 你好"},
    )

    request = observed["request"]
    assert result == {"ok": True}
    assert request.full_url == "http://127.0.0.1:8767/v1/execute"
    assert request.method == "POST"
    assert request.get_header("Authorization") == f"Bearer {TOKEN}"
    assert request.get_header("Content-type") == "application/json; charset=utf-8"
    assert json.loads(request.data.decode("utf-8")) == {"script": "puts 你好"}
    assert observed["timeout"] == 35


def test_request_json_uses_no_body_for_get(monkeypatch):
    observed = {}

    def fake_urlopen(request, timeout):
        observed["request"] = request
        return FakeResponse({"captureConnected": True})

    monkeypatch.setattr(cli, "_open_url", fake_urlopen)

    cli.request_json(descriptor(), "GET", "/v1/health")

    assert observed["request"].data is None
    assert observed["request"].method == "GET"


def test_response_budget_is_large_enough_for_protocol_fields():
    assert cli.RESPONSE_LIMIT_BYTES == 160 * 1024 * 1024


def test_request_json_probes_success_body_at_limit_plus_one(monkeypatch):
    observed_sizes = []

    class RecordingResponse(FakeResponse):
        def read(self, size=-1):
            observed_sizes.append(size)
            return super().read(size)

    monkeypatch.setattr(
        cli,
        "_open_url",
        lambda *_args, **_kwargs: RecordingResponse({"ok": True}),
    )

    assert cli.request_json(descriptor(), "GET", "/v1/health") == {"ok": True}
    assert observed_sizes == [cli.RESPONSE_LIMIT_BYTES + 1]


def test_request_json_rejects_oversized_success_body(monkeypatch):
    monkeypatch.setattr(cli, "RESPONSE_LIMIT_BYTES", 64, raising=False)
    body = b" " * 64 + b"{}"

    class OversizedResponse(FakeResponse):
        def read(self, size=-1):
            return body if size < 0 else body[:size]

    monkeypatch.setattr(
        cli,
        "_open_url",
        lambda *_args, **_kwargs: OversizedResponse(None),
    )

    with pytest.raises(cli.BridgeClientError, match="too large"):
        cli.request_json(descriptor(), "GET", "/v1/health")


def test_request_json_accepts_a_legal_4mib_control_character_field(monkeypatch):
    value = completed()
    value["result"] = "\x00" * (4 * 1024 * 1024)
    body = json.dumps(value).encode("utf-8")
    assert len(body) > 20 * 1024 * 1024
    assert len(body) < cli.RESPONSE_LIMIT_BYTES

    class RawResponse(FakeResponse):
        def read(self, size=-1):
            return body if size < 0 else body[:size]

    monkeypatch.setattr(
        cli,
        "_open_url",
        lambda *_args, **_kwargs: RawResponse(None),
    )

    response = cli.request_json(descriptor(), "POST", "/v1/execute", {})

    assert response["result"] == value["result"]


def test_request_json_rejects_redirect_without_forwarding_authorization():
    received_authorization = []

    class TargetHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            received_authorization.append(self.headers.get("Authorization"))
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
    target_thread = threading.Thread(target=target.serve_forever, daemon=True)
    target_thread.start()

    target_url = f"http://127.0.0.1:{target.server_port}/target"

    class RedirectHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(302)
            self.send_header("Location", target_url)
            self.end_headers()

        def log_message(self, *_args):
            pass

    redirect = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
    redirect_thread = threading.Thread(target=redirect.serve_forever, daemon=True)
    redirect_thread.start()
    try:
        value = descriptor(baseUrl=f"http://127.0.0.1:{redirect.server_port}")
        with pytest.raises(cli.BridgeClientError, match="HTTP 302"):
            cli.request_json(value, "GET", "/redirect")
        assert received_authorization == []
    finally:
        redirect.shutdown()
        redirect.server_close()
        target.shutdown()
        target.server_close()
        redirect_thread.join(timeout=2)
        target_thread.join(timeout=2)


def test_real_cli_ignores_environment_proxy_and_keeps_credentials_local(tmp_path):
    direct_requests = []
    proxy_requests = []

    class DirectHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            direct_requests.append((self.headers.get("Authorization"), body))
            response_body = json.dumps(completed()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        def log_message(self, *_args):
            pass

    class ProxyHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            proxy_requests.append(
                (self.headers.get("Authorization"), self.rfile.read(length))
            )
            self.send_response(502)
            self.end_headers()

        def log_message(self, *_args):
            pass

    direct = ThreadingHTTPServer(("127.0.0.1", 0), DirectHandler)
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), ProxyHandler)
    direct_thread = threading.Thread(target=direct.serve_forever, daemon=True)
    proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    direct_thread.start()
    proxy_thread.start()
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    write_descriptor(
        runtime_file,
        descriptor(baseUrl=f"http://127.0.0.1:{direct.server_port}"),
    )
    proxy_url = f"http://127.0.0.1:{proxy.server_port}"
    environment = os.environ.copy()
    environment.update(
        {
            "HTTP_PROXY": proxy_url,
            "HTTPS_PROXY": proxy_url,
            "ALL_PROXY": proxy_url,
            "http_proxy": proxy_url,
            "https_proxy": proxy_url,
            "all_proxy": proxy_url,
            "NO_PROXY": "",
            "no_proxy": "",
        }
    )
    try:
        process = subprocess.run(
            [
                sys.executable,
                str(Path(cli.__file__)),
                "--runtime-file",
                str(runtime_file),
                "-c",
                "puts proxy-secret-script",
            ],
            input="",
            text=True,
            capture_output=True,
            timeout=10,
            env=environment,
            check=False,
        )
    finally:
        direct.shutdown()
        direct.server_close()
        proxy.shutdown()
        proxy.server_close()
        direct_thread.join(timeout=2)
        proxy_thread.join(timeout=2)

    assert process.returncode == 0, process.stderr
    assert proxy_requests == []
    assert len(direct_requests) == 1
    authorization, body = direct_requests[0]
    assert authorization == f"Bearer {TOKEN}"
    assert json.loads(body.decode("utf-8")) == {
        "script": "puts proxy-secret-script"
    }


def test_request_json_converts_structured_http_errors(monkeypatch):
    body = json.dumps(
        {"ok": False, "error": {"code": "BRIDGE_BUSY", "message": "Still running."}}
    ).encode("utf-8")

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            409,
            "Conflict",
            {},
            io.BytesIO(body),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert str(raised.value) == "BRIDGE_BUSY: Still running."


def test_request_json_always_closes_http_error_response(monkeypatch):
    body = io.BytesIO(
        json.dumps(
            {
                "ok": False,
                "error": {"code": "BRIDGE_BUSY", "message": "Still running."},
            }
        ).encode("utf-8")
    )
    error = urllib.error.HTTPError(
        "http://127.0.0.1:8767/v1/execute",
        409,
        "Conflict",
        {},
        body,
    )

    def fail(*_args, **_kwargs):
        raise error

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError, match="BRIDGE_BUSY"):
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert body.closed is True


@pytest.mark.parametrize("failure_type", [OSError, RuntimeError])
def test_http_error_close_failure_does_not_mask_the_protocol_error(
    monkeypatch, failure_type
):
    class CloseFailureBody(io.BytesIO):
        def close(self):
            raise failure_type(f"close failed {TOKEN}")

    body = CloseFailureBody(
        json.dumps(
            {
                "ok": False,
                "error": {"code": "BRIDGE_BUSY", "message": "Still running."},
            }
        ).encode("utf-8")
    )
    error = urllib.error.HTTPError(
        "http://127.0.0.1:8767/v1/execute", 409, "Conflict", {}, body
    )
    monkeypatch.setattr(
        cli,
        "_open_url",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(error),
    )

    try:
        with pytest.raises(cli.BridgeClientError, match="BRIDGE_BUSY") as raised:
            cli.request_json(
                descriptor(), "POST", "/v1/execute", {"script": "x"}
            )
        assert TOKEN not in str(raised.value)
    finally:
        io.BytesIO.close(body)


def test_execution_timeout_preserves_safe_command_metadata(monkeypatch):
    body = json.dumps(
        {
            "ok": False,
            "error": {
                "code": "EXECUTION_TIMEOUT",
                "message": "The command is still running and was not cancelled.",
            },
            "id": "cmd-timeout-1",
            "state": "queued",
        }
    ).encode("utf-8")

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            504,
            "Gateway Timeout",
            {},
            io.BytesIO(body),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert str(raised.value).startswith("EXECUTION_TIMEOUT:")
    assert raised.value.metadata == {"id": "cmd-timeout-1", "state": "queued"}


@pytest.mark.parametrize(
    "body",
    [
        {
            "error": {"code": "BAD_\ud800", "message": "failure"},
            "ok": False,
        },
        {
            "error": {"code": "BAD_RESPONSE", "message": "bad \ud800"},
            "ok": False,
        },
        {
            "error": {"code": "EXECUTION_TIMEOUT", "message": "still running"},
            "id": "cmd-\ud800",
            "state": "queued",
            "ok": False,
        },
        {
            "error": {"code": "EXECUTION_TIMEOUT", "message": "still running"},
            "id": "cmd-1",
            "state": "queued-\ud800",
            "ok": False,
        },
    ],
)
def test_http_error_surrogates_never_reach_exception_text_or_metadata(
    monkeypatch, body
):
    response_body = json.dumps(body).encode("utf-8")

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            500,
            "Server Error",
            {},
            io.BytesIO(response_body),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert "\ud800" not in str(raised.value)
    str(raised.value).encode("utf-8", errors="strict")
    assert all("\ud800" not in value for value in raised.value.metadata.values())


def test_non_json_http_error_with_surrogate_reason_is_safe(monkeypatch):
    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            500,
            "bad \ud800 reason",
            {},
            io.BytesIO(b"not-json"),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert "\ud800" not in str(raised.value)
    str(raised.value).encode("utf-8", errors="strict")


def test_request_json_probes_http_error_body_at_limit_plus_one(monkeypatch):
    observed_sizes = []
    body = json.dumps(
        {"ok": False, "error": {"code": "BRIDGE_BUSY", "message": "Busy."}}
    ).encode("utf-8")

    class RecordingBody(io.BytesIO):
        def read(self, size=-1):
            observed_sizes.append(size)
            return super().read(size)

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            409,
            "Conflict",
            {},
            RecordingBody(body),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError, match="BRIDGE_BUSY"):
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert observed_sizes == [cli.RESPONSE_LIMIT_BYTES + 1]


def test_request_json_rejects_oversized_http_error_body_without_token(
    monkeypatch,
):
    monkeypatch.setattr(cli, "RESPONSE_LIMIT_BYTES", 64, raising=False)
    body = b" " * 64 + b"{}"

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            500,
            f"server failed {TOKEN}",
            {},
            io.BytesIO(body),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError, match="too large") as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert TOKEN not in str(raised.value)


def test_request_json_converts_unreadable_http_error_body(monkeypatch):
    class BrokenBody:
        def read(self, _size=-1):
            raise OSError(f"could not read {TOKEN}")

        def close(self):
            pass

    def fail(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            "http://127.0.0.1:8767/v1/execute",
            500,
            f"server failed {TOKEN}",
            {},
            BrokenBody(),
        )

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "POST", "/v1/execute", {"script": "x"})

    assert "HTTP 500" in str(raised.value)
    assert TOKEN not in str(raised.value)


@pytest.mark.parametrize(
    "failure",
    [
        urllib.error.URLError("runtime-secret-token connection refused"),
        TimeoutError("runtime-secret-token timed out"),
        ValueError("runtime-secret-token malformed response"),
    ],
)
def test_request_json_converts_failures_without_exposing_the_token(monkeypatch, failure):
    def fail(*_args, **_kwargs):
        raise failure

    monkeypatch.setattr(cli, "_open_url", fail)

    with pytest.raises(cli.BridgeClientError) as raised:
        cli.request_json(descriptor(), "GET", "/v1/health")

    assert TOKEN not in str(raised.value)


def test_request_json_rejects_non_json_success(monkeypatch):
    class InvalidResponse(FakeResponse):
        def read(self, size=-1):
            body = b"not-json"
            return body if size < 0 else body[:size]

    monkeypatch.setattr(
        cli,
        "_open_url",
        lambda *_args, **_kwargs: InvalidResponse(None),
    )

    with pytest.raises(cli.BridgeClientError, match="JSON"):
        cli.request_json(descriptor(), "GET", "/v1/health")


def test_resolve_script_accepts_command_utf8_file_and_stdin(tmp_path):
    script_file = tmp_path / "debug.tcl"
    script_file.write_text("puts 你好\nexpr {6 * 7}\n", encoding="utf-8")

    assert cli.resolve_script("expr {1 + 1}", None, None) == "expr {1 + 1}"
    assert cli.resolve_script(None, script_file, None) == "puts 你好\nexpr {6 * 7}\n"
    assert cli.resolve_script(None, None, "puts stdin\n") == "puts stdin\n"


@pytest.mark.parametrize(
    ("command", "file_value", "stdin"),
    [
        (None, None, None),
        ("x", Path("debug.tcl"), None),
        ("x", None, "piped"),
        (None, Path("debug.tcl"), "piped"),
    ],
)
def test_resolve_script_requires_exactly_one_source(command, file_value, stdin):
    with pytest.raises(cli.ScriptSourceError):
        cli.resolve_script(command, file_value, stdin)


def test_main_returns_three_for_non_utf8_script_file(monkeypatch, tmp_path, capsys):
    script_file = tmp_path / "bad.tcl"
    script_file.write_bytes(b"puts \xff")
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["-f", str(script_file)]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "UTF-8" in captured.err


def test_main_returns_three_for_stdin_decode_failure(monkeypatch, capsys):
    class BrokenStdin:
        def isatty(self):
            return False

        def read(self):
            raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")

    monkeypatch.setattr(cli.sys, "stdin", BrokenStdin())

    assert cli.main([]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "stdin" in captured.err.lower()


def test_main_returns_three_for_isolated_surrogate_command(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["-c", "puts \ud800"]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "UTF-8 JSON" in captured.err
    assert "Traceback" not in captured.err


def test_main_returns_three_for_isolated_surrogate_stdin(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli.sys, "stdin", io.StringIO("puts \ud800"))

    assert cli.main([]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "UTF-8 JSON" in captured.err
    assert "Traceback" not in captured.err


def test_print_human_success_preserves_streams_and_prints_result(capsys):
    assert cli.print_human(completed()) == 0

    captured = capsys.readouterr()
    assert captured.out == "hello\nResult: 42\n"
    assert captured.err == ""


def test_print_human_tcl_failure_returns_one_and_reports_details(capsys):
    assert cli.print_human(completed(ok=False)) == 1

    captured = capsys.readouterr()
    assert captured.out == "hello\n"
    assert captured.err == (
        "warning\nTcl error (return code 1): bad call\nstack line\n"
    )


def test_main_executes_command_and_returns_success(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(
        cli,
        "request_json",
        lambda value, method, path, payload=None: (
            calls.append((value, method, path, payload)) or completed()
        ),
    )
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["-c", "puts hello; expr {6 * 7}"]) == 0

    assert calls == [
        (
            descriptor(),
            "POST",
            "/v1/execute",
            {"script": "puts hello; expr {6 * 7}"},
        )
    ]
    assert capsys.readouterr().out == "hello\nResult: 42\n"


def test_main_reconfigures_supported_streams_to_utf8_for_human_emoji(monkeypatch):
    value = completed()
    value["stdout"] = "😀 from Capture\n"
    value["result"] = "你好 😀"
    stdout = ReconfigurableEncodingWriter("gbk")
    stderr = ReconfigurableEncodingWriter("gbk")
    monkeypatch.setattr(cli.sys, "stdout", stdout)
    monkeypatch.setattr(cli.sys, "stderr", stderr)
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: value)

    assert cli.main(["-c", "expr 1"]) == 0

    assert stdout.reconfigurations == [{"encoding": "utf-8", "errors": "strict"}]
    assert stderr.reconfigurations == [{"encoding": "utf-8", "errors": "strict"}]
    assert "".join(stdout.writes) == "😀 from Capture\nResult: 你好 😀\n"
    assert stderr.writes == []


def test_main_human_encoding_failure_is_exit_three_without_partial_output(
    monkeypatch,
):
    value = completed()
    value["stdout"] = "prefix that must not leak\n"
    value["result"] = "😀"
    stdout = EncodingWriter("ascii")
    stderr = EncodingWriter("ascii")
    monkeypatch.setattr(cli.sys, "stdout", stdout)
    monkeypatch.setattr(cli.sys, "stderr", stderr)
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: value)

    assert cli.main(["-c", "expr 1"]) == 3

    assert stdout.writes == []
    assert "human-readable output" in "".join(stderr.writes).lower()


def test_main_reads_a_piped_script(monkeypatch):
    calls = []
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(
        cli,
        "request_json",
        lambda _value, _method, _path, payload=None: (
            calls.append(payload) or completed()
        ),
    )
    monkeypatch.setattr(cli.sys, "stdin", io.StringIO("puts piped\n"))

    assert cli.main([]) == 0
    assert calls == [{"script": "puts piped\n"}]


def test_main_json_emits_only_one_complete_document(monkeypatch, capsys):
    value = completed(ok=False)
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: value)
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["--json", "-c", "error bad"]) == 1

    captured = capsys.readouterr()
    assert json.loads(captured.out) == value
    assert captured.out.count("\n") == 1
    assert captured.err == ""


@pytest.mark.parametrize("encoding", ["ascii", "gbk"])
def test_write_json_is_one_ascii_safe_write_with_emoji(monkeypatch, encoding):
    output = EncodingWriter(encoding)
    monkeypatch.setattr(cli.sys, "stdout", output)

    cli._write_json({"emoji": "😀", "text": "你好"})

    assert len(output.writes) == 1
    assert output.writes[0].isascii()
    assert json.loads(output.writes[0]) == {"emoji": "😀", "text": "你好"}


@pytest.mark.parametrize(
    "bad_result",
    [
        {**completed(), "id": ""},
        {**completed(), "id": 1},
        {**completed(), "state": "executing"},
        {**completed(), "ok": 1},
        {**completed(), "ok": False, "returnCode": 0},
        {**completed(), "ok": True, "returnCode": 1},
        {**completed(), "returnCode": True},
        {**completed(), "result": 42},
        {**completed(), "stdout": None},
        {**completed(), "stderr": []},
        {**completed(), "errorInfo": {}},
        {**completed(), "id": "cmd-\ud800"},
        {**completed(), "result": "bad \ud800"},
        {**completed(), "stdout": "bad \ud800"},
        {**completed(), "stderr": "bad \ud800"},
        {**completed(), "errorInfo": "bad \ud800"},
        {**completed(), "errorCode": ["BAD", "\ud800"]},
        {**completed(), "errorCode": "NONE"},
        {**completed(), "errorCode": ["A", 2]},
        {**completed(), "errorLine": True},
        {**completed(), "errorLine": "1"},
        {**completed(), "stdoutTruncated": 0},
        {**completed(), "stderrTruncated": None},
        {**completed(), "resultTruncated": "false"},
        {key: value for key, value in completed().items() if key != "result"},
    ],
)
def test_main_rejects_malformed_completed_result_without_json_output(
    monkeypatch, capsys, bad_result
):
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: bad_result)
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["--json", "-c", "expr 1"]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "invalid execution response" in captured.err.lower()


def test_main_timeout_error_prints_later_lookup_details(monkeypatch, capsys):
    error = cli.BridgeClientError(
        "EXECUTION_TIMEOUT: The command is still running.",
        metadata={"id": "cmd-timeout-1", "state": "executing"},
    )
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(
        cli,
        "request_json",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(error),
    )
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["-c", "after 40000"]) == 3

    captured = capsys.readouterr()
    assert captured.out == ""
    assert "cmd-timeout-1" in captured.err
    assert "executing" in captured.err
    assert "/v1/commands/cmd-timeout-1" in captured.err
    assert "not cancelled" in captured.err
    assert TOKEN not in captured.err


def test_main_returns_three_for_discovery_or_transport_failure(monkeypatch, capsys):
    monkeypatch.setattr(
        cli,
        "load_descriptor",
        lambda _path: (_ for _ in ()).throw(cli.BridgeClientError(f"bad {TOKEN}")),
    )
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    assert cli.main(["-c", "expr 1"]) == 3

    captured = capsys.readouterr()
    assert "Bridge error:" in captured.err
    assert TOKEN not in captured.err


def test_main_uses_argparse_exit_two_for_missing_or_multiple_sources(
    monkeypatch, tmp_path
):
    script_file = tmp_path / "debug.tcl"
    script_file.write_text("expr 1", encoding="utf-8")
    monkeypatch.setattr(cli.sys, "stdin", TtyInput())

    with pytest.raises(SystemExit) as missing:
        cli.main([])
    assert missing.value.code == 2

    with pytest.raises(SystemExit) as multiple:
        cli.main(["-c", "expr 1", "-f", str(script_file)])
    assert multiple.value.code == 2


def test_main_treats_closed_empty_stdin_as_no_script_source(monkeypatch):
    monkeypatch.setattr(cli.sys, "stdin", io.StringIO(""))

    with pytest.raises(SystemExit) as missing:
        cli.main([])

    assert missing.value.code == 2


def test_status_requires_exact_health_identity_and_reports_connected(
    monkeypatch, capsys
):
    health = {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "captureConnected": True,
        "busy": False,
        "capturePid": 4242,
        "serverPid": 4343,
    }
    calls = []
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(
        cli,
        "request_json",
        lambda value, method, path, payload=None: (
            calls.append((value, method, path, payload)) or health
        ),
    )

    assert cli.main(["status"]) == 0

    assert calls == [(descriptor(), "GET", "/v1/health", None)]
    assert capsys.readouterr().out == "Capture Tcl bridge: connected, idle\n"


@pytest.mark.parametrize(
    "changes",
    [
        {"service": "other"},
        {"protocolVersion": 2},
        {"capturePid": 9999},
        {"serverPid": 9999},
        {"capturePid": True},
    ],
)
def test_status_rejects_any_health_identity_mismatch(monkeypatch, capsys, changes):
    health = {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "captureConnected": True,
        "busy": False,
        "capturePid": 4242,
        "serverPid": 4343,
    }
    health.update(changes)
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: health)

    assert cli.main(["status"]) == 3

    captured = capsys.readouterr()
    assert "identity" in captured.err.lower()
    assert TOKEN not in captured.err


def test_status_reports_disconnected_with_exit_three(monkeypatch, capsys):
    health = {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "captureConnected": False,
        "busy": False,
        "capturePid": 4242,
        "serverPid": 4343,
    }
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: health)

    assert cli.main(["status"]) == 3
    assert capsys.readouterr().out == "Capture Tcl bridge: disconnected, idle\n"


def test_status_json_is_one_document_and_uses_connection_exit(monkeypatch, capsys):
    health = {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "captureConnected": True,
        "busy": True,
        "capturePid": 4242,
        "serverPid": 4343,
    }
    monkeypatch.setattr(cli, "load_descriptor", lambda _path: descriptor())
    monkeypatch.setattr(cli, "request_json", lambda *_args, **_kwargs: health)

    assert cli.main(["status", "--json"]) == 0
    captured = capsys.readouterr()
    assert json.loads(captured.out) == health
    assert captured.out.count("\n") == 1
    assert captured.err == ""
