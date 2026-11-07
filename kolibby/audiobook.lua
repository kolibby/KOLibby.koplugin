-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local MP3=require('kolibby/mp3')
local ID3=require('kolibby/id3')
local Covers=require('kolibby/covers')
local M={}
local MAX_BYTES=3*1024*1024*1024
local function path(value)
    if type(value)~='string' then error('Missing native audiobook part address',0) end
    return U.urldecode(value:gsub('^https://[^/]+',''):match('^[^?#]*')):gsub('^/+','')
end
function M.plan(rosters,book)
    local entries,version,id
    for _,r in ipairs(rosters) do if r.group=='title-content' then entries=r.entries;version=r.version;id=r.id;break end end
    if type(entries)~='table' or type(book.spine)~='table' or #book.spine==0 or #book.spine>1000 then error('Unsupported native audiobook manifest',0) end
    local by_path,by_name={},{}
    for _,entry in ipairs(entries) do
        local p=path(entry.url)
        if by_path[p] then error('Duplicate native audiobook part address',0) end
        by_path[p]=entry
        local name=p:match('[^/]+$')
        if by_name[name]==nil then by_name[name]=entry else by_name[name]=false end
    end
    local parts,total,identity,seen={},0,{},{}
    for i,s in ipairs(book.spine) do
        if s['media-type']~='audio/mpeg' and s['media-type']~='audio/mp3' then error('This native audiobook is not MP3 and cannot be exported as MP3 without re-encoding.',0) end
        local p=path(s['-odread-original-path'] or s.path)
        local entry=by_path[p] or by_name[p:match('[^/]+$')]
        local duration=tonumber(s['audio-duration'])
        local size=entry and tonumber(entry.bytes or s['-odread-file-bytes'])
        if not entry or seen[entry] or not Covers.allowed(entry.url) or not size or size<=0 or size>256*1024*1024 or size~=math.floor(size) or
            not duration or duration<=0 or duration~=duration or duration==math.huge then error('The native audiobook roster is incomplete or exceeds the supported part size.',0) end
        seen[entry]=true;total=total+size
        if total>MAX_BYTES then error('This audiobook exceeds the supported 3 GiB size.',0) end
        parts[#parts+1]={entry=entry,path=p,bytes=size,duration=duration,index=i}
        identity[#identity+1]=p..':'..size..':'..duration
    end
    return {parts=parts,bytes=total,version=tostring(version),roster_id=id,fingerprint=U.hash(table.concat(identity,'\n'))}
end
function M.chapters(book,parts)
    local starts,lookup,total={},{},0
    for i,p in ipairs(parts) do starts[i]=total;lookup[p.path]=i;total=total+(p.info and p.info.duration or p.duration) end
    local chapters={}
    local function walk(rows)
        for _,c in ipairs(rows or {}) do
            local children=c.contents or c.children
            if type(children)=='table' and #children>0 then walk(children)
            elseif c.path then
                local i=lookup[path(c.path)]
                local fragment=c.path:match('#(.*)$')
                local offset=fragment and tonumber(fragment) or 0
                if not i or not offset or offset<0 or offset~=offset or offset>parts[i].duration+.5 then error('An audiobook chapter has an unsupported time or part reference.',0) end
                chapters[#chapters+1]={title=tostring(c.title or ('Chapter '..(#chapters+1))),part=i,offset=offset,start_ms=math.floor((starts[i]+offset)*1000+.5),order=#chapters+1}
            end
        end
    end
    walk(book.nav and book.nav.toc)
    local end_ms=math.floor(total*1000+.5)
    if #chapters==0 then
        for i,p in ipairs(parts) do chapters[#chapters+1]={title='Part '..i,part=i,offset=0,start_ms=math.floor(starts[i]*1000+.5),order=i} end
    end
    table.sort(chapters,function(a,b) return a.start_ms==b.start_ms and a.order<b.order or a.start_ms<b.start_ms end)
    local out,previous_source={},nil
    for _,c in ipairs(chapters) do
        local previous=out[#out]
        local continuation=previous_source and previous_source.title==c.title and c.offset==0 and c.part==previous_source.part+1
        if c.start_ms<end_ms and not (previous and (previous.start_ms==c.start_ms or continuation)) then
            out[#out+1]=c
        end
        previous_source=c
    end
    if #out==0 then error('The audiobook has no usable chapters.',0) end
    for i,c in ipairs(out) do c.end_ms=out[i+1] and out[i+1].start_ms or end_ms end
    return out,end_ms
end
local function creators(book,role,fallback)
    local out={}
    for _,v in ipairs(book.creator or {}) do
        if type(v.role)=='string' and v.role:lower()==role and type(v.name)=='string' then out[#out+1]=v.name end
    end
    return #out>0 and table.concat(out,', ') or fallback
end
function M.run(client,loan,card,opts)
    local Store=require('kolibby/store')
    if loan.media_type~='audiobook' or not loan.expires or loan.expires<=os.time() then error('This audiobook loan is expired or unavailable. Synchronize first.',0) end
    Store.mkdir(opts.directory)
    local work=opts.cache_dir..'/audio-'..U.hash(loan.key..':'..tostring(loan.checkout_id))
    local job=Store.new(work)
    local function progress(stage,done,total,bytes,extra)
        if opts.progress then opts.progress({kind='mp3',stage=stage,done=done,total=total,bytes=bytes,detail=extra}) end
    end
    progress('authorizing',0,0,0)
    local passport,rosters,book=client:publication(loan,card)
    if tonumber(passport.expires) and tonumber(passport.expires)<=os.time() then error('The audiobook grant expired. Try again.',0) end
    local plan=M.plan(rosters,book)
    local identity={key=loan.key,checkout_id=loan.checkout_id,version=plan.version,roster=plan.roster_id,fingerprint=plan.fingerprint}
    local cache=job:read('parts.json',{files={}})
    if type(cache.files)~='table' then cache.files={} end
    local old=type(cache.identity)=='table' and cache.identity or {}
    if old.key~=identity.key or old.checkout_id~=identity.checkout_id or old.version~=identity.version or old.roster~=identity.roster or old.fingerprint~=identity.fingerprint then
        Store.remove_tree(work..'/parts');cache={identity=identity,files={}}
    end
    Store.mkdir(work..'/parts')
    local completed_bytes=0
    for i,part in ipairs(plan.parts) do
        part.file=work..'/parts/'..string.format('%04d.mp3',i)
        if cache.files[tostring(i)]~=part.bytes or Store.size(part.file)~=part.bytes then
            local request=part.entry.request or {}
            if request.method and request.method~='GET' or request.body or not Covers.allowed(request.url or part.entry.url) then error('Unsupported native audiobook resource request',0) end
            progress('downloading',completed_bytes,plan.bytes,completed_bytes,'Part '..i..' of '..#plan.parts)
            local response=client.transport{url=request.url or part.entry.url,profile='resource',method='GET',headers=U.copy(request.headers or {}),
                destination=part.file..'.part',max_bytes=256*1024*1024,
                on_progress=function(bytes) progress('downloading',completed_bytes+bytes,plan.bytes,completed_bytes+bytes,'Part '..i..' of '..#plan.parts) end}
            if response.status~=200 then os.remove(part.file..'.part');client:failure(response) end
            if Store.size(part.file..'.part')~=part.bytes then os.remove(part.file..'.part');error('An audiobook part was incomplete. Try again to resume.',0) end
            assert(os.rename(part.file..'.part',part.file),'Could not finish saving an audiobook part')
            cache.files[tostring(i)]=part.bytes;job:write('parts.json',cache)
        end
        completed_bytes=completed_bytes+part.bytes
        progress('downloading',completed_bytes,plan.bytes,completed_bytes,'Part '..i..' of '..#plan.parts)
    end
    local inspected=0
    for i,part in ipairs(plan.parts) do
        progress('checking',inspected,plan.bytes,completed_bytes,'Part '..i..' of '..#plan.parts)
        part.info=MP3.inspect(part.file,function(bytes) progress('checking',inspected+bytes,plan.bytes,completed_bytes,'Part '..i..' of '..#plan.parts) end)
        if math.abs(part.info.duration-part.duration)>.25 then error('An MP3 part duration does not match the native chapter map. This encoding is not supported yet.',0) end
        inspected=inspected+part.bytes
    end
    local chapters,duration_ms=M.chapters(book,plan.parts)
    local cover_path=opts.cover_dir and Covers.cached(loan,opts.cover_dir)
    local cover
    if cover_path and Store.size(cover_path)<=2*1024*1024 then
        local data=Store.read_file(cover_path)
        local mime=data:sub(1,3)=='\255\216\255' and 'image/jpeg' or data:sub(1,8)=='\137PNG\r\n\26\n' and 'image/png'
        if mime then cover={mime=mime,data=data} end
    end
    local title=type(book.title)=='table' and book.title or {}
    local tag=ID3.encode({title=title.main or loan.title,subtitle=title.subtitle or loan.subtitle,
        author=creators(book,'author',loan.author),narrator=creators(book,'narrator'),duration_ms=duration_ms},chapters,cover)
    local destination=opts.directory..'/'..U.filename(loan.title,loan.key..':'..tostring(loan.checkout_id),'mp3')
    progress('joining',0,plan.bytes,completed_bytes)
    local duration=MP3.join(plan.parts,destination..'.part',tag,function(_,_,bytes) progress('joining',bytes,plan.bytes,completed_bytes) end)
    if not os.rename(destination..'.part',destination) then os.remove(destination..'.part');error('Could not finish saving the MP3.',0) end
    progress('complete',plan.bytes,plan.bytes,completed_bytes)
    return {key=loan.key,checkout_id=loan.checkout_id,path=destination,kind='mp3',chapters=#chapters,parts=#plan.parts,
        duration=duration,expires=math.min(loan.expires,tonumber(passport.expires) or loan.expires),downloaded_at=os.time(),work=work}
end
return M
