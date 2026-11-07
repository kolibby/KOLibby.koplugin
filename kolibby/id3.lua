-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- ID3v2.3 with the CHAP/CTOC addendum. This module writes metadata only.
local M={}
function M.u32(n)
    assert(n>=0 and n<4294967296 and n==math.floor(n),'ID3 integer out of range')
    return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)
end
function M.synchsafe(n)
    assert(n>=0 and n<268435456,'ID3 tag too large')
    return string.char(math.floor(n/2097152)%128,math.floor(n/16384)%128,math.floor(n/128)%128,n%128)
end
local function utf16(value)
    local out={'\254\255'};local i=1
    value=tostring(value or ''):gsub('%z','')
    while i<=#value do
        local b=value:byte(i);local n,length
        if b<128 then n,length=b,1
        elseif b>=194 and b<=223 then n,length=b%32,2
        elseif b>=224 and b<=239 then n,length=b%16,3
        elseif b>=240 and b<=244 then n,length=b%8,4
        else error('Invalid UTF-8 metadata',0) end
        for k=1,length-1 do
            local c=value:byte(i+k)
            if not c or c<128 or c>191 then error('Invalid UTF-8 metadata',0) end
            n=n*64+c%64
        end
        if n>1114111 or n>=55296 and n<=57343 or length==2 and n<128 or length==3 and n<2048 or length==4 and n<65536 then error('Invalid UTF-8 metadata',0) end
        if n>=65536 then
            n=n-65536;local hi=55296+math.floor(n/1024);local lo=56320+n%1024
            out[#out+1]=string.char(math.floor(hi/256),hi%256,math.floor(lo/256),lo%256)
        else out[#out+1]=string.char(math.floor(n/256),n%256) end
        i=i+length
    end
    return table.concat(out)
end
local function frame(name,payload) return name..M.u32(#payload)..'\0\0'..payload end
local function text(name,value)
    if value==nil or value=='' then return '' end
    return frame(name,'\1'..utf16(value))
end
function M.encode(metadata,chapters,cover)
    assert(#chapters>0 and #chapters<=10000,'Unsupported chapter count')
    local parts={text('TIT2',metadata.title),text('TALB',metadata.title),text('TPE1',metadata.author),
        text('TCOM',metadata.narrator),text('TIT3',metadata.subtitle),text('TCON','Audiobook'),text('TLEN',metadata.duration_ms)}
    if cover and #cover.data<=2*1024*1024 and (cover.mime=='image/jpeg' or cover.mime=='image/png') then
        parts[#parts+1]=frame('APIC','\0'..cover.mime..'\0\3\0'..cover.data)
    end
    local ids={}
    for i,c in ipairs(chapters) do
        assert(c.start_ms>=0 and c.end_ms>c.start_ms and c.end_ms<4294967296,'Invalid chapter time')
        local id=string.format('ch%05d',i);ids[#ids+1]=id
        parts[#parts+1]=frame('CHAP',id..'\0'..M.u32(c.start_ms)..M.u32(c.end_ms)..string.rep('\255',8)..text('TIT2',c.title))
    end
    local function toc(id,children,top)
        return frame('CTOC',id..'\0'..string.char(top and 3 or 1,#children)..table.concat(children,'\0')..'\0'..text('TIT2','Chapters'))
    end
    if #ids<=255 then parts[#parts+1]=toc('toc',ids,true)
    else
        local groups={}
        for start=1,#ids,255 do
            local group={};for i=start,math.min(start+254,#ids) do group[#group+1]=ids[i] end
            local id='group'..#groups;groups[#groups+1]=id;parts[#parts+1]=toc(id,group,false)
        end
        parts[#parts+1]=toc('toc',groups,true)
    end
    local body=table.concat(parts)
    -- Like FFmpeg's v2.3 writer, omit optional legacy unsynchronisation.
    -- Modern readers skip this tag by its declared size, including binary APIC.
    if #body>4*1024*1024 then error('Audiobook metadata exceeds the supported size',0) end
    return 'ID3\3\0\0'..M.synchsafe(#body)..body
end
return M
