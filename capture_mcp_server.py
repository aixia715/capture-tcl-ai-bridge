"""MCP stdio server for inspecting OrCAD Capture and changing part properties.

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
DEFAULT_PROPERTIES = ("Value", "PCB Footprint")
MAX_MESSAGE_BYTES = 1024 * 1024
MAX_PROPERTY_NAME_LENGTH = 256
MAX_PROPERTY_VALUE_LENGTH = 64 * 1024
MAX_PROPERTIES_PER_READ = 32
MAX_RESULTS = 5000
MAX_SELECTION_RESULTS = 1000
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

proc _captureMcpReadPropertyRecord {obj propName} {
    set nameC [DboTclHelper_sMakeCString $propName]
    set valueC [DboTclHelper_sMakeCString]
    set st [$obj GetEffectivePropStringValue $nameC $valueC]
    if {[$st OK] == 1} {
        set value [DboTclHelper_sGetConstCharPtr $valueC]
        $st -delete
        return [list 1 $value]
    }
    set code [$st Code]
    if {$code == 1021} {
        $st -delete
        return [list 0 {}]
    }
    set msg [_captureMcpStatusMessage $st]
    $st -delete
    error "DBO_CALL_FAILED: GetEffectivePropStringValue($propName): $msg (code $code)"
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


proc _captureMcpComponentFields {st instOcc propertyNames designName pageObject pageName} {
    set refdes [_captureMcpStringOut $instOcc GetReference {GetReference}]
    set path [_captureMcpStringOut $instOcc GetPathName {GetPathName}]
    if {$pageObject eq {NULL}} {
        set pageObject [$instOcc GetPartInst $st]
        _captureMcpRequireOk $st {GetPartInst}
        if {$pageObject eq {NULL}} {
            error "PAGE_INSTANCE_NOT_FOUND: component occurrence has no page instance"
        }
        set pageOwner [$pageObject GetOwner]
        if {$pageOwner eq {NULL}} {
            error "PAGE_NOT_FOUND: component page instance has no owner"
        }
        set pageNameC [DboTclHelper_sMakeCString]
        DboBaseObject_GetName $pageOwner $pageNameC
        set pageName [DboTclHelper_sGetConstCharPtr $pageNameC]
    }
    set pageType [DboBaseObject_GetObjectType $pageObject]
    if {$pageType != $::DboBaseObject_DRAWN_INSTANCE &&
            $pageType != $::DboBaseObject_PLACED_INSTANCE} {
        error "UNEXPECTED_PAGE_INSTANCE_TYPE: expected DRAWN_INSTANCE or PLACED_INSTANCE, got object type $pageType"
    }
    set objectId [DboBaseObject_GetId $pageObject $st]
    _captureMcpRequireOk $st {GetId}
    set fields [list \
        design $designName \
        occurrence.refdes $refdes \
        occurrence.path $path \
        page_instance.page $pageName \
        page_instance.object_id $objectId]
    foreach propertyName $propertyNames {
        lassign [_captureMcpReadPropertyRecord $instOcc $propertyName] present value
        lappend fields "property_present:$propertyName" $present
        if {$present} {
            lappend fields "property_value:$propertyName" $value
        }
    }
    return $fields
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
proc _captureMcpAppendRecord {{fields outputVar}} {{
    upvar 1 $outputVar output
    set row [list CAPTURE_MCP_COMPONENT_V2 [expr {{[llength $fields] / 2}}]]
    foreach {{key value}} $fields {{
        lappend row [_captureMcpHex $key] [_captureMcpHex $value]
    }}
    if {{$output ne {{}}}} {{ append output "\n" }}
    append output [join $row "\t"]
}}

proc _captureMcpReadWalk {{st occHandle propertyNames designName useRefFilter targetRefdes usePathFilter targetPath maxResults outputVar countVar truncatedVar}} {{
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
            set fields [_captureMcpComponentFields $st $instOcc $propertyNames $designName NULL {{}}]
            _captureMcpAppendRecord $fields output
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
            _captureMcpReadWalk $st $child $propertyNames $designName $useRefFilter $targetRefdes $usePathFilter $targetPath $maxResults output count truncated
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
    set _captureMcpDesignNameC [DboTclHelper_sMakeCString]
    DboBaseObject_GetName $_captureMcpDesign $_captureMcpDesignNameC
    set _captureMcpDesignName [DboTclHelper_sGetConstCharPtr $_captureMcpDesignNameC]
    _captureMcpReadWalk $_captureMcpState $_captureMcpRoot $_captureMcpProperties $_captureMcpDesignName {int(refdes is not None)} $_captureMcpTargetRefdes {int(path is not None)} $_captureMcpTargetPath {max_results} _captureMcpOutput _captureMcpCount _captureMcpTruncated
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


def build_inspect_selection_script(
    property_names: list[str], max_results: int
) -> str:
    properties = " ".join(_tcl_decode_expression(name) for name in property_names)
    return (
        _TCL_COMMON
        + rf"""
