# Runtime packaging

The release workflow creates a Windows x64 ZIP containing Python 3.12 embeddable,
FastAPI, Uvicorn, and their transitive dependencies. End users run `install.ps1`;
the installer never downloads packages or uses a system Python.

The repository intentionally does not commit `runtime/`: it is generated only in
the release archive. Running `install.ps1` directly from a source checkout reports
that the bundled runtime is missing.
