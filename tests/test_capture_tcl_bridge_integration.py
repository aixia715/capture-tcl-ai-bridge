"""Real subprocess round trip for the Capture Tcl AI bridge."""

from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from typing import Any
import urllib.parse
import urllib.request

import pytest


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "capture_tcl_bridge_server.py"
CLI = ROOT / "capture_tcl_cli.py"
SCRIPT = "puts hello; expr {6 * 7}"
NONCE = "integration-test-nonce"


def _request_json(
    base_url: str,
    token: str,
    capture_pid: int,
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    *,
    timeout: float = 2.0,
) -> dict[str, Any]:
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "X-Capture-Pid": str(capture_pid),
    }
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

    readme = (ROOT / "readme.md").read_text(encoding="utf-8")
    for required in (
        "CaptureAiBridgeStart",
        "CaptureAiBridgeStatus",
        "CaptureAiBridgeStop",
    ):
        assert required in readme


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
