-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Bounded MPEG Layer III frame remuxer. Audio payload bytes are never re-encoded.
local ID3=require('kolibby/id3')
local M={}
local rates1={32,40,48,56,64,80,96,112,128,160,192,224,256,320}
local rates2={8,16,24,32,40,48,56,64,80,96,112,128,144,160}
local function bad() error('An audiobook part is incomplete or uses an unsupported MP3 encoding.',0) end
local function be(s) local n=0;for i=1,#s do n=n*256+s:byte(i) end;return n end
local function le(s) return be(s:reverse()) end
function M.header(s)
    if not s or #s~=4 then return nil end
    local a,b,c,d=s:byte(1,4)
    local version=math.floor(b/8)%4
    local layer=math.floor(b/2)%4
    local index=math.floor(c/16)
    local rate_index=math.floor(c/4)%4
    if a~=255 or b<224 or version==1 or layer~=1 or index==0 or index==15 or rate_index==3 then return nil end
    local rate=({44100,48000,32000})[rate_index+1]/(version==3 and 1 or version==2 and 2 or 4)
    local bitrate=(version==3 and rates1 or rates2)[index]
    return {version=version,channels=math.floor(d/64)==3 and 1 or 2,rate=rate,bitrate=bitrate,
        samples=version==3 and 1152 or 576,size=math.floor((version==3 and 144000 or 72000)*bitrate/rate)+math.floor(c/2)%2,
        bytes=s}
end
local function same(a,b) return a.version==b.version and a.channels==b.channels and a.rate==b.rate end
local function metadata_frame(data,h)
    local side=h.version==3 and (h.channels==1 and 17 or 32) or (h.channels==1 and 9 or 17)
    local marker=data:sub(5+side,8+side)
    return marker=='Xing' or marker=='Info' or data:sub(37,40)=='VBRI'
end
local function bounds(file,size)
    local start,finish=0,size
    file:seek('set',0)
    while true do
        local header=file:read(10)
        if not header or header:sub(1,3)~='ID3' then break end
        if #header~=10 then bad() end
        local version=header:byte(4);if version<2 or version>4 then bad() end
        local n=0
        for i=7,10 do local b=header:byte(i);if b>=128 then bad() end;n=n*128+b end
        if n>16*1024*1024 then bad() end
        start=start+10+n+(version==4 and math.floor(header:byte(6)/16)%2==1 and 10 or 0)
        if start>=finish then bad() end;file:seek('set',start)
    end
    -- Standard trailers may occur in either order; never search audio payload.
    while finish>start do
        local id3=false
        if finish-start>=128 then file:seek('set',finish-128);id3=file:read(3)=='TAG' end
        if id3 then finish=finish-128
        elseif finish-start>=32 then
            file:seek('set',finish-32);local tail=file:read(32)
            if not tail or tail:sub(1,8)~='APETAGEX' then break end
            local n=le(tail:sub(13,16));local flags=le(tail:sub(21,24))
            if le(tail:sub(9,12))~=2000 or n<32 or n>16*1024*1024 or finish-n<start then bad() end
            finish=finish-n
            if math.floor(flags/2147483648)%2==1 then
                if finish-start<32 then bad() end
                file:seek('set',finish-32)
                if file:read(8)~='APETAGEX' then bad() end
                finish=finish-32
            end
        else break end
    end
    return start,finish
