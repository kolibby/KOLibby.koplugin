# Publication privacy

Source and runtime packages must exclude credentials, account data, downloaded
publications, screenshots and captures. Regression tests use synthetic identifiers
and data. Keep internal research and comparison material outside the public tree.

The runtime archive contains plugin source, VERSION, README, LICENSE/NOTICE and its
file manifest. Development files and private state are excluded.

Run `python3 tools/check-package.py` before preparing a release. Its automated
checks complement a manual source and artifact review; they do not replace one.
Preserve upstream attribution and the project's AGPL-3.0-only notices.
