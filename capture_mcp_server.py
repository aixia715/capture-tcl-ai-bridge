"""MCP stdio server for reading and changing OrCAD Capture part properties.

The server intentionally exposes a narrow, typed surface instead of arbitrary Tcl.
It delegates each operation to the authenticated localhost Capture Tcl bridge.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, BinaryIO

from capture_tcl_cli import (
    BridgeClientError,
    SOFTWARE_VERSION,
    _validate_completed_result,
    default_runtime_file,
    load_descriptor,
    request_json,
)


SERVER_NAME = "capture-mcp"
SERVER_VERSION = SOFTWARE_VERSION
MODERN_PROTOCOL_VERSION = "2026-07-28"
LEGACY_PROTOCOL_VERSIONS = (
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
    "2025-11-25",
)
DEFAULT_PROPERTIES = ("Value", "Part Reference", "Part Name", "PCB Footprint")
MAX_MESSAGE_BYTES = 1024 * 1024
MAX_PROPERTY_NAME_LENGTH = 256
MAX_PROPERTY_VALUE_LENGTH = 64 * 1024
MAX_PROPERTIES_PER_READ = 32
MAX_RESULTS = 5000
SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"
PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"


class ToolExecutionError(RuntimeError):
    """A safe, actionable error that should be returned to the model."""


class InvalidToolArguments(ToolExecutionError):
    """A tool call failed local input validation."""


def _utf8_hex(value: str) -> str:
    return value.encode("utf-8", errors="strict").hex()


def _decode_hex(value: str) -> str:
    try:
        return bytes.fromhex(value).decode("utf-8", errors="strict")
    except (ValueError, UnicodeError) as error:
        raise ToolExecutionError("Capture returned malformed component data.") from error


def _tcl_decode_expression(value: str) -> str:
    # Hex is deliberately used instead of Tcl quoting. The generated token can only
    # contain [0-9a-f], so an MCP argument can never become Tcl syntax.
    return f"[_captureMcpDecode {{{_utf8_hex(value)}}}]"


_TCL_COMMON = r"""
proc _captureMcpDecode {hexValue} {
    return [encoding convertfrom utf-8 [binary format H* $hexValue]]
}

proc _captureMcpHex {value} {
    binary scan [encoding convertto utf-8 $value] H* encoded
    return $encoded
}

proc _captureMcpStatusMessage {st} {
    set msgC [DboTclHelper_sMakeCString]
    $st Message $msgC
    return [DboTclHelper_sGetConstCharPtr $msgC]
}

proc _captureMcpRequireOk {st what} {
    if {[$st OK] != 1} {
        error "DBO_CALL_FAILED: $what: [_captureMcpStatusMessage $st] (code [$st Code])"
    }
}

proc _captureMcpStringOut {obj method what} {
    set cstr [DboTclHelper_sMakeCString]
    set st [$obj $method $cstr]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: $what: [_captureMcpStatusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $cstr]
    $st -delete
    return $value
}

proc _captureMcpGetProp {obj propName} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: GetEffectivePropStringValue($propName): [_captureMcpStatusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    set value [DboTclHelper_sGetConstCharPtr $valueC]
    $st -delete
    return $value
}

proc _captureMcpSetProp {obj propName propValue} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString $propValue]
    set st [$obj SetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] != 1} {
        set msg "DBO_CALL_FAILED: SetEffectivePropStringValue($propName): [_captureMcpStatusMessage $st] (code [$st Code])"
        $st -delete
        error $msg
    }
    $st -delete
}

proc _captureMcpToInstOccurrence {occHandle} {
    set objType [DboBaseObject_GetObjectType $occHandle]
    if {$objType != $::DboBaseObject_INST_OCCURRENCE} {
        error "UNEXPECTED_OBJECT_TYPE: expected INST_OCCURRENCE, got object type $objType"
    }
    return [DboOccurrenceToDboInstOccurrence $occHandle]
}

