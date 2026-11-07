-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Structural fixtures are intentionally generated; real encoded audio is checked
-- separately by tools/audio-verify.py with FFmpeg/FFprobe.
return function(test,eq,fails,contains)
local A=require('kolibby/audiobook')
local MP3=require('kolibby/mp3')
local ID3=require('kolibby/id3')
local U=require('kolibby/util')
local function manifest()
 local spine,entries={},{}
 for i,name in ipairs({'Z {1}.mp3','A {2}.mp3','B {3}.mp3'}) do
  spine[i]={path=U.urlencode(name),['media-type']='audio/mpeg',['audio-duration']=10}
  entries[4-i]={url='https://a.listen.libbyshelf.com/path/'..U.urlencode(name),bytes=1000}
 end
 return {{group='title-content',entries=entries,version=1,id='audio'}},{spine=spine}
end
local function parts()
 return {{path='one.mp3',duration=10},{path='two.mp3',duration=10},{path='three.mp3',duration=10}}
end
local function chapter(book,p) return A.chapters({nav={toc=book}},p or parts()) end
local function file(data)
 local name=os.tmpname();local f=assert(io.open(name,'wb'));assert(f:write(data));assert(f:close());return name
end
local function using(data,fn)
 local name=file(data);local ok,err=pcall(fn,name);os.remove(name);assert(ok,err)
end
local function frame(header,fill)
 local h=assert(MP3.header(header));return header..string.rep('\0',32)..string.rep(fill or 'A',h.size-36)
