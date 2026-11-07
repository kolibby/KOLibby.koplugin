#!/usr/bin/env python3
# Copyright (C) 2026 KOLibby contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Independent development verification; FFmpeg is not a plugin dependency.

Generate real encoded MP3 fixtures, remux them using KOLibby's Lua modules,
compare packet hashes and FFmpeg stream-copy output, and parse/decode the result.
Optional --parts/--joined checks an authorized native download already on disk.
No network access, account state, or signed resource URLs are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, **kwargs):
    try:
        return subprocess.run([str(a) for a in args], check=True, capture_output=True, **kwargs).stdout
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(exc.stderr.decode(errors='replace')) from exc

def probe(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_format', '-show_chapters', '-show_streams', '-of', 'json', path]))

def packets(path):
    data = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_packets',
                          '-show_entries', 'packet=data_hash', '-show_data_hash', 'sha256', '-of', 'json', path]))
    return [p['data_hash'] for p in data['packets']]

def verify(parts, joined, work, expected_chapters=None):
    expected = [h for part in parts for h in packets(part)]
    actual = packets(joined)
    assert actual == expected, 'Encoded audio packet bytes changed or went missing'
    metadata = probe(joined)
    chapters = metadata['chapters']
    assert chapters and (expected_chapters is None or len(chapters) == expected_chapters)
    with joined.open('rb') as stream:
        assert stream.read(6) == b'ID3\x03\x00\x00'
    assert all(float(c['end_time']) > float(c['start_time']) for c in chapters)
    for left, right in zip(chapters, chapters[1:]):
        assert left['end'] == right['start']
    concat = work/'input.ffconcat'
    concat.write_text('ffconcat version 1.0\n'+''.join("file '"+str(p).replace("'", "'\\''")+"'\n" for p in parts))
    baseline = work/'ffmpeg-baseline.mp3'
    run(['ffmpeg', '-v', 'error', '-y', '-safe', '0', '-f', 'concat', '-i', concat,
         '-c:a', 'copy', '-id3v2_version', '3', baseline])
    assert packets(baseline) == actual, 'Audio packet sequence differs from FFmpeg stream copy'
    run(['ffmpeg', '-v', 'error', '-xerror', '-i', joined, '-map', '0:a:0', '-f', 'null', '-'])
    # Seek using the newly built global Xing/Info table, including near each join.
    elapsed = 0.0
    for part in parts[:-1]:
        elapsed += float(probe(part)['format']['duration'])
        run(['ffmpeg', '-v', 'error', '-xerror', '-ss', max(0, elapsed-.2), '-i', joined,
             '-t', '0.4', '-map', '0:a:0', '-f', 'null', '-'])
    digest = hashlib.sha256('\n'.join(actual).encode()).hexdigest()
    return {'parts': len(parts), 'packets': len(actual), 'chapters': len(chapters),
            'duration': metadata['format']['duration'], 'packet_sequence_sha256': digest,
            'frame_copy': True, 'ffmpeg_copy_match': True, 'full_decode': True, 'join_seeks': True}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lua', default='lua')
parser.add_argument('--parts', type=Path)
parser.add_argument('--joined', type=Path)
args = parser.parse_args()
assert bool(args.parts) == bool(args.joined), '--parts and --joined must be supplied together'
for tool in ['ffmpeg', 'ffprobe', args.lua]:
    assert shutil.which(tool), f'Missing development tool: {tool}'
with tempfile.TemporaryDirectory(prefix='kolibby-audio-verify-') as temporary:
    work = Path(temporary)
    harness = work/'remux.lua'
    harness.write_text("""
package.path='./?.lua;'..package.path
local M=require('kolibby/mp3');local ID3=require('kolibby/id3')
local parts,chapters,total={},{},0
for i=2,#arg do
 local info=M.inspect(arg[i]);parts[#parts+1]={file=arg[i],info=info}
 chapters[#chapters+1]={title='第一章 🌍 '..i,start_ms=math.floor(total*1000+.5),end_ms=math.floor((total+info.duration)*1000+.5)}
 total=total+info.duration
end
local tag=ID3.encode({title='Café 🌍',author='Writer',narrator='Narrator',duration_ms=math.floor(total*1000+.5)},chapters)
M.join(parts,arg[1],tag)
""")
    results = {}
    for name, rate, channels, encoding in [('cbr-stereo', 44100, 2, ['-b:a','64k']),
                                          ('vbr-stereo', 44100, 2, ['-q:a','4']),
                                          ('mpeg2-mono', 22050, 1, ['-b:a','48k'])]:
        parts = [work/f'{name}-{i}.mp3' for i in [1, 2]]
        for i, part in enumerate(parts):
            run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'sine=frequency={440+i*220}:duration=2',
                 '-ar', rate, '-ac', channels, '-codec:a', 'libmp3lame', *encoding, part])
        joined = work/f'{name}-joined.mp3'
        run([args.lua, harness, joined, *parts], cwd=ROOT)
        results[name] = verify(parts, joined, work, 2)
        metadata = probe(joined)
        assert metadata['format']['tags']['title'] == 'Café 🌍'
        assert metadata['chapters'][0]['tags']['title'] == '第一章 🌍 2'
    # FFprobe independently reads large chapter maps, including the CTOC hierarchy.
    large_harness = work/'large-toc.lua'
    large_harness.write_text("""
package.path='./?.lua;'..package.path
local M=require('kolibby/mp3');local ID3=require('kolibby/id3')
local info=M.inspect(arg[2]);local chapters={}
local duration=math.floor(info.duration*1000+.5)
for i=1,260 do chapters[i]={title='Chapter '..i,start_ms=math.floor((i-1)*duration/260),end_ms=math.floor(i*duration/260)} end
M.join({{file=arg[2],info=info}},arg[1],ID3.encode({title='Large TOC'},chapters))
""")
    large = work/'large-toc.mp3'
    run([args.lua, large_harness, large, parts[0]], cwd=ROOT)
    assert len(probe(large)['chapters']) == 260
    results['large-toc'] = {'chapters': 260, 'ffprobe_parse': True}
    if args.parts:
        parts = sorted(args.parts.resolve().glob('*.mp3'))
        assert parts, 'No MP3 parts found'
        results['native'] = verify(parts, args.joined.resolve(), work)
    print(json.dumps(results, indent=2))
