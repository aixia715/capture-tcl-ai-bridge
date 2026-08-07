# Capture Tcl AI Bridge Design

## Background

AI tools need a machine-readable way to execute debugging Tcl inside the live
OrCAD Capture interpreter and receive the result. Engineers also need a human
friendly command-line client for the same channel. The repository already uses
local FastAPI helpers and non-blocking Tcl polling for browser-to-Capture
communication, so this bridge follows the same proven process boundary while
remaining independent from the BOM and DNIPanel services.

## Goals

- Provide an authenticated HTTP/JSON interface for AI clients.
- Provide a command-line client for engineers.
- Execute complete, multi-line Tcl scripts in Capture's global Tcl scope.
- Return the Tcl result, completion code, captured stdout and stderr, and
  structured Tcl error details.
- Preserve the original Capture console output while capturing `puts`.
- Start and stop explicitly from Capture and exit automatically with Capture.

## Non-Goals

- Sandbox, inspect, rewrite, or approve submitted Tcl scripts.
- Allow access from another computer or from the local network.
- Run more than one Tcl script concurrently.
- Interrupt or forcibly terminate a Tcl script already executing in Capture.
- Merge the bridge into the BOM editor, DNIPanel, or planned schematic tools
  workbench.

## Architecture

The design has three focused components:

```text
AI client / human CLI
        |
        | HTTP/JSON + Bearer token
        v
capture_tcl_bridge_server.py (127.0.0.1:8767)
        |
        | authenticated command polling and result posting
        v
captureAiBridge.tcl (live Capture interpreter)
```

`capture_tcl_bridge_server.py` is the sole broker. It authenticates callers,
owns the single-command state machine, waits for results, and stores completed
results for later retrieval. It treats Tcl scripts as opaque strings.

`captureAiBridge.tcl` owns the Capture lifecycle. It starts the Python broker,
polls it with `after`, evaluates claimed scripts at global scope, captures Tcl
output, and posts results.

`capture_tcl_cli.py` is only an HTTP client. It does not create a second queue or
execute Tcl directly, ensuring human and AI callers have identical behavior.

The bridge uses port 8767 so it does not collide with the current BOM service on
8765 or DNIPanel and the planned unified workbench on 8766.

## Lifecycle and Discovery

The deployed Tcl module exposes exactly these public lifecycle commands:

```tcl
CaptureAiBridgeStart
CaptureAiBridgeStatus
CaptureAiBridgeStop
```

The operator explicitly sources the module and starts it:

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
CaptureAiBridgeStart
```

Starting the bridge launches `C:/tclpython/capture_tcl_bridge_server.py` with the
Capture PID and the runtime descriptor path. The server binds only to
`127.0.0.1:8767`, generates a new cryptographically random token, and atomically
writes `%TEMP%/capture_tcl_bridge.json` with:

- service name and protocol version;
- base URL;
- bearer token;
- Capture PID;
- server PID.

Tcl waits for a descriptor whose Capture PID matches the current process,
authenticates a health request, then starts polling. The CLI validates the
service identity and process metadata before using the descriptor. A stale or
partially written descriptor is rejected rather than silently reused.

Repeated `CaptureAiBridgeStart` calls do not launch a second server. If port
8767 belongs to an unrelated or stale service, the start command reports the
conflict in the Capture console and remains stopped. There is no idle shutdown.

`CaptureAiBridgeStop` cancels polling, requests authenticated server shutdown,
and removes the matching runtime descriptor. The Python server also watches the
Capture parent using the repository's Windows `OpenProcess` and
`WaitForSingleObject` pattern, so it exits and removes its descriptor if Capture
terminates without a clean stop.

## HTTP API

All endpoints require `Authorization: Bearer <token>`, including health and the
internal Tcl bridge endpoints.

### Execute

```http
POST /v1/execute
Content-Type: application/json

