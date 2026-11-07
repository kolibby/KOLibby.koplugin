# Release packaging

This document describes a future maintainer release. Building locally does not publish, create a tag or upload an asset.

1. Update the root `VERSION` file to a stable `major.minor.patch` value and write user-facing release notes.
2. Run `lua tests/run.lua`, check source syntax and run the applicable stock KOReader integration checks.
3. Run `python3 tools/package.py`. The output is `dist/KOLibby-<version>.zip` and its `.sha256` sidecar. Run `python3 tools/check-package.py` to check manifest/source agreement, archive integrity, license notices and common accidental privacy patterns. The ZIP contains only runtime files, VERSION, LICENSE/NOTICE, README and `release.json`. This automated scan complements the human review; it is not a guarantee against every kind of private data.
4. Review the source/artifacts for private state and confirm that distributed corresponding source matches the packaged runtime.
5. When publication has been authorized, publish that source and create a stable GitHub release tagged `v<version>` (a tag without the leading `v` also works). Attach the matching `KOLibby-<version>.zip` to that release and include release notes. GitHub's automatically generated source archive is not the runtime package.
6. Wait for the asset to reach uploaded state with its GitHub `sha256:` digest. The updater requires that digest and the exact versioned asset name. A sidecar is useful for manual verification but does not replace GitHub's asset metadata.

The updater reads the latest full release from `kolibby/KOLibby.koplugin`, ignores drafts/prereleases and refuses equal or older versions. It does not create repositories, push commits, create releases or upload anything. No GitHub token is stored or required for public updates.

## Recovery

A successful self-update keeps the previous runtime in a sibling directory named `<installed-plugin-folder>.update-backup`. The next successful update replaces that backup. If an interrupted activation leaves the plugin missing or unusable, close KOReader and restore the backup to the original plugin folder name. Libby credentials/settings and downloaded books are stored separately and are not part of the runtime swap.

Self-update is disabled for Git checkouts and symlink plugin roots. Use Git or a manual runtime ZIP installation for those development layouts. A failed validation leaves the active plugin intact; a cancelled preparation can be started again.

## Privacy and licensing

Do not include identities, card/account data, captures, downloaded books, screenshots of personal shelves, local paths or personal Git attribution in release assets or source history. Preserve the AGPL-3.0-only project notice and upstream third-party notices. The runtime ZIP contains no test dependencies; bundled test-only dkjson retains its upstream MIT license in source.
