# Capture AI Bridge

This context connects an AI agent to the design currently open in OrCAD Capture while preserving the user's control over review and saving.

## Language

**Current Selection**:
The set of page objects selected in the active OrCAD Capture user interface at the time a selection inspection begins.
_Avoid_: Saved selection, persistent selection

**Component Locator**:
The paired identities returned for a component: an occurrence identity (`design`, `refdes`, and hierarchical `path`) for logical property operations, and a page-instance identity (`design`, `page`, and `object_id`) for graphical page operations.
_Avoid_: Object handle, selection handle

**Page Object Locator**:
The design-bound identity for a supported non-component page object: `design`, `page`, normalized `kind`, and Capture `object_id`. A later mutation must re-resolve and validate every part; it must never fall back to approximate matching.
_Avoid_: Tcl handle, fuzzy locator

**Component Information**:
The shared result contract used whether a component was discovered from the Current Selection or by traversing the design. It contains both Component Locator identities and requested effective-property presence records.
_Avoid_: Selection component, read component record
