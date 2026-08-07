"""Static safety checks for the standalone Capture Tcl example scripts.

Every example under examples/ is submitted to Capture's Tcl interpreter
as-is through the bridge, so each file must be fully self-contained -- no
`source` of a shared TCLBOM helper file, no dependency on TCLBOM procs.
Four of the seven (the Task 7 examples) are read-only and must never call
a mutating Dbo API; the other three (the Task 8 examples) exist only to
mutate a single field after a whole-design uniqueness check, so
SetPartValue is confined to exactly those three. None of the seven -- read
or write -- may call RefreshParts or save the design; a write example
mutating one field is a deliberate, reviewable act, and auto-saving or
refreshing would turn it into something bigger than the caller asked for.

These are not style checks: an example that quietly depends on _dniWalk
would work in the TCLBOM tree it was copied from and then fail the moment
it is sent through the bridge on its own, and a read-only example that
gains a stray SetPartValue would silently start writing to the design.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"
COOKBOOK = ROOT / "docs" / "tcl-cookbook.md"

READ_ONLY_EXAMPLES = (
    "list_components.tcl",
    "selected_refs.tcl",
    "get_component_value.tcl",
    "extract_topology.tcl",
)

WRITE_EXAMPLES = (
    "set_component_value.tcl",
    "mark_selected_suffix.tcl",
    "remove_selected_suffix.tcl",
)

ALL_EXAMPLES = READ_ONLY_EXAMPLES + WRITE_EXAMPLES

FORBIDDEN_DEPENDENCIES = (
    "_dniWalk",
    "CollectSelectedDNIOccs",
    "RefreshParts",
    "TclPythonPath",
)

# A line that sources another file, however it is spelled ("source ../foo",
# "source [file join ...]", a plain "source helpers.tcl"): a self-contained
# example must not have one at all.
SOURCE_COMMAND = re.compile(r"(?m)^\s*source\s")


def _read(name: str) -> str:
    path = EXAMPLES / name
    assert path.is_file(), f"missing example: examples/{name}"
    return path.read_text(encoding="utf-8")


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_example_exists(name: str) -> None:
    _read(name)


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_example_has_no_tclbom_dependencies(name: str) -> None:
    text = _read(name)
    for forbidden in FORBIDDEN_DEPENDENCIES:
        assert forbidden not in text, f"{name} depends on {forbidden}"


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_example_does_not_source_shared_files(name: str) -> None:
    text = _read(name)
    assert not SOURCE_COMMAND.search(text), f"{name} sources another file"


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_example_never_saves_the_design(name: str) -> None:
    # Even the write examples only ever touch SetPartValue: saving is
    # always left to the caller, in every one of the seven scripts.
    text = _read(name)
    assert not re.search(r"\bSave\b", text), f"{name} calls Save"


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_set_part_value_is_confined_to_write_examples(name: str) -> None:
    text = _read(name)
    calls_set_part_value = re.search(r"\bSetPartValue\b", text) is not None
    if name in WRITE_EXAMPLES:
        assert calls_set_part_value, (
            f"{name} is a write example but never calls SetPartValue"
        )
    else:
        assert not calls_set_part_value, (
            f"{name} is read-only but calls SetPartValue"
        )


def test_task_7_and_task_8_examples_are_present() -> None:
    present = {path.name for path in EXAMPLES.glob("*.tcl")}
    missing = set(ALL_EXAMPLES) - present
    assert not missing, f"missing examples: {sorted(missing)}"


def test_cookbook_documents_exactly_the_examples_on_disk() -> None:
    # Independent of the byte-for-byte drift check in test_docs_contract.py:
    # this only asks whether the *set* of documented filenames matches the
    # set on disk, using its own regex, so a bug in one check does not hide
    # the other. Adding an example without documenting it, or leaving a
    # deleted example's entry behind, must fail here even if the cookbook
    # content test elsewhere has a bug.
    assert COOKBOOK.is_file(), "missing docs/tcl-cookbook.md"
    text = COOKBOOK.read_text(encoding="utf-8")
    documented = set(
        re.findall(r"<!-- BEGIN EXAMPLE SOURCE: ([A-Za-z0-9_.]+\.tcl) -->", text)
    )
    on_disk = {path.name for path in EXAMPLES.glob("*.tcl")}
    assert documented == on_disk, (
        f"documented={sorted(documented)} on_disk={sorted(on_disk)}"
    )
