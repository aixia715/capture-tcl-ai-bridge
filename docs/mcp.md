# Capture MCP

`capture_mcp_server.py` is a local stdio MCP server for AI agents such as
Codex, Claude Code and Hermes. Active Design tools talk to the authenticated
Capture Tcl bridge; Offline Design tools use a standalone SPB 16.6 DBO session.
The server intentionally exposes only five closed-world tools:

| Tool | Effect |
| --- | --- |
| `capture_inspect_selection` | Reads the Current Selection from the active schematic page and returns typed objects with locators. |
| `capture_read_component_properties` | Lists components in the active design and reads requested effective string properties. |
| `capture_set_component_property` | Changes one property on exactly one component and verifies it by immediate readback. |
| `capture_read_dsn_component_properties` | Reads Component Information from an absolute DSN path without starting Capture GUI. |
| `capture_set_dsn_component_property` | Sets one Occurrence Property in a staged DSN, saves it, and verifies it in a fresh process before publication. |

The Active Design write tool **does not save**; Capture remains where the user
reviews and saves or discards that change. The Offline Design write tool is
persistent and reports success only after a new `tclsh.exe` process reopens and
verifies the saved DSN.

## Prerequisites

Install the project first:

```powershell
.\install.ps1
```

Active Design tools also require the bridge. Run this in the Capture Tcl console:

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
CaptureAiBridgeStart
```

Offline Design tools do not require the bridge or a running `capture.exe`. They
require SPB 16.6. The MCP server uses `--cadence-root` when supplied, then
`CAPTURE_CADENCE_ROOT`, then `cds_root cds_root`; the selected root must contain
matching `tools\tcl84\bin\tclsh.exe` and
`tools\capture\orDb_Dll_TCL.dll` files.

The MCP process is launched by the agent client. Do not start it in a separate
terminal: stdio is reserved for MCP JSON-RPC traffic.

## Connect an agent

The installer puts the MCP server at
`C:\tclpython\capture_mcp_server.py` by default.

### Codex

```powershell
codex mcp add capture -- C:\tclpython\runtime\python.exe C:\tclpython\capture_mcp_server.py
codex mcp list
```

The equivalent `config.toml` entry is:

```toml
[mcp_servers.capture]
command = "python"
args = ["C:\\tclpython\\capture_mcp_server.py"]
tool_timeout_sec = 300
```

### Claude Code

```powershell
claude mcp add --transport stdio --scope user capture -- C:\tclpython\runtime\python.exe C:\tclpython\capture_mcp_server.py
claude mcp get capture
```

The equivalent `.mcp.json` entry is:

```json
{
  "mcpServers": {
    "capture": {
      "type": "stdio",
      "command": "python",
      "args": ["C:\\tclpython\\capture_mcp_server.py"]
    }
  }
}
```

### Hermes

In a Windows-hosted shell:

```powershell
hermes mcp add capture --command python --args C:\tclpython\capture_mcp_server.py
hermes mcp test capture
```

When Hermes runs in WSL, launch the installed Windows Python instead:

```bash
hermes mcp add capture --command python.exe --args 'C:\tclpython\capture_mcp_server.py'
```

The equivalent `~/.hermes/config.yaml` entry is:

```yaml
mcp_servers:
  capture:
    command: "python.exe"
    args: ["C:\\tclpython\\capture_mcp_server.py"]
    timeout: 300
    supports_parallel_tool_calls: false
