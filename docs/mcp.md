# Capture MCP

`capture_mcp_server.py` is a local stdio MCP server for AI agents such as
Codex, Claude Code and Hermes. It talks to the already-running authenticated
Capture Tcl bridge and intentionally exposes only three closed-world tools:

| Tool | Effect |
| --- | --- |
| `capture_inspect_selection` | Reads the Current Selection from the active schematic page and returns typed objects with locators. |
| `capture_read_component_properties` | Lists components in the active design and reads requested effective string properties. |
| `capture_set_component_property` | Changes one property on exactly one component and verifies it by immediate readback. |

The write tool changes the design open in Capture but **does not save it**.
Capture remains the place where the user reviews and saves or discards changes.

## Prerequisites

Install and start the Tcl bridge first:

```powershell
.\install.ps1
```

Then run this in the Capture Tcl console:

```tcl
source C:/cadence/SPB_17.4/tools/capture/tclscripts/capAutoLoad/captureAiBridge.tcl
CaptureAiBridgeStart
```

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
tool_timeout_sec = 45
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
    timeout: 45
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
`off_page_connector`, `comment_text`, `port`, and `title_block`. Supported
non-components use a `design + page + kind + object_id` locator. Unknown kinds
remain visible with `supported:false` and no locator. A field failure is attached
to only that object when the rest of the selection can still be returned.

Write results contain `before` and `after`. DBO failures are returned as MCP tool
errors so the agent can correct its request.

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

- Only the active Capture design is addressed.
- Selection is read at tool execution time; no snapshot token or Tcl handle is
  retained between MCP calls.
- No arbitrary Tcl tool is exposed through MCP.
- All MCP strings are UTF-8 encoded as hexadecimal before being embedded in a
  generated Tcl script, so property values cannot become Tcl source code.
- A write must resolve to exactly one component. Duplicate refdes values require
  an exact hierarchical path.
- Page object IDs are never used for component property writes.
- Every write is read back and compared before success is reported.
- The MCP server never saves the design and never modifies topology.
- The runtime descriptor and bearer token remain governed by the bridge's
  existing localhost security model; see [security.md](security.md).

The stdio implementation supports both the legacy initialization-based MCP
revisions (`2024-11-05` through `2025-11-25`) and the stateless
`2026-07-28` revision, allowing current and older agent clients to connect.

For a non-default runtime descriptor, append:

```text
--runtime-file C:\path\to\capture_tcl_bridge.json
```
