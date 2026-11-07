-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local Markup=require('kolibby/markup')
local Literal=require('kolibby/jsliteral')
local M={}
local function lead(s)
    -- JavaScript whitespace/BOM can surround the decoded body fragment.
    local spaces={'\194\160','\225\154\128','\226\128\128','\226\128\129','\226\128\130','\226\128\131','\226\128\132','\226\128\133','\226\128\134','\226\128\135','\226\128\136','\226\128\137','\226\128\138','\226\128\168','\226\128\169','\226\128\175','\226\129\159','\227\128\128','\239\187\191'}
    while true do
        local old=s;s=s:gsub('^%s+','')
        for _,space in ipairs(spaces) do if s:sub(1,#space)==space then s=s:sub(#space+1);break end end
        if s==old then return s end
    end
end
function M.native_key(value)
    -- Native book maps are indexed at [0] before selecting the digit string.
    if type(value)=='table' then
        local selected=value[1];if selected==nil then selected=value['0'] end
        if type(selected)=='table' and (#selected>0 or (tonumber(selected.length) or 0)>0) then error('Unsupported native decoding key',0) end
        return type(selected)=='string' and selected or ''
    end
    if type(value)=='string' and value~='' then
        local n,first,last=Markup.codes(value)()
        return n>65535 and '\0' or value:sub(first,last)
    end
    return ''
end
function M.decode_body(kind,payload,key)
    if kind=='1' then payload=payload:gsub('([^\r\n])([^\r\n])([^\r\n])([^\r\n])','%4%2%3%1')
    elseif kind=='3' then
        if type(key)=='table' then key=key[1] end
        if type(key)~='string' then key='' end
        if payload:find('[\128-\255]') then error('Unsupported native page character encoding',0) end
        if #key>0 then
            local digits={}
            for n in Markup.codes(key) do
                digits[#digits+1]=n>=48 and n<=57 and n-48 or 0
                if n>65535 then digits[#digits+1]=0 end -- JS UTF-16 surrogate pair
            end
            local out={}
            for i=1,#payload do
                local digit=digits[(i-1)%#digits+1]
                local n=payload:byte(i)
                if digit~=0 then n=n+(i-1+digit)%94;if n>126 then n=n%126+32 end end
                out[i]=string.char(n)
            end
            payload=table.concat(out)
        end
    elseif kind~='0' then error('This native page uses an unsupported reader encoding',0) end
    payload=payload:gsub('[ \t\r\n\f]','')
    if payload:find('[^A-Za-z0-9+/=]') then error('Invalid native page encoding',0) end
    if #payload%4~=0 and not payload:find('=',1,true) then payload=payload..string.rep('=',(4-#payload%4)%4) end
    local body=U.base64_decode(payload)
    for _ in Markup.codes(body) do end
    if not lead(body):lower():match('^<body') then error('The native page could not be decoded as a body',0) end
    return body
end
function M.tags(text)
    local next_token=Markup.tokens(text)
    return function()
        while true do
            local t=next_token();if not t then return end
            if t.kind=='start' or t.kind=='end' then return t.start,t.finish,t.name,t.kind=='end',t.attrs,t.raw end
        end
    end
end
function M.attributes(text) local _,values=Markup.attributes(text or '');return values end
local blocks={address=true,article=true,aside=true,blockquote=true,div=true,dl=true,fieldset=true,footer=true,form=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,header=true,hr=true,main=true,nav=true,ol=true,p=true,pre=true,section=true,table=true,ul=true}
local svg_names={lineargradient='linearGradient',radialgradient='radialGradient',clippath='clipPath',textpath='textPath',foreignobject='foreignObject'}
local svg_attributes={}
for name in ('attributeName attributeType baseFrequency baseProfile calcMode clipPathUnits diffuseConstant edgeMode filterUnits glyphRef gradientTransform gradientUnits kernelMatrix kernelUnitLength keyPoints keySplines keyTimes lengthAdjust limitingConeAngle markerHeight markerUnits markerWidth maskContentUnits maskUnits numOctaves pathLength patternContentUnits patternTransform patternUnits pointsAtX pointsAtY pointsAtZ preserveAlpha preserveAspectRatio primitiveUnits refX refY repeatCount repeatDur requiredExtensions requiredFeatures specularConstant specularExponent spreadMethod startOffset stdDeviation stitchTiles surfaceScale systemLanguage tableValues targetX targetY textLength viewBox viewTarget xChannelSelector yChannelSelector zoomAndPan'):gmatch('%S+') do svg_attributes[name:lower()]=name end
for name in ('altGlyph altGlyphDef altGlyphItem animateColor animateMotion animateTransform clipPath feBlend feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge feMergeNode feMorphology feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence foreignObject glyphRef linearGradient radialGradient textPath'):gmatch('%S+') do svg_names[name:lower()]=name end
local function normalize(s,options)
    options=options or {};local out,stack={},{}
    local have_html,have_body,have_head,have_title=false,false,false,false
    local skip_script,empty_head=false,false
    local function close(index)
        while #stack>=index do
            local t=stack[#stack]
            if t.name=='head' and not have_title then out[#out+1]='<title>'..U.xml(options.title or 'Chapter')..'</title>';have_title=true end
            out[#out+1]='</'..t.output..'>';stack[#stack]=nil
        end
    end
    local function matching(name,barrier)
        for i=#stack,1,-1 do if stack[i].name==name then return i end;if barrier and barrier[stack[i].name] then return end end
    end
    for t in Markup.tokens(lead(s)) do
        if skip_script then if t.kind=='end' and t.name=='script' then skip_script=false end
        elseif t.kind=='start' and t.name=='script' then skip_script=not t.empty
        elseif empty_head then
            if t.kind=='end' and t.name=='head' then empty_head=false
            elseif t.kind~='text' or t.raw:find('%S') then error('A publication has multiple nonempty document heads',0) end
        elseif t.kind=='start' then
            local name=t.name
            if name=='form' then error('Libby returned an interactive or sign-in page instead of a supported chapter',0) end
            if name=='base' or name=='meta' and (t.values.name=='generator' or (t.values['http-equiv'] or ''):lower()=='content-type') then
                -- Runtime reader metadata is not part of the publication.
            elseif name=='html' and have_html then error('A publication contains multiple HTML roots',0)
            elseif name=='head' and have_head then empty_head=not t.empty
            else
                if blocks[name] then local p=matching('p',{body=true,html=true});if p then close(p) end end
                if name=='li' then local i=matching('li',{ul=true,ol=true});if i then close(i) end end
                if name=='dt' or name=='dd' then
                    for i=#stack,1,-1 do if stack[i].name=='dt' or stack[i].name=='dd' then close(i);break elseif stack[i].name=='dl' then break end end
                end
                if name=='tr' then local i=matching('tr',{table=true});if i then close(i) end end
                if name=='td' or name=='th' then for i=#stack,1,-1 do if stack[i].name=='td' or stack[i].name=='th' then close(i);break elseif stack[i].name=='tr' then break end end end
                if name=='body' then
                    local head=matching('head');if head then close(head) end
                    if not have_head then out[#out+1]='<head><title>'..U.xml(options.title or 'Chapter')..'</title></head>';have_head=true end
                    if have_body then error('A publication contains multiple bodies',0) end;have_body=true
                elseif name=='head' then have_head=true
                elseif name=='title' then have_title=true end
                local foreign=(stack[#stack] and stack[#stack].foreign) or name=='svg' or name=='math'
                local output=foreign and (svg_names[name] or t.raw_name) or name
                if name=='html' then
                    have_html=true
                    Markup.set(t.attributes,'xmlns','http://www.w3.org/1999/xhtml')
                    Markup.set(t.attributes,'xmlns:epub','http://www.idpf.org/2007/ops')
                    Markup.set(t.attributes,'xmlns:xlink','http://www.w3.org/1999/xlink')
                    if t.values.lang and not t.values['xml:lang'] then Markup.set(t.attributes,'xml:lang',t.values.lang) end
                elseif name=='svg' then Markup.set(t.attributes,'xmlns','http://www.w3.org/2000/svg')
                elseif name=='math' then Markup.set(t.attributes,'xmlns','http://www.w3.org/1998/Math/MathML') end
                for i=#t.attributes,1,-1 do
                    local a=t.attributes[i]
                    if a.name:lower():match('^on') then table.remove(t.attributes,i)
                    elseif not foreign then a.name=a.name:lower()
                    elseif svg_attributes[a.name:lower()] then a.name=svg_attributes[a.name:lower()] end
                end
                local empty=Markup.void[name] or t.empty and name~='html' and name~='head' and name~='body'
                out[#out+1]=Markup.serialize(output,t.attributes,empty)
                if not empty then stack[#stack+1]={name=name,output=output,foreign=foreign};if #stack>512 then error('Publication markup is nested too deeply',0) end end
            end
        elseif t.kind=='end' then
            -- Browsers keep trailing fragment nodes inside the body.
            if t.name~='body' then local i=matching(t.name);if i then close(i) end end
        elseif t.kind=='text' then
            if have_html then out[#out+1]=Markup.text(t.raw)
            elseif t.raw:find('%S') then error('A publication contains text outside its document',0) end
        elseif t.kind=='cdata' then out[#out+1]=t.raw end
    end
    if not have_html or not have_body then error('Downloaded page is not a complete publication document',0) end
    if #stack>0 then close(1) end
    local result=table.concat(out)
    for _ in Markup.codes(result) do end
    if result:find('[%z\1-\8\11\12\14-\31]') then error('Unsupported control character in publication markup',0) end
    return '<?xml version="1.0" encoding="utf-8"?>\n'..result
end
function M.xhtml(raw,key,options)
    local decoded,decoded_kind,body_start,body_end,in_script,base=nil,nil,nil,nil,false,nil
    for t in Markup.tokens(raw) do
        if t.kind=='start' and t.name=='base' and not base then base=t.values.href end
        if t.kind=='start' and t.name=='body' then body_start=t.start end
        if t.kind=='end' and t.name=='body' then body_end=t.finish end
        if t.kind=='start' and t.name=='script' then in_script=true
        elseif t.kind=='end' and t.name=='script' then in_script=false
        elseif in_script and t.kind=='text' then
            local kind,payload=Literal.wrapper(t.raw)
            if kind then
                if decoded then error('Multiple native page decoders are unsupported',0) end
                decoded=M.decode_body(kind,payload,key);decoded_kind=kind
            end
        end
    end
    if decoded then
        if not body_start then error('Native page body is missing',0) end
        local trimmed=lead(decoded);local prefix=decoded:sub(1,#decoded-#trimmed)
        if prefix~='' then
            local first=Markup.tokens(trimmed)();trimmed=trimmed:sub(1,first.finish)..prefix..trimmed:sub(first.finish+1)
        end
        raw=raw:sub(1,body_start-1)..trimmed..(body_end and raw:sub(body_end+1) or '')
    end
    return normalize(raw,options),decoded_kind,base
end
return M