{"script": "puts \"hello\"\nexpr {1 + 1}"}
```

Only one command may be pending or executing. A second submission receives HTTP
409 with a stable `BRIDGE_BUSY` error. When Capture is not connected, submission
receives HTTP 503 with `CAPTURE_DISCONNECTED`. Invalid authentication receives
HTTP 401. Invalid JSON, a missing/non-string `script`, or an oversized script
receives HTTP 400 or 413 with a protocol error code.

The request waits up to 30 seconds for Capture. A completed Tcl command returns
HTTP 200 regardless of whether Tcl succeeded; `ok` and `returnCode` describe the
Tcl outcome. If waiting expires, the response is HTTP 504 and includes the
command ID and current state. Timeout does not cancel the Tcl script.

Example successful response:

```json
{
  "id": "7ecda83c-8f71-4f0e-90d6-513331650f11",
  "state": "completed",
  "ok": true,
  "returnCode": 0,
  "result": "2",
  "stdout": "hello\n",
  "stderr": "",
  "errorInfo": "",
  "errorCode": [],
  "errorLine": null,
  "stdoutTruncated": false,
  "stderrTruncated": false,
  "resultTruncated": false
}
```

### Result Lookup

```http
GET /v1/commands/<id>
```

This returns the current command state or its final response. The broker keeps
the 100 most recently completed commands in memory so a caller can retrieve a
result after its synchronous request timed out. Adding the 101st completed
command evicts the oldest completed command. Results are not persisted across
server restarts.

### Health

```http
GET /v1/health
```

The response includes the stable service name, protocol version,
`captureConnected`, `busy`, Capture PID, and server PID. Tcl heartbeats update
the connection state; five seconds without a successful heartbeat makes new
execution requests fail with `CAPTURE_DISCONNECTED`.

### Internal Bridge Endpoints

The Tcl module uses authenticated internal endpoints to:

- publish a heartbeat and Capture PID;
- claim the pending command;
- post the matching completed result;
- request a clean server shutdown.

Claiming is atomic. Result posting follows an explicit state machine:

- an unknown or mismatched command ID is rejected as a protocol error;
- the matching current command is accepted only while its state is
  `executing`, then its normalized result is stored and the active slot is
  cleared;
- if the same command ID is already `completed`, a repeated result POST returns
  the same completion acknowledgement without overwriting the stored result.

The last case is an idempotent retry path for a Tcl worker that posted a result
successfully but did not receive the HTTP acknowledgement.

## Tcl Execution and Output Capture

The Tcl module schedules a poll every 250 ms with `after`; it never uses a
blocking `while` loop. A claimed script runs in the live global Capture scope:

```tcl
catch {uplevel #0 $script} result options
```

While the script executes, the module temporarily wraps `puts` with a
signature-compatible dispatcher:

- the default channel and explicit `stdout` are appended to `stdout`;
- explicit `stderr` is appended to `stderr`;
- `-nonewline` is preserved exactly;
- every captured write is also forwarded to the original `puts`, preserving the
  Capture console;
- writes to files and other channels are only forwarded and are not captured.

The original `puts` command is restored in a guaranteed cleanup path after both
successful and failed execution. Internal procedure names are reserved while a
command is running; because the bridge intentionally executes unrestricted Tcl,
a submitted script can still interfere with bridge internals or Capture itself.

The result maps Tcl's `catch` completion code to `returnCode`. `ok` is true only
for code 0. The result also extracts `-errorinfo`, `-errorcode`, and `-errorline`
from the options dictionary when present. UTF-8 script input is limited to 1
MiB. The result, stdout, and stderr are each limited to 4 MiB of UTF-8 data and
carry independent truncation flags. These limits are protocol constants shared
by tests and API documentation rather than caller-configurable settings.

Capture runs the script on its Tcl/UI thread. Long or blocking scripts can make
Capture unresponsive, and neither an HTTP timeout nor client disconnection
stops an already claimed script.

## Command-Line Interface

The CLI locates and validates `%TEMP%/capture_tcl_bridge.json`, then invokes the
same HTTP API used by AI clients.

Supported forms are:

```powershell
python capture_tcl_cli.py status
python capture_tcl_cli.py -c "GetActiveDesign"
python capture_tcl_cli.py -f debug_script.tcl
Get-Content debug_script.tcl | python capture_tcl_cli.py
python capture_tcl_cli.py --json -c "expr {1 + 1}"
```

`-c`, `-f`, and piped stdin are mutually exclusive script sources. Without
`--json`, the CLI prints captured stdout and stderr, followed by a readable
result or error summary, and exits nonzero when the bridge request or Tcl
execution fails. With `--json`, it writes the complete API response without
human decoration.

## Security Model

The bridge does not sandbox Tcl. A valid token grants the same effective access
as typing into the Capture Tcl console, including filesystem and process access
available to Capture.

Security controls are:

- bind only to `127.0.0.1`;
- generate a new high-entropy bearer token for every server start;
- require the token on every endpoint;
- store discovery information in the current user's temporary directory;
- reject unexpected service identity, Capture PID, and protocol version;
- serialize execution to one command at a time;
- limit request and response memory use.

These controls prevent network access and accidental calls from unrelated local
pages or services. They do not protect against a malicious process already
running with the same Windows user permissions, because that process can read
the runtime descriptor or inspect the Capture environment.

## Error Semantics

Transport and bridge errors use non-200 HTTP statuses and stable symbolic error
codes. Tcl errors use HTTP 200 with `state: completed`, `ok: false`, a nonzero
`returnCode`, and Tcl error details. This distinction prevents an AI client from
mistaking a protocol failure for a Capture Tcl failure.

The server logs lifecycle and protocol failures without logging bearer tokens or
full submitted scripts. The Tcl module reports startup, shutdown, connection,
and protocol failures to the Capture console.

## Files

Create:

- `captureAiBridge.tcl`
- `capture_tcl_bridge_server.py`
- `capture_tcl_cli.py`
- `tests/test_capture_ai_bridge.tcl`
- `tests/test_capture_tcl_bridge_server.py`
- `tests/test_capture_tcl_cli.py`

Modify:

- `readme.md`
- `cpcode.bat` only if its existing wildcard deployment does not cover an
  implementation asset.

## Testing Strategy

Development follows test-driven development: each behavior receives a failing
test before production code.

Python API tests cover authentication, descriptor creation, atomic command
claiming, busy rejection, disconnected rejection, synchronous completion,
timeout and later lookup, bounded result retention, clean shutdown, port/service
identity handling, and Windows parent-process monitoring.

Tcl tests run under `tclsh` with HTTP calls isolated behind replaceable helper
procedures. They cover global and multi-line execution, result completion codes,
syntax and runtime failures, stdout, stderr, `puts -nonewline`, tee behavior,
ordinary file channels, guaranteed restoration of `puts`, polling scheduling,
and idempotent lifecycle commands.

CLI tests cover descriptor validation, `status`, command strings, UTF-8 script
files, stdin, mutual-exclusion errors, human-readable formatting, JSON output,
and process exit codes.

An integration test starts the real FastAPI service and a fake Tcl bridge to
prove complete HTTP and CLI round trips. Final manual acceptance in Capture
verifies:

1. source and explicitly start the bridge;
2. run a successful multi-line script through HTTP and CLI;
3. observe identical `puts` text in Capture and the client response;
4. run a failing Capture API call and inspect its Tcl stack information;
5. verify a concurrent request receives `BRIDGE_BUSY`;
6. stop the bridge and confirm the descriptor and server disappear;
7. restart and confirm the token changes;
8. exit Capture and confirm the server exits automatically.

## Acceptance Criteria

- AI clients can execute authenticated multi-line Tcl over localhost HTTP.
- Engineers can execute the same scripts through command, file, or stdin CLI
  input.
- Successful and failed executions return result, stdout, stderr, completion
  code, and available Tcl error details.
- Captured `puts` output remains visible in the Capture console.
- No command executes without the current random token.
- At most one command is pending or executing.
- HTTP timeout never claims that a still-running Tcl command was cancelled.
- Explicit stop and Capture exit both terminate the helper service.
- Automated API, Tcl, CLI, and integration tests pass.
