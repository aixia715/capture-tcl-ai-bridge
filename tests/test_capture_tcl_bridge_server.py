"""Contract tests for the authenticated Capture Tcl AI bridge service."""

import asyncio
import json
import os
from pathlib import Path
import socket
from contextlib import contextmanager
import threading
import time

import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

import capture_tcl_bridge_server as bridge


@pytest.fixture()
def client():
    bridge.reset_bridge_state()
    with TestClient(bridge.app) as test_client:
        yield test_client


def bridge_headers():
    return {"Authorization": "Bearer test-token"}


def capture_headers(pid=4242, command_id=None):
    if command_id is None:
        with bridge.bridge.lock:
            active = bridge.bridge.active
            command_id = active["id"] if active is not None else "command-1"
    return {
        **bridge_headers(),
        "X-Capture-Pid": str(pid),
        "X-Capture-Command-Id": command_id,
    }


def server_signal_paths(runtime_file):
    launch_file = runtime_file.with_name("capture_tcl_bridge_launch_test")
    cancel_file = Path(f"{launch_file}.cancel")
    ack_file = Path(f"{launch_file}.stopped")
    return launch_file, cancel_file, ack_file


def server_main_args(runtime_file, *extra):
    launch_file, cancel_file, ack_file = server_signal_paths(runtime_file)
    claim_file = Path(f"{launch_file}.claimed")
    launch_file.write_bytes(b"launch test-nonce\n")
    return [
        "--parent-pid",
        "123",
        "--runtime-file",
        str(runtime_file),
        "--launch-file",
        str(launch_file),
        "--claim-file",
        str(claim_file),
        "--cancel-file",
        str(cancel_file),
        "--ack-file",
        str(ack_file),
        *extra,
    ]


def result_payload(command_id, **overrides):
    payload = {
        "id": command_id,
        "returnCode": 0,
        "result": "done",
        "stdout": "",
        "stderr": "",
        "errorInfo": "",
        "errorCode": [],
        "errorLine": None,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "resultTruncated": False,
    }
    payload.update(overrides)
    return payload


def queue_and_claim(client, command_id="command-1", script="puts hello"):
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": command_id, "script": script, "state": "queued"}
    response = client.get("/internal/command", headers=capture_headers())
    assert response.status_code == 200
    assert response.json() == {"id": command_id, "script": script}
    return command_id


@pytest.mark.parametrize(
    ("body", "expected_field", "expected_reason"),
    [
        (b"{", "body", "invalid_json"),
        (json.dumps({"id": "command-1"}).encode(), "returnCode", "missing"),
        (
            json.dumps(result_payload("command-1", returnCode=True)).encode(),
            "returnCode",
            "invalid_type",
        ),
        (
            json.dumps(result_payload("command-1", errorInfo="\ud800")).encode(),
            "errorInfo",
            "invalid_utf8",
        ),
    ],
    ids=("invalid_json", "missing_field", "wrong_type", "unencodable"),
)
def test_invalid_result_authenticated_completion_replaces_invalid_capture_payload(
    client, body, expected_field, expected_reason
):
    command_id = queue_and_claim(client)

    response = client.post(
        "/internal/result", headers=capture_headers(command_id=command_id), content=body
    )

    assert response.status_code == 400
    response_body = response.json()
    assert response_body["error"]["code"] == "INVALID_RESULT"
    assert response_body["id"] == command_id
    assert response_body["state"] == "completed"
    assert response_body["field"] == expected_field
    assert response_body["reason"] == expected_reason
    assert "test-token" not in response.text
    assert bridge.bridge.active is None
    assert bridge.bridge.completed[command_id] == {
        "id": command_id,
        "state": "completed",
        "ok": False,
        "returnCode": 1,
        "result": "Capture returned an invalid bridge result.",
        "stdout": "",
        "stderr": "",
        "errorInfo": f"Invalid internal result payload: {expected_field}:{expected_reason}",
        "errorCode": ["CAPTURE", "AI", "BRIDGE", "INVALID_RESULT"],
        "errorLine": None,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "resultTruncated": False,
    }


def test_result_body_oversized_authenticated_completion_replaces_invalid_capture_payload(
    client, monkeypatch
):
    monkeypatch.setattr(bridge, "RESULT_BODY_LIMIT_BYTES", 16)
    command_id = queue_and_claim(client)

    response = client.post(
        "/internal/result",
        headers=capture_headers(command_id=command_id),
        content=b"{" + b"x" * 16,
    )

    assert response.status_code == 413
    assert response.json() == {
        "ok": False,
        "error": {
            "code": "REQUEST_TOO_LARGE",
            "message": "Result body is too large.",
        },
        "id": command_id,
        "state": "completed",
        "field": "body",
        "reason": "too_large",
    }
    assert bridge.bridge.active is None
    assert bridge.bridge.completed[command_id]["errorInfo"] == (
        "Invalid internal result payload: body:too_large"
    )


@pytest.mark.parametrize("header_id", (None, "wrong-id", "old-id"))
def test_command_id_mismatch_malformed_result_with_missing_wrong_or_old_header_cannot_finish_active_command(
    client, header_id
):
    command_id = queue_and_claim(client)
    headers = {**bridge_headers(), "X-Capture-Pid": "4242"}
    if header_id is not None:
        headers["X-Capture-Command-Id"] = header_id

    response = client.post("/internal/result", headers=headers, content=b"{")

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "COMMAND_ID_MISMATCH"
    assert bridge.bridge.active == {
        "id": command_id,
        "script": "puts hello",
        "state": "executing",
    }
    assert command_id not in bridge.bridge.completed


def test_internal_result_rejects_queued_command_even_when_header_and_payload_match(client):
    command_id = "queued-command"
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": command_id, "script": "puts hello", "state": "queued"}

    response = client.post(
        "/internal/result",
        headers=capture_headers(command_id=command_id),
        json=result_payload(command_id),
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "COMMAND_ID_MISMATCH"
    assert bridge.bridge.active["state"] == "queued"


def test_completed_result_replay_cannot_finish_a_later_executing_command(client):
    completed_id = "completed-command"
    later_id = "later-command"
    with bridge.bridge.lock:
        bridge.bridge.store_completed(result_payload(completed_id))
        bridge.bridge.active = {"id": later_id, "script": "puts later", "state": "executing"}

    replay = client.post(
        "/internal/result",
        headers=capture_headers(command_id=completed_id),
        json=result_payload(completed_id),
    )

    assert replay.status_code == 200
    assert replay.json() == {"id": completed_id, "state": "completed"}
    assert bridge.bridge.active == {
        "id": later_id,
        "script": "puts later",
        "state": "executing",
    }


def test_completed_header_replay_with_a_current_payload_id_is_rejected_without_touching_current(
    client,
):
    completed_id = "completed-command"
    current_id = "current-command"
    with bridge.bridge.lock:
        bridge.bridge.store_completed(result_payload(completed_id))
        bridge.bridge.active = {"id": current_id, "script": "puts current", "state": "executing"}

    replay = client.post(
        "/internal/result",
        headers=capture_headers(command_id=completed_id),
        json=result_payload(current_id),
    )

    assert replay.status_code == 409
    assert replay.json()["error"]["code"] == "COMMAND_ID_MISMATCH"
    assert bridge.bridge.active == {
        "id": current_id,
        "script": "puts current",
        "state": "executing",
    }
    assert current_id not in bridge.bridge.completed


def test_completed_header_replay_with_malformed_body_is_not_acknowledged(client):
    completed_id = "completed-command"
    current_id = "current-command"
    with bridge.bridge.lock:
        bridge.bridge.store_completed(result_payload(completed_id))
        bridge.bridge.active = {"id": current_id, "script": "puts current", "state": "executing"}

    replay = client.post(
        "/internal/result", headers=capture_headers(command_id=completed_id), content=b"{"
    )

    assert replay.status_code == 400
    assert replay.json()["error"]["code"] == "INVALID_RESULT"
    assert bridge.bridge.active == {
        "id": current_id,
        "script": "puts current",
        "state": "executing",
    }


def test_wrong_payload_id_before_missing_fields_cannot_synthetically_complete_current_command(client):
    current_id = "current-command"
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": current_id, "script": "puts current", "state": "executing"}

    response = client.post(
        "/internal/result",
        headers=capture_headers(command_id=current_id),
        json={"id": "wrong-command"},
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "COMMAND_ID_MISMATCH"
    assert bridge.bridge.active == {
        "id": current_id,
        "script": "puts current",
        "state": "executing",
    }
    assert current_id not in bridge.bridge.completed


def test_execute_waiter_receives_synthetic_completion_after_an_invalid_capture_result(client):
    client.get("/internal/command", headers=capture_headers())
    responses = []
    waiter = threading.Thread(
        target=lambda: responses.append(
            client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts hello"})
        )
    )
    waiter.start()
    deadline = time.monotonic() + 2
    while bridge.bridge.active is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert bridge.bridge.active is not None
    command_id = bridge.bridge.active["id"]
    assert client.get("/internal/command", headers=capture_headers()).json()["id"] == command_id

    invalid = client.post(
        "/internal/result", headers=capture_headers(command_id=command_id), content=b"{"
    )

    assert invalid.status_code == 400
    waiter.join(timeout=2)
    assert not waiter.is_alive()
    assert responses[0].json()["id"] == command_id
    assert responses[0].json()["errorCode"] == ["CAPTURE", "AI", "BRIDGE", "INVALID_RESULT"]


@pytest.mark.parametrize(
    ("method", "path", "kwargs"),
    [
        ("get", "/v1/health", {}),
        ("get", "/internal/command", {}),
        ("post", "/internal/shutdown", {}),
        ("post", "/v1/execute", {"json": {"script": "puts hello"}}),
        ("post", "/internal/result", {"json": result_payload("unknown")}),
        ("get", "/v1/commands/unknown", {}),
    ],
)
@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Bearer incorrect-token"},
    ],
)
def test_all_endpoints_reject_missing_or_incorrect_token(client, method, path, kwargs, headers):
    response = getattr(client, method)(path, headers=headers, **kwargs)

    assert response.status_code == 401
    assert response.json() == {
        "ok": False,
        "error": {"code": "UNAUTHORIZED", "message": "Invalid or missing bearer token."},
    }


