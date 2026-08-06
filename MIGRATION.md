# Capture Tcl AI bridge migration

This standalone repository imports the bridge baseline from
`D:\Documents\codeprj\tcl_bom`, worktree
`D:\Documents\codeprj\tcl_bom\.worktrees\capture-tcl-ai-bridge`, on branch
`codex/tcl-bridge-impl`.

## Baseline and source state

- Baseline commit: `2b86475` (`2b864757c2e84fff9550b933dbca802a04398ecd`).
- The source working tree intentionally had uncommitted bridge work at import:
  - modified: `captureAiBridge.tcl`, `capture_tcl_bridge_server.py`,
    `readme.md`, `tests/test_capture_ai_bridge.tcl`,
    `tests/test_capture_tcl_bridge_server.py`,
    `docs/superpowers/plans/2026-08-02-capture-tcl-ai-bridge.md`, and
    `docs/superpowers/specs/2026-08-02-capture-tcl-ai-bridge-design.md`;
  - untracked: `capture_tcl_cli.py`,
    `tests/test_capture_tcl_cli.py`,
    `tests/test_capture_tcl_bridge_integration.py`, and transient `.tmp/`
    test artifacts.
- The source status and commit were reconfirmed immediately before copying.
  No source file was edited or deleted by this migration.

## Imported files

| Source | Destination |
| --- | --- |
| `captureAiBridge.tcl` | `captureAiBridge.tcl` |
| `capture_tcl_bridge_server.py` | `capture_tcl_bridge_server.py` |
| `capture_tcl_cli.py` | `capture_tcl_cli.py` |
| `readme.md` | `README.md` (temporary migration compatibility mapping) |
| `tests/test_capture_ai_bridge.tcl` | `tests/test_capture_ai_bridge.tcl` |
| `tests/test_capture_tcl_bridge_server.py` | `tests/test_capture_tcl_bridge_server.py` |
| `tests/test_capture_tcl_cli.py` | `tests/test_capture_tcl_cli.py` |
| `tests/test_capture_tcl_bridge_integration.py` | `tests/test_capture_tcl_bridge_integration.py` |

The service continues to use localhost port `8767`.  Its runtime descriptor
remains compatible with the existing `capture_tcl_bridge.json` contract.

## Acceptance boundary

An unresolved HTTP 400 defect remains at this baseline.  This import does not
claim HTTP or real-OrCAD Capture acceptance.  `tcl_bom` remains the rollback
source until real Capture acceptance is completed; do not delete its worktree
or source files as part of this migration.
