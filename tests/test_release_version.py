from pathlib import Path
import re

import capture_tcl_bridge_server as server
import capture_tcl_cli as cli
import capture_mcp_server as mcp


ROOT = Path(__file__).resolve().parents[1]


def test_runtime_version_is_identical_in_every_deployed_component():
    expected = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    tcl = (ROOT / "captureAiBridge.tcl").read_text(encoding="utf-8")
    match = re.search(r"^set ::CaptureAiBridgeVersion \{([^}]+)\}$", tcl, re.MULTILINE)

    assert match is not None
    assert (
        expected
        == server.SOFTWARE_VERSION
        == cli.SOFTWARE_VERSION
        == mcp.SERVER_VERSION
        == match.group(1)
    )