end
local h1='\255\251\080\100' -- MPEG1, 64kbps, 44100, stereo
local h2='\255\243\128\192' -- MPEG2, 64kbps, 22050, mono
local function be(s) local n=0;for i=1,#s do n=n*256+s:byte(i) end;return n end
local function frames(tag,offset,finish)
 local out={};offset=offset or 11;finish=finish or #tag
 while offset<=finish do
  local id=tag:sub(offset,offset+3);local n=be(tag:sub(offset+4,offset+7));assert(n>0 and offset+9+n<=finish)
  out[#out+1]={id=id,body=tag:sub(offset+10,offset+9+n)};offset=offset+10+n
 end
 eq(offset,finish+1);return out
end
local function tag(count,cover)
 local chapters={};for i=1,count do chapters[i]={title='第一章 🌍 '..i,start_ms=(i-1)*1000,end_ms=i*1000} end
 return ID3.encode({title='Café 🌍',author='Author',narrator='Narrator',duration_ms=count*1000},chapters,cover)
end

test('Native audio plan follows spine order and decodes component names',function()
 local r,b=manifest();local p=A.plan(r,b);eq(p.parts[1].path,'Z {1}.mp3');eq(p.parts[2].path,'A {2}.mp3');eq(p.bytes,3000)
end)
test('Native audio rejects unsupported codecs and missing parts',function()
 local r,b=manifest();b.spine[1]['media-type']='audio/mp4';fails(function() A.plan(r,b) end,'not MP3')
 r,b=manifest();table.remove(r[1].entries,1);fails(function() A.plan(r,b) end,'incomplete')
end)
test('Ambiguous basenames remain ambiguous after a third collision',function()
 local r,b=manifest();local url=r[1].entries[1].url
 r[1].entries[2].url=url:gsub('/path/','/second/');r[1].entries[3].url=url:gsub('/path/','/third/')
 b.spine={b.spine[3]};fails(function() A.plan(r,b) end,'incomplete')
end)
test('Duplicate native addresses are rejected',function()
 local r,b=manifest();r[1].entries[2].url=r[1].entries[1].url;fails(function() A.plan(r,b) end,'Duplicate')
end)
test('Audio roster bounds and resource hosts are checked',function()
 local r,b=manifest();r[1].entries[1].bytes=256*1024*1024+1;fails(function() A.plan(r,b) end,'part size')
 r,b=manifest();r[1].entries[1].url='https://unrelated.example/B%20%7B3%7D.mp3';fails(function() A.plan(r,b) end,'incomplete')
end)
test('Fractional chapter offsets keep milliseconds on the actual frame timeline',function()
 local p=parts();p[1].info={duration=10.02}
 local c,n=chapter({{title='One',path='one.mp3#0.125'},{title='Two',path='two.mp3#1.2345'}},p)
 eq(c[1].start_ms,125);eq(c[2].start_ms,11255);eq(c[1].end_ms,11255);eq(n,30020)
end)
test('Normalized component paths are percent-decoded exactly once',function()
 local c=chapter({{title='Literal percent',path='one%2520.mp3'}},{{path='one%20.mp3',duration=10}})
 eq(c[1].start_ms,0);eq(c[1].end_ms,10000)
end)
test('Same chapter continued across three parts becomes one chapter',function()
 local c=chapter({{title='Long',path='one.mp3'},{title='Long',path='two.mp3'},{title='Long',path='three.mp3'}})
 eq(#c,1);eq(c[1].end_ms,30000)
end)
test('Repeated chapter titles elsewhere remain distinct',function()
 local c=chapter({{title='Same',path='one.mp3'},{title='Other',path='one.mp3#5'},{title='Same',path='two.mp3#2'}})
 eq(#c,3);eq(c[3].start_ms,12000)
end)
test('Missing chapter map uses ordered part chapters',function()
 local c=chapter({});eq(#c,3);eq(c[2].title,'Part 2');eq(c[3].end_ms,30000)
end)
test('Nested chapters use leaves and invalid chapter references fail',function()
 local c=chapter({{title='Section',contents={{title='Leaf',path='one.mp3#1.5'}}}});eq(#c,1);eq(c[1].start_ms,1500)
 fails(function() chapter({{title='Bad',path='missing.mp3'}}) end,'reference')
 fails(function() chapter({{title='Bad',path='one.mp3#20'}}) end,'reference')
end)
test('ID3v2.3 uses synchsafe tag size and UTF16 text with ordinary frame sizes',function()
 local t=tag(2);eq(t:sub(1,6),'ID3\3\0\0');local size=0
 for i=7,10 do assert(t:byte(i)<128);size=size*128+t:byte(i) end;eq(size,#t-10)
 local f=frames(t);eq(f[1].id,'TIT2');eq(f[1].body:sub(1,3),'\1\254\255');contains(f[1].body,'\216\060\223\013')
end)
test('CHAP contains milliseconds unknown byte offsets and nested title',function()
 for _,f in ipairs(frames(tag(2))) do if f.id=='CHAP' then
  local z=assert(f.body:find('\0',1,true));eq(be(f.body:sub(z+1,z+4)),0);eq(be(f.body:sub(z+5,z+8)),1000)
  eq(f.body:sub(z+9,z+16),string.rep('\255',8));eq(frames(f.body,z+17)[1].id,'TIT2');return
 end end;error('No CHAP')
end)
test('More than 255 chapters have a bounded ordered CTOC hierarchy',function()
 local count,tocs=0,{}
 for _,f in ipairs(frames(tag(256))) do
  if f.id=='CHAP' then count=count+1 end
  if f.id=='CTOC' then tocs[#tocs+1]=f.body end
 end
 eq(count,256);eq(#tocs,3);eq(tocs[3]:sub(1,6),'toc\0\3\2')
end)
test('APIC is a front cover and invalid UTF8 metadata fails',function()
 local t=tag(1,{mime='image/jpeg',data='\255\216\255image'});local found=false
 for _,f in ipairs(frames(t)) do if f.id=='APIC' then eq(f.body,'\0image/jpeg\0\3\0\255\216\255image');found=true end end;assert(found)
 fails(function() ID3.encode({title='\237\160\128'},{{title='C',start_ms=0,end_ms=1}}) end,'UTF-8')
end)
test('MPEG1 and MPEG2 headers yield correct sizes samples and channels',function()
 local a,b=MP3.header(h1),MP3.header(h2);eq(a.size,208);eq(a.samples,1152);eq(a.channels,2)
 eq(b.size,208);eq(b.samples,576);eq(b.channels,1);eq(b.rate,22050);eq(MP3.header('junk'),nil)
end)
test('Frame scan strips leading ID3 and trailing ID3v1 APE tags',function()
 local ape='APETAGEX'..'\208\7\0\0'..'\32\0\0\0'..string.rep('\0',16)
 using(tag(1)..frame(h1)..frame(h1)..ape..'TAG'..string.rep('\0',125),function(p)
  local i=MP3.inspect(p);eq(i.frames,2);eq(i.bytes,416)
 end)
end)
test('Initial Info metadata frame is skipped and VBR is detected',function()
 local meta=h1..string.rep('\0',32)..'Info'..string.rep('\0',168)
 using(meta..frame(h1)..frame('\255\251\096\100'),function(p)
  local i=MP3.inspect(p);eq(i.frames,2);assert(i.vbr);eq(i.first,208)
 end)
end)
test('Incomplete frames junk and external reservoir dependencies are rejected',function()
 for _,data in ipairs({frame(h1):sub(1,-2),frame(h1)..'junk',h1..'\1'..string.rep('\0',203),'ID3\3'}) do
  using(data,function(p) fails(function() MP3.inspect(p) end) end)
 end
end)
test('Join copies every encoded frame byte and replaces stale seek headers',function()
 using(frame(h1,'B')..frame(h1,'C'),function(a)
  using(frame(h1,'D'),function(b)
   local dest=os.tmpname();local t=tag(1);local p={{file=a,info=MP3.inspect(a)},{file=b,info=MP3.inspect(b)}}
   MP3.join(p,dest,t);local f=assert(io.open(dest,'rb'));local out=f:read('*a');f:close();os.remove(dest)
   local h=MP3.header(out:sub(#t+1,#t+4));contains(out:sub(#t+1,#t+h.size),'Info')
   eq(out:sub(#t+h.size+1),frame(h1,'B')..frame(h1,'C')..frame(h1,'D'))
  end)
 end)
end)
test('Incompatible sample rates cannot produce a completed join',function()
 using(frame(h1),function(a) using(frame(h2),function(b)
  local dest=os.tmpname();fails(function() MP3.join({{file=a,info=MP3.inspect(a)},{file=b,info=MP3.inspect(b)}},dest,tag(1)) end,'incompatible');os.remove(dest)
 end) end)
end)
test('Failed remux removes incomplete destination and preserves existing final file',function()
 using(frame(h1),function(a)
  local final=file('previous complete MP3');local p={{file=a,info=MP3.inspect(a)}}
  local f=assert(io.open(a,'ab'));f:write('truncated');f:close()
  fails(function() MP3.join(p,final..'.part',tag(1)) end)
  eq(io.open(final..'.part','rb'),nil);f=assert(io.open(final,'rb'));eq(f:read('*a'),'previous complete MP3');f:close();os.remove(final)
 end)
end)
end
