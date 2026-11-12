# Validation

The portable Lua suite has 223 passing tests. It covers shelf reconciliation,
multiple and partner cards, download queuing, publication assembly, audiobook
output, networking, privacy and update handling. Tests use synthetic data.

Audiobook download regressions exercise the complete download/check/join pipeline
and a three-loan batch where roster byte counts differ from complete HTTP
responses. They cover actual-size cache reuse, legacy cache entries, changed
cached files, compressed transfer sizes, incomplete transfers, truncated frames
and missing audio detected by the native duration check.

Android checks have exercised pairing, shelf refresh, selected EPUB/MP3 downloads,
menu placement, progress, cancellation and update installation. The Loans action
and card-filtered action have also been exercised with isolated UI fixtures.
Generated sample EPUBs pass EPUBCheck; selected audio outputs have independent
frame, metadata, chapter and playback checks.

EPUB metadata tests cover full and short descriptions, publisher HTML, entities,
Unicode, paragraph breaks and malformed optional text. A complete download fixture
checks the packaged description and cached synopsis without extra requests. A
synthetic description EPUB passes EPUBCheck, and Calibre reads back its expected
Unicode text and paragraphs.

These checks cover selected publications and Android installations. They do not
establish compatibility with every library, publication, player or KOReader device.
Kobo and Kindle still need hardware validation. Fixed-layout EPUB rendering remains
limited by the reader. No real ready-hold offer was consumed for testing.

Update installation has isolated fixture coverage, including 14 Android checks
for validation, activation, recovery and restart behavior. Verify the public
release metadata and downloadable artifacts when publishing an update.

Startup regressions cover installations with only KOReader's bundled filesystem
module, only the legacy module, or both. They load the actual plugin entry point,
initialize storage, and verify Tools registration. Update checks use the same
selected backend. These tests reproduce the missing-menu startup failure before
the fix and pass after it.

The Android runtime also reproduces the old import failure with the legacy alias
unavailable, then verifies storage and update checks using KOReader's bundled
filesystem backend. The updated plugin appears at the top of the Tools menu.

Portable regressions also cover relative data-folder migration, FAT-compatible
resource cache names, background task completion and cancellation, progress
write throttling, network diagnostics and the configured TLS modes.

Compression runtime checks reproduce the shared zlib declaration conflict before
the fix and verify both plugin load orders afterward. Each run covers 18
decompression checks, including another caller's stream and garbage collection,
plus 16 local HTTPS checks. All six runs pass using the Kindle, Kindle PW2 and
Kindle HF ARM runtimes from KOReader 2026.07.1. These are isolated user-mode ARM
executions with synthetic traffic, rather than Kindle firmware or hardware tests.

Bookshelf source tests cover loans and holds across all cards or a selected card,
merged and removed cards, cached covers, existing and missing downloads, stale
checkouts, picker cancellation, optional tokens and plugin-instance changes.
The normal opening path retains loan-expiry checks, fixed-layout confirmation
and MP3 handling. Bookshelf is optional and is accessed through its documented
source interface rather than runtime patches.

Android emulator checks with Bookshelf 6.3.3 exercise actual source registration,
cover rendering, template tokens and the collection/card picker. Synthetic
circulation and download fixtures exercise hold confirmation, shelf refresh,
download completion, Bookshelf's reader opener and return from the reader. These
checks do not borrow a real hold or establish hardware compatibility on every
device. The Bookshelf integration has also been confirmed on a Clear7.