```

The Capture bridge accepts only one command at a time, so parallel tool calls
should remain disabled.

## Tool usage

Inspect the objects selected in the active schematic at call time:

```json
{}
```

The selection tool accepts optional `property_names` for selected components and
`max_results` (default 100, maximum 1000). Empty selection succeeds. If Capture
focus is outside a schematic editor it returns `SCHEMATIC_VIEW_REQUIRED` rather
than reusing an old page.

Read the common properties (`Value` and `PCB Footprint`) for every component
(up to the default 500):

```json
{}
```

Read arbitrary effective string properties from one reference designator:

```json
{
  "refdes": "C3",
  "property_names": ["Value", "PCB Footprint", "Manufacturer"]
}
```

If a hierarchical design contains more than one `C3`, first read them and then
pass the exact returned `path` to the write tool:

```json
{
  "refdes": "C3",
  "path": "/TOP/POWER/C3",
  "property_name": "Value",
  "value": "100nF"
}
```

Both read tools return the same Component Information. Its occurrence locator
contains `design`, `refdes`, and hierarchical `path`; its page-instance locator
contains `design`, `page`, and `object_id`. Property writes continue to use only
the occurrence `refdes` and `path`.

Properties are keyed by the requested Capture name. Existing values use
`{"present":true,"value":"..."}`; an existing empty string keeps `value:""`;
a missing property uses `{"present":false}`. Explicit `property_names` replace
the defaults, and duplicates are removed in first-seen order.

Selection results preserve Capture's order and selection index. Supported kinds
are `component`, `hierarchical_block`, `wire` (scalar or bus), `global`,
`off_page_connector`, `comment_text`, `port`, `pin`, `net_alias`, `graphic_box`,
`graphic_line`, `graphic_ellipse`, and `title_block`. Ports and pins include their
page connection point, connectivity, and net name when connected; pins also
include the owner refdes, pin name/number/type/position, and body-side start
point. Aliases include name, location, and rotation. Graphic objects include
bounds or endpoints plus their applicable line/fill styles. Coordinates are raw
Capture document units. Supported non-components use a
`design + page + kind + object_id` locator. Unknown kinds remain visible with
`supported:false` and no locator. A field failure is attached to only that object
when the rest of the selection can still be returned.

Write results contain `before` and `after`. DBO failures are returned as MCP tool
errors so the agent can correct its request.

Both setters use the same Occurrence Property Set semantics. The assignment is
always made on the target occurrence: an existing occurrence value is replaced,
an inherited value is overridden on that occurrence, and a completely missing
property is created there. `before` and `after` use the same presence records as
reads, so missing and empty values remain distinct:

```json
{
  "before": {"present": false},
  "after": {"present": true, "value": "Acme"}
}
```

### Offline Design tools

Read a DSN without starting Capture GUI:

```json
{
  "dsn_path": "C:\\designs\\board.DSN",
  "refdes": "C5",
  "property_names": ["Value", "PCB Footprint"]
}
```

Offline reads return the same Component Information as Active Design reads,
including occurrence and page-instance locators. The component `design` field is
the normalized absolute DSN path.

Write to a new output DSN, which must not already exist:

```json
{
  "dsn_path": "C:\\designs\\board.DSN",
  "output_path": "C:\\designs\\board-updated.DSN",
  "refdes": "C5",
  "path": "FNC-QQ/C5",
  "property_name": "Manufacturer",
  "value": "Acme"
}
```

To replace the source explicitly, omit `output_path` and set `"in_place":true`.
The operation stages a private copy, runs a writer process, runs a separate
read-only verifier process, then atomically publishes the verified DSN. In-place
publication creates a temporary adjacent backup and removes it after success.

Capture indicates an open DSN with a same-directory sibling such as
`board.DSNlck`. The server never removes that file. Reads and output-copy writes
remain allowed and an output-copy result reports `source_locked:true`; in-place
writes fail with `DESIGN_LOCKED`. Output-copy reads only the last state saved on
disk, not unsaved GUI changes.

### Selection refresh rules for agents

- “current”, “newly selected”, or “just selected” means call
  `capture_inspect_selection` immediately before a write.
- A locator from an earlier result may be reused only when the user clearly
  identifies that earlier object.
- For ambiguous mutation targets, refresh selection or ask the user; never guess.
- `capture_set_component_property` does not inspect GUI selection itself.

### Beta.3 output migration

`capture_read_component_properties` no longer returns
`{refdes,path,properties:{name:value}}`. Clients must read `occurrence`,
`page_instance`, and the `present` property records described above. The removed
default properties are `Part Name` (unreliable in target designs) and
`Part Reference` (the authoritative refdes already lives in the occurrence
locator).

## Scope and safety

- Active Design tools address only the design open in Capture. Offline Design
  tools require an explicit absolute `.DSN` path and never infer it from the GUI.
- Selection is read at tool execution time; no snapshot token or Tcl handle is
  retained between MCP calls.
- No arbitrary Tcl tool is exposed through MCP.
- All MCP strings are UTF-8 encoded as hexadecimal before being embedded in a
  generated Tcl script, so property values cannot become Tcl source code.
- A write must resolve to exactly one component. Duplicate refdes values require
  an exact hierarchical path.
- Page object IDs are never used for component property writes.
- Every Active Design write is read back immediately. Every Offline Design write
  is saved and then re-read by a fresh `tclsh.exe` process before publication.
- Active Design writes never save. Offline Design writes persist only the requested
  Occurrence Property and never modify topology.
- The runtime descriptor and bearer token remain governed by the bridge's
  existing localhost security model; see [security.md](security.md).

The stdio implementation supports both the legacy initialization-based MCP
revisions (`2024-11-05` through `2025-11-25`) and the stateless
`2026-07-28` revision, allowing current and older agent clients to connect.

For a non-default runtime descriptor, append:

```text
--runtime-file C:\path\to\capture_tcl_bridge.json
```

Offline configuration options are:

```text
--cadence-root C:\Cadence\SPB_16.6
--offline-read-timeout 60
--offline-write-timeout 120
```

Each timeout applies to one isolated Cadence process. A timeout terminates that
process tree and discards staging; an unverified output is never published.