def test_health_rejects_non_ascii_authorization_without_an_internal_error(client):
    request = Request(
        {
            "type": "http",
            "headers": [(b"authorization", b"Bearer \xff")],
        }
    )

    response = asyncio.run(bridge.health(request))

    assert response.status_code == 401
    assert json.loads(response.body) == {
        "ok": False,
        "error": {"code": "UNAUTHORIZED", "message": "Invalid or missing bearer token."},
    }


def test_health_returns_exact_service_identity_and_connection_status(client):
    assert bridge.SERVICE == "capture-tcl-bridge"
    assert bridge.PROTOCOL_VERSION == 1

    response = client.get("/v1/health", headers=bridge_headers())

    assert response.status_code == 200
    assert response.json() == {
        "service": bridge.SERVICE,
        "protocolVersion": bridge.PROTOCOL_VERSION,
        "captureConnected": False,
        "busy": False,
        "capturePid": 4242,
        "serverPid": os.getpid(),
    }


def test_internal_command_poll_marks_capture_connected(client):
    response = client.get("/internal/command", headers=capture_headers())

    assert response.status_code == 200
    assert response.json() == {}

    health = client.get("/v1/health", headers=bridge_headers())
    assert health.json()["captureConnected"] is True


def test_capture_connection_expires_at_the_heartbeat_timeout(client, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(bridge.time, "monotonic", lambda: clock[0])

    client.get("/internal/command", headers=capture_headers())
    clock[0] += bridge.HEARTBEAT_TIMEOUT_SECONDS

    response = client.get("/v1/health", headers=bridge_headers())

    assert response.json()["captureConnected"] is False


def test_reset_keeps_one_bridge_instance_and_clears_its_state(client):
    state = bridge.bridge
    state.last_bridge_seen = 12.0
    state.active = {"id": "active"}
    state.completed["completed"] = {"id": "completed"}

    bridge.reset_bridge_state(token="replacement-token", capture_pid=7777)

    assert bridge.bridge is state
    assert state.token == "replacement-token"
    assert state.capture_pid == 7777
    assert state.last_bridge_seen is None
    assert state.active is None
    assert state.completed == {}


def test_internal_command_rejects_an_unexpected_capture_pid(client):
    response = client.get("/internal/command", headers=capture_headers(pid=99))

    assert response.status_code == 409
    assert response.json() == {
        "ok": False,
        "error": {"code": "CAPTURE_PID_MISMATCH", "message": "Capture PID does not match."},
    }


def test_execute_returns_disconnected_before_queueing(client):
    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts hello"})

    assert response.status_code == 503
    assert response.json() == {
        "ok": False,
        "error": {"code": "CAPTURE_DISCONNECTED", "message": "Capture is not connected."},
    }


def test_execute_reports_busy_not_disconnected_while_a_script_runs(client):
    """A running script blocks Capture's event loop, so heartbeats stop.

    Capture executes on its Tcl/UI thread, so any script lasting longer than
    the heartbeat window silently stops the heartbeat. Reporting that as
    CAPTURE_DISCONNECTED tells a caller the bridge is gone when the truth is
    "wait, something is running" - the opposite of the action it should take.
    A claimed, executing command is itself proof Capture was there.
    """
    bridge.bridge.active = {"id": "abc", "script": "after 45000", "state": "executing"}

    response = client.post(
        "/v1/execute", headers=bridge_headers(), json={"script": "puts hello"}
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "BRIDGE_BUSY"


def test_execute_still_reports_disconnected_for_an_unclaimed_command(client):
    """A queued command proves nothing: Capture may never have picked it up."""
    bridge.bridge.active = {"id": "abc", "script": "puts hello", "state": "queued"}

    response = client.post(
        "/v1/execute", headers=bridge_headers(), json={"script": "puts hello"}
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "CAPTURE_DISCONNECTED"


def test_execute_validates_request_shape_before_connection_state(client):
    response = client.post("/v1/execute", headers=bridge_headers(), json=["puts hello"])

    assert response.status_code == 400
    assert response.json() == {
        "ok": False,
        "error": {"code": "INVALID_REQUEST", "message": "Request body must be a JSON object with a string script."},
    }


def test_execute_rejects_malformed_json_before_connection_state(client):
    response = client.post(
        "/v1/execute",
        headers={**bridge_headers(), "Content-Type": "application/json"},
        content=b'{"script":',
    )

    assert response.status_code == 400
    assert response.json() == {
        "ok": False,
        "error": {"code": "INVALID_REQUEST", "message": "Request body must be a JSON object with a string script."},
    }


def test_execute_rejects_non_string_script_before_connection_state(client):
    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": 42})

    assert response.status_code == 400
    assert response.json() == {
        "ok": False,
        "error": {"code": "INVALID_REQUEST", "message": "Request body must be a JSON object with a string script."},
    }


def test_execute_rejects_script_with_unencodable_surrogate(client):
    response = client.post(
        "/v1/execute",
        headers={**bridge_headers(), "Content-Type": "application/json"},
        content=b'{"script": "\\ud800"}',
    )

    assert response.status_code == 400
    assert response.json() == {
        "ok": False,
        "error": {"code": "INVALID_REQUEST", "message": "Request body must be a JSON object with a string script."},
    }


def test_execute_rejects_large_utf8_script_before_connection_state(client):
    script = "中" * ((bridge.SCRIPT_LIMIT_BYTES // len("中".encode("utf-8"))) + 1)

    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": script})

    assert response.status_code == 413
    assert response.json() == {
        "ok": False,
        "error": {"code": "SCRIPT_TOO_LARGE", "message": "Script exceeds the 1 MiB limit."},
    }


def test_execute_accepts_script_at_exactly_the_size_limit(client):
    client.get("/internal/command", headers=capture_headers())
    script = "x" * bridge.SCRIPT_LIMIT_BYTES

    with bridge.bridge.lock:
        bridge.bridge.active = {"id": "occupied", "script": "", "state": "queued"}

    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": script})

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "BRIDGE_BUSY"


def test_execute_rejects_script_one_byte_over_the_size_limit(client):
    script = "x" * (bridge.SCRIPT_LIMIT_BYTES + 1)

    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": script})

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "SCRIPT_TOO_LARGE"


def test_execute_waits_for_claimed_result_and_returns_completed_result(client):
    client.get("/internal/command", headers=capture_headers())
    responses = []
    request_thread = threading.Thread(
        target=lambda: responses.append(
            client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts hello"})
        )
    )
    request_thread.start()

    deadline = time.monotonic() + 2
    while bridge.bridge.active is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert bridge.bridge.active is not None
    command_id = bridge.bridge.active["id"]

    claim = client.get("/internal/command", headers=capture_headers())
    assert claim.json() == {"id": command_id, "script": "puts hello"}
    submitted = client.post("/internal/result", headers=capture_headers(), json=result_payload(command_id))
    assert submitted.status_code == 200

    request_thread.join(timeout=2)
    assert not request_thread.is_alive()
    assert responses[0].status_code == 200
    assert responses[0].json() == {
        "id": command_id,
        "state": "completed",
        "ok": True,
        "returnCode": 0,
        "result": "done",
        "stdout": "",
        "stderr": "",
        "errorInfo": "",
        "errorCode": [],
        "errorLine": None,
        "stdoutTruncated": False,
        "stderrTruncated": False,
        "resultTruncated": False,
    }


def test_command_claims_queued_command_once_and_reports_executing_state(client):
    command_id = "command-1"
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": command_id, "script": "puts hello", "state": "queued"}
    queued = client.get(f"/v1/commands/{command_id}", headers=bridge_headers())
    assert queued.json() == {"id": command_id, "state": "queued"}

    claim = client.get("/internal/command", headers=capture_headers())
    assert claim.json() == {"id": command_id, "script": "puts hello"}

    assert client.get("/internal/command", headers=capture_headers()).json() == {}
    response = client.get(f"/v1/commands/{command_id}", headers=bridge_headers())

    assert response.status_code == 200
    assert response.json() == {"id": command_id, "state": "executing"}


def test_second_execute_is_rejected_while_first_command_is_active(client):
    client.get("/internal/command", headers=capture_headers())
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": "active", "script": "puts active", "state": "queued"}

    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts second"})

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "BRIDGE_BUSY"


def test_execute_timeout_keeps_active_command_for_later_result_and_lookup(client, monkeypatch):
    client.get("/internal/command", headers=capture_headers())
    monkeypatch.setattr(bridge, "EXECUTE_TIMEOUT_SECONDS", 0)

    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts later"})

    assert response.status_code == 504
    timeout_body = response.json()
    assert timeout_body["error"]["code"] == "EXECUTION_TIMEOUT"
    command_id = timeout_body["id"]
    assert timeout_body["state"] == "queued"
    assert bridge.bridge.active["id"] == command_id

    assert client.get("/internal/command", headers=capture_headers()).json() == {
        "id": command_id,
        "script": "puts later",
    }
    assert client.post("/internal/result", headers=capture_headers(), json=result_payload(command_id)).status_code == 200
    lookup = client.get(f"/v1/commands/{command_id}", headers=bridge_headers())

    assert lookup.status_code == 200
    assert lookup.json()["state"] == "completed"


def test_execute_returns_result_that_completes_in_the_deadline_decision_race(client, monkeypatch):
    clock = [0.0]
    sleep_entered = threading.Event()
    release_sleep = threading.Event()
    complete_at_deadline = threading.Event()
    original_sleep = bridge.asyncio.sleep

    monkeypatch.setattr(bridge, "EXECUTE_TIMEOUT_SECONDS", 0.01)
    monkeypatch.setattr(bridge.time, "monotonic", lambda: clock[0])

    async def controlled_sleep(_delay):
        sleep_entered.set()
        while not release_sleep.is_set():
            await original_sleep(0)
        complete_at_deadline.set()

    monkeypatch.setattr(bridge.asyncio, "sleep", controlled_sleep)

    def complete_during_deadline_check():
        if complete_at_deadline.is_set():
            complete_at_deadline.clear()
            with bridge.bridge.lock:
                active = bridge.bridge.active
                assert active is not None
                assert active["state"] == "executing"
                completed = bridge.normalize_result(result_payload(active["id"]))
                assert completed is not None
                bridge.bridge.store_completed(completed)
                bridge.bridge.active = None
            return 0.01
        return clock[0]

    monkeypatch.setattr(bridge.time, "monotonic", complete_during_deadline_check)
    client.get("/internal/command", headers=capture_headers())
    responses = []
    request_thread = threading.Thread(
        target=lambda: responses.append(
            client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts race"})
        )
    )
    request_thread.start()

    assert sleep_entered.wait(timeout=2)
    claim = client.get("/internal/command", headers=capture_headers())
    assert claim.status_code == 200
    assert claim.json()["script"] == "puts race"
    release_sleep.set()

    request_thread.join(timeout=2)
    assert not request_thread.is_alive()
    assert responses[0].status_code == 200
    assert responses[0].json()["state"] == "completed"


def test_execute_timeout_reports_executing_state_at_the_final_decision(client, monkeypatch):
    clock = [0.0]
    sleep_entered = threading.Event()
    release_sleep = threading.Event()
    original_sleep = bridge.asyncio.sleep

    monkeypatch.setattr(bridge, "EXECUTE_TIMEOUT_SECONDS", 0.01)
    monkeypatch.setattr(bridge.time, "monotonic", lambda: clock[0])

    async def controlled_sleep(_delay):
        sleep_entered.set()
        while not release_sleep.is_set():
            await original_sleep(0)
        clock[0] = 0.01

    monkeypatch.setattr(bridge.asyncio, "sleep", controlled_sleep)
    client.get("/internal/command", headers=capture_headers())
    responses = []
    request_thread = threading.Thread(
        target=lambda: responses.append(
            client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts timeout"})
        )
    )
    request_thread.start()

    assert sleep_entered.wait(timeout=2)
    claim = client.get("/internal/command", headers=capture_headers())
    assert claim.status_code == 200
    release_sleep.set()

    request_thread.join(timeout=2)
    assert not request_thread.is_alive()
    assert responses[0].status_code == 504
    assert responses[0].json()["state"] == "executing"


@pytest.mark.parametrize(
    "payload",
    [
        result_payload("different-id"),
        {"id": "command-1"},
        result_payload(1),
        result_payload("command-1", returnCode="0"),
        result_payload("command-1", returnCode=True),
        result_payload("command-1", result=1),
        result_payload("command-1", stdout={"not": "text"}),
        result_payload("command-1", stderr=None),
        result_payload("command-1", errorInfo=1),
        result_payload("command-1", errorCode="not-an-array"),
        result_payload("command-1", errorCode=["TCL", 7]),
        result_payload("command-1", errorLine="1"),
        result_payload("command-1", errorLine=True),
        result_payload("command-1", stdoutTruncated="no"),
        result_payload("command-1", stderrTruncated=0),
        result_payload("command-1", resultTruncated=[]),
    ],
)
def test_internal_result_rejects_mismatch_and_safely_completes_invalid_payload(client, payload):
    command_id = queue_and_claim(client)

    response = client.post("/internal/result", headers=capture_headers(), json=payload)

    expected_code = "COMMAND_ID_MISMATCH" if payload.get("id") != command_id else "INVALID_RESULT"
    assert response.status_code == (409 if expected_code == "COMMAND_ID_MISMATCH" else 400)
    assert response.json()["error"]["code"] == expected_code
    if expected_code == "COMMAND_ID_MISMATCH":
        assert bridge.bridge.active == {"id": command_id, "script": "puts hello", "state": "executing"}
    else:
        assert response.json()["id"] == command_id
        assert response.json()["state"] == "completed"
        assert bridge.bridge.active is None
        assert bridge.bridge.completed[command_id]["errorCode"] == [
            "CAPTURE",
            "AI",
            "BRIDGE",
            "INVALID_RESULT",
        ]


def test_internal_result_rejects_a_result_before_the_command_is_claimed(client):
    with bridge.bridge.lock:
        bridge.bridge.active = {"id": "command-1", "script": "puts hello", "state": "queued"}

    response = client.post("/internal/result", headers=capture_headers(), json=result_payload("command-1"))

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "COMMAND_ID_MISMATCH"
    assert bridge.bridge.active["state"] == "queued"


def test_internal_result_truncates_each_4mib_field_at_a_utf8_boundary_without_flag_leakage(client):
    oversized = "x" * (bridge.FIELD_LIMIT_BYTES - 1) + "é"
    assert len(oversized.encode("utf-8")) == bridge.FIELD_LIMIT_BYTES + 1

    for field, flag in (
        ("result", "resultTruncated"),
        ("stdout", "stdoutTruncated"),
        ("stderr", "stderrTruncated"),
    ):
        command_id = queue_and_claim(client, command_id=f"command-{field}")
        response = client.post(
            "/internal/result",
            headers=capture_headers(),
            json=result_payload(command_id, **{field: oversized}),
        )

        assert response.status_code == 200
        stored = bridge.bridge.completed[command_id]
        assert stored[field] == "x" * (bridge.FIELD_LIMIT_BYTES - 1)
        assert len(stored[field].encode("utf-8")) <= bridge.FIELD_LIMIT_BYTES
        assert stored[flag] is True
        for other_flag in {"resultTruncated", "stdoutTruncated", "stderrTruncated"} - {flag}:
            assert stored[other_flag] is False


def test_internal_result_keeps_a_field_at_exactly_4mib_without_truncation(client):
    command_id = queue_and_claim(client)
    exact_limit = "x" * bridge.FIELD_LIMIT_BYTES

    response = client.post(
        "/internal/result",
        headers=capture_headers(),
        json=result_payload(command_id, result=exact_limit),
    )

    assert response.status_code == 200
    stored = bridge.bridge.completed[command_id]
    assert stored["result"] == exact_limit
    assert stored["resultTruncated"] is False
    assert stored["stdoutTruncated"] is False
    assert stored["stderrTruncated"] is False


def test_normalize_result_bounds_error_info_at_a_utf8_boundary(monkeypatch):
    monkeypatch.setattr(bridge, "FIELD_LIMIT_BYTES", 7)

    normalized = bridge.normalize_result(
        result_payload("command-1", errorInfo="ab你cde")
    )

    assert normalized is not None
    assert normalized["errorInfo"] == "ab你cd"
    assert len(normalized["errorInfo"].encode("utf-8")) == 7


def test_normalize_result_bounds_aggregate_error_code_and_empty_items(monkeypatch):
    monkeypatch.setattr(bridge, "FIELD_LIMIT_BYTES", 7)

    normalized = bridge.normalize_result(
        result_payload("command-1", errorCode=["ab", "你", "cdef", "tail"])
    )
    empty_codes = bridge.normalize_result(
        result_payload("command-2", errorCode=[""] * 20)
    )

    assert normalized is not None
    assert normalized["errorCode"] == ["ab", "你", "cd"]
    assert sum(len(item.encode("utf-8")) for item in normalized["errorCode"]) <= 7
    assert empty_codes is not None
    assert empty_codes["errorCode"] == [""] * 7


def test_normalize_result_utf8_truncates_one_oversized_error_code_item(monkeypatch):
    monkeypatch.setattr(bridge, "FIELD_LIMIT_BYTES", 7)

    normalized = bridge.normalize_result(
        result_payload("command-1", errorCode=["你你你", "tail"])
    )

    assert normalized is not None
    assert normalized["errorCode"] == ["你你"]
    assert len(normalized["errorCode"][0].encode("utf-8")) == 6


def test_internal_result_safely_completes_an_unencodable_json_string(client):
    command_id = queue_and_claim(client)

    response = client.post(
        "/internal/result",
        headers=capture_headers(),
        content=json.dumps(result_payload(command_id, errorInfo="\ud800", errorCode=["\ud800"])).encode(),
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_RESULT"
    assert response.json()["id"] == command_id
    assert response.json()["state"] == "completed"
    assert bridge.bridge.active is None
    assert bridge.bridge.completed[command_id]["errorInfo"] == (
        "Invalid internal result payload: errorInfo:invalid_utf8"
    )


def test_nonzero_return_code_is_not_ok_and_preserves_error_details(client):
    command_id = queue_and_claim(client)
    response = client.post(
        "/internal/result",
        headers=capture_headers(),
        json=result_payload(
            command_id,
            returnCode=1,
            errorInfo="error details",
            errorCode=["TCL", "7"],
            errorLine=12,
            stderr="bad",
        ),
    )

    assert response.status_code == 200
    result = client.get(f"/v1/commands/{command_id}", headers=bridge_headers()).json()
    assert result["ok"] is False
    assert result["errorInfo"] == "error details"
    assert result["errorCode"] == ["TCL", "7"]
    assert result["errorLine"] == 12
    assert result["stderr"] == "bad"


def test_command_lookup_distinguishes_active_completed_and_missing_commands(client):
    command_id = queue_and_claim(client)
    active = client.get(f"/v1/commands/{command_id}", headers=bridge_headers())
    assert active.json() == {"id": command_id, "state": "executing"}

    client.post("/internal/result", headers=capture_headers(), json=result_payload(command_id))
    completed = client.get(f"/v1/commands/{command_id}", headers=bridge_headers())
    missing = client.get("/v1/commands/missing", headers=bridge_headers())

    assert completed.status_code == 200
    assert completed.json()["state"] == "completed"
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "COMMAND_NOT_FOUND"


def test_completed_history_keeps_only_the_most_recent_100_results():
    state = bridge.BridgeState(token="token", capture_pid=1)

    for index in range(101):
        state.store_completed({"id": str(index), "nested": {"index": index}})

    assert list(state.completed) == [str(index) for index in range(1, 101)]
    original = {"id": "new", "nested": {"value": "before"}}
    state.store_completed(original)
    original["nested"]["value"] = "after"
    assert state.completed["new"]["nested"]["value"] == "before"
    assert len(state.completed) == bridge.RESULT_HISTORY_LIMIT


def test_internal_result_requires_capture_pid(client):
    response = client.post("/internal/result", headers=capture_headers(pid=99), json=result_payload("command-1"))

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "CAPTURE_PID_MISMATCH"


def test_write_runtime_descriptor_is_atomic_and_contains_the_runtime_identity(tmp_path, monkeypatch):
    descriptor = tmp_path / "runtime" / "bridge.json"
    replaced = []
    original_replace = bridge.os.replace

    def checked_replace(source, destination):
        source_path = Path(source)
        replaced.append((source_path, Path(destination)))
        assert source_path.exists()
        original_replace(source, destination)

    monkeypatch.setattr(bridge.os, "replace", checked_replace)
    monkeypatch.setattr(bridge.os, "getpid", lambda: 9876)

    bridge.write_runtime_descriptor(descriptor, "secret", 4321, 8767)

    assert len(replaced) == 1
    assert replaced[0][0].parent == descriptor.parent
    assert replaced[0][0] != descriptor.with_suffix(".json.tmp")
    assert replaced[0][1] == descriptor
    assert json.loads(descriptor.read_text(encoding="utf-8")) == {
        "service": "capture-tcl-bridge",
        "protocolVersion": 1,
        "baseUrl": "http://127.0.0.1:8767",
        "token": "secret",
        "capturePid": 4321,
        "serverPid": 9876,
    }
    assert not list(descriptor.parent.glob(f".{descriptor.name}.*.tmp"))


def test_write_runtime_descriptor_removes_temporary_file_when_replace_fails(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    fixed_temporary = descriptor.with_suffix(".json.tmp")
    fixed_temporary.write_text("do not touch", encoding="utf-8")
    temporary_paths = []

    def blocked_replace(source, _destination):
        temporary_paths.append(Path(source))
        if os.name != "nt":
            assert Path(source).stat().st_mode & 0o777 == 0o600
        raise OSError("blocked")

    monkeypatch.setattr(bridge.os, "replace", blocked_replace)

    with pytest.raises(OSError, match="blocked"):
        bridge.write_runtime_descriptor(descriptor, "secret", 4321, 8767)

    assert not descriptor.exists()
    assert fixed_temporary.read_text(encoding="utf-8") == "do not touch"
    assert len(temporary_paths) == 1
    assert not temporary_paths[0].exists()


def test_concurrent_runtime_descriptor_writers_publish_complete_json_without_leftover_temps(tmp_path):
    descriptor = tmp_path / "bridge.json"
    start = threading.Barrier(3)
    failures = []

    def write(token):
        try:
            start.wait()
            bridge.write_runtime_descriptor(descriptor, token, 4321, 8767)
        except Exception as error:
            failures.append(error)

    first = threading.Thread(target=write, args=("first",))
    second = threading.Thread(target=write, args=("second",))
    first.start()
    second.start()
    start.wait()
    first.join(timeout=2)
    second.join(timeout=2)

    assert failures == []
    assert not first.is_alive()
    assert not second.is_alive()
    assert json.loads(descriptor.read_text(encoding="utf-8"))["token"] in {"first", "second"}
    assert not list(descriptor.parent.glob(f".{descriptor.name}.*.tmp"))


@pytest.mark.skipif(os.name == "nt", reason="Windows relies on the current-user temporary-file ACL")
def test_runtime_descriptor_and_lock_files_are_private_on_posix(tmp_path):
    descriptor = tmp_path / "bridge.json"

    bridge.write_runtime_descriptor(descriptor, "secret", 4321, 8767)

    assert descriptor.stat().st_mode & 0o777 == 0o600
    assert descriptor.with_suffix(".json.lock").stat().st_mode & 0o777 == 0o600


def test_runtime_descriptor_write_does_not_touch_a_preexisting_fixed_temporary_symlink(tmp_path):
    descriptor = tmp_path / "bridge.json"
    fixed_temporary = descriptor.with_suffix(".json.tmp")
    target = tmp_path / "sentinel.txt"
    target.write_text("do not touch", encoding="utf-8")
    try:
        fixed_temporary.symlink_to(target)
    except OSError:
        pytest.skip("symlink creation is unavailable for this test process")

    bridge.write_runtime_descriptor(descriptor, "secret", 4321, 8767)

    assert fixed_temporary.is_symlink()
    assert target.read_text(encoding="utf-8") == "do not touch"


def test_old_remove_cannot_delete_a_newer_descriptor_while_write_is_locked(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": 100}), encoding="utf-8")
    original_read_text = Path.read_text
    old_read_complete = threading.Event()
    allow_remove = threading.Event()
    writer_finished = threading.Event()
    monkeypatch.setattr(bridge.os, "getpid", lambda: 200)

    def paused_read(path, **kwargs):
        content = original_read_text(path, **kwargs)
        if path == descriptor:
            old_read_complete.set()
            assert allow_remove.wait(timeout=2)
        return content

    monkeypatch.setattr(Path, "read_text", paused_read)
    remover = threading.Thread(target=bridge.remove_runtime_descriptor, args=(descriptor, 100))
    writer = threading.Thread(
        target=lambda: (bridge.write_runtime_descriptor(descriptor, "new", 4321, 8767), writer_finished.set())
    )
    remover.start()
    try:
        assert old_read_complete.wait(timeout=2)
        writer.start()
        assert not writer_finished.wait(timeout=0.1)
    finally:
        allow_remove.set()
    remover.join(timeout=2)
    writer.join(timeout=2)

    assert not remover.is_alive()
    assert not writer.is_alive()
    assert json.loads(original_read_text(descriptor, encoding="utf-8"))["serverPid"] == 200


def test_remove_runtime_descriptor_only_deletes_matching_server_process(tmp_path):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": 100}), encoding="utf-8")

    bridge.remove_runtime_descriptor(descriptor, 101)
    assert descriptor.exists()

    bridge.remove_runtime_descriptor(descriptor, 100.0)
    assert descriptor.exists()

    bridge.remove_runtime_descriptor(descriptor, 100)
    assert not descriptor.exists()


@pytest.mark.parametrize("contents", ["{", "[]"])
def test_remove_runtime_descriptor_safely_ignores_invalid_descriptors(tmp_path, contents):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(contents, encoding="utf-8")

    bridge.remove_runtime_descriptor(descriptor, 100)

    assert descriptor.exists()


def test_remove_runtime_descriptor_safely_ignores_a_missing_path(tmp_path):
    bridge.remove_runtime_descriptor(tmp_path / "missing.json", 100)


def test_remove_runtime_descriptor_safely_ignores_read_errors(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"

    def read_failure(_path, **_kwargs):
        raise OSError("not readable")

    monkeypatch.setattr(Path, "read_text", read_failure)

    bridge.remove_runtime_descriptor(descriptor, 100)


def test_remove_runtime_descriptor_safely_ignores_unlink_errors(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": 100}), encoding="utf-8")

    def unlink_failure(_path, **_kwargs):
        raise OSError("not removable")

    monkeypatch.setattr(Path, "unlink", unlink_failure)

    bridge.remove_runtime_descriptor(descriptor, 100)

    assert descriptor.exists()


def test_remove_runtime_descriptor_safely_ignores_lock_errors(tmp_path, monkeypatch):
    @contextmanager
    def broken_lock(_path):
        raise TimeoutError("lock timed out")
        yield

    monkeypatch.setattr(bridge, "runtime_descriptor_lock", broken_lock)

    bridge.remove_runtime_descriptor(tmp_path / "bridge.json", 100)


def test_internal_shutdown_requires_capture_identity_and_requests_graceful_exit(
    client, tmp_path, monkeypatch
):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": os.getpid()}), encoding="utf-8")
    monkeypatch.setattr(bridge, "RUNTIME_FILE", descriptor)
    server = type("Server", (), {"should_exit": False})()
    monkeypatch.setattr(bridge, "ACTIVE_SERVER", server)

    missing_token = client.post("/internal/shutdown")
    wrong_token = client.post(
        "/internal/shutdown",
        headers={"Authorization": "Bearer incorrect-token", "X-Capture-Pid": "4242"},
    )
    wrong_pid = client.post("/internal/shutdown", headers=capture_headers(pid=99))

    assert missing_token.status_code == 401
    assert wrong_token.status_code == 401
    assert wrong_pid.status_code == 409
    assert descriptor.exists()
    assert server.should_exit is False

    accepted = client.post("/internal/shutdown", headers=capture_headers())

    assert accepted.status_code == 200
    assert accepted.json() == {"ok": True}
    assert descriptor.exists()
    assert server.should_exit is True


def test_shutdown_defers_graceful_exit_until_its_response_background_runs(tmp_path, monkeypatch):
    bridge.reset_bridge_state()
    descriptor = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "RUNTIME_FILE", descriptor)
    server = type("Server", (), {"should_exit": False})()
    monkeypatch.setattr(bridge, "ACTIVE_SERVER", server)
    request = Request(
        {
            "type": "http",
            "headers": [(b"authorization", b"Bearer test-token"), (b"x-capture-pid", b"4242")],
        }
    )

    response = asyncio.run(bridge.shutdown(request))

    assert response.background is not None
    assert server.should_exit is False
    asyncio.run(response.background())
    assert server.should_exit is True


def test_shutdown_rejection_does_not_set_a_background_task(monkeypatch):
    server = type("Server", (), {"should_exit": False})()
    monkeypatch.setattr(bridge, "ACTIVE_SERVER", server)
    request = Request({"type": "http", "headers": []})

    response = asyncio.run(bridge.shutdown(request))

    assert response.status_code == 401
    assert response.background is None
    assert server.should_exit is False


def test_shutdown_never_cleans_descriptor_before_server_run_returns(tmp_path, monkeypatch):
    bridge.reset_bridge_state()
    descriptor = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "RUNTIME_FILE", descriptor)
    monkeypatch.setattr(
        bridge,
        "remove_runtime_descriptor",
        lambda *_args: (_ for _ in ()).throw(OSError("cleanup failed")),
    )
    server = type("Server", (), {"should_exit": False})()
    monkeypatch.setattr(bridge, "ACTIVE_SERVER", server)
    request = Request(
        {"type": "http", "headers": [(b"authorization", b"Bearer test-token"), (b"x-capture-pid", b"4242")]}
    )

    response = asyncio.run(bridge.shutdown(request))
    asyncio.run(response.background())

    assert server.should_exit is True
    assert descriptor.exists() is False


class FakeWindowsCall:
    def __init__(self, result):
        self.result = result
        self.calls = []
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        self.calls.append(args)
        return self.result


def test_load_kernel32_configures_process_api_signatures(monkeypatch):
    kernel32 = type("Kernel32", (), {})()
    kernel32.OpenProcess = FakeWindowsCall(1)
    kernel32.WaitForSingleObject = FakeWindowsCall(1)
    kernel32.CloseHandle = FakeWindowsCall(1)
    calls = []
    monkeypatch.setattr(
        bridge.ctypes,
        "WinDLL",
        lambda *args, **kwargs: calls.append((args, kwargs)) or kernel32,
    )

    assert bridge.load_kernel32() is kernel32
    assert calls == [(('kernel32',), {"use_last_error": True})]
    assert kernel32.OpenProcess.argtypes == [
        bridge.wintypes.DWORD,
        bridge.wintypes.BOOL,
        bridge.wintypes.DWORD,
    ]
    assert kernel32.OpenProcess.restype == bridge.wintypes.HANDLE
    assert kernel32.WaitForSingleObject.argtypes == [bridge.wintypes.HANDLE, bridge.wintypes.DWORD]
    assert kernel32.WaitForSingleObject.restype == bridge.wintypes.DWORD
    assert kernel32.CloseHandle.argtypes == [bridge.wintypes.HANDLE]
    assert kernel32.CloseHandle.restype == bridge.wintypes.BOOL


def test_process_is_alive_uses_windows_wait_probe_and_closes_handle(monkeypatch):
    kernel32 = type("Kernel32", (), {})()
    kernel32.OpenProcess = FakeWindowsCall(55)
    kernel32.WaitForSingleObject = FakeWindowsCall(0x102)
    kernel32.CloseHandle = FakeWindowsCall(1)
    monkeypatch.setattr(bridge.os, "name", "nt")
    monkeypatch.setattr(bridge, "load_kernel32", lambda: kernel32)

    assert bridge.process_is_alive(123) is True
    assert kernel32.OpenProcess.calls == [(0x00100000, False, 123)]
    assert kernel32.WaitForSingleObject.calls == [(55, 0)]
    assert kernel32.CloseHandle.calls == [(55,)]


def test_process_is_alive_reports_windows_dead_and_unopenable_processes(monkeypatch):
    kernel32 = type("Kernel32", (), {})()
    kernel32.OpenProcess = FakeWindowsCall(55)
    kernel32.WaitForSingleObject = FakeWindowsCall(0)
    kernel32.CloseHandle = FakeWindowsCall(1)
    monkeypatch.setattr(bridge.os, "name", "nt")
    monkeypatch.setattr(bridge, "load_kernel32", lambda: kernel32)
    assert bridge.process_is_alive(123) is False
    assert kernel32.CloseHandle.calls == [(55,)]

    kernel32.OpenProcess = FakeWindowsCall(0)
    assert bridge.process_is_alive(123) is False
    assert bridge.process_is_alive(0) is False


def test_process_is_alive_closes_windows_handle_when_wait_raises(monkeypatch):
    kernel32 = type("Kernel32", (), {})()
    kernel32.OpenProcess = FakeWindowsCall(55)

    def wait_failure(*_args):
        raise RuntimeError("wait failed")

    kernel32.WaitForSingleObject = wait_failure
    kernel32.CloseHandle = FakeWindowsCall(1)
    monkeypatch.setattr(bridge.os, "name", "nt")
    monkeypatch.setattr(bridge, "load_kernel32", lambda: kernel32)

    with pytest.raises(RuntimeError, match="wait failed"):
        bridge.process_is_alive(123)

    assert kernel32.CloseHandle.calls == [(55,)]


def test_process_is_alive_uses_posix_kill_semantics(monkeypatch):
    monkeypatch.setattr(bridge.os, "name", "posix")
    calls = []
    monkeypatch.setattr(bridge.os, "kill", lambda pid, signal: calls.append((pid, signal)))
    assert bridge.process_is_alive(123) is True
    assert calls == [(123, 0)]

    monkeypatch.setattr(bridge.os, "kill", lambda *_args: (_ for _ in ()).throw(PermissionError()))
    assert bridge.process_is_alive(123) is True
    monkeypatch.setattr(bridge.os, "kill", lambda *_args: (_ for _ in ()).throw(OSError()))
    assert bridge.process_is_alive(123) is False


def test_process_is_alive_safely_rejects_overflowing_posix_pid(monkeypatch):
    monkeypatch.setattr(bridge.os, "name", "posix")
    monkeypatch.setattr(bridge.os, "kill", lambda *_args: (_ for _ in ()).throw(OverflowError()))

    assert bridge.process_is_alive(2**100) is False


def test_watch_parent_process_requests_graceful_exit_when_parent_disappears(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": os.getpid()}), encoding="utf-8")
    states = iter([True, False])
    monkeypatch.setattr(bridge, "process_is_alive", lambda _pid: next(states))
    monkeypatch.setattr(bridge.time, "sleep", lambda _interval: None)

    server = type("Server", (), {"should_exit": False})()
    bridge.watch_parent_process(123, descriptor, interval=0, server=server)
    assert server.should_exit is True
    assert descriptor.exists()


def test_watch_parent_process_fails_closed_when_the_probe_raises(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    descriptor.write_text(json.dumps({"serverPid": os.getpid()}), encoding="utf-8")
    monkeypatch.setattr(bridge, "process_is_alive", lambda _pid: (_ for _ in ()).throw(OSError("probe failed")))

    server = type("Server", (), {"should_exit": False})()
    bridge.watch_parent_process(123, descriptor, server=server)
    assert server.should_exit is True
    assert descriptor.exists()


def test_watch_parent_process_does_not_cleanup_descriptor_it_does_not_own(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "process_is_alive", lambda _pid: False)
    monkeypatch.setattr(
        bridge,
        "remove_runtime_descriptor",
        lambda *_args: (_ for _ in ()).throw(OSError("cleanup failed")),
    )

    server = type("Server", (), {"should_exit": False})()
    bridge.watch_parent_process(123, descriptor, server=server)
    assert server.should_exit is True


def test_watch_parent_process_keeps_launch_control_until_main_ack(tmp_path, monkeypatch):
    descriptor = tmp_path / "bridge.json"
    cancel_file = tmp_path / "capture_tcl_bridge_cancel_parent.marker"
    cancel_file.write_bytes(b"run\n")
    monkeypatch.setattr(bridge, "process_is_alive", lambda _pid: False)

    server = type("Server", (), {"should_exit": False})()
    bridge.watch_parent_process(123, descriptor, cancel_file=cancel_file, server=server)
    assert server.should_exit is True
    assert cancel_file.exists()


def test_start_parent_watchdog_creates_named_daemon_thread_for_positive_pid(monkeypatch, tmp_path):
    created = []

    class FakeThread:
        def __init__(self, **kwargs):
            self.kwargs = kwargs
            self.daemon = False
            created.append(self)

        def start(self):
            self.started = True

    monkeypatch.setattr(bridge.threading, "Thread", FakeThread)
    runtime_file = tmp_path / "bridge.json"

    assert bridge.start_parent_watchdog(0, runtime_file) is None
    worker = bridge.start_parent_watchdog(123, runtime_file)

    assert worker is created[0]
    assert worker.kwargs == {
        "target": bridge.watch_parent_process,
        "args": (123, runtime_file),
        "name": "capture-bridge-parent-watchdog",
    }
    assert worker.daemon is True
    assert worker.started is True


def test_server_has_no_forced_process_exit_helper():
    assert not hasattr(bridge, "schedule_process_exit")


@pytest.mark.parametrize(
    "arguments",
    [
        ["--host", "0.0.0.0", "--parent-pid", "1", "--runtime-file", "bridge.json"],
        ["--parent-pid", "0", "--runtime-file", "bridge.json"],
    ],
)
def test_main_rejects_non_local_host_and_non_positive_parent_pid(arguments):
    with pytest.raises(SystemExit) as error:
        bridge.main(arguments)

    assert error.value.code == 2


def test_main_binds_before_writing_descriptor_and_passes_bound_socket_to_uvicorn(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    written = []
    tokens = []
    reset_calls = []
    server_runs = []
    cleanup_callbacks = []

    monkeypatch.setattr(bridge.secrets, "token_urlsafe", lambda length: tokens.append(length) or "random-token")
    monkeypatch.setattr(bridge, "reset_bridge_state", lambda token, capture_pid: reset_calls.append((token, capture_pid)))
    original_write = bridge.write_runtime_descriptor

    def recording_write(*args):
        written.append(args)
        original_write(*args)

    monkeypatch.setattr(bridge, "write_runtime_descriptor", recording_write)
    watchdog_calls = []
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *args: watchdog_calls.append(args))
    monkeypatch.setattr(
        bridge.atexit,
        "register",
        lambda callback, *args: cleanup_callbacks.append((callback, args)),
    )

    class FakeConfig:
        def __init__(self, app, host, port):
            self.app = app
            self.host = host
            self.port = port

    class FakeServer:
        def __init__(self, config):
            self.config = config

        def run(self, *, sockets):
            server_runs.append((self.config, sockets[0].getsockname()))
            assert runtime_file.exists()

    monkeypatch.setattr(bridge.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(bridge.uvicorn, "Server", FakeServer)

    bridge.main(server_main_args(runtime_file, "--port", "0"))

    assert tokens == [32]
    assert reset_calls == [("random-token", 123)]
    assert written[0][0] == runtime_file
    assert written[0][1:3] == ("random-token", 123)
    assert server_runs[0][0].host == "127.0.0.1"
    assert server_runs[0][0].port == 0
    assert server_runs[0][1][0] == "127.0.0.1"
    assert not runtime_file.exists()
    assert bridge.RUNTIME_FILE is None
    assert len(cleanup_callbacks) == 1
    assert len(watchdog_calls) == 1
    assert watchdog_calls[0][:3] == (
        123,
        runtime_file,
        runtime_file.with_name("capture_tcl_bridge_launch_test.cancel"),
    )
    assert watchdog_calls[0][3] is not None


def test_main_does_not_write_descriptor_when_port_is_already_bound(tmp_path):
    runtime_file = tmp_path / "bridge.json"
    launch_file = tmp_path / "capture_tcl_bridge_launch_test"
    cancel_file = Path(f"{launch_file}.cancel")
    ack_file = Path(f"{launch_file}.stopped")
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    try:
        port = listener.getsockname()[1]
        with pytest.raises(OSError):
            bridge.main(server_main_args(runtime_file, "--port", str(port)))
    finally:
        listener.close()

    assert not runtime_file.exists()
    assert not launch_file.exists()
    assert not cancel_file.exists()
    assert ack_file.read_bytes() == b"stopped test-nonce\n"


def test_main_removes_descriptor_before_closing_socket_on_normal_return(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    events = []
    original_remove = bridge.remove_runtime_descriptor
    original_write_ack = bridge.write_stopped_ack
    monkeypatch.setattr(bridge.secrets, "token_urlsafe", lambda _length: "random-token")
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *_args: None)
    monkeypatch.setattr(bridge.atexit, "register", lambda *_args: None)

    def recording_remove(*args):
        events.append("remove")
        original_remove(*args)

    monkeypatch.setattr(bridge, "remove_runtime_descriptor", recording_remove)

    def recording_write_ack(path, nonce):
        events.append("ack")
        original_write_ack(path, nonce)

    monkeypatch.setattr(bridge, "write_stopped_ack", recording_write_ack)

    class FakeSocket:
        def bind(self, _address):
            pass

        def listen(self):
            pass

        def getsockname(self):
            return ("127.0.0.1", 8767)

        def close(self):
            assert bridge.RUNTIME_FILE is None
            events.append("close")

    sock = FakeSocket()
    monkeypatch.setattr(bridge.socket, "socket", lambda *_args: sock)

    class FakeConfig:
        def __init__(self, *_args, **_kwargs):
            pass

    class FakeServer:
        def __init__(self, _config):
            pass

        def run(self, *, sockets):
            assert sockets == [sock]
            events.append("run_return")

    monkeypatch.setattr(bridge.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(bridge.uvicorn, "Server", FakeServer)

    bridge.main(server_main_args(runtime_file))

    assert events == ["run_return", "remove", "close", "ack"]
    assert not runtime_file.exists()


def test_main_cleans_runtime_state_when_uvicorn_run_raises(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    events = []
    monkeypatch.setattr(bridge, "RUNTIME_FILE", None)
    monkeypatch.setattr(bridge.secrets, "token_urlsafe", lambda _length: "random-token")
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *_args: None)
    monkeypatch.setattr(bridge.atexit, "register", lambda *_args: None)
    original_remove = bridge.remove_runtime_descriptor

    def recording_remove(*args):
        events.append("remove")
        original_remove(*args)

    monkeypatch.setattr(bridge, "remove_runtime_descriptor", recording_remove)

    class FakeSocket:
        def __init__(self):
            self.bound_to = None
            self.listened = False
            self.closed = False

        def bind(self, address):
            self.bound_to = address

        def listen(self):
            self.listened = True

        def getsockname(self):
            return ("127.0.0.1", 8767)

        def close(self):
            assert bridge.RUNTIME_FILE is None
            self.closed = True
            events.append("close")

    sock = FakeSocket()
    monkeypatch.setattr(bridge.socket, "socket", lambda *_args: sock)

    class FakeConfig:
        def __init__(self, *_args, **_kwargs):
            pass

    class FakeServer:
        def __init__(self, _config):
            pass

        def run(self, *, sockets):
            assert sockets == [sock]
            assert runtime_file.exists()
            raise RuntimeError("uvicorn failed")

    monkeypatch.setattr(bridge.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(bridge.uvicorn, "Server", FakeServer)

    with pytest.raises(RuntimeError, match="uvicorn failed"):
        bridge.main(server_main_args(runtime_file))

    assert sock.bound_to == ("127.0.0.1", bridge.DEFAULT_PORT)
    assert sock.listened is True
    assert sock.closed is True
    assert not runtime_file.exists()
    assert bridge.RUNTIME_FILE is None
    assert events == ["remove", "close"]


def test_main_resets_state_and_closes_socket_when_descriptor_cleanup_fails(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "RUNTIME_FILE", None)
    monkeypatch.setattr(bridge.secrets, "token_urlsafe", lambda _length: "random-token")
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *_args: None)
    monkeypatch.setattr(bridge.atexit, "register", lambda *_args: None)
    monkeypatch.setattr(
        bridge,
        "remove_runtime_descriptor",
        lambda *_args: (_ for _ in ()).throw(OSError("cleanup failed")),
    )

    class FakeSocket:
        def bind(self, _address):
            pass

        def listen(self):
            pass

        def getsockname(self):
            return ("127.0.0.1", 8767)

        def close(self):
            self.closed = True

    sock = FakeSocket()
    monkeypatch.setattr(bridge.socket, "socket", lambda *_args: sock)

    class FakeConfig:
        def __init__(self, *_args, **_kwargs):
            pass

    class FakeServer:
        def __init__(self, _config):
            pass

        def run(self, *, sockets):
            assert sockets == [sock]

    monkeypatch.setattr(bridge.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(bridge.uvicorn, "Server", FakeServer)

    bridge.main(server_main_args(runtime_file))

    assert sock.closed is True
    assert bridge.RUNTIME_FILE is None


def test_main_cleans_socket_and_state_when_descriptor_write_fails(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    monkeypatch.setattr(bridge, "RUNTIME_FILE", None)
    monkeypatch.setattr(bridge.secrets, "token_urlsafe", lambda _length: "random-token")
    monkeypatch.setattr(bridge, "write_runtime_descriptor", lambda *_args: (_ for _ in ()).throw(OSError("write failed")))
    watchdog_calls = []
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *args: watchdog_calls.append(args))

    class FakeSocket:
        def __init__(self):
            self.closed = False

        def bind(self, _address):
            pass

        def listen(self):
            pass

        def getsockname(self):
            return ("127.0.0.1", 8767)

        def close(self):
            self.closed = True

    sock = FakeSocket()
    monkeypatch.setattr(bridge.socket, "socket", lambda *_args: sock)

    with pytest.raises(OSError, match="write failed"):
        bridge.main(server_main_args(runtime_file))

    assert sock.closed is True
    assert bridge.RUNTIME_FILE is None
    assert watchdog_calls == []


def test_cancel_request_present_before_start_skips_socket_and_writes_ack(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    launch_file, cancel_file, ack_file = server_signal_paths(runtime_file)
    cancel_file.write_bytes(b"cancel test-nonce\n")

    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("cancelled launch must not create a socket"),
    )

    bridge.main(args)

    assert not runtime_file.exists()
    assert not launch_file.exists()
    assert not cancel_file.exists()
    assert ack_file.read_bytes() == b"stopped test-nonce\n"


def test_cancel_watcher_requests_graceful_server_exit(tmp_path):
    launch_file = tmp_path / "capture_tcl_bridge_launch_running"
    cancel_file = Path(f"{launch_file}.cancel")
    launch_file.write_bytes(b"launch nonce-123\n")
    cancel_file.write_bytes(b"cancel nonce-123\n")

    class FakeServer:
        should_exit = False

    server = FakeServer()
    bridge.watch_launch_signals(launch_file, cancel_file, "nonce-123", server, interval=0)

    assert server.should_exit is True


def test_launch_watcher_treats_missing_launch_as_exit(tmp_path):
    launch_file = tmp_path / "capture_tcl_bridge_launch_missing"
    cancel_file = Path(f"{launch_file}.cancel")

    class FakeServer:
        should_exit = False

    server = FakeServer()
    bridge.watch_launch_signals(launch_file, cancel_file, "nonce-123", server, interval=0)
    assert server.should_exit is True


def test_launch_watcher_treats_invalid_cancel_request_as_exit(tmp_path):
    launch_file = tmp_path / "capture_tcl_bridge_launch_invalid_runtime"
    cancel_file = Path(f"{launch_file}.cancel")
    launch_file.write_bytes(b"launch nonce-123\n")
    cancel_file.write_bytes(b"invalid\n")

    class FakeServer:
        should_exit = False

    server = FakeServer()
    bridge.watch_launch_signals(launch_file, cancel_file, "nonce-123", server, interval=0)
    assert server.should_exit is True


@pytest.mark.parametrize("contents", [b"", b"launch", b"invalid\n", b"x" * 65])
def test_main_rejects_invalid_launch_control_before_binding(tmp_path, monkeypatch, contents):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    launch_file, _cancel_file, _ack_file = server_signal_paths(runtime_file)
    launch_file.write_bytes(contents)
    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("invalid control must be rejected before binding"),
    )
    with pytest.raises(SystemExit):
        bridge.main(args)


def test_main_rejects_missing_launch_control_before_binding(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    launch_file, _cancel_file, _ack_file = server_signal_paths(runtime_file)
    launch_file.unlink()
    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("missing control must be rejected before binding"),
    )
    with pytest.raises(SystemExit):
        bridge.main(args)


def test_main_rejects_symlink_launch_control_before_binding(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    launch_file, _cancel_file, _ack_file = server_signal_paths(runtime_file)
    launch_file.unlink()
    target = tmp_path / "target.launch"
    target.write_bytes(b"launch test-nonce\n")
    try:
        launch_file.symlink_to(target)
    except OSError:
        pytest.skip("symlink creation is unavailable")
    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("symlink control must be rejected before binding"),
    )
    with pytest.raises(SystemExit):
        bridge.main(args)


def test_main_rejects_dangling_ack_symlink_before_binding(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    _launch_file, _cancel_file, ack_file = server_signal_paths(runtime_file)
    try:
        ack_file.symlink_to(tmp_path / "missing-target")
    except OSError:
        pytest.skip("symlink creation is unavailable")
    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("pre-existing ack path must be rejected before binding"),
    )
    with pytest.raises(SystemExit):
        bridge.main(args)


def test_main_running_cancel_cleans_descriptor_and_writes_stopped_ack(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file, "--port", "0")
    launch_file, cancel_file, ack_file = server_signal_paths(runtime_file)
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *_args: None)
    monkeypatch.setattr(bridge.atexit, "register", lambda *_args: None)

    class FakeConfig:
        def __init__(self, *_args, **_kwargs):
            pass

    class FakeServer:
        def __init__(self, _config):
            self.should_exit = False

        def run(self, *, sockets):
            assert runtime_file.exists()
            cancel_file.write_bytes(b"cancel test-nonce\n")
            bridge.watch_launch_signals(
                launch_file, cancel_file, "test-nonce", self, interval=0
            )
            assert self.should_exit is True

    monkeypatch.setattr(bridge.uvicorn, "Config", FakeConfig)
    monkeypatch.setattr(bridge.uvicorn, "Server", FakeServer)

    bridge.main(args)

    assert not runtime_file.exists()
    assert not launch_file.exists()
    assert not cancel_file.exists()
    assert ack_file.read_bytes() == b"stopped test-nonce\n"


def test_stopped_ack_is_exclusive_and_contains_launch_nonce(tmp_path):
    ack_file = tmp_path / "capture_tcl_bridge_launch_test.stopped"

    bridge.write_stopped_ack(ack_file, "nonce-123")

    assert ack_file.read_bytes() == b"stopped nonce-123\n"
    with pytest.raises(FileExistsError):
        bridge.write_stopped_ack(ack_file, "nonce-123")


def test_launch_claim_is_exclusive_and_contains_launch_nonce(tmp_path):
    claim_file = tmp_path / "capture_tcl_bridge_launch_test.claimed"

    bridge.write_launch_claim(claim_file, "nonce-123")

    assert claim_file.read_bytes() == b"claimed nonce-123\n"
    with pytest.raises(FileExistsError):
        bridge.write_launch_claim(claim_file, "nonce-123")


@pytest.mark.parametrize("failure", ["short-write", "write", "fsync", "close"])
def test_launch_claim_failure_removes_partially_created_file(tmp_path, monkeypatch, failure):
    claim_file = tmp_path / "capture_tcl_bridge_launch_failed.claimed"
    if failure == "short-write":
        monkeypatch.setattr(bridge.os, "write", lambda _fd, value: len(value) - 1)
    elif failure == "write":
        monkeypatch.setattr(
            bridge.os, "write", lambda *_args: (_ for _ in ()).throw(OSError("write failed"))
        )
    elif failure == "fsync":
        monkeypatch.setattr(
            bridge.os, "fsync", lambda *_args: (_ for _ in ()).throw(OSError("fsync failed"))
        )
    else:
        original_close = bridge.os.close
        def close_then_fail(descriptor):
            original_close(descriptor)
            raise OSError("close failed")
        monkeypatch.setattr(
            bridge.os, "close", close_then_fail
        )

    with pytest.raises(OSError):
        bridge.write_launch_claim(claim_file, "nonce-123")

    assert not claim_file.exists()


def test_launch_watchdog_exits_when_immutable_launch_file_disappears(tmp_path):
    launch_file = tmp_path / "capture_tcl_bridge_launch_test"
    cancel_file = tmp_path / "capture_tcl_bridge_launch_test.cancel"
    launch_file.write_bytes(b"launch nonce-123\n")

    class FakeServer:
        should_exit = False

    server = FakeServer()
    launch_file.unlink()
    bridge.watch_launch_signals(launch_file, cancel_file, "nonce-123", server, interval=0)

    assert server.should_exit is True


def test_documentation_and_openapi_routes_are_disabled(client):
    assert client.get("/docs").status_code == 404
    assert client.get("/redoc").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_execute_rejects_stream_body_over_limit_after_authentication(client, monkeypatch):
    monkeypatch.setattr(bridge, "EXECUTE_BODY_LIMIT_BYTES", 16)
    unauthorized = client.post("/v1/execute", content=b"x" * 17)
    assert unauthorized.status_code == 401
    response = client.post("/v1/execute", headers=bridge_headers(), content=b"{}" + b" " * 15)
    assert response.status_code == 413


def test_execute_rejects_immediately_while_server_is_shutting_down(client):
    with bridge.bridge.lock:
        bridge.bridge.shutting_down = True
    response = client.post("/v1/execute", headers=bridge_headers(), json={"script": "puts x"})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "SERVER_SHUTTING_DOWN"


def test_result_retry_for_completed_command_is_idempotent(client):
    payload = result_payload("already-completed")
    with bridge.bridge.lock:
        bridge.bridge.store_completed(payload)
    response = client.post(
        "/internal/result",
        headers=capture_headers(command_id="already-completed"),
        json=payload,
    )
    assert response.status_code == 200
    assert response.json() == {"id": "already-completed", "state": "completed"}


def test_result_declared_body_over_limit_safely_completes_active_command(
    client, monkeypatch
):
    monkeypatch.setattr(bridge, "RESULT_BODY_LIMIT_BYTES", 16)
    with bridge.bridge.lock:
        bridge.bridge.active = {
            "id": "oversized-result",
            "script": "puts x",
            "state": "executing",
        }

    response = client.post(
        "/internal/result",
        headers=capture_headers(),
        content=b"{" + b"x" * 16,
    )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    with bridge.bridge.lock:
        assert bridge.bridge.active is None
        assert bridge.bridge.completed["oversized-result"]["errorInfo"] == (
            "Invalid internal result payload: body:too_large"
        )


def test_result_chunked_body_over_limit_safely_completes_active_command(
    client, monkeypatch
):
    monkeypatch.setattr(bridge, "RESULT_BODY_LIMIT_BYTES", 16)
    with bridge.bridge.lock:
        bridge.bridge.active = {
            "id": "chunked-oversized-result",
            "script": "puts x",
            "state": "executing",
        }

    def body_chunks():
        yield b"{" + b"x" * 7
        yield b"y" * 9

    response = client.post(
        "/internal/result",
        headers={**capture_headers(), "Transfer-Encoding": "chunked"},
        content=body_chunks(),
    )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "REQUEST_TOO_LARGE"
    with bridge.bridge.lock:
        assert bridge.bridge.active is None
        assert bridge.bridge.completed["chunked-oversized-result"]["errorInfo"] == (
            "Invalid internal result payload: body:too_large"
        )


def test_revalidation_after_claim_prevents_bind_after_tcl_revocation(tmp_path, monkeypatch):
    runtime_file = tmp_path / "bridge.json"
    args = server_main_args(runtime_file)
    launch_file, cancel_file, ack_file = server_signal_paths(runtime_file)
    original_write_claim = bridge.write_launch_claim

    def revoke_then_claim(path, nonce):
        cancel_file.write_bytes(b"cancel test-nonce\n")
        launch_file.unlink()
        original_write_claim(path, nonce)

    monkeypatch.setattr(bridge, "write_launch_claim", revoke_then_claim)
    monkeypatch.setattr(
        bridge.socket,
        "socket",
        lambda *_args: pytest.fail("revoked launch must never reach bind"),
    )
    monkeypatch.setattr(bridge, "start_parent_watchdog", lambda *_args: None)

    bridge.main(args)

    assert not runtime_file.exists()
    assert ack_file.read_bytes() == b"stopped test-nonce\n"
