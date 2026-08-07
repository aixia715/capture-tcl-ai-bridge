"""The documentation must state the facts operators depend on.

These are not style checks. Each asserted string is a promise the runtime
actually makes - a port, a file location, a safety boundary - and a document
that loses it will mislead somebody into an unsafe or unrecoverable state.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
EXAMPLES = ROOT / "examples"


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


@pytest.fixture(scope="module")
def cookbook() -> str:
    return _read("docs/tcl-cookbook.md")


def _example_names() -> list[str]:
    return sorted(path.name for path in EXAMPLES.glob("*.tcl"))


# Each example gets its own "## `name.tcl`" section; splitting the cookbook
# on that heading lets every per-example assertion below check the facts
# actually live in that example's own section, not merely somewhere in the
# document (a "回读验证" heading under the wrong script would pass a
# document-wide substring check and still be wrong).
_EXAMPLE_HEADING_RE = re.compile(r"^## `([A-Za-z0-9_.]+\.tcl)`\s*$", re.MULTILINE)


def _cookbook_example_sections(cookbook: str) -> dict[str, str]:
    headings = list(_EXAMPLE_HEADING_RE.finditer(cookbook))
    sections: dict[str, str] = {}
    for index, heading in enumerate(headings):
        start = heading.end()
        end = headings[index + 1].start() if index + 1 < len(headings) else len(cookbook)
        sections[heading.group(1)] = cookbook[start:end]
    return sections


# Each embedded script sits between a BEGIN/END pair naming the file, wrapped
# in a ```tcl fence. HTML comments are invisible in a rendered Markdown page
# but stay intact in the raw text this test reads, so the markers survive
# rendering without becoming visible clutter, and the filename inside each
# marker makes every pair unambiguous even if two blocks sit close together.
_SOURCE_BLOCK_RE = re.compile(
    r"<!-- BEGIN EXAMPLE SOURCE: ([A-Za-z0-9_.]+\.tcl) -->\n"
    r"```tcl\n(.*?)```\n"
    r"<!-- END EXAMPLE SOURCE: \1 -->",
    re.DOTALL,
)


def test_cookbook_documents_exactly_the_examples_on_disk(cookbook: str) -> None:
    sections = _cookbook_example_sections(cookbook)
    assert set(sections) == set(_example_names())


def test_cookbook_documents_the_three_invocation_methods(cookbook: str) -> None:
    for required in (
        "python C:\\tclpython\\capture_tcl_cli.py -f .\\examples\\selected_refs.tcl",
        "Get-Content -Raw .\\examples\\selected_refs.tcl | "
        "python C:\\tclpython\\capture_tcl_cli.py",
        "%TEMP%\\capture_tcl_bridge.json",
        "baseUrl",
        "token",
    ):
        assert required in cookbook, required


@pytest.mark.parametrize("name", _example_names())
def test_cookbook_entry_covers_every_required_facet(name: str, cookbook: str) -> None:
    sections = _cookbook_example_sections(cookbook)
    assert name in sections, f"no '## `{name}`' section in the cookbook"
    section = sections[name]
    for required in (
        "用途",
        "风险级别",
        "输入参数",
        f"-f .\\examples\\{name}",
        f"Get-Content -Raw .\\examples\\{name}",
        "HTTP 调用",
        "预期输出",
        "UI 阻塞风险",
        "回读验证",
        "撤销",
        "不自动保存",
    ):
        assert required in section, f"{name}: missing {required!r}"


def test_cookbook_states_the_blocking_risk_for_full_design_walks(cookbook: str) -> None:
    sections = _cookbook_example_sections(cookbook)
    for name in ("list_components.tcl", "extract_topology.tcl"):
        section = sections[name]
        assert "不会取消" in section, name
        assert "超时" in section, name


def test_cookbook_states_duplicate_refdes_is_refused_not_guessed(cookbook: str) -> None:
    sections = _cookbook_example_sections(cookbook)
    for name in ("get_component_value.tcl", "set_component_value.tcl"):
        assert "COMPONENT_NOT_UNIQUE" in sections[name], name


def test_cookbook_never_hardcodes_a_token_in_its_http_example(cookbook: str) -> None:
    pattern = re.compile(r"Bearer\s+[A-Za-z0-9_\-]{16,}")
    assert not pattern.search(cookbook)


def test_cookbook_embeds_every_example_source_exactly_once(cookbook: str) -> None:
    names = [match.group(1) for match in _SOURCE_BLOCK_RE.finditer(cookbook)]
    assert sorted(names) == _example_names()
    assert len(names) == len(set(names)), "an example is embedded more than once"


@pytest.mark.parametrize("name", _example_names())
def test_cookbook_embedded_source_matches_disk_byte_for_byte(
    name: str, cookbook: str
) -> None:
    match = None
    for candidate in _SOURCE_BLOCK_RE.finditer(cookbook):
        if candidate.group(1) == name:
            match = candidate
            break
    assert match is not None, f"no embedded source block for {name}"
    embedded = match.group(2).replace("\r\n", "\n")
    on_disk = (EXAMPLES / name).read_text(encoding="utf-8").replace("\r\n", "\n")
    assert embedded == on_disk, (
        f"docs/tcl-cookbook.md's copy of {name} has drifted from examples/{name}"
    )


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
    readme: str,
    protocol: str,
    security: str,
    troubleshooting: str,
    migration: str,
    cookbook: str,
) -> None:
    pattern = re.compile(r"Bearer\s+[A-Za-z0-9_\-]{16,}")
    for name, document in (
        ("README.md", readme),
        ("docs/protocol.md", protocol),
        ("docs/security.md", security),
        ("docs/troubleshooting.md", troubleshooting),
        ("MIGRATION.md", migration),
        ("docs/tcl-cookbook.md", cookbook),
    ):
        assert not pattern.search(document), f"{name} looks like it embeds a token"


def test_migration_does_not_claim_acceptance_it_has_not_earned(
    migration: str,
) -> None:
    assert "capture-tcl-ai-bridge" in migration
    # The HTTP 400 defect is fixed under automated test, but a real Capture
    # session has not signed it off; the document must not imply otherwise.
    assert "待验收" in migration or "not claim" in migration
