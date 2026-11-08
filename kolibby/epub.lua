-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require("kolibby/util")
local M={}
local function path(entry)
    local p=entry._kolibby_path or entry['-odread-original-path'] or entry.path
    if type(p)~="string" then error("A publication spine entry has no path",0) end
    return U.resource_path("/"..p:gsub("^/+",""))
end
local function toc(items)
    local out={"<ol>"}
    for _,entry in ipairs(items or {}) do
        local label=U.xml(entry.title or entry.sectionName or "Contents")
        out[#out+1]="<li>"
        if entry.path then
            local target,fragment=entry.path:match("^([^#]*)#?(.*)$")
            target=U.href(U.resource_path("/"..target:gsub("^/+","")))
            if fragment~="" then target=target.."#"..U.urlencode(U.urldecode(fragment)) end
            out[#out+1]='<a href="'..U.xml(target)..'">'..label..'</a>'
        else out[#out+1]="<span>"..label.."</span>" end
        local children=entry.contents or entry.items
        if type(children)=="table" and #children>0 then out[#out+1]=toc(children) end
        out[#out+1]="</li>"
    end
    out[#out+1]="</ol>";return table.concat(out)
end
function M.navigation(book)
    local entries=type(book.nav)=="table" and book.nav.toc
    if type(entries)~="table" or #entries==0 then
        entries={}
        for i,entry in ipairs(book.spine or {}) do entries[#entries+1]={title="Section "..i,path=path(entry)} end
    end
    return '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1>'..toc(entries)..'</nav></body></html>'
end
function M.identifier(loan) return "urn:kolibby:"..U.urlencode(loan.id) end
local function description_text(value)
    if type(value)~='string' or #value>128*1024 then return nil end
    local Markup=require('kolibby/markup')
    local html=value:find('</?[%a_:]')~=nil
    local hidden,out={},{}
    local omit={script=true,style=true,head=true,template=true,iframe=true,object=true}
    local blocks={p=true,div=true,section=true,article=true,blockquote=true,ul=true,ol=true,
        h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,table=true}
    local function append(text,decode)
        if decode then text=Markup.decode(text) end
        text=text:gsub('\194\160',' '):gsub('\r\n','\n'):gsub('\r','\n')
        if html then text=text:gsub('%s+',' ') end
        out[#out+1]=text
    end
    for token in Markup.tokens(value) do
        if token.kind=='start' and omit[token.name] and not token.empty then
            hidden[#hidden+1]=token.name
        elseif token.kind=='end' and hidden[#hidden]==token.name then
            table.remove(hidden)
        elseif #hidden==0 then
            if token.kind=='text' then append(token.raw,true)
            elseif token.kind=='cdata' then append(token.raw:sub(10,-4),false)
            elseif token.kind=='start' or token.kind=='end' then
                if blocks[token.name] then out[#out+1]='\n\n'
                elseif token.name=='br' or token.name=='li' or token.name=='tr' then out[#out+1]='\n'
                elseif token.name=='td' or token.name=='th' then out[#out+1]=' ' end
            end
        end
    end
    local text=table.concat(out);local valid={}
    -- Optional publisher text must not introduce illegal XML characters.
    for code,a,z in Markup.codes(text) do
        if (code==9 or code==10 or code==13 or code>=32) and code%65536<65534 then
            valid[#valid+1]=text:sub(a,z)
        end
    end
    text=table.concat(valid):gsub('[ \t]+',' '):gsub(' *\n *','\n'):gsub('\n\n\n+','\n\n')
    text=U.trim(text)
    return text~='' and text or nil
end
function M.description(book)
    local value=book and book.description
    local function clean(raw)
        local ok,text=pcall(description_text,raw)
        return ok and text or nil
    end
    if type(value)=='table' then return clean(value.full) or clean(value.short) end
    return clean(value)
end
function M.package(book,loan,assets,now)
    local title=type(book.title)=="table" and book.title.main or loan.title
    local language=type(book.language)=="string" and book.language or "und"
    local out={'<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '<dc:identifier id="book-id">'..U.xml(M.identifier(loan))..'</dc:identifier>',
        '<dc:title>'..U.xml(title)..'</dc:title><dc:language>'..U.xml(language)..'</dc:language>'}
    for _,creator in ipairs(type(book.creator)=="table" and book.creator or {}) do
        if type(creator)=="table" and type(creator.name)=="string" then out[#out+1]='<dc:creator>'..U.xml(creator.name)..'</dc:creator>' end
    end
    local description=M.description(book)
    if description then out[#out+1]='<dc:description>'..U.xml(description)..'</dc:description>' end
    local layout=book._kolibby_layout or {layout='reflowable'}
    out[#out+1]='<meta property="rendition:layout">'..layout.layout..'</meta>'
    for _,name in ipairs({'orientation','spread'}) do if layout[name] then out[#out+1]='<meta property="rendition:'..name..'">'..layout[name]..'</meta>' end end
    out[#out+1]='<meta property="dcterms:modified">'..os.date("!%Y-%m-%dT%H:%M:%SZ",now or os.time())..'</meta></metadata><manifest>'
    local ids,ncx={},nil
    for i,asset in ipairs(assets) do
        local id="r"..i;ids[asset.path]=id
        local flags={}
        if asset.path=="kolibby-nav.xhtml" then flags[#flags+1]="nav" end
        for _,flag in ipairs({"svg","mathml"}) do if asset.properties and asset.properties[flag] then flags[#flags+1]=flag end end
        local properties=#flags>0 and ' properties="'..table.concat(flags," ")..'"' or ""
        if asset.media_type=="application/x-dtbncx+xml" then ncx=id end
        out[#out+1]='<item id="'..id..'" href="'..U.xml(U.href(asset.path))..'" media-type="'..U.xml(asset.media_type)..'"'..properties..'/>'
    end
    out[#out+1]='</manifest><spine'..(ncx and ' toc="'..ncx..'"' or "")..(layout.direction and ' page-progression-direction="'..layout.direction..'"' or '')..'>'
    for _,entry in ipairs(book.spine) do
        local id=ids[path(entry)]
        if not id then error("A required chapter is missing from the native download",0) end
        local properties=require('kolibby/layout').properties(entry._kolibby_layout,layout)
        out[#out+1]='<itemref idref="'..id..'"'..(properties~='' and ' properties="'..properties..'"' or '')..(entry.linear=="no" and ' linear="no"' or "")..'/>'
    end
    out[#out+1]='</spine></package>';return table.concat(out)
end
function M.ncx(raw,loan)
    local changed=false
    raw=raw:gsub("(<meta%s+([^>]-)>)",function(full,attrs)
        local Decoder=require("kolibby/decoder");local values=Decoder.attributes(attrs)
        if values.name=="dtb:uid" then changed=true;return '<meta name="dtb:uid" content="'..U.xml(M.identifier(loan))..'"/>' end
        return full
    end)
    if not changed then error("Native navigation metadata is incomplete",0) end
    return raw
end
M.spine_path=path
M.CONTAINER='<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
return M
