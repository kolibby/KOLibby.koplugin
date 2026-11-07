-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Quote-aware HTML/XML tokens. This is not a JavaScript or browser runtime.
local U=require('kolibby/util')
local entities=require('kolibby/entities')
local M={}
M.void={area=true,base=true,br=true,col=true,embed=true,hr=true,img=true,input=true,link=true,meta=true,param=true,source=true,track=true,wbr=true}
local function utf8(n)
    if n<0 or n>1114111 or n>=55296 and n<=57343 or n%65536>=65534 or n<32 and n~=9 and n~=10 and n~=13 then n=65533 end
    if n<128 then return string.char(n) end
    if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
    if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
    return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end
function M.codes(s)
    local p=1
    return function()
        if p>#s then return end
        local start=p;local b=s:byte(p);local n,count
        if b<128 then n,count=b,1
        elseif b>=194 and b<=223 then n,count=b%32,2
        elseif b>=224 and b<=239 then n,count=b%16,3
        elseif b>=240 and b<=244 then n,count=b%8,4
        else error('Invalid UTF-8 in publication text',0) end
        for i=1,count-1 do local c=s:byte(p+i);if not c or c<128 or c>191 then error('Invalid UTF-8 in publication text',0) end;n=n*64+c%64 end
        if n>1114111 or n>=55296 and n<=57343 or count==2 and n<128 or count==3 and n<2048 or count==4 and n<65536 then error('Invalid UTF-8 in publication text',0) end
        p=p+count;return n,start,p-1
    end
end
local function numeric(value)
    local n=value:match('^#([0-9]+)$') or value:match('^#[xX]([0-9a-fA-F]+)$')
    return n and tonumber(n,value:sub(2,2):lower()=='x' and 16 or 10)
end
function M.decode(value)
    return (tostring(value or ''):gsub('&([^;%s<&]+);',function(name)
        local n=numeric(name);if n then return utf8(n) end
        local basic={amp='&',lt='<',gt='>',quot='"',apos="'"}
        if basic[name] then return basic[name] end
        local encoded=entities[name]
        if encoded then return (encoded:gsub('&#([^;]+);',function(d) return utf8(tonumber(d) or 65533) end)) end
        return '&'..name..';'
    end))
end
function M.text(value)
    local out={};local pos=1
    while pos<=#value do
        local a=value:find('&',pos,true)
        local chunk=a and value:sub(pos,a-1) or value:sub(pos)
        out[#out+1]=chunk:gsub('<','&lt;'):gsub('>','&gt;')
        if not a then break end
        local name,finish=value:match('^&([^;%s<&]+);()',a)
        if name then
            local n=numeric(name)
            if n then out[#out+1]=U.xml(utf8(n))
            elseif name=='amp' or name=='lt' or name=='gt' or name=='quot' or name=='apos' then out[#out+1]='&'..name..';'
            elseif entities[name] then out[#out+1]=entities[name]
            else out[#out+1]='&amp;'..name..';' end
            pos=finish
        else out[#out+1]='&amp;';pos=a+1 end
    end
    return table.concat(out)
end
function M.attributes(text)
    local list,values,seen={},{},{};local p=1
    while p<=#text do
        local _,z=text:find('^%s+',p);if z then p=z+1 end
        if p>#text or text:sub(p):match('^/%s*$') then break end
        local name,finish=text:match('^([^%s=<>/"\']+)()',p)
        if not name then error('Unsupported publication attribute syntax',0) end
        p=finish
        _,z=text:find('^%s+',p);if z then p=z+1 end
        local value=''
        if text:sub(p,p)=='=' then
            p=p+1;_,z=text:find('^%s+',p);if z then p=z+1 end
            local q=text:sub(p,p)
            if q=='"' or q=="'" then
                local last=text:find(q,p+1,true);if not last then error('Unterminated publication attribute',0) end
                value=text:sub(p+1,last-1);p=last+1
            else
                value,finish=text:match('^([^%s<>]+)()',p)
                if not value then error('Missing publication attribute value',0) end
                p=finish
            end
        end
        local lower=name:lower()
        if not seen[lower] then
            value=M.decode(value);list[#list+1]={name=name,value=value};values[lower]=value;seen[lower]=true
        end
    end
    return list,values
end
function M.set(list,name,value)
    for _,a in ipairs(list) do if a.name:lower()==name:lower() then a.value=value;return end end
    list[#list+1]={name=name,value=value}
end
function M.serialize(name,list,empty)
    local out={'<'..name}
    for _,a in ipairs(list or {}) do out[#out+1]=' '..a.name..'="'..U.xml(a.value)..'"' end
    out[#out+1]=empty and ' />' or '>';return table.concat(out)
end
function M.tokens(text)
    local pos,raw_name=1,nil;local lower=text:lower()
    return function()
        if pos>#text then return nil end
        if raw_name then
            local a=lower:find('</'..raw_name..'%s*>',pos)
            raw_name=nil
            if not a then local t={kind='text',raw=text:sub(pos),start=pos,finish=#text};pos=#text+1;return t end
            if a>pos then local t={kind='text',raw=text:sub(pos,a-1),start=pos,finish=a-1};pos=a;return t end
        end
        local start=text:find('<',pos,true)
        if not start or start>pos then
            local finish=start and start-1 or #text
            local t={kind='text',raw=text:sub(pos,finish),start=pos,finish=finish};pos=finish+1;return t
        end
        local kind,finish
        if text:sub(pos,pos+3)=='<!--' then kind='comment';local z=text:find('-->',pos+4,true);if not z then error('Unterminated publication comment',0) end;finish=z+2
        elseif text:sub(pos,pos+8)=='<![CDATA[' then kind='cdata';local z=text:find(']]>',pos+9,true);if not z then error('Unterminated publication CDATA',0) end;finish=z+2
        elseif text:sub(pos,pos+1)=='<?' then kind='pi';local z=text:find('?>',pos+2,true);if not z then error('Unterminated publication instruction',0) end;finish=z+1
        elseif not text:sub(pos):match('^</?[%a_:]') and text:sub(pos,pos+1)~='<!' then
            pos=pos+1;return {kind='text',raw='<',start=pos-1,finish=pos-1}
        end
        if not finish then
            local quote,depth=nil,0
            for i=pos+1,#text do
                local c=text:sub(i,i)
                if quote then if c==quote then quote=nil end
                elseif c=='"' or c=="'" then quote=c
                elseif c=='[' then depth=depth+1
                elseif c==']' then depth=math.max(0,depth-1)
                elseif c=='>' and depth==0 then finish=i;break end
            end
            if not finish then error('Incomplete publication markup',0) end
        end
        local raw=text:sub(pos,finish);local t={kind=kind,raw=raw,start=pos,finish=finish};pos=finish+1
        if not kind then
            if raw:sub(1,2)=='<!' then t.kind='doctype'
            else
                local slash,name,attrs=raw:match('^<(/?)([%w:_%-]+)(.-)>$')
                if not name then error('Invalid publication tag',0) end
                t.kind=slash=='/' and 'end' or 'start';t.name=name:lower();t.raw_name=name;t.attrs=attrs;t.empty=attrs:match('/%s*$')~=nil
                if t.kind=='start' then
                    t.attributes,t.values=M.attributes(attrs)
                    if not t.empty and (t.name=='script' or t.name=='style' or t.name=='textarea' or t.name=='title') then raw_name=t.name end
                end
            end
        end
        return t
    end
end
return M
