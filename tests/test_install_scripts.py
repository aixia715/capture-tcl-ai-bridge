"""Behaviour of the standalone install.ps1 and uninstall.ps1 scripts.

The installer owns three runtime files and one manifest. Everything these
tests assert is about ownership boundaries: the installer must never clobber a
file it does not own, and the uninstaller must never delete a file the manifest
does not prove it installed.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "install.ps1"
UNINSTALL = ROOT / "uninstall.ps1"
SERVER_NAME = "capture_tcl_bridge_server.py"
CLI_NAME = "capture_tcl_cli.py"
MCP_NAME = "capture_mcp_server.py"
TCL_NAME = "captureAiBridge.tcl"
AUTOSTART_NAME = "captureAiBridgeAutoStart.tcl"

pytestmark = pytest.mark.skipif(
    os.name != "nt", reason="the installer targets Windows PowerShell"
)


def _powershell() -> str:
    for candidate in ("pwsh", "powershell"):
        found = shutil.which(candidate)
        if found:
            return found
    pytest.skip("no PowerShell interpreter is available")
    raise AssertionError("unreachable")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run(
    script: Path,
    args: list[str],
    *,
    local_app_data: Path,
    skip_runtime_validation: bool = False,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["LOCALAPPDATA"] = str(local_app_data)
    if skip_runtime_validation:
        env["CAPTURE_AI_BRIDGE_TEST_SKIP_RUNTIME_VALIDATION"] = "1"
    return subprocess.run(
        [
            _powershell(),
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            *args,
        ],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=str(ROOT),
        env=env,
        timeout=180,
    )


@pytest.fixture
def sandbox(tmp_path: Path) -> SimpleNamespace:
    box = SimpleNamespace(
        root=tmp_path,
        local_app_data=tmp_path / "localappdata",
        python_target=tmp_path / "python",
        capture_target=tmp_path / "capture",
    )
    box.local_app_data.mkdir()
    box.capture_target.mkdir()
    box.runtime_source = tmp_path / "bundled-runtime"
    (box.runtime_source / "Lib" / "site-packages" / "fastapi").mkdir(parents=True)
    (box.runtime_source / "Lib" / "site-packages" / "uvicorn").mkdir(parents=True)
    (box.runtime_source / "python.exe").write_bytes(b"embedded python")
    (box.runtime_source / "python312._pth").write_text("Lib\nLib/site-packages\nimport site\n", encoding="ascii")
    (box.runtime_source / "Lib" / "site-packages" / "fastapi" / "__init__.py").write_text("", encoding="utf-8")
    (box.runtime_source / "Lib" / "site-packages" / "uvicorn" / "__init__.py").write_text("", encoding="utf-8")
    box.runtime_target = box.python_target / "runtime"
    box.manifest_path = (
        box.local_app_data / "capture-tcl-ai-bridge" / "install.json"
    )
    box.server = box.python_target / SERVER_NAME
    box.cli = box.python_target / CLI_NAME
    box.mcp = box.python_target / MCP_NAME
    box.tcl = box.capture_target / TCL_NAME
    box.autostart = box.capture_target / AUTOSTART_NAME
    return box


def _install(
    sandbox: SimpleNamespace,
    *extra: str,
) -> subprocess.CompletedProcess[str]:
    return _run(
        INSTALL,
        [
            "-PythonTarget",
            str(sandbox.python_target),
            "-CaptureTclTarget",
            str(sandbox.capture_target),
            "-RuntimeSource",
            str(sandbox.runtime_source),
            *extra,
        ],
        local_app_data=sandbox.local_app_data,
        skip_runtime_validation=True,
    )


def _uninstall(
    sandbox: SimpleNamespace, *extra: str
) -> subprocess.CompletedProcess[str]:
    return _run(
        UNINSTALL, list(extra), local_app_data=sandbox.local_app_data
    )


def _manifest(sandbox: SimpleNamespace) -> dict:
    return json.loads(sandbox.manifest_path.read_text(encoding="utf-8"))



def test_install_creates_the_bridge_owned_python_target(sandbox):
    assert not sandbox.python_target.exists()

    result = _install(sandbox)

    assert result.returncode == 0, result.stderr
    assert sandbox.python_target.is_dir()
    assert sandbox.runtime_target.joinpath("python.exe").exists()


def test_install_copies_all_bridge_files_and_bundled_runtime(sandbox):
    result = _install(sandbox)

    assert result.returncode == 0, result.stderr
    assert sandbox.server.read_bytes() == (ROOT / SERVER_NAME).read_bytes()
    assert sandbox.cli.read_bytes() == (ROOT / CLI_NAME).read_bytes()
    assert sandbox.mcp.read_bytes() == (ROOT / MCP_NAME).read_bytes()
    assert sandbox.tcl.read_bytes() == (ROOT / TCL_NAME).read_bytes()
    assert sandbox.runtime_target.joinpath("python.exe").read_bytes() == b"embedded python"
    assert [p.name for p in sandbox.capture_target.iterdir()] == [TCL_NAME]


def test_install_rejects_an_incomplete_bundled_runtime(sandbox):
    result = _run(
        INSTALL,
        [
            "-PythonTarget",
            str(sandbox.python_target),
            "-CaptureTclTarget",
            str(sandbox.capture_target),
            "-RuntimeSource",
            str(sandbox.runtime_source),
        ],
        local_app_data=sandbox.local_app_data,
    )

    assert result.returncode != 0
    assert "bundled runtime is incomplete" in (result.stderr + result.stdout)
    assert not sandbox.python_target.exists()


def test_install_reports_runtime_probe_output_when_an_executable_exits_nonzero(sandbox):
    shutil.copyfile(_powershell(), sandbox.runtime_source / "python.exe")

    result = _run(
        INSTALL,
        [
            "-PythonTarget",
            str(sandbox.python_target),
            "-CaptureTclTarget",
            str(sandbox.capture_target),
            "-RuntimeSource",
            str(sandbox.runtime_source),
        ],
        local_app_data=sandbox.local_app_data,
    )

    combined = result.stdout + result.stderr
    assert result.returncode != 0
    assert "bundled runtime is incomplete" in combined
    assert "Python exited with code" not in combined


def test_install_does_not_auto_start_unless_asked(sandbox):
    """Auto-start widens the exposure window, so it is never the default."""
    _install(sandbox)

    assert not sandbox.autostart.exists()
    manifest = _manifest(sandbox)
    assert AUTOSTART_NAME not in json.dumps(manifest)


def test_enable_auto_start_installs_a_fourth_owned_file(sandbox):
    result = _install(sandbox, "-EnableAutoStart")

    assert result.returncode == 0, result.stderr
    body = sandbox.autostart.read_text(encoding="utf-8")
    assert "AiBridge start" in body
    recorded = {entry["path"] for entry in _manifest(sandbox)["files"]}
    assert str(sandbox.autostart.resolve()) in recorded


def test_enable_auto_start_can_configure_the_diagnostic_log(sandbox, tmp_path):
    log = tmp_path / "bridge.log"

    _install(sandbox, "-EnableAutoStart", "-LogFile", str(log))

    body = sandbox.autostart.read_text(encoding="utf-8")
    assert "::CaptureAiBridgeLogFile" in body
    assert log.as_posix() in body.replace("\\", "/")


def test_uninstall_removes_the_auto_start_file_too(sandbox):
    _install(sandbox, "-EnableAutoStart")

    result = _uninstall(sandbox)

    assert result.returncode == 0, result.stderr
    assert not sandbox.autostart.exists()
    assert not sandbox.manifest_path.exists()


def test_uninstall_still_refuses_a_path_outside_the_four_targets(sandbox, tmp_path):
    _install(sandbox, "-EnableAutoStart")
    outsider = tmp_path / "elsewhere" / AUTOSTART_NAME
    outsider.parent.mkdir(parents=True)
    shutil.copyfile(sandbox.autostart, outsider)
    manifest = _manifest(sandbox)
    manifest["files"].append({"path": str(outsider), "sha256": _sha256(outsider)})
    sandbox.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    result = _uninstall(sandbox)

    assert result.returncode != 0
    assert outsider.exists()
    assert sandbox.autostart.exists(), "a rejected manifest must delete nothing"


def test_install_reports_the_source_and_start_commands(sandbox):
    result = _install(sandbox)

    assert result.returncode == 0, result.stderr
    assert str(sandbox.tcl) in result.stdout
    assert "AiBridge start" in result.stdout
    assert "AiBridge status" in result.stdout
    assert f"{sandbox.runtime_target}\\ (" in result.stdout
    assert str(sandbox.runtime_target / "python.exe") not in result.stdout


def test_install_writes_a_manifest_describing_the_installed_files(sandbox):
    _install(sandbox)

    manifest = _manifest(sandbox)
    assert manifest["schemaVersion"] == 3
    assert manifest["project"] == "capture-tcl-ai-bridge"
    assert Path(manifest["pythonTarget"]) == sandbox.python_target.resolve()
    assert [Path(path) for path in manifest["captureTclTargets"]] == [sandbox.capture_target.resolve()]
    assert Path(manifest["runtimeTarget"]) == sandbox.runtime_target.resolve()
    assert Path(manifest["pythonExecutable"]) == (sandbox.runtime_target / "python.exe").resolve()

    recorded = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
    assert set(recorded) == {
        str(sandbox.server.resolve()),
        str(sandbox.cli.resolve()),
        str(sandbox.mcp.resolve()),
        str(sandbox.tcl.resolve()),
        str((sandbox.runtime_target / "python.exe").resolve()),
        str((sandbox.runtime_target / "python312._pth").resolve()),
        str((sandbox.runtime_target / "Lib" / "site-packages" / "fastapi" / "__init__.py").resolve()),
        str((sandbox.runtime_target / "Lib" / "site-packages" / "uvicorn" / "__init__.py").resolve()),
    }
    for path, digest in recorded.items():
        assert digest == _sha256(Path(path))
        assert digest == digest.lower()


def test_install_is_idempotent(sandbox):
    assert _install(sandbox).returncode == 0
    first = _manifest(sandbox)
    stamps = {p: p.stat().st_mtime_ns for p in (sandbox.server, sandbox.cli, sandbox.mcp, sandbox.tcl)}

    second_result = _install(sandbox)

    assert second_result.returncode == 0, second_result.stderr
    assert _manifest(sandbox) == first
    for path, stamp in stamps.items():
        assert path.stat().st_mtime_ns == stamp, f"{path.name} was rewritten"


def test_install_refuses_to_overwrite_an_unowned_file(sandbox):
    sandbox.python_target.mkdir()
    sandbox.cli.write_text("someone else's file\n", encoding="utf-8")

    result = _install(sandbox)

    assert result.returncode != 0
    assert sandbox.cli.read_text(encoding="utf-8") == "someone else's file\n"
    assert not sandbox.manifest_path.exists()


def test_install_does_not_copy_anything_when_one_target_is_unsafe(sandbox):
    sandbox.tcl.write_text("hand written bridge\n", encoding="utf-8")

    result = _install(sandbox)

    assert result.returncode != 0
    assert not sandbox.server.exists(), "preflight must precede every copy"
    assert not sandbox.cli.exists()
    assert sandbox.tcl.read_text(encoding="utf-8") == "hand written bridge\n"


def test_install_upgrades_a_file_it_still_owns(sandbox):
    _install(sandbox)
    sandbox.cli.write_text("stale release\n", encoding="utf-8")
    manifest = _manifest(sandbox)
    for entry in manifest["files"]:
        if entry["path"] == str(sandbox.cli.resolve()):
            entry["sha256"] = _sha256(sandbox.cli)
    sandbox.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    result = _install(sandbox)

    assert result.returncode == 0, result.stderr
    assert sandbox.cli.read_bytes() == (ROOT / CLI_NAME).read_bytes()


def test_install_refuses_to_overwrite_a_file_the_user_edited(sandbox):
    _install(sandbox)
    sandbox.cli.write_text("local debugging edit\n", encoding="utf-8")

    result = _install(sandbox)

    assert result.returncode != 0
    assert sandbox.cli.read_text(encoding="utf-8") == "local debugging edit\n"


def test_install_force_overwrites_a_file_the_user_edited(sandbox):
    _install(sandbox)
    sandbox.cli.write_text("local debugging edit\n", encoding="utf-8")

    result = _install(sandbox, "-ForceOverwriteModified")

    assert result.returncode == 0, result.stderr
    assert sandbox.cli.read_bytes() == (ROOT / CLI_NAME).read_bytes()
    assert _sha256(sandbox.cli) in json.dumps(_manifest(sandbox))


def test_install_aborts_when_a_manifest_points_at_other_targets(sandbox, tmp_path):
    _install(sandbox)
    other_python = tmp_path / "python2"
    other_capture = tmp_path / "capture2"

    result = _run(
        INSTALL,
        [
            "-PythonTarget",
            str(other_python),
            "-CaptureTclTarget",
            str(other_capture),
            "-RuntimeSource",
            str(sandbox.runtime_source),
        ],
        local_app_data=sandbox.local_app_data,
        skip_runtime_validation=True,
    )

    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert "uninstall" in combined.lower()
    assert "no files were copied or overwritten" in combined.lower()
    assert not other_python.exists()
    assert not other_capture.exists()
    assert Path(_manifest(sandbox)["pythonTarget"]) == sandbox.python_target.resolve()


def test_install_requires_the_bundled_runtime(sandbox):
    shutil.rmtree(sandbox.runtime_source)

    result = _install(sandbox)

    assert result.returncode != 0
    assert "bundled runtime is missing" in (result.stdout + result.stderr).lower()
    assert not sandbox.server.exists()


def test_tcl_resolves_the_installed_python_target(sandbox, tmp_path):
    _install(sandbox)
    probe = tmp_path / "probe.tcl"
    probe.write_text(
        f"source {json.dumps(str(ROOT / TCL_NAME))}\n"
        "puts [_captureAiResolvePythonPath]\n",
        encoding="utf-8",
    )
    env = dict(os.environ)
    env["LOCALAPPDATA"] = str(sandbox.local_app_data)
    tclsh = shlex.split(env.get("CAPTURE_TCL_TCLSH", "tclsh"))

    result = subprocess.run(
        [*tclsh, str(probe)],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )

    assert result.returncode == 0, result.stderr
    assert Path(result.stdout.strip()) == sandbox.python_target.resolve()


def test_uninstall_removes_unmodified_files_and_the_manifest(sandbox):
    _install(sandbox)

    result = _uninstall(sandbox)

    assert result.returncode == 0, result.stderr
    assert not sandbox.server.exists()
    assert not sandbox.cli.exists()
    assert not sandbox.mcp.exists()
    assert not sandbox.tcl.exists()
    assert not sandbox.runtime_target.exists()
    assert not sandbox.manifest_path.exists()


def test_uninstall_keeps_target_directories_and_foreign_files(sandbox):
    _install(sandbox)
    neighbour = sandbox.python_target / "other_project.py"
    neighbour.write_text("unrelated\n", encoding="utf-8")

    assert _uninstall(sandbox).returncode == 0
    assert sandbox.python_target.is_dir()
    assert sandbox.capture_target.is_dir()
    assert neighbour.read_text(encoding="utf-8") == "unrelated\n"


def test_uninstall_keeps_modified_files_and_rewrites_the_manifest(sandbox):
    _install(sandbox)
    sandbox.cli.write_text("local debugging edit\n", encoding="utf-8")

    result = _uninstall(sandbox)

    assert result.returncode == 0, result.stderr
    assert sandbox.cli.read_text(encoding="utf-8") == "local debugging edit\n"
    assert not sandbox.server.exists()
    assert not sandbox.tcl.exists()
    remaining = _manifest(sandbox)
    assert [entry["path"] for entry in remaining["files"]] == [
        str(sandbox.cli.resolve())
    ]


def test_uninstall_force_removes_modified_files(sandbox):
    _install(sandbox)
    sandbox.cli.write_text("local debugging edit\n", encoding="utf-8")

    result = _uninstall(sandbox, "-ForceModified")

    assert result.returncode == 0, result.stderr
    assert not sandbox.cli.exists()
    assert not sandbox.manifest_path.exists()


def test_uninstall_refuses_a_path_outside_the_recorded_targets(sandbox, tmp_path):
    _install(sandbox)
    outsider = tmp_path / "elsewhere" / CLI_NAME
    outsider.parent.mkdir(parents=True)
    shutil.copyfile(sandbox.cli, outsider)
    manifest = _manifest(sandbox)
    manifest["files"].append(
        {"path": str(outsider), "sha256": _sha256(outsider)}
    )
    sandbox.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    result = _uninstall(sandbox)

    assert result.returncode != 0
    assert outsider.exists()
    assert sandbox.server.exists(), "a rejected manifest must delete nothing"
    assert sandbox.cli.exists()
    assert sandbox.mcp.exists()
    assert sandbox.tcl.exists()


def test_uninstall_refuses_a_foreign_project_manifest(sandbox):
    _install(sandbox)
    manifest = _manifest(sandbox)
    manifest["project"] = "tcl-bom"
    sandbox.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    result = _uninstall(sandbox)

    assert result.returncode != 0
    assert sandbox.server.exists()
    assert sandbox.manifest_path.exists()