proc _captureMcpAppendSelectionRecord {{index kind rawType supported fields outputVar}} {{
    upvar 1 $outputVar output
    set row [list CAPTURE_MCP_SELECTION_V1 $index [_captureMcpHex $kind] $rawType $supported [expr {{[llength $fields] / 2}}]]
    foreach {{key value}} $fields {{
        lappend row [_captureMcpHex $key] [_captureMcpHex $value]
    }}
    if {{$output ne {{}}}} {{ append output "\n" }}
    append output [join $row "\t"]
}}

proc _captureMcpBaseName {{obj}} {{
    set valueC [DboTclHelper_sMakeCString]
    DboBaseObject_GetName $obj $valueC
    return [DboTclHelper_sGetConstCharPtr $valueC]
}}

proc _captureMcpLocatorFields {{st obj designName pageName kind}} {{
    set objectId [DboBaseObject_GetId $obj $st]
    _captureMcpRequireOk $st {{GetId}}
    return [list locator.design $designName locator.page $pageName locator.kind $kind locator.object_id $objectId]
}}

proc _captureMcpPointFields {{prefix point}} {{
    return [list "$prefix.x" [DboTclHelper_sGetCPointX $point] "$prefix.y" [DboTclHelper_sGetCPointY $point]]
}}

proc _captureMcpObjectErrorCode {{message}} {{
    if {{[regexp {{^([A-Z][A-Z0-9_]*):}} $message _ code]}} {{ return $code }}
    return OBJECT_INSPECTION_FAILED
}}

