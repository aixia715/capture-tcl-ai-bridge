"""The documentation must state the facts operators depend on.

These are not style checks. Each asserted string is a promise the runtime
actually makes - a port, a file location, a safety boundary - and a document
that loses it will mislead somebody into an unsafe or unrecoverable state.
"""

from __future__ import annotations

from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"


def _read(relative: str) -> str:
    path = ROOT / relative
    assert path.is_file(), f"missing documentation file: {relative}"
    return path.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def readme() -> str:
    return _read("README.md")


@pytest.fixture(scope="module")
def protocol() -> str:
    return _read("docs/protocol.md")


@pytest.fixture(scope="module")
def security() -> str:
    return _read("docs/security.md")


@pytest.fixture(scope="module")
def troubleshooting() -> str:
    return _read("docs/troubleshooting.md")


@pytest.fixture(scope="module")
def migration() -> str:
    return _read("MIGRATION.md")


def test_readme_documents_the_shortest_path(readme: str) -> None:
    for required in (
        ".\\install.ps1",
        ".\\uninstall.ps1",
        "source ",
        "CaptureAiBridgeStart",
        "CaptureAiBridgeStatus",
        "CaptureAiBridgeStop",
        "capture_tcl_cli.py",
    ):
        assert required in readme, required


def test_readme_states_the_supported_platforms(readme: str) -> None:
    for required in ("Python 3.12", "Windows 10", "17.4", "16.6"):
        assert required in readme, required


def test_readme_no_longer_describes_the_tclbom_project(readme: str) -> None:
    # Naming TCLBOM as the historical source is fine; describing its features
    # is not, because this README is now the standalone project's front door.
    for forbidden in ("ExportBom", "ImportBom", "DNIPanel", "cpcode.bat"):
        assert forbidden not in readme, forbidden


def test_documents_pin_the_localhost_endpoint(readme: str, protocol: str) -> None:
    for document in (readme, protocol):
        assert "127.0.0.1:8767" in document


def test_documents_pin_the_runtime_descriptor(readme: str, protocol: str) -> None:
    for document in (readme, protocol):
        assert "%TEMP%\\capture_tcl_bridge.json" in document


def test_protocol_documents_the_public_endpoints(protocol: str) -> None:
    for required in (
        "GET  /v1/health",
        "POST /v1/execute",
        "GET  /v1/commands/{id}",
        "Authorization: Bearer",
        "schemaVersion",
        "BRIDGE_BUSY",
        "CAPTURE_DISCONNECTED",
        "COMMAND_ID_MISMATCH",
        "INVALID_RESULT",
        "X-Capture-Command-Id",
        "returnCode",
        "stdoutTruncated",
    ):
        assert required in protocol, required


def test_protocol_documents_the_timeout_that_does_not_cancel(protocol: str) -> None:
    assert "30" in protocol
    assert "504" in protocol
    # The single most dangerous misreading of this API.
    assert "不会取消" in protocol


def test_protocol_documents_the_token_rotation(protocol: str) -> None:
    assert "随机" in protocol
    assert "Bearer" in protocol


def test_security_states_that_the_bridge_is_not_a_sandbox(security: str) -> None:
    assert "不是沙箱" in security
    for required in ("127.0.0.1", "Bearer", "Capture", "Tcl"):
        assert required in security, required


def test_security_states_what_the_controls_do_not_protect_against(
    security: str,
) -> None:
    assert "同一" in security and "用户" in security


def test_troubleshooting_covers_the_known_failure_modes(
    troubleshooting: str,
) -> None:
    for required in (
        "8767",
        "capture_tcl_bridge.json",
        "CaptureAiBridgeDumpPendingResult",
        "CaptureAiBridgeStop",
        "CaptureAiBridgeStatus",
        "source ",
        "install.json",
        "400",
    ):
        assert required in troubleshooting, required


def test_docs_carry_the_puts_tee_guarantee(readme: str, protocol: str) -> None:
    assert "puts" in readme
    assert "puts" in protocol
    assert "Capture" in readme


def test_docs_never_embed_a_bearer_token(
    readme: str, protocol: str, security: str, troubleshooting: str, migration: str
) -> None:
    import re

    pattern = re.compile(r"Bearer\s+[A-Za-z0-9_\-]{16,}")
    for name, document in (
        ("README.md", readme),
        ("docs/protocol.md", protocol),
        ("docs/security.md", security),
        ("docs/troubleshooting.md", troubleshooting),
        ("MIGRATION.md", migration),
    ):
        assert not pattern.search(document), f"{name} looks like it embeds a token"


def test_migration_does_not_claim_acceptance_it_has_not_earned(
    migration: str,
) -> None:
    assert "capture-tcl-ai-bridge" in migration
    # The HTTP 400 defect is fixed under automated test, but a real Capture
    # session has not signed it off; the document must not imply otherwise.
    assert "待验收" in migration or "not claim" in migration