proc _captureMcpMatches {refdes path useRefFilter targetRefdes usePathFilter targetPath} {
    if {$useRefFilter && $refdes ne $targetRefdes} { return 0 }
    if {$usePathFilter && $path ne $targetPath} { return 0 }
    return 1
}
"""


def build_read_script(
    refdes: str | None,
    path: str | None,
    property_names: list[str],
    max_results: int,
) -> str:
    properties = " ".join(_tcl_decode_expression(name) for name in property_names)
    target_refdes = _tcl_decode_expression(refdes or "")
    target_path = _tcl_decode_expression(path or "")
    return (
        _TCL_COMMON
        + rf"""
proc _captureMcpAppendRecord {{values outputVar}} {{
    upvar 1 $outputVar output
    set fields {{CAPTURE_MCP_V1}}
    foreach value $values {{ lappend fields [_captureMcpHex $value] }}
    if {{$output ne {{}}}} {{ append output "\n" }}
    append output [join $fields "\t"]
}}

proc _captureMcpReadWalk {{st occHandle propertyNames useRefFilter targetRefdes usePathFilter targetPath maxResults outputVar countVar truncatedVar}} {{
    upvar 1 $outputVar output $countVar count $truncatedVar truncated
    if {{$truncated}} {{ return }}
    set instOcc [_captureMcpToInstOccurrence $occHandle]
    set isPrimitive [$instOcc IsPrimitive $st]
    _captureMcpRequireOk $st {{IsPrimitive}}
    if {{$isPrimitive == 1}} {{
        set refdes [_captureMcpStringOut $instOcc GetReference {{GetReference}}]
        set path [_captureMcpStringOut $instOcc GetPathName {{GetPathName}}]
        if {{[_captureMcpMatches $refdes $path $useRefFilter $targetRefdes $usePathFilter $targetPath]}} {{
            if {{$count >= $maxResults}} {{
                set truncated 1
                return
            }}
            set record [list $refdes $path]
            foreach propertyName $propertyNames {{
                lappend record $propertyName [_captureMcpGetProp $instOcc $propertyName]
            }}
            _captureMcpAppendRecord $record output
            incr count
        }}
    }}

    set childrenIter [$instOcc NewChildrenIter $st $::IterDefs_INSTS]
    _captureMcpRequireOk $st {{NewChildrenIter}}
    $childrenIter Sort $st
    _captureMcpRequireOk $st {{Sort}}
    try {{
        while {{!$truncated}} {{
            set child [$childrenIter NextOccurrence $st]
            if {{$child eq {{NULL}}}} {{ break }}
            _captureMcpRequireOk $st {{NextOccurrence}}
            _captureMcpReadWalk $st $child $propertyNames $useRefFilter $targetRefdes $usePathFilter $targetPath $maxResults output count truncated
        }}
    }} finally {{
        delete_DboOccurrenceChildrenIter $childrenIter
    }}
}}

set _captureMcpProperties [list {properties}]
set _captureMcpTargetRefdes {target_refdes}
set _captureMcpTargetPath {target_path}
set _captureMcpOutput {{}}
set _captureMcpCount 0
set _captureMcpTruncated 0
set _captureMcpState [DboState]
try {{
    set _captureMcpDesign [GetActivePMDesign]
    if {{$_captureMcpDesign eq {{NULL}}}} {{
        error "NO_ACTIVE_DESIGN: open a design in Capture before using the MCP server"
    }}
    set _captureMcpRoot [$_captureMcpDesign GetRootOccurrence $_captureMcpState]
    _captureMcpRequireOk $_captureMcpState {{GetRootOccurrence}}
    _captureMcpReadWalk $_captureMcpState $_captureMcpRoot $_captureMcpProperties {int(refdes is not None)} $_captureMcpTargetRefdes {int(path is not None)} $_captureMcpTargetPath {max_results} _captureMcpOutput _captureMcpCount _captureMcpTruncated
}} finally {{
    $_captureMcpState -delete
}}
set _captureMcpMeta "CAPTURE_MCP_META_V1\t$_captureMcpCount\t$_captureMcpTruncated"
if {{$_captureMcpOutput eq {{}}}} {{
    set _captureMcpMeta
}} else {{
    append _captureMcpMeta "\n" $_captureMcpOutput
}}
"""
    )


def build_set_script(
    refdes: str,
    path: str | None,
    property_name: str,
    value: str,
) -> str:
    return (
        _TCL_COMMON
        + rf"""
