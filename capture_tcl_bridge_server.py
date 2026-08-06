"""Local authenticated bridge between the AI client and Capture Tcl."""

from collections import OrderedDict
import argparse
import asyncio
import atexit
import copy
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import json
import logging
import os
from pathlib import Path
import secrets
import socket
import stat
import tempfile
import threading
import time
from typing import Any
import uuid

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.background import BackgroundTask
import uvicorn


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8767
SERVICE = "capture-tcl-bridge"
PROTOCOL_VERSION = 1
SCRIPT_LIMIT_BYTES = 1_048_576
EXECUTE_BODY_LIMIT_BYTES = 8 * 1_048_576
RESULT_BODY_LIMIT_BYTES = 160 * 1_048_576
FIELD_LIMIT_BYTES = 4_194_304
HEARTBEAT_TIMEOUT_SECONDS = 5.0
EXECUTE_TIMEOUT_SECONDS = 30.0
RESULT_HISTORY_LIMIT = 100
RUNTIME_LOCK_TIMEOUT_SECONDS = 2.0
RUNTIME_FILE: Path | None = None
LAUNCH_FILE: Path | None = None
CLAIM_FILE: Path | None = None
CANCEL_FILE: Path | None = None
ACK_FILE: Path | None = None
ACTIVE_SERVER: Any | None = None
LOGGER = logging.getLogger(__name__)
CANCEL_CONTROL_LIMIT_BYTES = 64
_RUNTIME_LOCKS_GUARD = threading.Lock()
_RUNTIME_LOCKS: dict[Path, threading.RLock] = {}


class BridgeState:
    """Mutable bridge state guarded by a re-entrant lock."""

    def __init__(self, token: str, capture_pid: int) -> None:
        self.lock = threading.RLock()
        self.token: str = token
        self.capture_pid: int = capture_pid
        self.last_bridge_seen: float | None = None
        self.active: dict[str, Any] | None = None
        self.completed: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self.shutting_down = False

    def reset(self, token: str, capture_pid: int) -> None:
        with self.lock:
            self.token = token
            self.capture_pid = capture_pid
            self.last_bridge_seen = None
            self.active = None
            self.completed.clear()
            self.shutting_down = False

    def connected(self) -> bool:
        with self.lock:
            return (
                self.last_bridge_seen is not None
                and time.monotonic() - self.last_bridge_seen < HEARTBEAT_TIMEOUT_SECONDS
            )

    def mark_seen(self) -> None:
        with self.lock:
            self.last_bridge_seen = time.monotonic()

    def store_completed(self, result: dict[str, Any]) -> None:
        """Store a private copy of a completed command result."""
        with self.lock:
            command_id = result["id"]
            self.completed.pop(command_id, None)
            self.completed[command_id] = copy.deepcopy(result)
            while len(self.completed) > RESULT_HISTORY_LIMIT:
                self.completed.popitem(last=False)


bridge = BridgeState(token="test-token", capture_pid=4242)
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def request_shutdown(server: Any | None = None) -> None:
    """Make shutdown visible to requests before asking uvicorn to exit."""
    with bridge.lock:
        bridge.shutting_down = True
    target = server if server is not None else ACTIVE_SERVER
    if target is not None:
        target.should_exit = True


class RequestBodyTooLarge(ValueError):
    pass


async def read_json_limited(request: Request, limit: int) -> Any:
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            declared_length = int(content_length)
        except ValueError:
            pass
        else:
            if declared_length > limit:
                raise RequestBodyTooLarge
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise RequestBodyTooLarge
    return json.loads(bytes(body).decode("utf-8"))


def reset_bridge_state(token: str = "test-token", capture_pid: int = 4242) -> None:
    """Restore bridge state for isolated tests."""
    bridge.reset(token=token, capture_pid=capture_pid)


