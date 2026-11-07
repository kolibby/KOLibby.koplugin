# Development

The repository is the plugin directory. Runtime code lives in `main.lua` and
`kolibby/`; `tests/` and `tools/` contain development-only checks and packaging tools.

## Local checks

Run the portable suite with a Lua 5.1-compatible interpreter:

```sh
lua tests/run.lua
```

Tests use synthetic data and do not need a Libby connection. The bundled test-only
dkjson copy retains its upstream MIT notice; production uses KOReader's bundled
module. Preserve all third-party notices when changing dependencies.

Check Lua syntax for changed files, then build and inspect the runtime package:

```sh
python3 tools/package.py
python3 tools/check-package.py
```

The package checker validates archive contents, manifest/source agreement, version,
license notices and common accidental private-data patterns. See
[release packaging](releases.md) for naming and update conventions.

## Device checks

Validate UI and file behavior on a test installation of KOReader. Keep test data
separate from real settings and downloads, and preserve the user's reading session.
Check new controls, empty states, cancellation and restart behavior as applicable.
Validate generated EPUBs with EPUBCheck and inspect audiobook output with an
independent audio tool or player when changing those paths.

The runtime integration checks under `tests/` use isolated fixtures. Development
files are excluded from the installable archive. Remove temporary hooks and test
files after validation.

## Contribution boundaries

Keep credentials, account data, downloaded publications, screenshots and captures
out of source and releases. Error messages must not expose secrets or raw service
responses. Use invented identifiers in regression tests.

Preserve existing settings and completed downloads during updates. Keep changes
local until publication is authorized. Project code is AGPL-3.0-only; see the root
LICENSE and NOTICE.