proc _captureMcpFindWalk {{st occHandle targetRefdes usePathFilter targetPath matchesVar pathsVar}} {{
    upvar 1 $matchesVar matches $pathsVar paths
    set instOcc [_captureMcpToInstOccurrence $occHandle]
    set isPrimitive [$instOcc IsPrimitive $st]
    _captureMcpRequireOk $st {{IsPrimitive}}
    if {{$isPrimitive == 1}} {{
        set refdes [_captureMcpStringOut $instOcc GetReference {{GetReference}}]
        set path [_captureMcpStringOut $instOcc GetPathName {{GetPathName}}]
        if {{[_captureMcpMatches $refdes $path 1 $targetRefdes $usePathFilter $targetPath]}} {{
            lappend matches $instOcc
            lappend paths $path
        }}
    }}

    set childrenIter [$instOcc NewChildrenIter $st $::IterDefs_INSTS]
    _captureMcpRequireOk $st {{NewChildrenIter}}
    $childrenIter Sort $st
    _captureMcpRequireOk $st {{Sort}}
    try {{
        while {{1}} {{
            set child [$childrenIter NextOccurrence $st]
            if {{$child eq {{NULL}}}} {{ break }}
            _captureMcpRequireOk $st {{NextOccurrence}}
            _captureMcpFindWalk $st $child $targetRefdes $usePathFilter $targetPath matches paths
        }}
    }} finally {{
        delete_DboOccurrenceChildrenIter $childrenIter
    }}
}}

set _captureMcpTargetRefdes {_tcl_decode_expression(refdes)}
set _captureMcpTargetPath {_tcl_decode_expression(path or "")}
set _captureMcpPropertyName {_tcl_decode_expression(property_name)}
set _captureMcpPropertyValue {_tcl_decode_expression(value)}
set _captureMcpMatchesList {{}}
set _captureMcpPaths {{}}
set _captureMcpState [DboState]
try {{
    set _captureMcpDesign [GetActivePMDesign]
    if {{$_captureMcpDesign eq {{NULL}}}} {{
        error "NO_ACTIVE_DESIGN: open a design in Capture before using the MCP server"
    }}
    set _captureMcpRoot [$_captureMcpDesign GetRootOccurrence $_captureMcpState]
    _captureMcpRequireOk $_captureMcpState {{GetRootOccurrence}}
    _captureMcpFindWalk $_captureMcpState $_captureMcpRoot $_captureMcpTargetRefdes {int(path is not None)} $_captureMcpTargetPath _captureMcpMatchesList _captureMcpPaths
}} finally {{
    $_captureMcpState -delete
}}

set _captureMcpMatchCount [llength $_captureMcpMatchesList]
if {{$_captureMcpMatchCount == 0}} {{
    error "COMPONENT_NOT_FOUND: no component matched the supplied reference designator and path"
}}
if {{$_captureMcpMatchCount > 1}} {{
    error "COMPONENT_NOT_UNIQUE: $_captureMcpMatchCount components matched; supply the exact hierarchical path"
}}