end
local function scan(path,on_frame)
    local file=assert(io.open(path,'rb'))
    local ok,result=pcall(function()
        local size=file:seek('end');local start,finish=bounds(file,size)
        file:seek('set',start)
        local info={frames=0,bytes=0,first=start,finish=finish,file_size=size}
        local position=start
        while position<finish do
            local head=file:read(4);local h=M.header(head);if not h or position+h.size>finish then bad() end
            local rest=file:read(h.size-4);if not rest or #rest~=h.size-4 then bad() end
            local data=head..rest
            if position==start and metadata_frame(data,h) then info.first=position+h.size
            else
                -- A separately downloaded part must not depend on a previous
                -- part's bit reservoir. CRC, when present, precedes side info.
                if info.frames==0 then
                    local offset=5+(h.bytes:byte(2)%2==0 and 2 or 0)
                    local reservoir=h.version==3 and (data:byte(offset)*2+math.floor(data:byte(offset+1)/128)) or data:byte(offset)
                    if reservoir~=0 then bad() end
                end
                if info.header and not same(info.header,h) then bad() end
                info.header=info.header or h;info.frames=info.frames+1;info.bytes=info.bytes+#data
                if info.bitrate and info.bitrate~=h.bitrate then info.vbr=true end
                info.bitrate=info.bitrate or h.bitrate
                if on_frame then on_frame(data,h,info) end
            end
            position=position+h.size
        end
        if info.frames==0 then bad() end
        info.duration=info.frames*info.header.samples/info.header.rate
        return info
    end)
    file:close();if not ok then error(result,0) end;return result
end
function M.inspect(path,progress)
    local last=0
    return scan(path,function(_,_,info)
        if progress and info.bytes-last>=1024*1024 then last=info.bytes;progress(info.bytes) end
    end)
end
local function seek_frame(header,frames,bytes,toc,vbr)
    local h=header.bytes
    -- No CRC, padding, or audio is placed in this new metadata frame.
    local side=header.version==3 and (header.channels==1 and 17 or 32) or (header.channels==1 and 9 or 17)
    local minimum=4+side+120
    local chosen
    for i,rate in ipairs(header.version==3 and rates1 or rates2) do
        local size=math.floor((header.version==3 and 144000 or 72000)*rate/header.rate)
        if size>=minimum then chosen={index=i,size=size};break end
    end
    assert(chosen,'Unsupported MP3 header')
    local b2=h:byte(2)-h:byte(2)%2+1
    local b3=chosen.index*16+math.floor(h:byte(3)/4)%4*4
    local prefix=string.char(255,b2,b3,h:byte(4))..string.rep('\0',side)
    local payload=(vbr and 'Xing' or 'Info')..ID3.u32(15)..ID3.u32(frames)..ID3.u32(bytes+chosen.size)..toc..ID3.u32(0)
    return prefix..payload..string.rep('\0',chosen.size-#prefix-#payload)
end
function M.join(parts,destination,tag,progress)
    local first=assert(parts[1]);local frames,bytes,vbr=0,0,false
    for _,part in ipairs(parts) do
        if not same(first.info.header,part.info.header) then error('MP3 parts have incompatible sample rates or channels; they cannot be joined without re-encoding.',0) end
        frames=frames+part.info.frames;bytes=bytes+part.info.bytes
        vbr=vbr or part.info.vbr or part.info.bitrate~=first.info.bitrate
    end
    if bytes>3*1024*1024*1024 then error('This audiobook exceeds the supported 3 GiB MP3 size.',0) end
    local dummy=seek_frame(first.info.header,frames,bytes,string.rep('\0',100),vbr)
    local out=assert(io.open(destination,'wb'))
    local ok,err=pcall(function()
        assert(out:write(tag,dummy))
        local toc={[1]=string.char(0)};local next_tick=1;local done,size,last=0,#dummy,0
        for _,part in ipairs(parts) do
            local checked=scan(part.file,function(data)
                while next_tick<100 and done>=math.floor(frames*next_tick/100) do
                    toc[next_tick+1]=string.char(math.min(255,math.floor(256*size/(#dummy+bytes))))
                    next_tick=next_tick+1
                end
                assert(out:write(data));done=done+1;size=size+#data
                if progress and size-last>=1024*1024 then last=size;progress(done,frames,size) end
            end)
            if checked.bytes~=part.info.bytes or checked.frames~=part.info.frames then bad() end
        end
        while next_tick<100 do toc[next_tick+1]=string.char(255);next_tick=next_tick+1 end
        out:seek('set',#tag);assert(out:write(seek_frame(first.info.header,frames,bytes,table.concat(toc),vbr)))
    end)
    local closed=out:close()
    if not ok or not closed then os.remove(destination);error(ok and 'Could not save the joined audiobook. Check available storage.' or err,0) end
    return frames*first.info.header.samples/first.info.header.rate
end
return M