@contextmanager
def runtime_descriptor_lock(path: Path):
    """Serialize descriptor updates across threads and bridge processes."""
    key = path.resolve()
    with _RUNTIME_LOCKS_GUARD:
        thread_lock = _RUNTIME_LOCKS.setdefault(key, threading.RLock())

    thread_locked = thread_lock.acquire(timeout=RUNTIME_LOCK_TIMEOUT_SECONDS)
    if not thread_locked:
        raise TimeoutError("Timed out waiting for runtime descriptor lock.")
    lock_fd: int | None = None
    platform_locked = False
    try:
        lock_path = path.with_suffix(path.suffix + ".lock")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        if os.name != "nt":
            os.fchmod(lock_fd, 0o600)
        if os.fstat(lock_fd).st_size == 0:
            os.write(lock_fd, b"\0")
        os.lseek(lock_fd, 0, os.SEEK_SET)
        deadline = time.monotonic() + RUNTIME_LOCK_TIMEOUT_SECONDS
        if os.name == "nt":
            import msvcrt

            while True:
                try:
                    msvcrt.locking(lock_fd, msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Timed out waiting for runtime descriptor lock.")
                    time.sleep(0.01)
        else:
            import fcntl

            while True:
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Timed out waiting for runtime descriptor lock.")
                    time.sleep(0.01)
        platform_locked = True
        yield
    finally:
        try:
            if lock_fd is not None:
                try:
                    if platform_locked and os.name == "nt":
                        import msvcrt

                        os.lseek(lock_fd, 0, os.SEEK_SET)
                        msvcrt.locking(lock_fd, msvcrt.LK_UNLCK, 1)
                    elif platform_locked:
                        import fcntl

                        fcntl.flock(lock_fd, fcntl.LOCK_UN)
                finally:
                    os.close(lock_fd)
        finally:
            if thread_locked:
                thread_lock.release()


def write_runtime_descriptor(path: Path, token: str, capture_pid: int, port: int) -> None:
    """Atomically publish the connection details for this bridge process."""
    descriptor = {
        "service": SERVICE,
        "protocolVersion": PROTOCOL_VERSION,
        "baseUrl": f"http://{DEFAULT_HOST}:{port}",
        "token": token,
        "capturePid": capture_pid,
        "serverPid": os.getpid(),
    }
    with runtime_descriptor_lock(path):
        temporary_path: Path | None = None
        try:
            temporary_fd, temporary_name = tempfile.mkstemp(
                prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
            )
            temporary_path = Path(temporary_name)
            if os.name != "nt":
                os.fchmod(temporary_fd, 0o600)
            with os.fdopen(temporary_fd, "w", encoding="utf-8") as temporary_file:
                json.dump(descriptor, temporary_file)
                temporary_file.flush()
                os.fsync(temporary_file.fileno())
            os.replace(temporary_path, path)
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except FileNotFoundError:
                    pass
                except OSError:
                    pass


def remove_runtime_descriptor(path: Path, expected_server_pid: int) -> None:
    """Remove a descriptor only when it belongs to this server process."""
    try:
        with runtime_descriptor_lock(path):
            try:
                descriptor = json.loads(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                return
            except (OSError, UnicodeError, ValueError) as error:
                LOGGER.warning("runtime descriptor could not be read for cleanup: %s", error)
                return
            if (
                type(expected_server_pid) is not int
                or not isinstance(descriptor, dict)
                or type(descriptor.get("serverPid")) is not int
                or descriptor["serverPid"] != expected_server_pid
            ):
                return
            try:
                path.unlink()
            except OSError as error:
                LOGGER.warning("runtime descriptor could not be removed: %s", error)
    except Exception as error:
        LOGGER.warning("runtime descriptor cleanup lock failed: %s", error)
        return


def remove_launch_signal(path: Path) -> None:
    """Unlink one launch-scoped signal path without following its target."""
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass


def read_small_regular_file(path: Path) -> bytes:
    """Read a small regular file without accepting links or reparse points."""
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("cancel control must be a regular file")
    if getattr(metadata, "st_file_attributes", 0) & 0x400:
        raise ValueError("cancel control must not be a reparse point")
    if metadata.st_size > CANCEL_CONTROL_LIMIT_BYTES:
        raise ValueError("cancel control is too large")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or getattr(opened_metadata, "st_file_attributes", 0) & 0x400
            or (opened_metadata.st_dev, opened_metadata.st_ino)
            != (metadata.st_dev, metadata.st_ino)
        ):
            raise ValueError("cancel control changed during validation")
        value = os.read(descriptor, CANCEL_CONTROL_LIMIT_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(value) > CANCEL_CONTROL_LIMIT_BYTES:
        raise ValueError("launch signal is too large")
    return value


def read_launch_control(path: Path) -> str:
    """Return the nonce from an immutable launch file."""
    value = read_small_regular_file(path)
    if not value.startswith(b"launch ") or not value.endswith(b"\n"):
        raise ValueError("launch control has invalid content")
    nonce_bytes = value[7:-1]
    if not nonce_bytes or len(nonce_bytes) > 48 or any(
        byte not in b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        for byte in nonce_bytes
    ):
        raise ValueError("launch control has invalid nonce")
    return nonce_bytes.decode("ascii")


def read_cancel_request(path: Path, nonce: str) -> bool:
    """Return whether this launch's exclusive cancellation request exists."""
    try:
        value = read_small_regular_file(path)
    except FileNotFoundError:
        return False
    if value != f"cancel {nonce}\n".encode("ascii"):
        raise ValueError("cancel request has invalid content")
    return True


def read_launch_claim(path: Path, nonce: str) -> bool:
    """Validate an existing server claim, or report that it is absent."""
    try:
        value = read_small_regular_file(path)
    except FileNotFoundError:
        return False
    if value != f"claimed {nonce}\n".encode("ascii"):
        raise ValueError("launch claim has invalid content")
    return True


def write_launch_claim(path: Path, nonce: str) -> None:
    """Atomically claim this launch before any socket bind is attempted."""
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_BINARY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path, flags, 0o600)
    failure: BaseException | None = None
    try:
        value = f"claimed {nonce}\n".encode("ascii")
        if os.write(descriptor, value) != len(value):
            raise OSError("short launch claim write")
        os.fsync(descriptor)
    except BaseException as error:
        failure = error
    try:
        os.close(descriptor)
    except BaseException as error:
        if failure is None:
            failure = error
    if failure is not None:
        remove_launch_signal(path)
        raise failure


def write_stopped_ack(path: Path, nonce: str) -> None:
    """Create the authoritative stopped acknowledgement exactly once."""
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_BINARY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path, flags, 0o600)
    try:
        value = f"stopped {nonce}\n".encode("ascii")
        if os.write(descriptor, value) != len(value):
            raise OSError("short stopped acknowledgement write")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def watch_launch_signals(
    launch_file: Path,
    cancel_file: Path,
    nonce: str,
    server: Any,
    interval: float = 0.05,
) -> None:
    """Exit when launch integrity is lost or a cancel request appears."""
    while not server.should_exit:
        try:
            if read_launch_control(launch_file) != nonce:
                raise ValueError("launch nonce changed")
            cancelled = read_cancel_request(cancel_file, nonce)
        except (OSError, ValueError):
            request_shutdown(server)
            return
        if cancelled:
            request_shutdown(server)
            return
        time.sleep(interval)