set _captureMcpTarget [lindex $_captureMcpMatchesList 0]
set _captureMcpMatchedPath [lindex $_captureMcpPaths 0]
set _captureMcpBefore [_captureMcpGetProp $_captureMcpTarget $_captureMcpPropertyName]
_captureMcpSetProp $_captureMcpTarget $_captureMcpPropertyName $_captureMcpPropertyValue
set _captureMcpAfter [_captureMcpGetProp $_captureMcpTarget $_captureMcpPropertyName]
if {{$_captureMcpAfter ne $_captureMcpPropertyValue}} {{
    error "PROPERTY_WRITE_FAILED: property readback does not match the requested value"
}}
join [list CAPTURE_MCP_SET_V1 [_captureMcpHex $_captureMcpTargetRefdes] [_captureMcpHex $_captureMcpMatchedPath] [_captureMcpHex $_captureMcpPropertyName] [_captureMcpHex $_captureMcpBefore] [_captureMcpHex $_captureMcpAfter]] "\t"
"""
    )


def _execute_capture_script(runtime_file: Path, script: str) -> str:
    try:
        descriptor = load_descriptor(runtime_file)
        response = request_json(
            descriptor,
            "POST",
            "/v1/execute",
            {"script": script},
        )
        _validate_completed_result(response)
    except BridgeClientError as error:
        raise ToolExecutionError(str(error)) from error

    if any(
        response[field]
        for field in ("resultTruncated", "stdoutTruncated", "stderrTruncated")
    ):
        raise ToolExecutionError("Capture truncated the operation result; narrow the request.")
    if not response["ok"]:
        message = response["result"].strip() or "Capture Tcl operation failed."
        if response["errorInfo"] and response["errorInfo"].strip() != message:
            message = f"{message}\n{response['errorInfo'].strip()}"
        token = descriptor.get("token", "")
        if isinstance(token, str) and token:
            message = message.replace(token, "[redacted]")
        raise ToolExecutionError(message)
    return response["result"]


def _parse_read_result(raw: str, property_names: list[str]) -> dict[str, Any]:
    lines = raw.splitlines()
    if not lines:
        raise ToolExecutionError("Capture returned an empty component result.")
    meta = lines[0].split("\t")
    if len(meta) != 3 or meta[0] != "CAPTURE_MCP_META_V1":
        raise ToolExecutionError("Capture returned malformed component metadata.")
    try:
        count = int(meta[1])
        truncated_number = int(meta[2])
    except ValueError as error:
        raise ToolExecutionError("Capture returned malformed component metadata.") from error
    if count < 0 or truncated_number not in (0, 1) or count != len(lines) - 1:
        raise ToolExecutionError("Capture returned inconsistent component metadata.")

    components: list[dict[str, Any]] = []
    expected_fields = 3 + 2 * len(property_names)
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != expected_fields or fields[0] != "CAPTURE_MCP_V1":
            raise ToolExecutionError("Capture returned malformed component data.")
        decoded = [_decode_hex(field) for field in fields[1:]]
        properties: dict[str, str] = {}
        for index in range(2, len(decoded), 2):
            name, value = decoded[index], decoded[index + 1]
            if name != property_names[(index - 2) // 2]:
                raise ToolExecutionError("Capture returned properties in an unexpected order.")
            properties[name] = value
        components.append(
            {"refdes": decoded[0], "path": decoded[1], "properties": properties}
        )
    return {"components": components, "count": count, "truncated": bool(truncated_number)}


def _parse_set_result(raw: str) -> dict[str, str]:
    fields = raw.split("\t")
    if len(fields) != 6 or fields[0] != "CAPTURE_MCP_SET_V1":
        raise ToolExecutionError("Capture returned malformed property-write data.")
    decoded = [_decode_hex(field) for field in fields[1:]]
    return {
        "refdes": decoded[0],
        "path": decoded[1],
        "property": decoded[2],
        "before": decoded[3],
        "after": decoded[4],
    }


def _string_argument(
    arguments: dict[str, Any],
    name: str,
    *,
    required: bool = False,
    max_length: int = MAX_PROPERTY_VALUE_LENGTH,
) -> str | None:
    value = arguments.get(name)
    if value is None and not required:
        return None
    if type(value) is not str:
        raise InvalidToolArguments(f"{name} must be a string.")
    if not value:
        raise InvalidToolArguments(f"{name} must not be empty.")
    try:
        encoded = value.encode("utf-8", errors="strict")
    except UnicodeError as error:
        raise InvalidToolArguments(f"{name} must be valid UTF-8 text.") from error
    if b"\x00" in encoded:
        raise InvalidToolArguments(f"{name} must not contain a NUL character.")
    if len(value) > max_length:
        raise InvalidToolArguments(f"{name} is too long.")
    return value


def _validate_arguments_object(arguments: Any) -> dict[str, Any]:
    if arguments is None:
        return {}
    if type(arguments) is not dict:
        raise InvalidToolArguments("Tool arguments must be a JSON object.")
    return arguments


def read_component_properties(runtime_file: Path, arguments: Any) -> dict[str, Any]:
    values = _validate_arguments_object(arguments)
    allowed = {"refdes", "path", "property_names", "max_results"}
    unknown = sorted(set(values) - allowed)
    if unknown:
        raise InvalidToolArguments(f"Unknown argument(s): {', '.join(unknown)}.")
    refdes = _string_argument(values, "refdes", max_length=256)
    path = _string_argument(values, "path", max_length=4096)

    raw_names = values.get("property_names", list(DEFAULT_PROPERTIES))
    if type(raw_names) is not list or not raw_names:
        raise InvalidToolArguments("property_names must be a non-empty array.")
    if len(raw_names) > MAX_PROPERTIES_PER_READ:
        raise InvalidToolArguments(
            f"property_names accepts at most {MAX_PROPERTIES_PER_READ} names."
        )
    property_names: list[str] = []
    seen: set[str] = set()
    for raw_name in raw_names:
        temporary = {"property_name": raw_name}
        name = _string_argument(
            temporary,
            "property_name",
            required=True,
            max_length=MAX_PROPERTY_NAME_LENGTH,
        )
        assert name is not None
        if name in seen:
            raise InvalidToolArguments(f"Duplicate property name: {name}.")
        seen.add(name)
        property_names.append(name)

    max_results = values.get("max_results", 500)
    if type(max_results) is not int or not 1 <= max_results <= MAX_RESULTS:
        raise InvalidToolArguments(
            f"max_results must be an integer from 1 through {MAX_RESULTS}."
        )
    script = build_read_script(refdes, path, property_names, max_results)
    raw = _execute_capture_script(runtime_file, script)
    return _parse_read_result(raw, property_names)


def set_component_property(runtime_file: Path, arguments: Any) -> dict[str, str]:
    values = _validate_arguments_object(arguments)
    allowed = {"refdes", "path", "property_name", "value"}
    unknown = sorted(set(values) - allowed)
    if unknown:
        raise InvalidToolArguments(f"Unknown argument(s): {', '.join(unknown)}.")
    refdes = _string_argument(values, "refdes", required=True, max_length=256)
    path = _string_argument(values, "path", max_length=4096)
    property_name = _string_argument(
        values,
        "property_name",
        required=True,
        max_length=MAX_PROPERTY_NAME_LENGTH,
    )
    # Empty property values are legal, so validate this field separately.
    if "value" not in values or type(values["value"]) is not str:
        raise InvalidToolArguments("value must be a string.")
    value = values["value"]
    try:
        encoded_value = value.encode("utf-8", errors="strict")
    except UnicodeError as error:
        raise InvalidToolArguments("value must be valid UTF-8 text.") from error
    if b"\x00" in encoded_value:
        raise InvalidToolArguments("value must not contain a NUL character.")
    if len(value) > MAX_PROPERTY_VALUE_LENGTH:
        raise InvalidToolArguments("value is too long.")
    assert refdes is not None and property_name is not None
    script = build_set_script(refdes, path, property_name, value)
    raw = _execute_capture_script(runtime_file, script)
    return _parse_set_result(raw)


READ_TOOL = {
    "name": "capture_read_component_properties",
    "title": "Read Capture component properties",
    "description": (
        "Read effective string properties from components in the active OrCAD Capture "
        "design. Omit refdes/path to list components. A repeated refdes can be narrowed "
        "with the exact hierarchical path returned by this tool."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "refdes": {"type": "string", "minLength": 1},
            "path": {"type": "string", "minLength": 1},
            "property_names": {
                "type": "array",
                "minItems": 1,
                "maxItems": MAX_PROPERTIES_PER_READ,
                "items": {"type": "string", "minLength": 1},
                "default": list(DEFAULT_PROPERTIES),
            },
            "max_results": {
                "type": "integer",
                "minimum": 1,
                "maximum": MAX_RESULTS,
                "default": 500,
            },
        },
        "additionalProperties": False,
    },
    "annotations": {
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
}

SET_TOOL = {
    "name": "capture_set_component_property",
    "title": "Set a Capture component property",
    "description": (
        "Set one effective string property on exactly one component in the active "
        "OrCAD Capture design and verify it by immediate readback. The design is not "
        "saved. Supply path when refdes is not unique."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "refdes": {"type": "string", "minLength": 1},
            "path": {"type": "string", "minLength": 1},
            "property_name": {"type": "string", "minLength": 1},
            "value": {"type": "string"},
        },
        "required": ["refdes", "property_name", "value"],
        "additionalProperties": False,
    },
    "annotations": {
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": True,
        "openWorldHint": False,
    },
}


def _server_meta() -> dict[str, Any]:
    return {SERVER_INFO_META_KEY: {"name": SERVER_NAME, "version": SERVER_VERSION}}


def _modern_request(message: dict[str, Any]) -> bool:
    params = message.get("params")
    return (
        type(params) is dict
        and type(params.get("_meta")) is dict
        and params["_meta"].get(PROTOCOL_VERSION_META_KEY) == MODERN_PROTOCOL_VERSION
    )


def _complete_result(value: dict[str, Any], modern: bool) -> dict[str, Any]:
    if not modern:
        return value
    return {"resultType": "complete", **value, "_meta": _server_meta()}


def _tool_result(value: dict[str, Any], modern: bool) -> dict[str, Any]:
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return _complete_result(
        {
            "content": [{"type": "text", "text": text}],
            "structuredContent": value,
        },
        modern,
    )


def _tool_error(message: str, modern: bool) -> dict[str, Any]:
    return _complete_result(
        {"content": [{"type": "text", "text": message}], "isError": True}, modern
    )


class CaptureMcpServer:
    def __init__(self, runtime_file: Path) -> None:
        self.runtime_file = runtime_file
        self.legacy_protocol: str | None = None

    def handle(self, message: Any) -> dict[str, Any] | None:
        if type(message) is not dict or message.get("jsonrpc") != "2.0":
            return self._error(None, -32600, "Invalid Request")
        request_id = message.get("id")
        method = message.get("method")
        if type(method) is not str:
            return self._error(request_id, -32600, "Invalid Request")
        is_notification = "id" not in message
        modern = _modern_request(message) or method == "server/discover"
        requested_protocol = self._request_protocol(message)

        if method == "notifications/initialized":
            return None
        if method.startswith("notifications/"):
            return None
        if is_notification:
            return None

        if method == "initialize":
            return self._initialize(request_id, message.get("params"))
        if method == "server/discover":
            result = {
                "supportedVersions": [MODERN_PROTOCOL_VERSION],
                "capabilities": {"tools": {}},
                "instructions": self._instructions(),
                "ttlMs": 86_400_000,
                "cacheScope": "public",
            }
            return self._success(request_id, _complete_result(result, True))
        if requested_protocol is not None and requested_protocol != MODERN_PROTOCOL_VERSION:
            return self._error(
                request_id,
                -32022,
                f"Unsupported protocol version; expected {MODERN_PROTOCOL_VERSION}.",
            )
        if modern and not self._valid_modern_envelope(message):
            return self._error(
                request_id,
                -32022,
                f"Unsupported protocol version; expected {MODERN_PROTOCOL_VERSION}.",
            )
        if method == "ping":
            return self._success(request_id, _complete_result({}, modern))
        if method == "tools/list":
            result: dict[str, Any] = {"tools": [READ_TOOL, SET_TOOL]}
            if modern:
                result.update({"ttlMs": 86_400_000, "cacheScope": "public"})
            return self._success(request_id, _complete_result(result, modern))
        if method == "tools/call":
            return self._call_tool(request_id, message.get("params"), modern)
        return self._error(request_id, -32601, f"Method not found: {method}")

    def _initialize(self, request_id: Any, params: Any) -> dict[str, Any]:
        if type(params) is not dict or type(params.get("protocolVersion")) is not str:
            return self._error(request_id, -32602, "Invalid initialize parameters.")
        requested = params["protocolVersion"]
        negotiated = (
            requested
            if requested in LEGACY_PROTOCOL_VERSIONS
            else LEGACY_PROTOCOL_VERSIONS[-1]
        )
        self.legacy_protocol = negotiated
        return self._success(
            request_id,
            {
                "protocolVersion": negotiated,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": self._instructions(),
            },
        )

    @staticmethod
    def _instructions() -> str:
        return (
            "Operate only on the active OrCAD Capture design. Read components first "
            "when identity or current values are uncertain. Writes change in-memory "
            "properties and verify readback, but never save the design. If a refdes is "
            "ambiguous, retry with the exact path returned by the read tool."
        )

    @staticmethod
    def _request_protocol(message: dict[str, Any]) -> Any | None:
        params = message.get("params")
        if type(params) is not dict or type(params.get("_meta")) is not dict:
            return None
        return params["_meta"].get(PROTOCOL_VERSION_META_KEY)

    @staticmethod
    def _valid_modern_envelope(message: dict[str, Any]) -> bool:
        params = message.get("params")
        if type(params) is not dict or type(params.get("_meta")) is not dict:
            return False
        return params["_meta"].get(PROTOCOL_VERSION_META_KEY) == MODERN_PROTOCOL_VERSION

    def _call_tool(
        self, request_id: Any, params: Any, modern: bool
    ) -> dict[str, Any]:
        if type(params) is not dict or type(params.get("name")) is not str:
            return self._error(request_id, -32602, "Invalid tool call parameters.")
        name = params["name"]
        arguments = params.get("arguments", {})
        try:
            if name == READ_TOOL["name"]:
                value = read_component_properties(self.runtime_file, arguments)
            elif name == SET_TOOL["name"]:
                value = set_component_property(self.runtime_file, arguments)
            else:
                return self._error(request_id, -32602, f"Unknown tool: {name}")
        except (InvalidToolArguments, ToolExecutionError) as error:
            return self._success(request_id, _tool_error(str(error), modern))
        except Exception:
            print("capture-mcp: unexpected tool failure", file=sys.stderr)
            return self._success(
                request_id,
                _tool_error("Unexpected Capture MCP server failure.", modern),
            )
        return self._success(request_id, _tool_result(value, modern))

    @staticmethod
    def _success(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(
        request_id: Any, code: int, message: str, data: Any | None = None
    ) -> dict[str, Any]:
        error: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        return {"jsonrpc": "2.0", "id": request_id, "error": error}


def serve_stdio(
    server: CaptureMcpServer,
    input_stream: BinaryIO | None = None,
    output_stream: BinaryIO | None = None,
) -> int:
    input_stream = input_stream or sys.stdin.buffer
    output_stream = output_stream or sys.stdout.buffer
    while True:
        line = input_stream.readline(MAX_MESSAGE_BYTES + 1)
        if line == b"":
            return 0
        if len(line) > MAX_MESSAGE_BYTES:
            response = CaptureMcpServer._error(None, -32700, "MCP message is too large.")
            output_stream.write(
                json.dumps(response, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
                + b"\n"
            )
            output_stream.flush()
            return 1
        if not line.strip():
            continue
        try:
            message = json.loads(line.decode("utf-8", errors="strict"))
        except (UnicodeError, json.JSONDecodeError):
            response = CaptureMcpServer._error(None, -32700, "Parse error")
        else:
            response = server.handle(message)
        if response is None:
            continue
        encoded = json.dumps(
            response, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8", errors="strict")
        output_stream.write(encoded + b"\n")
        output_stream.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Expose OrCAD Capture component properties through MCP over stdio."
    )
    parser.add_argument(
        "--runtime-file",
        type=Path,
        default=default_runtime_file(),
        help="Capture Tcl bridge runtime descriptor (defaults to %%TEMP%%).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    return serve_stdio(CaptureMcpServer(arguments.runtime_file))


if __name__ == "__main__":
    raise SystemExit(main())
