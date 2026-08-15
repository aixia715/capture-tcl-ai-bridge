# Capture AI Bridge

This context connects an AI agent to OrCAD Capture designs while preserving explicit control over which design is accessed and when changes become persistent.

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

**Active Design**:
The design currently open in the OrCAD Capture user interface. Changes to it remain subject to the user's decision to save or discard them.
_Avoid_: Current file, GUI design

**Offline Design**:
A Capture design identified by its DSN file path and accessed independently of the OrCAD Capture user interface. A successful property change to it is persistent.
_Avoid_: Active Design, headless design, open design

**Occurrence Property**:
A property directly owned by one component occurrence, distinct from an effective value inherited from a page instance or shared definition. Offline Design property changes operate only at this layer.
_Avoid_: Instance property, inherited property

**Occurrence Property Set**:
Assignment of a value on a specific component occurrence. It replaces an existing Occurrence Property or creates an occurrence override, without modifying the source of an inherited value.
_Avoid_: Property update, property create
