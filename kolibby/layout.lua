-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local Markup=require('kolibby/markup')
local Publication=require('kolibby/publication')
local M={}
local function dimension(n)
    n=tonumber(n);return n and n>0 and n<10000000 and n or nil
end
local function viewport(value)
    if type(value)=='table' then
        local w,h=dimension(value.width),dimension(value.height);if w and h then return {width=w,height=h} end
    elseif type(value)=='string' then
        local w=dimension(value:match('width%s*=%s*([%d.]+)'));local h=dimension(value:match('height%s*=%s*([%d.]+)'))
        if w and h then return {width=w,height=h} end
    end
end
M.viewport=viewport
local function selected(value,values) return type(value)=='string' and values[value] and value or nil end
local orientations={auto=true,landscape=true,portrait=true}
local spreads={auto=true,none=true,landscape=true,both=true}
function M.entry(entry,media)
    local layout=entry['rendition-layout']=='pre-paginated' and 'pre-paginated' or 'reflowable'
    if media and media:match('^image/') then layout='pre-paginated' end
    return {layout=layout,viewport=viewport(entry['rendition-viewport']),
        position=selected(entry['rendition-position'],{left=true,right=true,center=true}),
        orientation=selected(entry['rendition-orientation'],orientations),spread=selected(entry['rendition-spread'],spreads)}
end
function M.document(text,info,media)
    if info.layout~='pre-paginated' then return text end
    local tokens={};local existing,svg_root,has_viewbox
    for t in Markup.tokens(text) do
        tokens[#tokens+1]=t
        if t.kind=='start' and t.name=='meta' and (t.values.name or ''):lower()=='viewport' then existing=viewport(t.values.content) end
        if t.kind=='start' and t.name=='svg' and media=='image/svg+xml' and not svg_root then
            svg_root=t
            local _,_,w,h=(t.values.viewbox or ''):match('^%s*([%d.eE+%-]+)[%s,]+([%d.eE+%-]+)[%s,]+([%d.eE+%-]+)[%s,]+([%d.eE+%-]+)%s*$')
            if dimension(w) and dimension(h) then existing={width=tonumber(w),height=tonumber(h)};has_viewbox=true
            else
                local function pixels(value) return dimension(value) or type(value)=='string' and dimension(value:match('^%s*([%d.]+)px%s*$')) end
                w,h=pixels(t.values.width),pixels(t.values.height)
                if w and h then existing={width=w,height=h} end
            end
        end
    end
    local size=info.viewport or existing or {width=768,height=1024}
    info.viewport=size
    local value=string.format('width=%g, height=%g',size.width,size.height)
    local out,inserted={},false
    for _,t in ipairs(tokens) do
        if t.kind=='start' and t.name=='meta' and (t.values.name or ''):lower()=='viewport' then
            if not inserted then out[#out+1]='<meta name="viewport" content="'..value..'" />';inserted=true end
        elseif t.kind=='end' and t.name=='head' and media~='image/svg+xml' then
            if not inserted then out[#out+1]='<meta name="viewport" content="'..value..'" />';inserted=true end
            out[#out+1]=t.raw
        elseif t==svg_root then
            if not has_viewbox then Markup.set(t.attributes,'viewBox',string.format('0 0 %g %g',size.width,size.height)) end
            Markup.set(t.attributes,'width',tostring(size.width));Markup.set(t.attributes,'height',tostring(size.height))
            out[#out+1]=Markup.serialize(t.raw_name,t.attributes,t.empty);inserted=true
        else out[#out+1]=t.raw end
    end
    if not inserted then error('A fixed-layout page has no supported viewport container',0) end
    return table.concat(out)
end
function M.image_page(path,image,size,title)
    local src=U.xml(Publication.relative(path,image));local w,h=size.width,size.height
    return string.format('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>%s</title><meta name="viewport" content="width=%g, height=%g"/><style>html,body{margin:0;padding:0;width:100%%;height:100%%;}svg{display:block;width:100%%;height:100%%;}</style></head><body><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 %g %g" width="%g" height="%g"><title>%s</title><image width="%g" height="%g" xlink:href="%s" preserveAspectRatio="xMidYMid meet"/></svg></body></html>',U.xml(title),w,h,w,h,w,h,U.xml(title),w,h,src)
end
-- Apply native fields to a copied book map and resource files, before packaging.
function M.prepare(book,assets,work)
    local Epub=require('kolibby/epub');local Store=require('kolibby/store')
    local paths,packed_paths={},{};for _,asset in ipairs(assets) do paths[asset.original_path or asset.path]=asset;packed_paths[asset.path]=true end
    local fixed=0;local map={}
    for i,entry in ipairs(book.spine or {}) do
        local original=Epub.spine_path(entry);local asset=paths[original]
        if not asset then error('A required chapter is missing from the native download',0) end
        local info=M.entry(entry,asset.media_type);entry._kolibby_layout=info
        if info.layout=='pre-paginated' then
            fixed=fixed+1
            if asset.media_type=='application/xhtml+xml' or asset.media_type=='image/svg+xml' then
                Store.write_file(asset.file,M.document(Store.read_file(asset.file),info,asset.media_type))
            elseif asset.media_type:match('^image/') then
                local page=string.format('_kolibby-pages/%04d.xhtml',i)
                if packed_paths[page] then error('Generated fixed-layout page conflicts with a resource',0) end
                packed_paths[page]=true
                local f=assert(io.open(asset.file,'rb'));local prefix=f:read(131072);f:close()
                local size=info.viewport or require('kolibby/assets').dimensions(prefix) or {width=768,height=1024}
                info.viewport=size
                local file=work..'/pages/'..i..'.xhtml';Store.mkdir(work..'/pages')
                Store.write_file(file,M.image_page(page,asset.path,size,'Page '..i))
                assets[#assets+1]={path=page,media_type='application/xhtml+xml',file=file,properties={svg=true},generated=true}
                entry._kolibby_path=page;asset.page_path=asset.page_path or page;map[original]=map[original] or page
            else error('A fixed-layout spine has an unsupported page format',0) end
        elseif asset.media_type~='application/xhtml+xml' then error('A publication spine has an unsupported document format',0) end
    end
    local function nav(items)
        for _,entry in ipairs(items or {}) do
            if type(entry.path)=='string' then
                local p,suffix=entry.path:match('^([^?#]+)(.*)$')
                if p then p=U.resource_path('/'..p:gsub('^/+',''));if map[p] then entry.path=map[p]..suffix end end
            end
            nav(entry.contents or entry.items)
        end
    end
    nav(type(book.nav)=='table' and book.nav.toc)
    local info={layout=fixed>0 and fixed==#book.spine and 'pre-paginated' or 'reflowable',fixed=fixed,mixed=fixed>0 and fixed<#book.spine,
        direction=selected(book['i18n-page-progression-direction'],{ltr=true,rtl=true}),
        orientation=selected(book['rendition-orientation'],orientations),spread=selected(book['rendition-spread'],spreads)}
    book._kolibby_layout=info;return info
end
function M.properties(info,global)
    if not info then return '' end
    local out={}
    if info.layout~=global.layout then out[#out+1]='rendition:layout-'..info.layout end
    for _,name in ipairs({'orientation','spread'}) do if info[name] and info[name]~=global[name] then out[#out+1]='rendition:'..name..'-'..info[name] end end
    if info.position then out[#out+1]=info.position=='center' and 'rendition:page-spread-center' or 'page-spread-'..info.position end
    return table.concat(out,' ')
end
return M
