"""Real subprocess round trip for the Capture Tcl AI bridge."""

from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shlex
import subprocess
import sys
import threading
import time
from typing import Any
import urllib.parse
import urllib.error
import urllib.request

import pytest


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "capture_tcl_bridge_server.py"
CLI = ROOT / "capture_tcl_cli.py"
TCL_BRIDGE = ROOT / "captureAiBridge.tcl"
SCRIPT = "puts hello; expr {6 * 7}"
NONCE = "integration-test-nonce"
# The bridge sources need Tcl 8.6 (dict, lassign, {*}, try/finally). Where the
# interpreter on PATH is older, point CAPTURE_TCL_TCLSH at a suitable one. The
# value may carry leading arguments, but it must resolve to the process that
# actually runs Tcl: the server authenticates the Capture PID, so a wrapper
# script that spawns a child interpreter would report a PID the server rejects.
TCLSH = shlex.split(os.environ.get("CAPTURE_TCL_TCLSH", "tclsh"))


def _request_json(
    base_url: str,
    token: str,
    capture_pid: int,
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    *,
    command_id: str | None = None,
    timeout: float = 2.0,
) -> dict[str, Any]:
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Capture-Pid": str(capture_pid),
    }
    if command_id is not None:
        headers["X-Capture-Command-Id"] = command_id
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"{base_url}{path}", data=data, headers=headers, method=method
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        value = json.loads(response.read().decode("utf-8"))
    assert isinstance(value, dict)
    return value


