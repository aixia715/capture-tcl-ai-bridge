"""Read-only acceptance of the three connectivity tools on a running Capture.

Run with Windows Python from a checkout containing the new MCP server. Capture
and AiBridge must already be running. No design edits or saves are performed.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, default=Path(__file__).resolve().parents[1] / "capture_mcp_server.py")
    parser.add_argument("--runtime-file", type=Path)
    parser.add_argument("--refdes", help="Optional component to test; otherwise try the first 100 components")
    parser.add_argument("--path", help="Exact occurrence path when --refdes is repeated")
    args = parser.parse_args()
    command = [sys.executable, str(args.server)]
    if args.runtime_file:
        command += ["--runtime-file", str(args.runtime_file)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               text=True, encoding="utf-8")
    request_id = 0

    def rpc(method, params):
        nonlocal request_id
        request_id += 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                        "method": method, "params": params}) + "\n")
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        if response.get("id") != request_id or "error" in response:
            raise RuntimeError(f"MCP request failed: {response}")
        return response["result"]

    def tool(name, arguments):
        result = rpc("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(result["content"][0]["text"])
        return result["structuredContent"]

    try:
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "connectivity-acceptance", "version": "1"}})
        names = {t["name"] for t in rpc("tools/list", {})["tools"]}
        expected = {"capture_get_component_pins", "capture_get_pin_net", "capture_get_net_pins"}
        if not expected <= names:
            raise RuntimeError("MCP server does not expose all three connectivity tools")
        if args.refdes:
            targets = [{"refdes": args.refdes, **({"path": args.path} if args.path else {})}]
        else:
            components = tool("capture_read_component_properties", {"max_results": 100})
            targets = [{"refdes": c["occurrence"]["refdes"], "path": c["occurrence"]["path"]}
                       for c in components["components"]]
        for target in targets:
            data = tool("capture_get_component_pins", {**target, "max_results": 5000})
            if data["truncated"]:
                raise RuntimeError("Component pins were truncated; cannot verify completeness")
            connected = next((p for p in data["pins"] if p["connected"]), None)
            if connected is None:
                continue
            pin = tool("capture_get_pin_net", {**target, "pin_number": connected["pin_number"]})["pin"]
            if pin != connected:
                raise RuntimeError("Component pin and pin-net results disagree")
            network = tool("capture_get_net_pins", {"net_name": pin["net"]["name"], "max_results": 5000})
            if network["truncated"] or pin not in network["pins"]:
                raise RuntimeError("Network does not return the original endpoint, or was truncated")
            if not all(p["connected"] and p["net"] == pin["net"] for p in network["pins"]):
                raise RuntimeError("Network contains an endpoint from another net")
            unconnected = next((p for p in data["pins"] if not p["connected"]), None)
            if unconnected:
                readback = tool("capture_get_pin_net", {**target, "pin_number": unconnected["pin_number"]})["pin"]
                if readback != unconnected or readback["net"] is not None:
                    raise RuntimeError("Unconnected-pin readback disagrees")
            print(json.dumps({"ok": True, "component": target, "component_pin_count": data["count"],
                              "pin": pin, "net_pin_count": network["count"], "net_pins": network["pins"],
                              "unconnected_pin_checked": unconnected is not None}, ensure_ascii=True, indent=2))
            return 0
        raise RuntimeError("No connected pin found in the tested components; specify --refdes and --path")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print(f"Connectivity acceptance failed: {error}", file=sys.stderr)
        raise SystemExit(1)
