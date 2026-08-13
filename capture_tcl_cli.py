"""Human command-line client for the local Capture Tcl bridge."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
import urllib.error
import urllib.parse
import urllib.request


SERVICE = "capture-tcl-bridge"
SOFTWARE_VERSION = "0.1.0-beta.3"
PROTOCOL_VERSION = 1
REQUEST_TIMEOUT_SECONDS = 35
RUNTIME_FILENAME = "capture_tcl_bridge.json"
# Five 4 MiB UTF-8 field/list budgets can expand sixfold as JSON escapes;
# 160 MiB covers that 120 MiB worst case plus list and object framing.
RESPONSE_LIMIT_BYTES = 160 * 1024 * 1024
_CANONICAL_BASE_URL = re.compile(r"http://127\.0\.0\.1:([1-9][0-9]{0,4})")
_SAFE_COMMAND_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_SAFE_COMMAND_STATE = re.compile(r"[a-z][a-z0-9_-]{0,31}")


def _is_strict_utf8_text(value: object) -> bool:
    if type(value) is not str:
        return False
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeError:
        return False
    return True


def _safe_utf8_text(value: object, fallback: str) -> str:
    try:
        text = str(value)
    except Exception:
        return fallback
    return text if _is_strict_utf8_text(text) else fallback


class BridgeClientError(RuntimeError):
    """A discovery, protocol, or transport failure safe to report to a user."""

    def __init__(
        self, message: str, *, metadata: dict[str, object] | None = None
    ) -> None:
        super().__init__(_safe_utf8_text(message, "Unprintable bridge error."))
        self.metadata: dict[str, str] = {}
        if metadata is None:
            return
        command_id = metadata.get("id")
        state = metadata.get("state")
        if _is_strict_utf8_text(command_id) and _SAFE_COMMAND_ID.fullmatch(command_id):
            self.metadata["id"] = command_id
        if _is_strict_utf8_text(state) and _SAFE_COMMAND_STATE.fullmatch(state):
            self.metadata["state"] = state


class ScriptSourceError(ValueError):
    """The requested script sources are missing or ambiguous."""


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Turn every redirect into an HTTPError before credentials can move hosts."""

    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


_URL_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _NoRedirectHandler()
)


def _open_url(request: urllib.request.Request, timeout: int):
    return _URL_OPENER.open(request, timeout=timeout)


def default_runtime_file() -> Path:
    """Return the per-user runtime descriptor used by the bridge service."""
    return Path(os.environ.get("TEMP", Path.cwd())) / RUNTIME_FILENAME


def _descriptor_error(field: str) -> BridgeClientError:
    return BridgeClientError(f"Invalid runtime descriptor {field}.")


def _is_positive_integer(value: object) -> bool:
    return type(value) is int and value > 0


def _valid_token(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and value.isascii()
        and all(33 <= ord(character) <= 126 for character in value)
    )


def _validate_base_url(value: object) -> str:
    if not isinstance(value, str):
        raise _descriptor_error("baseUrl")
    match = _CANONICAL_BASE_URL.fullmatch(value)
    if match is None or int(match.group(1)) > 65535:
        raise _descriptor_error("baseUrl")
    return value


def load_descriptor(path: str | Path) -> dict[str, Any]:
    """Load and strictly validate one local bridge runtime descriptor."""
    runtime_path = Path(path)
    try:
        value = json.loads(runtime_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BridgeClientError("Runtime descriptor is unavailable or invalid.") from error
    if not isinstance(value, dict):
        raise BridgeClientError("Runtime descriptor must be a JSON object.")
    if value.get("service") != SERVICE or type(value.get("service")) is not str:
        raise _descriptor_error("service")
    if value.get("version") != SOFTWARE_VERSION or type(value.get("version")) is not str:
        raise _descriptor_error("version")
    if (
        type(value.get("protocolVersion")) is not int
        or value["protocolVersion"] != PROTOCOL_VERSION
    ):
        raise _descriptor_error("protocolVersion")
    if not _valid_token(value.get("token")):
        raise _descriptor_error("token")
    value["baseUrl"] = _validate_base_url(value.get("baseUrl"))
    for field in ("capturePid", "serverPid"):
        if not _is_positive_integer(value.get(field)):
            raise _descriptor_error(field)
    return value


def _redact(message: object, token: str) -> str:
    text = _safe_utf8_text(message, "Unprintable bridge error.")
    return text.replace(token, "[redacted]") if token else text


def _read_response_body(response: Any) -> bytes:
    body = response.read(RESPONSE_LIMIT_BYTES + 1)
    if not isinstance(body, bytes):
        raise BridgeClientError("Bridge returned an invalid response body.")
    if len(body) > RESPONSE_LIMIT_BYTES:
        raise BridgeClientError("Bridge response body is too large.")
    return body


def _decode_error_response(
    error: urllib.error.HTTPError, token: str
) -> BridgeClientError:
    try:
        body = json.loads(_read_response_body(error).decode("utf-8"))
        details = body["error"]
        code = details["code"]
        message = details["message"]
        if not _is_strict_utf8_text(code) or not _is_strict_utf8_text(message):
            raise ValueError
        metadata = None
        if code == "EXECUTION_TIMEOUT":
            metadata = {"id": body.get("id"), "state": body.get("state")}
        return BridgeClientError(
            _redact(f"{code}: {message}", token), metadata=metadata
        )
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, json.JSONDecodeError):
        reason = _redact(error.reason, token)
        return BridgeClientError(f"HTTP {error.code}: {reason}")