set _captureMcpProperties [list {properties}]
set _captureMcpDesign [GetActivePMDesign]
if {{$_captureMcpDesign eq {{NULL}}}} {{
    error "NO_ACTIVE_DESIGN: open a design in Capture before using the MCP server"
}}
set _captureMcpPage [GetActivePage]
set _captureMcpParentOccurrence [GetInstanceOccurrence]
if {{$_captureMcpPage eq {{NULL}} || $_captureMcpParentOccurrence eq {{NULL}}}} {{
    error "SCHEMATIC_VIEW_REQUIRED: focus an open schematic page before inspecting selection"
}}
set _captureMcpDesignNameC [DboTclHelper_sMakeCString]
DboBaseObject_GetName $_captureMcpDesign $_captureMcpDesignNameC
set _captureMcpDesignName [DboTclHelper_sGetConstCharPtr $_captureMcpDesignNameC]
set _captureMcpPageNameC [DboTclHelper_sMakeCString]
DboBaseObject_GetName $_captureMcpPage $_captureMcpPageNameC
set _captureMcpPageName [DboTclHelper_sGetConstCharPtr $_captureMcpPageNameC]
set _captureMcpSelected [GetSelectedObjects]
set _captureMcpSelectionCount [llength $_captureMcpSelected]
set _captureMcpReturnedCount [expr {{$_captureMcpSelectionCount < {max_results} ? $_captureMcpSelectionCount : {max_results}}}]
set _captureMcpTruncated [expr {{$_captureMcpSelectionCount > {max_results}}}]
set _captureMcpOutput {{}}
set _captureMcpState [DboState]
try {{
    for {{set _captureMcpIndex 0}} {{$_captureMcpIndex < $_captureMcpReturnedCount}} {{incr _captureMcpIndex}} {{
        set _captureMcpObject [lindex $_captureMcpSelected $_captureMcpIndex]
        set _captureMcpType [DboBaseObject_GetObjectType $_captureMcpObject]
        set _captureMcpKind unknown
        set _captureMcpSupported 0
        if {{[catch {{
        if {{$_captureMcpType == $::DboBaseObject_DRAWN_INSTANCE ||
                $_captureMcpType == $::DboBaseObject_PLACED_INSTANCE}} {{
            set _captureMcpKind component
            set _captureMcpSupported 1
            set _captureMcpOccurrence [$_captureMcpObject GetObjectOccurrence $_captureMcpParentOccurrence]
            if {{$_captureMcpOccurrence eq {{NULL}}}} {{
                error "COMPONENT_OCCURRENCE_NOT_FOUND: selected page instance has no occurrence in the active hierarchy"
            }}
            set _captureMcpInstOccurrence [_captureMcpToInstOccurrence $_captureMcpOccurrence]
            set _captureMcpPrimitive [$_captureMcpInstOccurrence IsPrimitive $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{IsPrimitive}}
            if {{$_captureMcpPrimitive == 1}} {{
                set _captureMcpFields [_captureMcpComponentFields $_captureMcpState $_captureMcpInstOccurrence $_captureMcpProperties $_captureMcpDesignName $_captureMcpObject $_captureMcpPageName]
                _captureMcpAppendSelectionRecord $_captureMcpIndex component $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
            }} else {{
                set _captureMcpKind hierarchical_block
                set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
                set _captureMcpName [_captureMcpBaseName $_captureMcpObject]
                set _captureMcpPath [_captureMcpStringOut $_captureMcpInstOccurrence GetPathName {{GetPathName}}]
                lassign [_captureMcpReadPropertyRecord $_captureMcpInstOccurrence {{Implementation Type}}] _captureMcpPresent _captureMcpImplementationType
                if {{!$_captureMcpPresent}} {{ set _captureMcpImplementationType {{}} }}
                lappend _captureMcpFields name $_captureMcpName path $_captureMcpPath implementation_type $_captureMcpImplementationType
                _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
            }}
        }} elseif {{$_captureMcpType == $::DboBaseObject_WIRE_SCALAR ||
                $_captureMcpType == $::DboBaseObject_WIRE_BUS}} {{
            set _captureMcpKind wire
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            set _captureMcpWireKind [expr {{$_captureMcpType == $::DboBaseObject_WIRE_BUS ? {{bus}} : {{scalar}}}}]
            set _captureMcpNet [$_captureMcpObject GetNet $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetNet}}
            set _captureMcpNetName {{}}
            if {{$_captureMcpNet ne {{NULL}}}} {{
                set _captureMcpNetName [_captureMcpStringOut $_captureMcpNet GetName {{GetName(net)}}]
            }}
            set _captureMcpStart [$_captureMcpObject GetStartPoint $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetStartPoint}}
            set _captureMcpEnd [$_captureMcpObject GetEndPoint $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetEndPoint}}
            lappend _captureMcpFields wire_kind $_captureMcpWireKind net $_captureMcpNetName
            set _captureMcpFields [concat $_captureMcpFields [_captureMcpPointFields start $_captureMcpStart] [_captureMcpPointFields end $_captureMcpEnd]]
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} elseif {{$_captureMcpType == $::DboBaseObject_GLOBAL_SYMBOL}} {{
            set _captureMcpKind global
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            set _captureMcpPinType [$_captureMcpObject GetPinType $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetPinType}}
            lappend _captureMcpFields name [_captureMcpBaseName $_captureMcpObject] pin_type $_captureMcpPinType
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} elseif {{$_captureMcpType == $::DboBaseObject_OFF_PAGE_CONNECTOR}} {{
            set _captureMcpKind off_page_connector
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            set _captureMcpLocation [$_captureMcpObject GetLocation $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetLocation}}
            lappend _captureMcpFields name [_captureMcpBaseName $_captureMcpObject]
            set _captureMcpFields [concat $_captureMcpFields [_captureMcpPointFields location $_captureMcpLocation]]
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} elseif {{$_captureMcpType == $::DboBaseObject_COMMENT_TEXT ||
                ([info exists ::DboBaseObject_GRAPHIC_COMMENTTEXT_INST] && $_captureMcpType == $::DboBaseObject_GRAPHIC_COMMENTTEXT_INST)}} {{
            set _captureMcpKind comment_text
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            lappend _captureMcpFields text [_captureMcpBaseName $_captureMcpObject]
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} elseif {{$_captureMcpType == $::DboBaseObject_PORT_INSTANCE}} {{
            set _captureMcpKind port
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            set _captureMcpPinType [$_captureMcpObject GetPinType $_captureMcpState]
            _captureMcpRequireOk $_captureMcpState {{GetPinType}}
            lappend _captureMcpFields name [_captureMcpBaseName $_captureMcpObject] pin_type $_captureMcpPinType
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} elseif {{$_captureMcpType == $::DboBaseObject_TITLEBLOCK_INSTANCE}} {{
            set _captureMcpKind title_block
            set _captureMcpSupported 1
            set _captureMcpFields [_captureMcpLocatorFields $_captureMcpState $_captureMcpObject $_captureMcpDesignName $_captureMcpPageName $_captureMcpKind]
            lappend _captureMcpFields page_name $_captureMcpPageName
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType 1 $_captureMcpFields _captureMcpOutput
        }} else {{
            _captureMcpAppendSelectionRecord $_captureMcpIndex unknown $_captureMcpType 0 {{}} _captureMcpOutput
        }}
        }} _captureMcpObjectError]}} {{
            set _captureMcpErrorFields [list error.code [_captureMcpObjectErrorCode $_captureMcpObjectError] error.message $_captureMcpObjectError]
            _captureMcpAppendSelectionRecord $_captureMcpIndex $_captureMcpKind $_captureMcpType $_captureMcpSupported $_captureMcpErrorFields _captureMcpOutput
        }}
    }}
}} finally {{
    $_captureMcpState -delete
}}
set _captureMcpMeta [join [list CAPTURE_MCP_SELECTION_META_V1 $_captureMcpSelectionCount $_captureMcpReturnedCount $_captureMcpTruncated [_captureMcpHex $_captureMcpDesignName] [_captureMcpHex $_captureMcpPageName]] "\t"]
if {{$_captureMcpOutput eq {{}}}} {{
    set _captureMcpMeta
}} else {{
    append _captureMcpMeta "\n" $_captureMcpOutput
}}
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
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 2 or fields[0] != "CAPTURE_MCP_COMPONENT_V2":
            raise ToolExecutionError("Capture returned malformed component data.")
        try:
            field_count = int(fields[1])
        except ValueError as error:
            raise ToolExecutionError("Capture returned malformed component data.") from error
        if field_count < 0 or len(fields) != 2 + field_count * 2:
            raise ToolExecutionError("Capture returned malformed component data.")
        decoded_fields = _parse_key_value_fields(fields, 2, "component")
        component = _component_information(decoded_fields, property_names)
        if decoded_fields:
            raise ToolExecutionError("Capture returned unexpected component fields.")
        components.append(component)
    return {"components": components, "count": count, "truncated": bool(truncated_number)}


