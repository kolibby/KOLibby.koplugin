# Validation

The portable Lua suite has 168 passing tests. It covers shelf reconciliation,
multiple and partner cards, download queuing, publication assembly, audiobook
output, networking, privacy and update handling. Tests use synthetic data.

Android checks have exercised pairing, shelf refresh, selected EPUB/MP3 downloads,
menu placement, progress, cancellation and update installation. The Loans action
and card-filtered action have also been exercised with isolated UI fixtures.
Generated sample EPUBs pass EPUBCheck; selected audio outputs have independent
frame, metadata, chapter and playback checks.

These checks cover selected publications and Android installations. They do not
establish compatibility with every library, publication, player or KOReader device.
Kobo and Kindle still need hardware validation. Fixed-layout EPUB rendering remains
limited by the reader. No real ready-hold offer was consumed for testing.

Update installation has isolated fixture coverage. Testing a publicly hosted update
remains a release step once publication is authorized.
