-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Read a JS string literal without evaluating the surrounding script.
local M={}
function M.string(s,p,ascii_only)
    local quote=s:sub(p,p);if quote~='"' and quote~="'" then error('Unsupported native page string literal',0) end
    local out={};p=p+1
    while p<=#s do
        local c=s:sub(p,p)
        if c==quote then return table.concat(out),p+1 end
        if c=='\n' or c=='\r' then error('Invalid native page string literal',0) end
        if c~='\\' then out[#out+1]=c;p=p+1
        else
            local escaped=s:sub(p+1,p+1)
            local simple={['n']='\n',['r']='\r',['t']='\t',['b']='\b',['f']='\f',['v']='\11',['0']='\0'}
            if escaped=='\n' then p=p+2
            elseif escaped=='\r' then p=p+(s:sub(p+2,p+2)=='\n' and 3 or 2)
            elseif escaped=='x' or escaped=='u' then
                local n=escaped=='x' and 2 or 4;local digits=s:sub(p+2,p+1+n)
                if #digits~=n or digits:find('[^%x]') then error('Invalid native page escape',0) end
                local code=tonumber(digits,16)
                -- The native payload alphabet is ASCII. Non-ASCII escapes are
                -- outside this wrapper format, rather than executable content.
                if code>127 and ascii_only then error('Unsupported native page payload escape',0) end
                out[#out+1]=code<=127 and string.char(code) or require('kolibby/markup').decode('&#'..code..';');p=p+2+n
            elseif escaped~='' then out[#out+1]=simple[escaped] or escaped;p=p+2
            else error('Incomplete native page escape',0) end
        end
    end
    error('Unterminated native page string literal',0)
end
function M.wrapper(script)
    if not script:find('__bif_cfc',1,true) then return end
    local p,result=1,nil
    while p<=#script do
        local c=script:sub(p,p)
        if c=='"' or c=="'" then local _,z=M.string(script,p);p=z
        elseif script:sub(p,p+1)=='//' then p=(script:find('[\r\n]',p+2) or #script)+1
        elseif script:sub(p,p+1)=='/*' then local z=script:find('*/',p+2,true);if not z then error('Incomplete native page script',0) end;p=z+2
        else
            local bracket=script:match('^parent%s*%[%s*()',p)
            if bracket and (script:sub(bracket,bracket)=='\"' or script:sub(bracket,bracket)=="'") then
                local name=M.string(script,bracket)
                if name:match('^__bif_cfc') then error('Unsupported native page decoder invocation',0) end
            end
            local kind,target,last=script:match('^parent%s*%.%s*__bif_cfc(%d+)%s*%(%s*([%w_$]+)%s*,%s*()',p)
            if kind then
                if target~='self' and target~='window' then error('Unsupported native page target',0) end
                local payload,finish=M.string(script,last,true)
                if not script:sub(finish):match('^%s*%)') then error('Unsupported native page decoder arguments',0) end
                if result then error('Multiple native page decoders are unsupported',0) end
                result={kind,payload};p=finish
            end
            if not kind and script:sub(p,p+8)=='__bif_cfc' then error('Unsupported native page decoder invocation',0) end
            p=p+1
        end
    end
    if result then return result[1],result[2] end
end
return M
