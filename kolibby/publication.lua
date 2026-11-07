-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local Markup=require('kolibby/markup')
local M={}
local function split(url)
    local scheme,host,tail=url:match('^(https?)://([^/?#]+)(.*)$')
    if not host or host:find('[@%s\\]') then error('Publication address is incomplete',0) end
    local path=tail:match('^[^?#]*');if path=='' then path='/' end
    return scheme,host:lower(),path,tail:match('(%?[^#]*)') or ''
end
function M.origin(url) local scheme,host=split(url);return scheme..'://'..host end
function M.canonical(url) local _,host,path=split(url);return host..U.urldecode(path) end
function M.resolve(base,reference)
    -- Callers provide logical attribute/CSS values, already entity-decoded.
    reference=U.trim(reference)
    if reference:match('^https?://') then return reference end
    local scheme,host,path,query=split(base)
    if reference:sub(1,2)=='//' then return scheme..':'..reference end
    if reference:match('^[%w+.-]+:') then error('Unsupported publication reference scheme',0) end
    local fragment=reference:match('#(.*)$')
    local rpath=reference:match('^[^?#]*')
    local rquery=reference:match('(%?[^#]*)')
    if rpath=='' then return scheme..'://'..host..path..(rquery or query)..(fragment and '#'..fragment or '') end
    if rpath:sub(1,1)~='/' then rpath=(path:match('^(.*/)') or '/')..rpath end
    local parts={}
    for part in rpath:gmatch('[^/]+') do
        local decoded=U.urldecode(part)
        if decoded=='..' then
            if #parts==0 then error('A publication link escapes its root',0) end
            table.remove(parts)
        elseif decoded~='.' then parts[#parts+1]=part end
    end
    local trailing=rpath:sub(-1)=='/' and '/' or ''
    return scheme..'://'..host..'/'..table.concat(parts,'/')..trailing..(rquery or '')..(fragment and '#'..fragment or '')
end
local function relative(from,to)
    local a,b={},{}
    for v in from:gmatch('[^/]+') do a[#a+1]=v end
    for v in to:gmatch('[^/]+') do b[#b+1]=v end
    table.remove(a)
    local common=0;while a[common+1] and a[common+1]==b[common+1] do common=common+1 end
    local out={};for _=common+1,#a do out[#out+1]='..' end
    for i=common+1,#b do out[#out+1]=b[i] end
    return U.href(table.concat(out,'/'))
end
M.relative=relative
-- WHATWG candidate collection: a comma inside a URL (notably data:) is
-- not a separator. Descriptors are validated before a candidate is used.
function M.srcset(value,reference)
    local out,p={},1
    while p<=#value do
        local _,z=value:find('^[%s,]+',p);if z then p=z+1 end
        if p>#value then break end
        local url,last=value:match('^([^%s]+)()',p);p=last
        local descriptors={}
        if url:sub(-1)==',' then url=url:gsub(',+$','')
        else
            local start,depth=p,0
            while p<=#value do
                local c=value:sub(p,p)
                if c=='(' then depth=depth+1 elseif c==')' then depth=math.max(0,depth-1) elseif c==',' and depth==0 then break end
                p=p+1
            end
            for d in value:sub(start,p-1):gmatch('%S+') do descriptors[#descriptors+1]=d end
            p=p+1
        end
        local w,x,h,valid=nil,nil,nil,url~=''
        for _,d in ipairs(descriptors) do
            local n=tonumber(d:sub(1,-2));local unit=d:sub(-1)
            if unit=='w' and d:match('^%d+w$') and n>0 and not w and not x then w=n
            elseif unit=='h' and d:match('^%d+h$') and n>0 and not h and not x then h=n
            elseif unit=='x' and n and n>=0 and n<math.huge and not x and not w and not h and (d:sub(1,-2):match('^%-?%d+%.?%d*$') or d:sub(1,-2):match('^%-?%.%d+$') or d:sub(1,-2):match('^%-?[%d.]+[eE][+%-]?%d+$')) then x=n
            else valid=false end
        end
        if h and not w then valid=false end
        if valid then out[#out+1]=reference(url,true)..(#descriptors>0 and ' '..table.concat(descriptors,' ') or '') end
    end
    return table.concat(out,', ')
end
local function css_value(s)
    return (s:gsub('\\(%x%x?%x?%x?%x?%x?)(%s?)',function(h) return Markup.decode('&#'..tonumber(h,16)..';') end)
        :gsub('\\\r\n',''):gsub('\\[\r\n\f]',''):gsub('\\(.)','%1'))
end
local function css_quote(s) return '"'..s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('[\r\n\f]',function(c) return string.format('\\%x ',c:byte()) end)..'"' end
local function css_string(s,p)
    local q=s:sub(p,p);local start=p+1;p=start
    while p<=#s do
        local c=s:sub(p,p)
        if c==q then return css_value(s:sub(start,p-1)),p+1 end
        p=p+(c=='\\' and 2 or 1)
    end
    error('Unterminated publication CSS string',0)
end
function M.css(text,reference)
    local out,p,cursor={},1,1;local lower=text:lower()
    while p<=#text do
        local c=text:sub(p,p)
        if text:sub(p,p+1)=='/*' then
            local z=text:find('*/',p+2,true);if not z then error('Unterminated publication CSS comment',0) end;p=z+2
        elseif c=='"' or c=="'" then local _,z=css_string(text,p);p=z
        else
            local a,b=lower:find('^url%s*%(%s*',p)
            if a and not text:sub(p-1,p-1):match('[%w_%-]') then
                local value,finish;local q=text:sub(b+1,b+1)
                if q=='"' or q=="'" then value,finish=css_string(text,b+1);local _,z=text:find('^%s*%)',finish);if not z then error('Invalid publication CSS URL',0) end;finish=z+1
                else
                    finish=b+1;local start=finish
                    while finish<=#text do
                        local ch=text:sub(finish,finish)
                        if ch==')' then break end
                        finish=finish+(ch=='\\' and 2 or 1)
                    end
                    if finish>#text then error('Unterminated publication CSS URL',0) end
                    value=css_value(U.trim(text:sub(start,finish-1)));finish=finish+1
                end
                out[#out+1]=text:sub(cursor,p-1);out[#out+1]='url('..css_quote(reference(value,true))..')';cursor=finish;p=finish
            else
                local _,z=lower:find('^@import%s+',p)
                if z and (text:sub(z+1,z+1)=='"' or text:sub(z+1,z+1)=="'") then
                    local value,finish=css_string(text,z+1)
                    out[#out+1]=text:sub(cursor,z);out[#out+1]=css_quote(reference(value,true));cursor=finish;p=finish
                else p=p+1 end
            end
        end
    end
    out[#out+1]=text:sub(cursor);return table.concat(out)
end
local function transform(text,asset,reference)
    if asset.media_type=='text/css' then return M.css(text,reference) end
    local out,in_style={},false
    for t in Markup.tokens(text) do
        if t.kind=='start' then
            for _,a in ipairs(t.attributes) do
                local attr=a.name:lower();local name=t.name
                if attr=='srcset' or attr=='imagesrcset' then a.value=M.srcset(a.value,reference)
                elseif attr=='style' then a.value=M.css(a.value,reference)
                elseif attr=='src' or attr=='poster' or attr=='xlink:href' or attr=='href' or attr=='data' and name=='object' then
                    local hyperlink=(attr=='href' or attr=='xlink:href') and (name=='a' or name=='area')
                    local metadata=name=='link' and not (' '..(t.values.rel or ''):lower()..' '):find('%sstylesheet%s') and not (' '..(t.values.rel or ''):lower()..' '):find('%sicon%s') and not (' '..(t.values.rel or ''):lower()..' '):find('%spreload%s')
                    a.value=reference(a.value,not hyperlink and not metadata,hyperlink)
                end
            end
            out[#out+1]=Markup.serialize(t.raw_name,t.attributes,t.empty)
            if t.name=='style' then in_style=true end
        elseif t.kind=='end' then if t.name=='style' then in_style=false end;out[#out+1]=t.raw
        elseif in_style and t.kind=='text' then out[#out+1]=Markup.text(M.css(Markup.decode(t.raw),reference))
        elseif in_style and t.kind=='cdata' then out[#out+1]='<![CDATA['..M.css(t.raw:sub(10,-4),reference):gsub(']]>',']]]]><![CDATA[>')..']]>'
        else out[#out+1]=t.raw end
    end
    return table.concat(out)
end
local function target(asset,ref,required)
    ref=U.trim(ref)
    if ref=='' or ref:sub(1,1)=='#' or ref:lower():match('^data:') then return nil end
    if ref:match('^[%w+.-]+:') and not ref:match('^https?://') then
        if required then error('A publication contains an unsupported embedded resource',0) end
        return nil
    end
    return M.resolve(asset.base_url or asset.url,ref)
end
function M.references(text,asset)
    local refs={}
    transform(text,asset,function(ref,required,follow)
        local url=target(asset,ref,required)
        if url then refs[#refs+1]={url=url,required=required,internal=M.origin(url)==M.origin(asset.url),discover=required or follow} end
        return ref
    end)
    return refs
end
function M.rewrite(text,asset,by_url)
    return transform(text,asset,function(ref,required,follow)
        local url=target(asset,ref,required)
        if not url then return ref:lower():match('^%s*javascript:') and '#' or ref end
        local found=by_url[M.canonical(url)]
        if not found then
            if required or follow and M.origin(url)==M.origin(asset.url) then error('The native publication is missing a linked resource',0) end
            return ref
        end
        local fragment=url:match('#(.*)$')
        return relative(asset.path,not required and found.page_path or found.path)..(fragment and '#'..fragment or '')
    end)
end
return M
