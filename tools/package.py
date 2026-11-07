#!/usr/bin/env python3
# Copyright (C) 2026 KOLibby contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Build the reproducible runtime ZIP and its checked update manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

root = Path(__file__).resolve().parents[1]
version = (root/'VERSION').read_text().strip()
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
    raise SystemExit('VERSION must contain major.minor.patch')
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=root/f'dist/KOLibby-{version}.zip')
args = parser.parse_args()
files = [root/name for name in ['main.lua', '_meta.lua', 'README.md', 'LICENSE', 'NOTICE', 'VERSION']]
files += sorted((root/'kolibby').glob('*.lua'))
contents = {file.relative_to(root).as_posix(): file.read_bytes() for file in files}
manifest = {'version': version, 'files': {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()} for name, data in contents.items()}}
contents['release.json'] = (json.dumps(manifest, sort_keys=True, indent=2)+'\n').encode()
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for name, data in contents.items():
        info = zipfile.ZipInfo('KOLibby.koplugin/'+name, date_time=(1980,1,1,0,0,0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, data)
digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
args.output.with_suffix(args.output.suffix+'.sha256').write_text(f'{digest}  {args.output.name}\n')
print(f'{args.output}: {len(contents)} runtime files')
