#!/usr/bin/env python3
# Copyright (C) 2026 KOLibby contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Check the runtime manifest/source match and common accidental-private-data patterns.

This is a release check, not a guarantee that a human privacy review is unnecessary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

root=Path(__file__).resolve().parents[1]
version=(root/'VERSION').read_text().strip()
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive',type=Path,default=root/f'dist/KOLibby-{version}.zip')
args=parser.parse_args()
for file in root.rglob('*'):
    if not file.is_file() or any(part in {'.git','dist','.local','__pycache__'} for part in file.relative_to(root).parts):
        continue
    text=file.read_text(errors='replace')
    patterns=[r'/'+r'Users/[^/\s]+/',r'/'+r'home/[^/\s]+/',
              r'github_pat_[A-Za-z0-9_]{20,}',r'gh[pousr]_[A-Za-z0-9]{25,}',
              r'-----BEGIN [A-Z ]*PRIVATE KEY-----',r'Bearer [A-Za-z0-9_.-]{30,}']
    if any(re.search(pattern,text) for pattern in patterns):
        raise SystemExit(f'Review possible private material in {file.relative_to(root)}')
    if file.name in {'identity.json','shelf.json','downloads.json','cookies.txt'}:
        raise SystemExit(f'Local state must not be in the source tree: {file.relative_to(root)}')
with zipfile.ZipFile(args.archive) as archive:
    names=archive.namelist()
    assert len(names)==len(set(names)), 'Duplicate ZIP entries'
    assert all(name.startswith('KOLibby.koplugin/') for name in names)
    prefix='KOLibby.koplugin/'
    manifest=json.loads(archive.read(prefix+'release.json'))
    assert manifest['version']==version
    assert set(names)=={prefix+'release.json'}|{prefix+n for n in manifest['files']}
    assert archive.read(prefix+'VERSION')==(version+'\n').encode()
    assert archive.testzip() is None
    for name,info in manifest['files'].items():
        assert name in {'main.lua','_meta.lua','README.md','LICENSE','NOTICE','VERSION'} or re.fullmatch(r'kolibby/[a-z][a-z0-9_]*\.lua',name)
        data=archive.read(prefix+name)
        assert len(data)==info['bytes'] and hashlib.sha256(data).hexdigest()==info['sha256']
        assert data==(root/name).read_bytes(), f'Packaged file differs from source: {name}'
    assert b'GNU AFFERO GENERAL PUBLIC LICENSE' in archive.read(prefix+'LICENSE')
    assert b'AGPL-3.0-only' in archive.read(prefix+'NOTICE')
sidecar=args.archive.with_suffix(args.archive.suffix+'.sha256').read_text().split()[0]
assert hashlib.sha256(args.archive.read_bytes()).hexdigest()==sidecar
print(f'Package/source checks and common privacy-pattern scan passed for {version}')
