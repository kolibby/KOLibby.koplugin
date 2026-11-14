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

## Concurrent downloads

Download all runs up to three loan subprocesses inside its existing cancellable
worker. Individual EPUB resources and MP3 parts stay sequential. Each loan creates
its own HTTP session after fork; the coordinator closes its shelf-sync session
before starting the pool. Only the coordinator writes shared download and identity
records, and it saves each completed loan before filling a free slot. Identity
refreshes use the worker's starting identity as a guard against stale siblings.

The loan workers inherit the coordinator's process group. KOReader's normal
cancellation kills the entire group; Linux also stops a worker when its coordinator
dies. Errors starting workers or persisting results stop the pool. Failed loans
free their slots so other loans can continue. Each worker has separate progress
and result files in the private batch cache. Completed results left by interruption
are recovered only for current eligible checkouts with existing output files.
Normal completion removes these temporary IPC files. Publication caches continue
to provide the existing resume behavior.

The portable suite covers scheduling, the three-loan limit, mixed media, reordered
completion, independent clients, storage/startup failures, result recovery and
progress updates. Run `tests/parallel_runtime.lua` in KOReader/LuaJIT by calling its
returned function with an isolated writable directory. It uses real processes,
synthetic publications and no network. It checks overlapping workers, process
groups, worker crashes, Cancel all and retrying an uncollected completion. It
removes its synthetic directory after success. Run it only from an isolated test
process; the test deliberately kills its own temporary coordinator group.

## Restart after an update

After successful activation, the completion dialog always offers **Restart KOReader**
and **Later**. Devices supporting automatic restart use KOReader's `Restart` event;
other devices use its normal `Exit` event and show a reminder to open KOReader
again. These events let KOReader save reader and plugin state before exiting.
Postponing keeps the existing restart-required guard: reopening KOLibby offers
the dialog again and further plugin operations wait until restart.