def _parse_key_value_fields(
    values: list[str], start: int, record_name: str
) -> dict[str, str]:
    fields: dict[str, str] = {}
    for field_index in range(start, len(values), 2):
        key = _decode_hex(values[field_index])
        if key in fields:
            raise ToolExecutionError(
                f"Capture returned duplicate {record_name} fields."
            )
        fields[key] = _decode_hex(values[field_index + 1])
    return fields


def _component_information(
    fields: dict[str, str], property_names: list[str]
) -> dict[str, Any]:
    try:
        component: dict[str, Any] = {
            "kind": "component",
            "design": fields.pop("design"),
            "occurrence": {
                "refdes": fields.pop("occurrence.refdes"),
                "path": fields.pop("occurrence.path"),
            },
            "page_instance": {
                "page": fields.pop("page_instance.page"),
                "object_id": int(fields.pop("page_instance.object_id")),
            },
        }
    except (KeyError, ValueError) as error:
        raise ToolExecutionError("Capture returned malformed component data.") from error
    properties: dict[str, dict[str, Any]] = {}
    for name in property_names:
        present_key = f"property_present:{name}"
        present_raw = fields.pop(present_key, None)
        if present_raw not in ("0", "1"):
            raise ToolExecutionError("Capture returned malformed property data.")
        if present_raw == "1":
            value_key = f"property_value:{name}"
            if value_key not in fields:
                raise ToolExecutionError("Capture returned malformed property data.")
            properties[name] = {"present": True, "value": fields.pop(value_key)}
        else:
            properties[name] = {"present": False}
    component["properties"] = properties
    return component


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