def _post_invalid_result(
    base_url: str, token: str, capture_pid: int, command_id: str
) -> tuple[int, dict[str, Any]]:
    request = urllib.request.Request(
        f"{base_url}/internal/result",
        data=b"{",
        headers={
            "Authorization": f"Bearer {token}",
            "X-Capture-Pid": str(capture_pid),
            "X-Capture-Command-Id": command_id,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        value = json.loads(error.read().decode("utf-8"))
        assert isinstance(value, dict)
        return error.code, value


def _wait_for_descriptor(
    runtime_file: Path, server: subprocess.Popen[str], timeout: float = 5.0
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if server.poll() is not None:
            stdout, stderr = server.communicate()
            raise AssertionError(
                f"bridge server exited before publishing its descriptor\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        try:
            value = json.loads(runtime_file.read_text(encoding="utf-8"))
        except (FileNotFoundError, UnicodeError, json.JSONDecodeError):
            time.sleep(0.02)
            continue
        if isinstance(value, dict):
            return value
    raise AssertionError("bridge server did not publish its descriptor within five seconds")


def _fake_capture_worker(
    descriptor: dict[str, Any],
    capture_pid: int,
    connected: threading.Event,
    stop: threading.Event,
    failures: queue.Queue[Exception],
) -> None:
    try:
        base_url = descriptor["baseUrl"]
        token = descriptor["token"]
        deadline = time.monotonic() + 10.0
        while not stop.is_set() and time.monotonic() < deadline:
            command = _request_json(
                base_url, token, capture_pid, "GET", "/internal/command"
            )
            connected.set()
            if not command:
                time.sleep(0.02)
                continue
            if command["script"] == "invalid Capture result":
                status, invalid = _post_invalid_result(
                    base_url, token, capture_pid, command["id"]
                )
                assert status == 400
                assert invalid["id"] == command["id"]
                assert invalid["state"] == "completed"
                continue
            assert command["script"] == SCRIPT
            result = {
                "id": command["id"],
                "returnCode": 0,
                "result": "42",
                "stdout": "hello from Capture\n",
                "stderr": "",
                "errorInfo": "",
                "errorCode": [],
                "errorLine": None,
                "stdoutTruncated": False,
                "stderrTruncated": False,
                "resultTruncated": False,
            }
            response = _request_json(
                base_url,
                token,
                capture_pid,
                "POST",
                "/internal/result",
                result,
                command_id=command["id"],
            )
            assert response == {"id": command["id"], "state": "completed"}
            return
        raise AssertionError("fake Capture worker did not receive a command")
    except Exception as error:
        failures.put(error)
        connected.set()


def _stop_server(
    server: subprocess.Popen[str],
    descriptor: dict[str, Any] | None,
    capture_pid: int,
    cancel_file: Path,
) -> None:
    if server.poll() is not None:
        return
    if descriptor is not None:
        try:
            _request_json(
                descriptor["baseUrl"],
                descriptor["token"],
                capture_pid,
                "POST",
                "/internal/shutdown",
                {},
            )
        except Exception:
            pass
    try:
        server.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        cancel_file.write_bytes(f"cancel {NONCE}\n".encode("ascii"))
        server.wait(timeout=5)
        return
    except (OSError, subprocess.TimeoutExpired):
        pass
    server.terminate()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait(timeout=5)


def _assert_server_cleanup(
    server: Any,
    runtime_file: Path,
    launch_file: Path,
    claim_file: Path,
    cancel_file: Path,
    ack_file: Path,
) -> None:
    """Validate the server-owned cleanup before the test removes artifacts."""
    assert server.poll() is not None, "bridge server process is still running"
    for path in (runtime_file, launch_file, claim_file, cancel_file):
        assert not path.exists(), f"bridge server left {path.name} behind"
    assert ack_file.is_file(), "bridge server did not create its stopped acknowledgement"
    assert ack_file.read_bytes() == f"stopped {NONCE}\n".encode("ascii")


def test_real_server_fake_capture_and_real_cli_round_trip(tmp_path):
    capture_pid = os.getpid()
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    launch_file = tmp_path / "capture_tcl_bridge_launch_integration"
    claim_file = Path(f"{launch_file}.claimed")
    cancel_file = Path(f"{launch_file}.cancel")
    ack_file = Path(f"{launch_file}.stopped")
    lock_file = runtime_file.with_suffix(".json.lock")
    launch_file.write_bytes(f"launch {NONCE}\n".encode("ascii"))
    server = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            "0",
            "--parent-pid",
            str(capture_pid),
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
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    descriptor: dict[str, Any] | None = None
    worker: threading.Thread | None = None
    stop_worker = threading.Event()
    worker_failures: queue.Queue[Exception] = queue.Queue()
    cleanup_paths = (
        runtime_file,
        lock_file,
        launch_file,
        claim_file,
        cancel_file,
        ack_file,
    )
    try:
        descriptor = _wait_for_descriptor(runtime_file, server)
        parsed_base_url = urllib.parse.urlsplit(descriptor["baseUrl"])
        assert parsed_base_url.scheme == "http"
        assert parsed_base_url.hostname == "127.0.0.1"
        assert parsed_base_url.port is not None
        assert 0 < parsed_base_url.port <= 65535
        assert parsed_base_url.netloc == f"127.0.0.1:{parsed_base_url.port}"
        assert parsed_base_url.path == ""
        assert parsed_base_url.query == ""
        assert parsed_base_url.fragment == ""
        assert descriptor["capturePid"] == capture_pid
        connected = threading.Event()
        worker = threading.Thread(
            target=_fake_capture_worker,
            args=(
                descriptor,
                capture_pid,
                connected,
                stop_worker,
                worker_failures,
            ),
            daemon=True,
        )
        worker.start()
        assert connected.wait(timeout=5), "fake Capture worker did not connect"
        if not worker_failures.empty():
            raise worker_failures.get()

        invalid = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "--runtime-file",
                str(runtime_file),
                "-c",
                "invalid Capture result",
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
            check=False,
        )
        assert invalid.returncode == 1
        assert "Capture returned an invalid bridge result." in invalid.stderr

        completed = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "--runtime-file",
                str(runtime_file),
                "-c",
                SCRIPT,
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=10,
            check=False,
        )
        if worker is not None:
            worker.join(timeout=5)
        if not worker_failures.empty():
            raise worker_failures.get()
        assert completed.returncode == 0, completed.stderr
        assert completed.stdout == "hello from Capture\nResult: 42\n"
        assert completed.stderr == ""
    finally:
        stop_worker.set()
        try:
            if worker is not None:
                worker.join(timeout=2)
        finally:
            try:
                _stop_server(server, descriptor, capture_pid, cancel_file)
                server.communicate(timeout=2)
                _assert_server_cleanup(
                    server,
                    runtime_file,
                    launch_file,
                    claim_file,
                    cancel_file,
                    ack_file,
                )
            finally:
                try:
                    if server.poll() is None:
                        server.kill()
                        server.wait(timeout=5)
                finally:
                    for path in cleanup_paths:
                        path.unlink(missing_ok=True)

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for required in (
        "CaptureAiBridgeStart",
        "CaptureAiBridgeStatus",
        "CaptureAiBridgeStop",
    ):
        assert required in readme


def test_real_server_accepts_a_tcl_tick_result_post_with_its_command_id_header(tmp_path):
    ready_file = tmp_path / "tcl_result_sender_ready.tcl"
    bootstrap_file = tmp_path / "tcl_result_sender_bootstrap.tcl"
    ready_file.unlink(missing_ok=True)
    bootstrap_file.write_text(
        "set readyFile [lindex $argv 0]\n"
        "while {![file exists $readyFile]} { after 10 }\n"
        "source $readyFile\n",
        encoding="utf-8",
    )
    tcl_process = subprocess.Popen(
        [*TCLSH, str(bootstrap_file), str(ready_file)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    capture_pid = tcl_process.pid
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    launch_file = tmp_path / "capture_tcl_bridge_launch_tcl_result"
    claim_file = Path(f"{launch_file}.claimed")
    cancel_file = Path(f"{launch_file}.cancel")
    ack_file = Path(f"{launch_file}.stopped")
    lock_file = runtime_file.with_suffix(".json.lock")
    launch_file.write_bytes(f"launch {NONCE}\n".encode("ascii"))
    server = subprocess.Popen(
        [
            sys.executable,
            str(SERVER),
            "--host",
            "127.0.0.1",
            "--port",
            "0",
            "--parent-pid",
            str(capture_pid),
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
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    descriptor: dict[str, Any] | None = None
    execute_thread: threading.Thread | None = None
    execute_results: queue.Queue[dict[str, Any] | Exception] = queue.Queue()
    cleanup_paths = (
        runtime_file,
        lock_file,
        launch_file,
        claim_file,
        cancel_file,
        ack_file,
        ready_file,
        bootstrap_file,
    )
    try:
        descriptor = _wait_for_descriptor(runtime_file, server)
        assert tcl_process.poll() is None, "Tcl sender exited before receiving its result script"
        _request_json(descriptor["baseUrl"], descriptor["token"], capture_pid, "GET", "/internal/command")

        def execute_command() -> None:
            try:
                execute_results.put(
                    _request_json(
                        descriptor["baseUrl"],
                        descriptor["token"],
                        capture_pid,
                        "POST",
                        "/v1/execute",
                        {"script": "puts Tcl result"},
                        timeout=5,
                    )
                )
            except urllib.error.HTTPError as error:
                execute_results.put(RuntimeError(error.read().decode("utf-8")))
            except Exception as error:
                execute_results.put(error)

        execute_thread = threading.Thread(target=execute_command, daemon=True)
        execute_thread.start()
        deadline = time.monotonic() + 5
        command: dict[str, Any] = {}
        while time.monotonic() < deadline:
            command = _request_json(
                descriptor["baseUrl"], descriptor["token"], capture_pid, "GET", "/internal/command"
            )
            if command:
                break
            time.sleep(0.02)
        assert command, "real Tcl sender did not receive a command"

        result_payload = json.dumps(
            {
                "id": command["id"],
                "returnCode": 0,
                "result": "tcl-result",
                "stdout": "",
                "stderr": "",
                "errorInfo": "",
                "errorCode": [],
                "errorLine": None,
                "stdoutTruncated": False,
                "stderrTruncated": False,
                "resultTruncated": False,
            }
        )
        port = urllib.parse.urlsplit(descriptor["baseUrl"]).port
        assert port is not None
        ready_file.write_text(
            "package require http\n"
            "package require json\n"
            f"source {{{TCL_BRIDGE.as_posix()}}}\n"
            f"set ::CaptureAiBridgePort {port}\n"
            f"set ::CaptureAiBridgeBaseUrl {{{descriptor['baseUrl']}}}\n"
            f"set ::CaptureAiBridgeToken {{{descriptor['token']}}}\n"
            "set ::CaptureAiBridgeGeneration 1\n"
            "set ::CaptureAiBridgeActive 1\n"
            f"set ::CaptureAiBridgePendingResultId {{{command['id']}}}\n"
            f"set ::CaptureAiBridgePendingResultJson {{{result_payload}}}\n"
            "set ::CaptureAiBridgePendingResultGeneration 1\n"
            "_captureAiTick 1\n"
            "if {$::CaptureAiBridgePendingResultId ne {}} { error {Tcl result was not acknowledged} }\n"
            "after 3000 {set ::captureAiIntegrationDone 1}\n"
            "vwait ::captureAiIntegrationDone\n",
            encoding="utf-8",
        )

        execute_thread.join(timeout=5)
        assert not execute_thread.is_alive()
        completed = execute_results.get_nowait()
        if isinstance(completed, Exception):
            if tcl_process.poll() is not None:
                tcl_stdout, tcl_stderr = tcl_process.communicate()
                raise AssertionError(
                    f"Tcl sender exited {tcl_process.returncode}\n"
                    f"stdout:\n{tcl_stdout}\nstderr:\n{tcl_stderr}"
                ) from completed
            raise completed
        assert completed["id"] == command["id"]
        assert completed["result"] == "tcl-result"
        tcl_stdout, tcl_stderr = tcl_process.communicate(timeout=5)
        assert tcl_process.returncode == 0, f"stdout:\n{tcl_stdout}\nstderr:\n{tcl_stderr}"
    finally:
        if tcl_process.poll() is None:
            tcl_process.terminate()
        try:
            tcl_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tcl_process.kill()
            tcl_process.wait(timeout=5)
        try:
            _stop_server(server, descriptor, capture_pid, cancel_file)
            server.communicate(timeout=2)
            _assert_server_cleanup(
                server,
                runtime_file,
                launch_file,
                claim_file,
                cancel_file,
                ack_file,
            )
        finally:
            if server.poll() is None:
                server.kill()
                server.wait(timeout=5)
            for path in cleanup_paths:
                path.unlink(missing_ok=True)


@pytest.mark.parametrize(
    "bad_state", ("server-running", "runtime-leftover", "wrong-ack")
)
def test_server_cleanup_validation_fails_before_test_fallback_and_still_cleans(
    tmp_path, bad_state
):
    runtime_file = tmp_path / "capture_tcl_bridge.json"
    launch_file = tmp_path / "capture_tcl_bridge_launch_integration"
    claim_file = Path(f"{launch_file}.claimed")
    cancel_file = Path(f"{launch_file}.cancel")
    ack_file = Path(f"{launch_file}.stopped")
    lock_file = runtime_file.with_suffix(".json.lock")
    ack_file.write_bytes(
        b"wrong acknowledgement\n"
        if bad_state == "wrong-ack"
        else f"stopped {NONCE}\n".encode("ascii")
    )
    if bad_state == "runtime-leftover":
        runtime_file.write_bytes(b"left behind")
    lock_file.write_bytes(b"persistent synchronization file")
    all_paths = (
        runtime_file,
        lock_file,
        launch_file,
        claim_file,
        cancel_file,
        ack_file,
    )

    class FakeProcess:
        def __init__(self, running):
            self.returncode = None if running else 0

        def poll(self):
            return self.returncode

        def kill(self):
            self.returncode = -9

        def wait(self):
            return self.returncode

    server = FakeProcess(bad_state == "server-running")

    try:
        with pytest.raises(AssertionError):
            _assert_server_cleanup(
                server,
                runtime_file,
                launch_file,
                claim_file,
                cancel_file,
                ack_file,
            )
        if bad_state == "server-running":
            assert server.poll() is None
        elif bad_state == "runtime-leftover":
            assert runtime_file.exists()
        else:
            assert ack_file.read_bytes() == b"wrong acknowledgement\n"
    finally:
        if server.poll() is None:
            server.kill()
            server.wait()
        for path in all_paths:
            path.unlink(missing_ok=True)

    assert server.poll() is not None
    assert all(not path.exists() for path in all_paths)
