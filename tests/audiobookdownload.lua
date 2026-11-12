-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Complete audiobook pipeline with synthetic MPEG frames and an isolated filesystem.
return function(test,eq,fails,contains)
local U=require('kolibby/util');local J=require('kolibby/json')
local header='\255\251\080\100'
local audio=string.rep(header..string.rep('\0',32)..string.rep('A',172),100)
local duration=100*1152/44100
local function fixture(options)
    options=options or {}
    local files,modules,requests={},{},{}
    local fs={}
    function fs.open(path,mode)
        mode=mode or 'r'
        if mode:sub(1,1)=='r' and not files[path] then return nil,'missing' end
        local data=mode:sub(1,1)=='w' and '' or files[path];local pos=0
        local h={}
        function h:read(n)
            if pos>=#data then return nil end
            local s=n=='*a' and data:sub(pos+1) or data:sub(pos+1,pos+n)
            pos=pos+#s;return s
        end
        function h:write(s) data=data:sub(1,pos)..s..data:sub(pos+#s+1);pos=pos+#s;return self end
        function h:seek(whence,offset)
            offset=offset or 0;whence=whence or 'cur'
            pos=(whence=='set' and 0 or whence=='end' and #data or pos)+offset;return pos
        end
        function h:close() if mode:sub(1,1)=='w' then files[path]=data end;return true end
        return h
    end
    local fake_os=setmetatable({rename=function(a,b) if not files[a] then return nil end;files[b]=files[a];files[a]=nil;return true end,
        remove=function(path) files[path]=nil;return true end},{__index=os})
    local Store={mkdir=function() end}
    function Store.size(path) return files[path] and #files[path] end
    function Store.exists(path) return files[path]~=nil end
    function Store.remove_tree(path) for name in pairs(files) do if name:sub(1,#path+1)==path..'/' then files[name]=nil end end end
    function Store.new(root)
        return {read=function(_,name,default) return files[root..'/'..name] and J.decode(files[root..'/'..name]) or U.copy(default) end,
            write=function(_,name,value) files[root..'/'..name]=J.encode(value) end}
    end
    local import
    import=function(name)
        if name=='kolibby/store' then return Store end
        if name=='kolibby/audiobook' or name=='kolibby/mp3' or name=='kolibby/batch' then
            if not modules[name] then
                local chunk=assert(loadfile(name..'.lua'))
                setfenv(chunk,setmetatable({require=import,io=fs,os=fake_os},{__index=_G}));modules[name]=chunk()
            end
            return modules[name]
        end
        return require(name)
    end
    local client={}
    function client:publication(loan)
        local entries,spine={},{}
        for i=1,(options.parts or 1) do
            entries[i]={url='https://fixture.listen.libbyshelf.com/'..loan.id..'-'..i..'.mp3',bytes=#audio+(options.deltas and options.deltas[loan.id] or options.delta or 0)}
            spine[i]={path=loan.id..'-'..i..'.mp3',['media-type']='audio/mpeg',['audio-duration']=duration}
        end
        return {},{{group='title-content',id=loan.id,version=1,entries=entries}},{title={main=loan.title},spine=spine}
    end
    function client.transport(req)
        requests[#requests+1]=req
        if options.fail_request==#requests then error('Synthetic interruption',0) end
        local data=options.data or audio
        files[req.destination]=data
        return {status=200,bytes=options.response_bytes or #data,encoded_bytes=options.encoded_bytes,headers={['content-length']=tostring(options.content_length or #data),['content-encoding']=options.encoding}}
    end
    local loan={key='A:audio',id='audio',checkout_id='fixture',title='Sample audio',author='Sample Author',card_id='A',
        media_type='audiobook',download_kind='mp3',downloadable=true,expires=os.time()+3600}
    local opts={directory='/fixture/output',cache_dir='/fixture/cache'}
    return {files=files,requests=requests,client=client,loan=loan,opts=opts,options=options,import=import,exists=Store.exists}
end
local function run(f) return f.import('kolibby/audiobook').run(f.client,f.loan,{},f.opts) end
test('Complete audio responses may differ from the roster byte estimate',function()
    for _,delta in ipairs({44,212,-44}) do
        local f=fixture{delta=delta}
        local record=run(f)
        eq(record.kind,'mp3');assert(f.files[record.path]);eq(#f.requests,1)
    end
end)
test('Download all completes three audiobooks with different roster size estimates',function()
    local f=fixture{deltas={first=212,second=44,third=0}}
    local shelf={cards={A={id='A'}},loans={}}
    for _,id in ipairs({'first','second','third'}) do
        local loan=U.copy(f.loan);loan.id=id;loan.key='A:'..id;loan.title=id;shelf.loans[loan.key]=loan
    end
    local records={};local opts=U.copy(f.opts);opts.exists=f.exists
    local persisted=0;opts.persist=function() persisted=persisted+1 end
    local batch=f.import('kolibby/batch')
    local result=batch.run(f.client,shelf,records,opts)
    eq(result.downloaded,3);eq(#result.failures,0);eq(persisted,3);eq(#f.requests,3)
    result=batch.run(f.client,shelf,records,opts)
    eq(result.downloaded,0);eq(result.already_downloaded,3);eq(#f.requests,3)
end)
test('Resume reuses actual byte sizes and remains compatible with older cache entries',function()
    for _,delta in ipairs({0,44}) do
        local f=fixture{delta=delta,parts=2,fail_request=2}
        fails(function() run(f) end,'Synthetic interruption');eq(#f.requests,2)
        f.options.fail_request=nil;local record=run(f)
        eq(#f.requests,3);eq(f.requests[1].url,f.requests[2].url:gsub('audio%-2','audio-1'))
        eq(f.requests[2].url,f.requests[3].url);assert(f.files[record.path])
    end
end)
test('A cached part with a changed length is downloaded again',function()
    local f=fixture{delta=44,parts=2,fail_request=2}
    fails(function() run(f) end,'Synthetic interruption')
    for name,data in pairs(f.files) do if name:match('/0001%.mp3$') then f.files[name]=data:sub(1,-2) end end
    f.options.fail_request=nil;run(f);eq(#f.requests,4);eq(f.requests[1].url,f.requests[3].url)
end)
test('A response shorter than its HTTP content length remains incomplete',function()
    local f=fixture{delta=44,content_length=#audio+44}
    fails(function() run(f) end,'An audiobook part was incomplete')
    eq(f.files[f.requests[1].destination],nil)
end)
test('Empty parts or inconsistent response byte counts cannot become completed parts',function()
    for _,options in ipairs({{response_bytes=#audio+1},{data=''}}) do
        local f=fixture(options)
        fails(function() run(f) end,'An audiobook part was incomplete')
        eq(f.files[f.requests[1].destination],nil)
    end
end)
test('A complete HTTP response with a truncated MP3 frame cannot finish',function()
    local f=fixture{delta=44,data=audio:sub(1,-2)}
    fails(function() run(f) end,'incomplete or uses an unsupported MP3 encoding')
    for name in pairs(f.files) do assert(not name:find('/output/',1,true)) end
end)
test('Missing whole audio frames fail the native duration check',function()
    local f=fixture{delta=44,data=audio:sub(1,208*80)}
    fails(function() run(f) end,'duration does not match')
    for name in pairs(f.files) do assert(not name:find('/output/',1,true)) end
end)
test('Compressed HTTP length is compared with encoded bytes instead of decoded audio',function()
    local f=fixture{delta=44,encoding='gzip',encoded_bytes=120,content_length=120}
    local record=run(f);assert(f.files[record.path])
end)
end