def request_json(
    descriptor: dict[str, Any],
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Send one authenticated JSON request to the validated local service."""
    token = descriptor["token"]
    if method not in {"GET", "POST"} or not path.startswith("/") or "//" in path:
        raise BridgeClientError("Invalid bridge request target.")
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if payload is not None:
        try:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        except (TypeError, ValueError, UnicodeError) as error:
            raise BridgeClientError(
                "Bridge request payload is not valid UTF-8 JSON."
            ) from error
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(
        f"{descriptor['baseUrl'].rstrip('/')}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    try:
        with _open_url(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            value = json.loads(_read_response_body(response).decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            failure = _decode_error_response(error, token)
        finally:
            try:
                error.close()
            except Exception:
                pass
        raise failure from error
    except (json.JSONDecodeError, UnicodeError) as error:
        raise BridgeClientError("Bridge returned invalid UTF-8 JSON.") from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        message = _redact(error, token)
        raise BridgeClientError(f"Bridge request failed: {message}") from error
    if not isinstance(value, dict):
        raise BridgeClientError("Bridge returned a non-object JSON response.")
    return value


def resolve_script(
    command: str | None,
    file: str | Path | None,
    stdin: str | None,
) -> str:
    """Resolve exactly one command, UTF-8 file, or piped standard input."""
    sources = sum(source is not None for source in (command, file, stdin))
    if sources != 1:
        raise ScriptSourceError(
            "Provide exactly one script source: -c, -f, or piped stdin."
        )
    if command is not None:
        return command
    if file is not None:
        try:
            return Path(file).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise BridgeClientError("The Tcl script file could not be read as UTF-8.") from error
    assert stdin is not None
    return stdin


def print_human(result: dict[str, Any]) -> int:
    """Print captured streams and a readable Tcl completion summary."""
    stdout_text = str(result.get("stdout", ""))
    stderr_text = str(result.get("stderr", ""))
    if result.get("ok") is True:
        stdout_text += f"Result: {result.get('result', '')}\n"
        exit_code = 0
    else:
        return_code = result.get("returnCode", "unknown")
        stderr_text += (
            f"Tcl error (return code {return_code}): {result.get('result', '')}\n"
        )
        error_info = str(result.get("errorInfo", ""))
        if error_info:
            stderr_text += error_info
            if not error_info.endswith("\n"):
                stderr_text += "\n"
        exit_code = 1

    for stream, text in ((sys.stdout, stdout_text), (sys.stderr, stderr_text)):
        encoding = getattr(stream, "encoding", None) or "utf-8"
        try:
            text.encode(encoding, errors="strict")
        except (LookupError, UnicodeError) as error:
            raise BridgeClientError(
                "Human-readable output cannot be encoded for this terminal."
            ) from error
    try:
        if stdout_text:
            sys.stdout.write(stdout_text)
        if stderr_text:
            sys.stderr.write(stderr_text)
    except (OSError, UnicodeError) as error:
        raise BridgeClientError("Human-readable output could not be written.") from error
    return exit_code


def _validate_completed_result(result: dict[str, Any]) -> None:
    string_fields = ("result", "stdout", "stderr", "errorInfo")
    truncation_fields = (
        "stdoutTruncated",
        "stderrTruncated",
        "resultTruncated",
    )
    command_id = result.get("id")
    return_code = result.get("returnCode")
    error_code = result.get("errorCode")
    error_line = result.get("errorLine")
    valid = (
        type(command_id) is str
        and bool(command_id)
        and result.get("state") == "completed"
        and type(result.get("state")) is str
        and type(result.get("ok")) is bool
        and type(return_code) is int
        and result.get("ok") is (return_code == 0)
        and all(type(result.get(field)) is str for field in string_fields)
        and type(error_code) is list
        and all(type(item) is str for item in error_code)
        and all(
            _is_strict_utf8_text(value)
            for value in (
                command_id,
                *(result.get(field) for field in string_fields),
                *error_code,
            )
        )
        and (error_line is None or type(error_line) is int)
        and all(type(result.get(field)) is bool for field in truncation_fields)
    )
    if not valid:
        raise BridgeClientError("Invalid execution response.")


def _format_bridge_error(error: BridgeClientError) -> str:
    message = str(error)
    command_id = error.metadata.get("id")
    state = error.metadata.get("state")
    if command_id is None or state is None:
        return message
    lookup_id = urllib.parse.quote(command_id, safe="")
    return (
        f"{message} Command {command_id} is {state}; execution was not cancelled. "
        f"Query GET /v1/commands/{lookup_id}."
    )


def _validate_health(
    health: dict[str, Any], descriptor: dict[str, Any]
) -> None:
    expected = {
        "service": descriptor["service"],
        "version": descriptor["version"],
        "protocolVersion": descriptor["protocolVersion"],
        "capturePid": descriptor["capturePid"],
        "serverPid": descriptor["serverPid"],
    }
    for field, expected_value in expected.items():
        actual = health.get(field)
        if type(actual) is not type(expected_value) or actual != expected_value:
            raise BridgeClientError("Bridge health identity does not match the descriptor.")
    if type(health.get("captureConnected")) is not bool:
        raise BridgeClientError("Bridge health response has an invalid connection state.")
    if type(health.get("busy")) is not bool:
        raise BridgeClientError("Bridge health response has an invalid busy state.")


def _write_json(value: dict[str, Any]) -> None:
    document = json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n"
    sys.stdout.write(document)


def _runtime_descriptor(path: Path) -> dict[str, Any] | None:
    try:
        return load_descriptor(path)
    except BridgeClientError:
        print("Bridge error: runtime descriptor is unavailable or invalid.", file=sys.stderr)
        return None


def _configure_standard_streams() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if not callable(reconfigure):
            continue
        try:
            reconfigure(encoding="utf-8", errors="strict")
        except (OSError, TypeError, ValueError):
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Execute Tcl in a running OrCAD Capture process."
    )
    parser.add_argument("action", nargs="?", choices=("status",))
    parser.add_argument("-c", "--command", help="Tcl command or multi-line script")
    parser.add_argument("-f", "--file", type=Path, help="UTF-8 Tcl script file")
    parser.add_argument("--json", action="store_true", help="print the complete JSON response")
    parser.add_argument("--runtime-file", type=Path, default=default_runtime_file())
    return parser


def main(argv: list[str] | None = None) -> int:
    _configure_standard_streams()
    parser = build_parser()
    arguments = parser.parse_args(argv)

    if arguments.action == "status":
        if arguments.command is not None or arguments.file is not None:
            parser.error("status does not accept a Tcl script")
        descriptor = _runtime_descriptor(arguments.runtime_file)
        if descriptor is None:
            return 3
        try:
            health = request_json(descriptor, "GET", "/v1/health")
            _validate_health(health, descriptor)
        except BridgeClientError as error:
            print(
                f"Bridge error: {_redact(_format_bridge_error(error), descriptor['token'])}",
                file=sys.stderr,
            )
            return 3
        if arguments.json:
            _write_json(health)
        else:
            connection = "connected" if health["captureConnected"] else "disconnected"
            workload = "busy" if health["busy"] else "idle"
            print(f"Capture Tcl bridge v{health['version']}: {connection}, {workload}")
        return 0 if health["captureConnected"] else 3

    stdin_value: str | None = None
    try:
        if not sys.stdin.isatty():
            stdin_value = sys.stdin.read()
            if stdin_value == "":
                stdin_value = None
    except (OSError, UnicodeError):
        print("Bridge error: piped stdin could not be read as UTF-8.", file=sys.stderr)
        return 3
    try:
        script = resolve_script(arguments.command, arguments.file, stdin_value)
    except ScriptSourceError as error:
        parser.error(str(error))
    except BridgeClientError as error:
        print(f"Bridge error: {error}", file=sys.stderr)
        return 3

    descriptor = _runtime_descriptor(arguments.runtime_file)
    if descriptor is None:
        return 3
    try:
        result = request_json(
            descriptor,
            "POST",
            "/v1/execute",
            {"script": script},
        )
        _validate_completed_result(result)
    except BridgeClientError as error:
        print(
            f"Bridge error: {_redact(_format_bridge_error(error), descriptor['token'])}",
            file=sys.stderr,
        )
        return 3
    if arguments.json:
        _write_json(result)
        return 0 if result["ok"] else 1
    try:
        return print_human(result)
    except BridgeClientError as error:
        sys.stderr.write(f"Bridge error: {error}\n")
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
