-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require("kolibby/util")
local Store=require("kolibby/store")
local Decoder=require("kolibby/decoder")
local Publication=require("kolibby/publication")
local Epub=require("kolibby/epub")
local Assets=require("kolibby/assets")
local M={}
local function type_for(path,header)
    return Assets.classify(path,header)
end
local function allowed(url)
    local host=url:match("^https://([^/]+)/")
    if not host then return false end
    host=host:lower()
    for _,domain in ipairs({"libbyshelf.com","libbyapp.com","overdrive.com","od-cdn.com","contentreserve.com"}) do
        if host==domain or host:sub(-#domain-1)=="."..domain then return true end
    end
    return false
end
function M.run(client,loan,card,opts)
    if not loan.downloadable then error("This loan does not offer a supported native ebook",0) end
    if not loan.expires or loan.expires<=os.time() then error("This loan has expired or its due date is unknown. Synchronize first.",0) end
    Store.mkdir(opts.directory)
    local work=opts.cache_dir.."/"..U.hash(loan.key..":"..tostring(loan.checkout_id))
    local job=Store.new(work)
    local saved_bytes=0
    local function progress(done,total,stage)
        if opts.progress then opts.progress({done=done,total=total,stage=stage,bytes=saved_bytes}) end
    end
    progress(0,0,"authorizing")
    local passport,rosters,book=client:publication(loan,card)
    local entries,version,roster_id
    for _,r in ipairs(rosters) do
        if r.group=="title-content" then entries=r.entries;version=tostring(r.version);roster_id=r.id;break end
    end
    local MAX_RESOURCES=10000
    if type(entries)~="table" or #entries==0 or #entries>MAX_RESOURCES then error("Libby returned an unsupported native resource roster",0) end
    if passport.expires and tonumber(passport.expires) and tonumber(passport.expires)<=os.time() then error("The publication grant expired. Try the download again.",0) end
    local identity={key=loan.key,checkout_id=loan.checkout_id,roster=roster_id,version=version,pipeline="epub-0.6"}
    local resume=job:read("resources.json",{files={}})
    if not resume.identity or resume.identity.key~=identity.key or resume.identity.checkout_id~=identity.checkout_id or resume.identity.roster~=roster_id or resume.identity.version~=version or resume.identity.pipeline~=identity.pipeline then
        Store.remove_tree(work.."/assets");resume={identity=identity,files={}}
    end
    local assets,by_url,by_path={},{},{}
    local total_bytes=0
    local function add(entry,depth)
        if type(entry)~="table" or type(entry.url)~="string" or not allowed(entry.url) then error("Unsupported native publication resource host",0) end
        local path=U.resource_path(entry.url);local canonical=Publication.canonical(entry.url)
        if by_path[path] and by_path[path]~=canonical then error("Native publication contains conflicting resource paths",0) end
        if by_url[canonical] then return by_url[canonical] end
        if #assets>=MAX_RESOURCES or (depth or 0)>32 then error("This publication exceeds the supported dependency limit",0) end
        local asset={url=entry.url,path=path,original_path=path,entry=entry,depth=depth or 0,file=work.."/assets/"..path,media_type=type_for(path)}
        assets[#assets+1]=asset;by_url[canonical]=asset;by_path[path]=asset
        return asset
    end
    for _,entry in ipairs(entries) do add(entry) end
    if type(book.spine)~='table' or #book.spine==0 then error('The native publication has no reading order',0) end
    local key=Decoder.native_key(book['-odread-kdigits'])
    local function textual(asset)
        return asset.media_type=='application/xhtml+xml' or asset.media_type=='text/css' or asset.media_type=='image/svg+xml'
    end
    -- ipairs observes dependencies appended during traversal. Saved files remain
    -- normalized originals; layout/rewrite happens on separate packaging copies.
    for i,asset in ipairs(assets) do
        local old=resume.files[asset.original_path]
        if old and old.size==Store.size(asset.file) and old.size>0 then
            asset.media_type=old.media_type or asset.media_type
            asset.path=old.pack_path or asset.path;asset.base_url=old.base_url
        else
            local attrs=asset.entry.request or {}
            local url=attrs.url or asset.url
            if not allowed(url) then error("Unsupported native resource request",0) end
            Store.mkdir(asset.file:match("^(.*)/[^/]+$"))
            local raw_file=asset.file..".part"
            local response=client.transport{url=url,method=attrs.method or asset.entry.method or "GET",profile="resource",
                headers=U.copy(attrs.headers or {}),body=attrs.body or asset.entry.body,destination=raw_file,max_bytes=128*1024*1024}
            if response.status<200 or response.status>=300 then os.remove(raw_file);client:failure(response) end
            local prefix_file=assert(io.open(raw_file,"rb"));local prefix=prefix_file:read(4096);prefix_file:close()
            asset.media_type,asset.path=Assets.classify(asset.path,(response.headers or {})['content-type'],prefix and prefix:sub(1,4))
            Assets.validate(asset.media_type,prefix)
            if textual(asset) and Store.size(raw_file)>16*1024*1024 then error("A publication text resource exceeds the supported 16 MiB limit",0) end
            if asset.media_type=="application/xhtml+xml" then
                local body,_,base=Decoder.xhtml(Store.read_file(raw_file),key,{title=loan.title})
                if base then asset.base_url=Publication.resolve(asset.url,base) end
                Store.write_file(raw_file,body)
            elseif asset.media_type=="application/x-dtbncx+xml" then
                Store.write_file(raw_file,Epub.ncx(Store.read_file(raw_file),loan))
            end
            if not os.rename(raw_file,asset.file) then error("Could not finish saving a native resource",0) end
            resume.files[asset.original_path]={size=Store.size(asset.file),media_type=asset.media_type,pack_path=asset.path,base_url=asset.base_url}
            job:write("resources.json",resume)
        end
        if asset.path~=asset.original_path then
            local host=Publication.canonical(asset.url):match("^([^/]+)")
            local alias=host.."/"..asset.path
            if by_url[alias] and by_url[alias]~=asset then error('Publication resource names conflict after normalization',0) end
            by_url[alias]=asset
        end
        total_bytes=total_bytes+(Store.size(asset.file) or 0);saved_bytes=total_bytes
        if total_bytes>512*1024*1024 then error("This publication exceeds the supported 512 MiB size limit",0) end
        if textual(asset) then
            for _,ref in ipairs(Publication.references(Store.read_file(asset.file),asset)) do
                if not by_url[Publication.canonical(ref.url)] and (ref.required or ref.discover and ref.internal) then
                    if not ref.internal or not allowed(ref.url) then error('A publication embeds an unsupported external resource',0) end
                    add({url=ref.url:gsub('#.*$','')},asset.depth+1)
                end
            end
        end
        progress(i,#assets,"downloading")
    end
    for _,entry in ipairs(book.spine) do if not by_path[Epub.spine_path(entry)] then error("The native roster omits a required chapter",0) end end
    progress(#assets,#assets,"packaging")
    -- Keep resume inputs independent of generated layouts and local references.
    Store.remove_tree(work..'/pack');Store.mkdir(work..'/pack')
    local downloaded_resources=#assets
    for i,asset in ipairs(assets) do
        if textual(asset) then
            local file=work..'/pack/'..i
            local source=assert(io.open(asset.file,'rb'));local target=assert(io.open(file,'wb'))
            while true do local chunk=source:read(262144);if not chunk then break end;assert(target:write(chunk)) end
            source:close();assert(target:close());asset.file=file
        end
    end
    book=U.copy(book)
    local layout=require('kolibby/layout').prepare(book,assets,work)
    local packed_paths={}
    for _,asset in ipairs(assets) do
        if packed_paths[asset.path] then error("Publication resource names conflict after normalization",0) end
        packed_paths[asset.path]=true
        if textual(asset) then
            local rewritten=Store.read_file(asset.file)
            if not asset.generated then rewritten=Publication.rewrite(rewritten,asset,by_url) end
            Store.write_file(asset.file,rewritten)
            if asset.media_type=="application/xhtml+xml" then
                asset.properties={}
                for _,_,name in Decoder.tags(rewritten) do
                    if name=="svg" or name and name:match(":svg$") then asset.properties.svg=true end
                    if name=="math" or name and name:match(":math$") then asset.properties.mathml=true end
                end
            end
        end
    end
    if packed_paths["kolibby-nav.xhtml"] then error("Generated navigation conflicts with a publication resource",0) end
    local nav={path="kolibby-nav.xhtml",media_type="application/xhtml+xml",file=work.."/navigation.xhtml"}
    Store.write_file(nav.file,Epub.navigation(book));assets[#assets+1]=nav
    local package=Epub.package(book,loan,assets)
    local destination=opts.directory.."/"..U.filename(loan.title,loan.key..":"..tostring(loan.checkout_id))
    local temporary=destination..".part"
    local writer=require("ffi/archiver").Writer:new()
    local ok,err=pcall(function()
        assert(writer:open(temporary,"epub"),writer.err)
        assert(writer:setZipCompression("store"),writer.err)
        require("kolibby/archive").add_mimetype(writer)
        assert(writer:setZipCompression("deflate"),writer.err)
        assert(writer:addFileFromMemory("META-INF/container.xml",Epub.CONTAINER),writer.err)
        assert(writer:addFileFromMemory("OEBPS/content.opf",package),writer.err)
        for _,asset in ipairs(assets) do
            writer:addPath("OEBPS/"..asset.path,asset.file,false)
            if writer.err then error("Could not package a publication resource",0) end
        end
    end)
    local closed=require("kolibby/archive").close(writer)
    if not ok or not closed then os.remove(temporary);error("The EPUB could not be packaged. Check available storage.",0) end
    if not Store.size(temporary) or Store.size(temporary)<200 then os.remove(temporary);error("The generated EPUB is incomplete",0) end
    if not os.rename(temporary,destination) then os.remove(temporary);error("Could not finish saving the EPUB",0) end
    progress(downloaded_resources,downloaded_resources,"complete")
    return {key=loan.key,checkout_id=loan.checkout_id,path=destination,expires=math.min(loan.expires,tonumber(passport.expires) or loan.expires),resources=downloaded_resources,spine=#book.spine,downloaded_at=os.time(),fixed_layout=layout.fixed>0,mixed_layout=layout.mixed}
end
return M
