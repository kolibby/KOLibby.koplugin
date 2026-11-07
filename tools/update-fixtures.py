#!/usr/bin/env python3
# Copyright (C) 2026 KOLibby contributors
# SPDX-License-Identifier: AGPL-3.0-only
from pathlib import Path
import hashlib,json,subprocess,shutil,zipfile,warnings
import argparse
import tempfile
parser=argparse.ArgumentParser(description='Generate isolated local updater fixtures; no account access or publishing.')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
candidate=Path(tempfile.mkdtemp(prefix='kolibby-update-build-'))
for name in ['main.lua','_meta.lua','README.md','LICENSE','NOTICE','VERSION']:
 shutil.copy2(root/name,candidate/name)
(candidate/'kolibby').mkdir()
for file in (root/'kolibby').glob('*.lua'):shutil.copy2(file,candidate/'kolibby'/file.name)
(candidate/'tools').mkdir();shutil.copy2(root/'tools/package.py',candidate/'tools/package.py')
(candidate/'VERSION').write_text('0.5.1\n')
subprocess.run(['python3',str(candidate/'tools/package.py')],check=True,capture_output=True)
output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(candidate/'dist/KOLibby-0.5.1.zip') as archive:
 base={n:archive.read(n) for n in archive.namelist()}
prefix='KOLibby.koplugin/'
index={}
def write(name,files,manifest=True,duplicate=False,symlink=False):
 files=dict(files)
 if manifest:
  files[prefix+'release.json']=(json.dumps({'version':'0.5.1','files':{n[len(prefix):]:{'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()} for n,b in files.items() if n!=prefix+'release.json'}})+'\n').encode()
 p=output/(name+'.zip')
 with warnings.catch_warnings():
  warnings.simplefilter('ignore',UserWarning)
  with zipfile.ZipFile(p,'w',compression=zipfile.ZIP_DEFLATED) as z:
   for n,b in files.items():z.writestr(n,b)
   if duplicate:z.writestr(prefix+'main.lua',files[prefix+'main.lua'])
   if symlink:
    info=zipfile.ZipInfo(prefix+'kolibby/link.lua');info.create_system=3;info.external_attr=0o120777<<16
    z.writestr(info,'../../settings/identity.json')
 index[name]={'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
write('valid',base)
f=dict(base);f[prefix+'../escape.txt']=b'escape';write('traversal',f)
write('duplicate',base,duplicate=True)
write('symlink',base,symlink=True)
f=dict(base);f[prefix+'main.lua']=b'function invalid syntax';write('invalid-lua',f)
f=dict(base);f[prefix+'main.lua']+=b'\n-- mismatched data';write('bad-file-hash',f,manifest=False)
f=dict(base);f[prefix+'VERSION']=b'0.6.0\n';write('wrong-version',f)
f=dict(base);f.pop(prefix+'main.lua');write('missing-main',f)
f=dict(base);f[prefix+'kolibby/large.lua']=b'x'*(4*1024*1024+1);write('oversized-file',f)
f=dict(base)
for i in range(17):f[prefix+f'kolibby/bomb_{i}.lua']=b'x'*(4*1024*1024)
write('oversized-total',f)
f=dict(base)
for i in range(513):f[prefix+f'kolibby/extra_{i}.lua']=b'-- fixture'
write('too-many-files',f)
(output/'index.json').write_text(json.dumps(index))
print('Generated',len(index),'isolated update fixtures')

shutil.rmtree(candidate)
