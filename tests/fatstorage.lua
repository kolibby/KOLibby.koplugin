-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Kindle (/mnt/us) and Kobo (/mnt/onboard) store KOReader data on FAT: names are
-- case-insensitive and : * ? " < > | are invalid. An in-memory filesystem with
-- those rules runs the real EPUB pipeline; no files are written to disk.
return function(test,eq,fails,contains)
local function fat(cwd)
    local files,dirs={},{['']=true}
    local function key(path)
        path=tostring(path):gsub('/+$','')
        for part in path:gmatch('[^/]+') do
            if part:find('[:*?"<>|]') then return nil,path..': Invalid argument' end
        end
        return path:lower()
    end
    local function parent(k) return k:match('^(.*)/[^/]*$') or '' end
    local fs={files=files}
    local function handle(k,mode)
        local data=mode:sub(1,1)=='r' and files[k] or '';local pos=1
        local h={}
        function h:read(n)
            if pos>#data then return nil end
            if n=='*a' or n=='a' then local s=data:sub(pos);pos=#data+1;return s end
            local s=data:sub(pos,pos+n-1);pos=pos+#s;return s
        end
        function h:write(s) data=data..s;return self end
        function h:close() if mode:sub(1,1)=='w' then files[k]=data end;return true end
        return h
    end
    fs.io=setmetatable({open=function(path,mode)
        mode=mode or 'r'
        local k,err=key(path);if not k then return nil,err,22 end
        if mode:sub(1,1)=='r' then
            if not files[k] then return nil,path..': No such file or directory',2 end
        elseif not dirs[parent(k)] then return nil,path..': No such file or directory',2 end
        return handle(k,mode)
    end},{__index=io})
    fs.os=setmetatable({
        rename=function(a,b)
            local ka,kb=key(a),key(b)
            if not ka or not kb or not files[ka] then return nil,'Invalid argument' end
            files[kb]=files[ka];if ka~=kb then files[ka]=nil end;return true
        end,
        remove=function(path) local k=key(path);if k and files[k] then files[k]=nil;return true end;return nil,'No such file' end,
    },{__index=os})
    local lfs={}
    function lfs.attributes(path,field)
        local k=key(path);if not k then return nil end
        local mode=files[k] and 'file' or dirs[k] and 'directory'
        if not mode then return nil end
        if field=='mode' then return mode elseif field=='size' then return files[k] and #files[k] or 0 end
        return {mode=mode,size=files[k] and #files[k] or 0}
    end
    lfs.symlinkattributes=lfs.attributes
    function lfs.mkdir(path)
        local k=key(path);if not k or not dirs[parent(k)] then return nil,'Invalid argument' end
        dirs[k]=true;return true
    end
    function lfs.rmdir(path) local k=key(path);if k then dirs[k]=nil end;return true end
    function lfs.dir(path)
        local k=key(path);local names={}
        for name in pairs(files) do if parent(name)==k then names[#names+1]=name:match('[^/]+$') end end
        for name in pairs(dirs) do if name~='' and parent(name)==k then names[#names+1]=name:match('[^/]+$') end end
        local i=0;return function() i=i+1;return names[i] end
    end
    function lfs.currentdir() return cwd end
    fs.lfs=lfs
    return fs
end
local function environment(cwd)
    local fs=fat(cwd or '/mnt/us/koreader')
    local modules,entries={},{}
    local import
    local archiver={Writer={}}
    function archiver.Writer:new()
        local w={}
        function w:open(path) self.target=path;self.archive={};return true end
        function w:setZipCompression() return true end
        function w:addFileFromMemory(name,content) entries[name]=content;return true end
        function w:addPath(name,file)
            local f=fs.io.open(file,'rb');if not f then self.err='missing '..file;return end
            entries[name]=f:read('*a');f:close()
        end
        return w
    end
    local archive={add_mimetype=function() entries.mimetype='application/epub+zip' end,
        close=function(writer)
            local f=fs.io.open(writer.target,'wb');if not f then return false end
            for name,content in pairs(entries) do f:write(name..'\n'..content..'\n') end
            return f:close()
        end}
    local function load_source(path)
        local chunk=assert(loadfile(path))
        setfenv(chunk,setmetatable({require=function(name) return import(name) end,io=fs.io,os=fs.os},{__index=_G}))
        return chunk()
    end
    import=function(name)
        if name=='libs/libkoreader-lfs' or name=='lfs' then return fs.lfs
        elseif name=='ffi/archiver' then return archiver
        elseif name=='kolibby/archive' then return archive
        elseif name=='kolibby/store' or name=='kolibby/download' or name=='kolibby/layout' then
            if not modules[name] then modules[name]=load_source(name..'.lua') end
            return modules[name]
        end
        return require(name)
    end
    return {fs=fs,import=import,entries=entries}
end

local png=require('kolibby/util').base64_decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jF1sAAAAASUVORK5CYII=')
local function html(title) return '<html><head><title>'..title..'</title></head><body><p>'..title..'</p></body></html>' end
test('EPUB resources whose names FAT rejects or folds together are cached under hashed names',function()
    local env=environment()
    local Download=env.import('kolibby/download')
    local host='https://fixture.libbyshelf.com'
    local sources={['/Text/Chapter.xhtml']=html('Upper chapter'),['/Text/chapter.xhtml']=html('Lower chapter'),['/Images/fig:1.png']=png}
    local client={}
    function client:publication()
        return {expires=os.time()+3600},{{group='title-content',id='fat',version=1,entries={
            {url=host..'/Text/Chapter.xhtml'},{url=host..'/Text/chapter.xhtml'},{url=host..'/Images/fig%3A1.png'}}}},
            {title={main='FAT storage'},language='en',creator={{name='Synthetic Author'}},description={full='<p>Publisher &amp; synopsis.</p>'},spine={{path='Text/Chapter.xhtml'},{path='Text/chapter.xhtml'}}}
    end
    function client.transport(req)
        local path=require('kolibby/util').urldecode(assert(req.url:match('^https://fixture.libbyshelf.com([^?#]*)')))
        local f=assert(env.fs.io.open(req.destination,'wb'));f:write(assert(sources[path],'unexpected request'));f:close()
        return {status=200,headers={}}
    end
    local loan={key='synthetic:fat',id='fat',checkout_id='synthetic',title='FAT storage',downloadable=true,expires=os.time()+3600}
    local record=Download.run(client,loan,{},{directory='/mnt/us/KOLibby',cache_dir='/mnt/us/koreader/cache/kolibby'})
    eq(record.resources,3);eq(record.spine,2)
    eq(record.description,'Publisher & synopsis.')
    contains(env.entries['OEBPS/content.opf'],'<dc:description>Publisher &amp; synopsis.</dc:description>')
    contains(env.entries['OEBPS/Text/Chapter.xhtml'],'Upper chapter')
    contains(env.entries['OEBPS/Text/chapter.xhtml'],'Lower chapter')
    eq(env.entries['OEBPS/Images/fig:1.png'],png)
    assert(env.fs.lfs.attributes(record.path,'mode')=='file')
    for name in pairs(env.fs.files) do
        local base=name:match('[^/]+$')
        assert(not base:find('[:*?"<>|]'),'FAT-invalid cache name '..name)
        if name:find('/assets/',1,true) then assert(base:match('^%x+$'),'unhashed cache name '..name) end
    end
end)
test('Relative KOReader data paths resolve against the working directory',function()
    local env=environment('/mnt/onboard/.adds/koreader')
    local Store=env.import('kolibby/store')
    eq(Store.absolute('./KOLibby'),'/mnt/onboard/.adds/koreader/KOLibby')
    eq(Store.absolute('.'),'/mnt/onboard/.adds/koreader')
    eq(Store.absolute('./cache/kolibby/../x'),'/mnt/onboard/.adds/koreader/cache/kolibby/../x')
    eq(Store.absolute('KOLibby/a.epub'),'/mnt/onboard/.adds/koreader/KOLibby/a.epub')
    eq(Store.absolute('/sdcard/koreader/KOLibby'),'/sdcard/koreader/KOLibby')
    eq(Store.absolute('KOLibby','/'),'/KOLibby')
    eq(Store.absolute('./KOLibby','relative'),'./KOLibby')
    eq(Store.absolute(nil),nil)
end)
end
