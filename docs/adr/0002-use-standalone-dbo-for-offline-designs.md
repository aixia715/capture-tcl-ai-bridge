# Use standalone DBO sessions for Offline Designs

Offline Design tools launch the SPB 16.6 `tclsh.exe`, load the matching `orDb_Dll_TCL`, and open an explicit DSN in a short-lived DBO session instead of launching `capture.exe` or routing work through the GUI bridge. Cadence's documented `capture <script>` path still opens Capture, while standalone DBO provides the required no-GUI boundary and lets writes be staged, saved, and verified in a fresh process before publication.