def start_launch_watchdog(
    launch_file: Path, cancel_file: Path, nonce: str, server: Any
) -> threading.Thread:
    """Start the launch integrity and cancellation watcher."""
    worker = threading.Thread(
        target=watch_launch_signals,
        args=(launch_file, cancel_file, nonce, server),
        name="capture-bridge-cancel-watchdog",
        daemon=True,
    )
    worker.start()
    return worker


def load_kernel32() -> Any:
    """Return the Windows process API with explicit ctypes signatures."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    return kernel32


def process_is_alive(pid: int) -> bool:
    """Return whether the operating system reports a process as alive."""
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            kernel32 = load_kernel32()
            handle = kernel32.OpenProcess(0x00100000, False, pid)
        except (OSError, OverflowError):
            return False
        if not handle:
            return False
        try:
            return kernel32.WaitForSingleObject(handle, 0) == 0x102
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, OverflowError):
        return False
    return True


def watch_parent_process(
    parent_pid: int,
    runtime_file: Path,
    interval: float = 1.0,
    cancel_file: Path | None = None,
    server: Any | None = None,
) -> None:
    """Request graceful exit when the Capture parent process disappears."""
    try:
        while process_is_alive(parent_pid):
            time.sleep(interval)
    except Exception:
        pass
    request_shutdown(server)


def start_parent_watchdog(
    parent_pid: int,
    runtime_file: Path,
    cancel_file: Path | None = None,
    server: Any | None = None,
) -> threading.Thread | None:
    """Start a daemon watcher when a positive parent process ID was supplied."""
    if parent_pid <= 0:
        return None
    worker_args = (
        (parent_pid, runtime_file)
        if cancel_file is None
        else (parent_pid, runtime_file, 1.0, cancel_file, server)
    )
    worker = threading.Thread(
        target=watch_parent_process,
        args=worker_args,
        name="capture-bridge-parent-watchdog",
    )
    worker.daemon = True
    worker.start()
    return worker


def error_response(
    status_code: int, code: str, message: str, **details: Any
) -> JSONResponse:
    content = {"ok": False, "error": {"code": code, "message": message}}
    content.update(details)
    return JSONResponse(
        status_code=status_code,
        content=content,
    )


def valid_token(request: Request) -> bool:
    authorization = request.headers.get("Authorization")
    if authorization is None or not authorization.isascii():
        return False
    with bridge.lock:
        token = bridge.token
    return secrets.compare_digest(authorization, f"Bearer {token}")


async def require_token(request: Request) -> JSONResponse | None:
    if not valid_token(request):
        return error_response(401, "UNAUTHORIZED", "Invalid or missing bearer token.")
    return None


async def require_capture(request: Request) -> JSONResponse | None:
    unauthorized = await require_token(request)
    if unauthorized is not None:
        return unauthorized

    capture_pid = request.headers.get("X-Capture-Pid")
    with bridge.lock:
        if capture_pid != str(bridge.capture_pid):
            return error_response(409, "CAPTURE_PID_MISMATCH", "Capture PID does not match.")
    return None


@app.get("/v1/health")
async def health(request: Request) -> JSONResponse:
    unauthorized = await require_token(request)
    if unauthorized is not None:
        return unauthorized

    with bridge.lock:
        return JSONResponse(
            content={
                "service": SERVICE,
                "protocolVersion": PROTOCOL_VERSION,
                "captureConnected": bridge.connected(),
                "busy": bridge.active is not None,
                "capturePid": bridge.capture_pid,
                "serverPid": os.getpid(),
            }
        )


@app.get("/internal/command")
async def command(request: Request) -> JSONResponse:
    rejected = await require_capture(request)
    if rejected is not None:
        return rejected

    with bridge.lock:
        bridge.last_bridge_seen = time.monotonic()
        active = bridge.active
        if active is None or active["state"] != "queued":
            return JSONResponse(content={})
        active["state"] = "executing"
        return JSONResponse(content={"id": active["id"], "script": active["script"]})


@app.post("/internal/shutdown")
async def shutdown(request: Request) -> JSONResponse:
    """Allow the owning Capture process to request a controlled shutdown."""
    rejected = await require_capture(request)
    if rejected is not None:
        return rejected

    def finish_shutdown() -> None:
        request_shutdown()

    return JSONResponse(content={"ok": True}, background=BackgroundTask(finish_shutdown))


def truncate_utf8(value: str, limit_bytes: int) -> tuple[str, bool]:
    """Limit text by encoded UTF-8 bytes without splitting a character."""
    encoded = value.encode("utf-8")
    if len(encoded) <= limit_bytes:
        return value, False

    truncated = encoded[:limit_bytes]
    while truncated:
        try:
            return truncated.decode("utf-8"), True
        except UnicodeDecodeError as error:
            truncated = truncated[: error.start]
    return "", True


def is_utf8_text(value: Any) -> bool:
    """Return whether a JSON string can be returned safely as UTF-8."""
    if not isinstance(value, str):
        return False
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def truncate_utf8_list(values: list[str], limit_bytes: int) -> list[str]:
    """Bound aggregate UTF-8 metadata, charging empty entries one byte each."""
    bounded: list[str] = []
    remaining = max(0, limit_bytes)
    for value in values:
        if remaining == 0:
            break
        encoded_length = len(value.encode("utf-8"))
        if encoded_length == 0:
            bounded.append(value)
            remaining -= 1
            continue
        text, truncated = truncate_utf8(value, remaining)
        if text:
            bounded.append(text)
            remaining -= len(text.encode("utf-8"))
        if truncated:
            break
    return bounded


def normalize_result(payload: Any) -> dict[str, Any] | None:
    """Validate and normalize an internal Capture result without raising."""
    required = {
        "id",
        "returnCode",
        "result",
        "stdout",
        "stderr",
        "errorInfo",
        "errorCode",
        "errorLine",
        "stdoutTruncated",
        "stderrTruncated",
        "resultTruncated",
    }
    if not isinstance(payload, dict) or not required.issubset(payload):
        return None

    command_id = payload["id"]
    return_code = payload["returnCode"]
    error_info = payload["errorInfo"]
    error_code = payload["errorCode"]
    error_line = payload["errorLine"]
    flags = ("stdoutTruncated", "stderrTruncated", "resultTruncated")
    if (
        not is_utf8_text(command_id)
        or not command_id
        or not isinstance(return_code, int)
        or isinstance(return_code, bool)
        or any(not is_utf8_text(payload[name]) for name in ("result", "stdout", "stderr", "errorInfo"))
        or not isinstance(error_code, list)
        or any(not is_utf8_text(item) for item in error_code)
        or (error_line is not None and (not isinstance(error_line, int) or isinstance(error_line, bool)))
        or any(not isinstance(payload[name], bool) for name in flags)
    ):
        return None

    bounded_error_info, _ = truncate_utf8(error_info, FIELD_LIMIT_BYTES)
    normalized: dict[str, Any] = {
        "id": command_id,
        "state": "completed",
        "ok": return_code == 0,
        "returnCode": return_code,
        "errorInfo": bounded_error_info,
        "errorCode": truncate_utf8_list(error_code, FIELD_LIMIT_BYTES),
        "errorLine": error_line,
    }
    for field, flag in (
        ("result", "resultTruncated"),
        ("stdout", "stdoutTruncated"),
        ("stderr", "stderrTruncated"),
    ):
        text, truncated = truncate_utf8(payload[field], FIELD_LIMIT_BYTES)
        normalized[field] = text
        normalized[flag] = payload[flag] or truncated
    return normalized


@app.post("/v1/execute")
async def execute(request: Request) -> JSONResponse:
    unauthorized = await require_token(request)
    if unauthorized is not None:
        return unauthorized

    try:
        body = await read_json_limited(request, EXECUTE_BODY_LIMIT_BYTES)
    except RequestBodyTooLarge:
        return error_response(413, "REQUEST_TOO_LARGE", "Request body is too large.")
    except (UnicodeDecodeError, ValueError):
        return error_response(
            400,
            "INVALID_REQUEST",
            "Request body must be a JSON object with a string script.",
        )

    if not isinstance(body, dict) or not isinstance(body.get("script"), str):
        return error_response(
            400,
            "INVALID_REQUEST",
            "Request body must be a JSON object with a string script.",
        )

    try:
        script_size = len(body["script"].encode("utf-8"))
    except UnicodeEncodeError:
        return error_response(
            400,
            "INVALID_REQUEST",
            "Request body must be a JSON object with a string script.",
        )

    if script_size > SCRIPT_LIMIT_BYTES:
        return error_response(413, "SCRIPT_TOO_LARGE", "Script exceeds the 1 MiB limit.")

    with bridge.lock:
        if bridge.shutting_down:
            return error_response(503, "SERVER_SHUTTING_DOWN", "Server is shutting down.")
        if not bridge.connected():
            return error_response(503, "CAPTURE_DISCONNECTED", "Capture is not connected.")
        if bridge.active is not None:
            return error_response(409, "BRIDGE_BUSY", "Capture already has an active command.")
        command_id = str(uuid.uuid4())
        bridge.active = {"id": command_id, "script": body["script"], "state": "queued"}

    deadline = time.monotonic() + EXECUTE_TIMEOUT_SECONDS
    while True:
        with bridge.lock:
            if bridge.shutting_down:
                active = bridge.active
                state = active["state"] if active is not None and active["id"] == command_id else "queued"
                return error_response(503, "SERVER_SHUTTING_DOWN", "Server is shutting down.", id=command_id, state=state)
            completed = bridge.completed.get(command_id)
            if completed is not None:
                return JSONResponse(content=copy.deepcopy(completed))
        if time.monotonic() >= deadline:
            with bridge.lock:
                completed = bridge.completed.get(command_id)
                if completed is not None:
                    return JSONResponse(content=copy.deepcopy(completed))
                active = bridge.active
                state = active["state"] if active is not None and active["id"] == command_id else "queued"
                return error_response(
                    504,
                    "EXECUTION_TIMEOUT",
                    "Script execution timed out; Capture may still complete it.",
                    id=command_id,
                    state=state,
                )
        await asyncio.sleep(0.01)


@app.post("/internal/result")
async def result(request: Request) -> JSONResponse:
    rejected = await require_capture(request)
    if rejected is not None:
        return rejected

    bridge.mark_seen()
    try:
        payload = await read_json_limited(request, RESULT_BODY_LIMIT_BYTES)
    except RequestBodyTooLarge:
        return error_response(413, "REQUEST_TOO_LARGE", "Result body is too large.")
    except (UnicodeDecodeError, ValueError):
        return error_response(400, "INVALID_RESULT", "Result body must contain a valid command result.")

    normalized = normalize_result(payload)
    if normalized is None:
        return error_response(400, "INVALID_RESULT", "Result body must contain a valid command result.")

    with bridge.lock:
        completed = bridge.completed.get(normalized["id"])
        if completed is not None:
            return JSONResponse(content={"id": normalized["id"], "state": "completed"})
        active = bridge.active
        if (
            active is None
            or active["id"] != normalized["id"]
            or active["state"] != "executing"
        ):
            return error_response(409, "COMMAND_ID_MISMATCH", "Result does not match the executing command.")
        bridge.store_completed(normalized)
        bridge.active = None
    return JSONResponse(content={"id": normalized["id"], "state": "completed"})


@app.get("/v1/commands/{command_id}")
async def command_status(command_id: str, request: Request) -> JSONResponse:
    unauthorized = await require_token(request)
    if unauthorized is not None:
        return unauthorized

    with bridge.lock:
        completed = bridge.completed.get(command_id)
        if completed is not None:
            return JSONResponse(content=copy.deepcopy(completed))
        active = bridge.active
        if active is not None and active["id"] == command_id:
            return JSONResponse(content={"id": command_id, "state": active["state"]})
    return error_response(404, "COMMAND_NOT_FOUND", "Command was not found.")


def main(argv: list[str] | None = None) -> None:
    """Run the local bridge after publishing an authenticated runtime descriptor."""
    parser = argparse.ArgumentParser(description="Local Capture Tcl bridge")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--runtime-file", type=Path, required=True)
    parser.add_argument("--launch-file", type=Path, required=True)
    parser.add_argument("--claim-file", type=Path, required=True)
    parser.add_argument("--cancel-file", type=Path, required=True)
    parser.add_argument("--ack-file", type=Path, required=True)
    arguments = parser.parse_args(argv)
    if arguments.host != DEFAULT_HOST:
        parser.error("--host must be 127.0.0.1")
    if arguments.parent_pid <= 0:
        parser.error("--parent-pid must be positive")

    runtime_file: Path = arguments.runtime_file
    server_pid = os.getpid()
    launch_file = arguments.launch_file
    claim_file = arguments.claim_file
    cancel_file = arguments.cancel_file
    ack_file = arguments.ack_file
    if (
        launch_file.parent.resolve() != runtime_file.parent.resolve()
        or claim_file.parent.resolve() != runtime_file.parent.resolve()
        or cancel_file.parent.resolve() != runtime_file.parent.resolve()
        or ack_file.parent.resolve() != runtime_file.parent.resolve()
        or not launch_file.name.startswith("capture_tcl_bridge_launch_")
        or claim_file != Path(f"{launch_file}.claimed")
        or cancel_file != Path(f"{launch_file}.cancel")
        or ack_file != Path(f"{launch_file}.stopped")
    ):
        parser.error("launch signal paths must be derived beside --runtime-file")
    try:
        nonce = read_launch_control(launch_file)
        initially_cancelled = read_cancel_request(cancel_file, nonce)
    except (OSError, ValueError) as error:
        parser.error(f"invalid launch signals: {error}")
    try:
        ack_file.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        parser.error(f"invalid --ack-file: {error}")
    else:
        parser.error("--ack-file must not exist before startup")
    try:
        claim_file.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        parser.error(f"invalid --claim-file: {error}")
    else:
        parser.error("--claim-file must not exist before startup")

    descriptor_written = False
    claim_written = False
    sock: socket.socket | None = None
    try:
        config = uvicorn.Config(app, host=DEFAULT_HOST, port=arguments.port)
        config.timeout_graceful_shutdown = 2.0
        server = uvicorn.Server(config)
        if not hasattr(server, "should_exit"):
            server.should_exit = False
        global RUNTIME_FILE, LAUNCH_FILE, CLAIM_FILE, CANCEL_FILE, ACK_FILE, ACTIVE_SERVER
        RUNTIME_FILE = runtime_file
        LAUNCH_FILE = launch_file
        CLAIM_FILE = claim_file
        CANCEL_FILE = cancel_file
        ACK_FILE = ack_file
        ACTIVE_SERVER = server
        start_launch_watchdog(launch_file, cancel_file, nonce, server)
        write_launch_claim(claim_file, nonce)
        claim_written = True
        try:
            launch_still_valid = read_launch_control(launch_file) == nonce
            cancelled_after_claim = read_cancel_request(cancel_file, nonce)
        except (OSError, ValueError):
            request_shutdown(server)
            launch_still_valid = False
            cancelled_after_claim = True
        if (
            initially_cancelled
            or cancelled_after_claim
            or not launch_still_valid
            or server.should_exit
        ):
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind((DEFAULT_HOST, arguments.port))
        sock.listen()
        bound_port = sock.getsockname()[1]

        token = secrets.token_urlsafe(32)
        reset_bridge_state(token, arguments.parent_pid)
        write_runtime_descriptor(runtime_file, token, arguments.parent_pid, bound_port)
        descriptor_written = True
        atexit.register(remove_runtime_descriptor, runtime_file, server_pid)
        start_parent_watchdog(arguments.parent_pid, runtime_file, cancel_file, server)
        try:
            server.run(sockets=[sock])
        finally:
            request_shutdown(server)
    finally:
        try:
            if descriptor_written:
                try:
                    remove_runtime_descriptor(runtime_file, server_pid)
                except Exception as error:
                    LOGGER.warning("runtime descriptor cleanup failed: %s", error)
        finally:
            try:
                if RUNTIME_FILE == runtime_file:
                    RUNTIME_FILE = None
                if LAUNCH_FILE == launch_file:
                    LAUNCH_FILE = None
                if CLAIM_FILE == claim_file:
                    CLAIM_FILE = None
                if CANCEL_FILE == cancel_file:
                    CANCEL_FILE = None
                if ACK_FILE == ack_file:
                    ACK_FILE = None
                if ACTIVE_SERVER is locals().get("server"):
                    ACTIVE_SERVER = None
            finally:
                try:
                    if sock is not None:
                        sock.close()
                finally:
                    if claim_written:
                        try:
                            write_stopped_ack(ack_file, nonce)
                        except OSError as error:
                            LOGGER.warning("stopped acknowledgement could not be created: %s", error)
                        finally:
                            remove_launch_signal(claim_file)
                            remove_launch_signal(launch_file)
                            remove_launch_signal(cancel_file)


if __name__ == "__main__":
    main()
