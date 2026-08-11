# Capture MCP

`capture_mcp_server.py` is a local stdio MCP server for AI agents such as
Codex, Claude Code and Hermes. It talks to the already-running authenticated
Capture Tcl bridge and intentionally exposes only two tools:

| Tool | Effect |
| --- | --- |
| `capture_read_component_properties` | Lists components in the active design and reads selected effective string properties. |
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

Read the common properties for every component (up to the default 500):

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

Read results contain `refdes`, `path`, and a property map. Write results contain
`before` and `after`. Unknown properties and DBO failures are returned as MCP
tool errors so the agent can correct its request.

## Scope and safety

- Only the active Capture design is addressed.
- No arbitrary Tcl tool is exposed through MCP.
- All MCP strings are UTF-8 encoded as hexadecimal before being embedded in a
  generated Tcl script, so property values cannot become Tcl source code.
- A write must resolve to exactly one component. Duplicate refdes values require
  an exact hierarchical path.
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
