"""Static safety checks for the standalone Capture Tcl example scripts.

Every example under examples/ is submitted to Capture's Tcl interpreter
as-is through the bridge, so each file must be fully self-contained -- no
`source` of a shared TCLBOM helper file, no dependency on TCLBOM procs --
and the read-only examples covered by this task must never call a mutating
Dbo API. These are not style checks: an example that quietly depends on
_dniWalk or calls SetPartValue would work in the TCLBOM tree it was
copied from and then fail, or silently write to the design, the moment it
is sent through the bridge on its own.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"

READ_ONLY_EXAMPLES = (
    "list_components.tcl",
    "selected_refs.tcl",
    "get_component_value.tcl",
    "extract_topology.tcl",
)

FORBIDDEN_DEPENDENCIES = (
    "_dniWalk",
    "CollectSelectedDNIOccs",
    "RefreshParts",
    "TclPythonPath",
)

MUTATING_CALLS = ("SetPartValue", "Save")

# A line that sources another file, however it is spelled ("source ../foo",
# "source [file join ...]", a plain "source helpers.tcl"): a self-contained
# example must not have one at all.
SOURCE_COMMAND = re.compile(r"(?m)^\s*source\s")


def _read(name: str) -> str:
    path = EXAMPLES / name
    assert path.is_file(), f"missing example: examples/{name}"
    return path.read_text(encoding="utf-8")


@pytest.mark.parametrize("name", READ_ONLY_EXAMPLES)
def test_example_exists(name: str) -> None:
    _read(name)


@pytest.mark.parametrize("name", READ_ONLY_EXAMPLES)
def test_example_has_no_tclbom_dependencies(name: str) -> None:
    text = _read(name)
    for forbidden in FORBIDDEN_DEPENDENCIES:
        assert forbidden not in text, f"{name} depends on {forbidden}"


@pytest.mark.parametrize("name", READ_ONLY_EXAMPLES)
def test_example_does_not_source_shared_files(name: str) -> None:
    text = _read(name)
    assert not SOURCE_COMMAND.search(text), f"{name} sources another file"


@pytest.mark.parametrize("name", READ_ONLY_EXAMPLES)
def test_example_is_read_only(name: str) -> None:
    text = _read(name)
    for mutating in MUTATING_CALLS:
        assert not re.search(rf"\b{mutating}\b", text), (
            f"{name} calls the mutating API {mutating}"
        )


def test_read_only_examples_are_present() -> None:
    # Subset, not equality: Task 8 adds mutating examples (set_component_value
    # etc.) to this same directory, and those must not be swept into the
    # read-only checks above.
    present = {path.name for path in EXAMPLES.glob("*.tcl")}
    missing = set(READ_ONLY_EXAMPLES) - present
    assert not missing, f"missing read-only examples: {sorted(missing)}"