def _parse_selection_result(raw: str, property_names: list[str]) -> dict[str, Any]:
    lines = raw.splitlines()
    if not lines:
        raise ToolExecutionError("Capture returned an empty selection result.")
    meta = lines[0].split("\t")
    if len(meta) != 6 or meta[0] != "CAPTURE_MCP_SELECTION_META_V1":
        raise ToolExecutionError("Capture returned malformed selection metadata.")
    try:
        selection_count = int(meta[1])
        returned_count = int(meta[2])
        truncated_number = int(meta[3])
    except ValueError as error:
        raise ToolExecutionError("Capture returned malformed selection metadata.") from error
    if (
        selection_count < 0
        or returned_count < 0
        or returned_count > selection_count
        or truncated_number not in (0, 1)
        or bool(truncated_number) != (returned_count < selection_count)
        or returned_count != len(lines) - 1
    ):
        raise ToolExecutionError("Capture returned inconsistent selection metadata.")
    objects: list[dict[str, Any]] = []
    for line in lines[1:]:
        values = line.split("\t")
        if len(values) < 6 or values[0] != "CAPTURE_MCP_SELECTION_V1":
            raise ToolExecutionError("Capture returned malformed selection data.")
        try:
            selection_index = int(values[1])
            raw_capture_type = int(values[3])
            supported_number = int(values[4])
            field_count = int(values[5])
        except ValueError as error:
            raise ToolExecutionError("Capture returned malformed selection data.") from error
        if (
            selection_index < 0
            or selection_index != len(objects)
            or supported_number not in (0, 1)
            or field_count < 0
            or len(values) != 6 + field_count * 2
        ):
            raise ToolExecutionError("Capture returned malformed selection data.")
        kind = _decode_hex(values[2])
        fields = _parse_key_value_fields(values, 6, "selection")
        record: dict[str, Any] = {
            "selection_index": selection_index,
            "kind": kind,
            "raw_capture_type": raw_capture_type,
            "supported": bool(supported_number),
        }
        if "error.code" in fields:
            try:
                record["error"] = {
                    "code": fields.pop("error.code"),
                    "message": fields.pop("error.message"),
                }
            except KeyError as error:
                raise ToolExecutionError(
                    "Capture returned malformed selection object error."
                ) from error
        elif kind == "component" and supported_number:
            component = _component_information(fields, property_names)
            component.pop("kind")
            record.update(component)
        elif supported_number:
            try:
                record["locator"] = {
                    "design": fields.pop("locator.design"),
                    "page": fields.pop("locator.page"),
                    "kind": fields.pop("locator.kind"),
                    "object_id": int(fields.pop("locator.object_id")),
                }
                if record["locator"]["kind"] != kind:
                    raise ValueError("locator kind mismatch")
                if kind == "hierarchical_block":
                    record.update(
                        {
                            "name": fields.pop("name"),
                            "path": fields.pop("path"),
                            "implementation_type": fields.pop("implementation_type"),
                        }
                    )
                elif kind == "wire":
                    wire_kind = fields.pop("wire_kind")
                    if wire_kind not in ("scalar", "bus"):
                        raise ValueError("invalid wire kind")
                    record.update(
                        {
                            "wire_kind": wire_kind,
                            "net": fields.pop("net"),
                            "start": {
                                "x": int(fields.pop("start.x")),
                                "y": int(fields.pop("start.y")),
                            },
                            "end": {
                                "x": int(fields.pop("end.x")),
                                "y": int(fields.pop("end.y")),
                            },
                        }
                    )
                elif kind in ("global", "port"):
                    record.update(
                        {
                            "name": fields.pop("name"),
                            "pin_type": int(fields.pop("pin_type")),
                        }
                    )
                elif kind == "off_page_connector":
                    record.update(
                        {
                            "name": fields.pop("name"),
                            "location": {
                                "x": int(fields.pop("location.x")),
                                "y": int(fields.pop("location.y")),
                            },
                        }
                    )
                elif kind == "comment_text":
                    record["text"] = fields.pop("text")
                elif kind == "title_block":
                    record["page_name"] = fields.pop("page_name")
                else:
                    raise ValueError("unexpected supported kind")
            except (KeyError, ValueError) as error:
                raise ToolExecutionError(
                    "Capture returned malformed selection object data."
                ) from error
        if fields:
            raise ToolExecutionError("Capture returned unexpected selection fields.")
        objects.append(record)
    return {
        "objects": objects,
        "selection_count": selection_count,
        "returned_count": returned_count,
        "truncated": bool(truncated_number),
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


def _property_names(arguments: dict[str, Any]) -> list[str]:
    raw_names = arguments.get("property_names", list(DEFAULT_PROPERTIES))
    if type(raw_names) is not list or not raw_names:
        raise InvalidToolArguments("property_names must be a non-empty array.")
    if len(raw_names) > MAX_PROPERTIES_PER_READ:
        raise InvalidToolArguments(
            f"property_names accepts at most {MAX_PROPERTIES_PER_READ} names."
        )
    property_names: list[str] = []
    seen: set[str] = set()
    for raw_name in raw_names:
        name = _string_argument(
            {"property_name": raw_name},
            "property_name",
            required=True,
            max_length=MAX_PROPERTY_NAME_LENGTH,
        )
        assert name is not None
        if name not in seen:
            seen.add(name)
            property_names.append(name)
    return property_names


def read_component_properties(runtime_file: Path, arguments: Any) -> dict[str, Any]:
    values = _validate_arguments_object(arguments)
    allowed = {"refdes", "path", "property_names", "max_results"}
    unknown = sorted(set(values) - allowed)
    if unknown:
        raise InvalidToolArguments(f"Unknown argument(s): {', '.join(unknown)}.")
    refdes = _string_argument(values, "refdes", max_length=256)
    path = _string_argument(values, "path", max_length=4096)

    property_names = _property_names(values)

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


def inspect_selection(runtime_file: Path, arguments: Any) -> dict[str, Any]:
    values = _validate_arguments_object(arguments)
    allowed = {"property_names", "max_results"}
    unknown = sorted(set(values) - allowed)
    if unknown:
        raise InvalidToolArguments(f"Unknown argument(s): {', '.join(unknown)}.")
    property_names = _property_names(values)
    max_results = values.get("max_results", 100)
    if type(max_results) is not int or not 1 <= max_results <= MAX_SELECTION_RESULTS:
        raise InvalidToolArguments(
            f"max_results must be an integer from 1 through {MAX_SELECTION_RESULTS}."
        )
    script = build_inspect_selection_script(property_names, max_results)
    raw = _execute_capture_script(runtime_file, script)
    return _parse_selection_result(raw, property_names)


INSPECT_SELECTION_TOOL = {
    "name": "capture_inspect_selection",
    "title": "Inspect the current Capture selection",
    "description": (
        "Read the schematic objects selected in the active OrCAD Capture UI at "
        "call time. Use this tool again before a write when the user refers to "
        "the current, newly selected, or just-selected object."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
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
                "maximum": MAX_SELECTION_RESULTS,
                "default": 100,
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
        "saved. Supply path when refdes is not unique. This tool does not inspect the "
        "GUI selection; call capture_inspect_selection first when the user means the "
        "current or newly selected component."
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
            result: dict[str, Any] = {
                "tools": [INSPECT_SELECTION_TOOL, READ_TOOL, SET_TOOL]
            }
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
            "Operate only on the active OrCAD Capture design. When a user refers to "
            "the current, newly selected, or just-selected object, call "
            "capture_inspect_selection immediately before writing. Reuse an earlier "
            "locator only when the user clearly refers to that earlier result. If a "
            "mutation target is ambiguous, refresh the selection or ask; never guess. "
            "Property writes use the occurrence refdes and exact path, change only "
            "in-memory properties, verify readback, and never save the design."
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
            if name == INSPECT_SELECTION_TOOL["name"]:
                value = inspect_selection(self.runtime_file, arguments)
            elif name == READ_TOOL["name"]:
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
        description="Expose typed OrCAD Capture inspection and property tools over MCP stdio."
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
