-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M={}
function M.classify(path,header,prefix)
    local ext=path:match("%.([^%.]+)$");ext=ext and ext:lower()
    local types={xhtml="application/xhtml+xml",html="application/xhtml+xml",htm="application/xhtml+xml",css="text/css",jpg="image/jpeg",jpeg="image/jpeg",png="image/png",gif="image/gif",webp="image/webp",bmp="image/bmp",mp3="audio/mpeg",mp4="video/mp4",m4a="audio/mp4",vtt="text/vtt",svg="image/svg+xml",ncx="application/x-dtbncx+xml",woff="font/woff",woff2="font/woff2",ttf="font/ttf",otf="font/otf"}
    local media=types[ext] or type(header)=="string" and header:match("^[^;]+") or "application/octet-stream"
    -- Libby can serve WOFF bytes under a .ttf URL. Keep the font's true format.
    if prefix=="wOFF" or prefix=="wOF2" then
        local suffix=prefix=="wOFF" and "woff" or "woff2"
        media="font/"..suffix
        path=path:gsub("%.[^./]+$","").."."..suffix
    elseif prefix=="OTTO" and (ext=="ttf" or ext=="otf") then
        media="font/otf";path=path:gsub("%.[^./]+$","")..".otf"
    end
    return media,path
end
function M.validate(media,prefix)
    if type(prefix)~="string" or #prefix==0 then error("Libby returned an empty publication resource",0) end
    if media=="image/webp" or media=="image/bmp" then error("This publication uses an image format without a supported EPUB fallback",0) end
    local valid=true
    if media=="image/jpeg" then valid=prefix:sub(1,3)=="\255\216\255"
    elseif media=="image/png" then valid=prefix:sub(1,8)=="\137PNG\r\n\26\n"
    elseif media=="image/gif" then valid=prefix:sub(1,6)=="GIF87a" or prefix:sub(1,6)=="GIF89a"
    elseif media=="font/woff" then valid=prefix:sub(1,4)=="wOFF"
    elseif media=="font/woff2" then valid=prefix:sub(1,4)=="wOF2"
    elseif media=="font/ttf" then valid=prefix:sub(1,4)=="\0\1\0\0" or prefix:sub(1,4)=="true"
    elseif media=="font/otf" then valid=prefix:sub(1,4)=="OTTO"
    elseif media=="image/svg+xml" then valid=prefix:lower():find("<svg[%s>]")~=nil
    elseif media=="text/css" then valid=not prefix:lower():find("<html[%s>]") end
    if not valid then error("A native publication resource has an unexpected format. Synchronize and try again.",0) end
end
function M.dimensions(s)
    if type(s)~='string' then return end
    local function be(p,n) local v=0;for i=p,p+n-1 do local b=s:byte(i);if not b then return end;v=v*256+b end;return v end
    local function le(p,n) local v=0;for i=p+n-1,p,-1 do local b=s:byte(i);if not b then return end;v=v*256+b end;return v end
    local w,h
    if s:sub(1,8)=='\137PNG\r\n\26\n' then w,h=be(17,4),be(21,4)
    elseif s:sub(1,3)=='GIF' then w,h=le(7,2),le(9,2)
    elseif s:sub(1,2)=='\255\216' then
        local p=3
        while p<#s do
            if s:byte(p)~=255 then break end
            while s:byte(p)==255 do p=p+1 end
            local marker=s:byte(p);p=p+1
            if not marker or marker==217 or marker==218 then break end
            local length=be(p,2);if not length or length<2 then break end
            if marker>=192 and marker<=207 and marker~=196 and marker~=200 and marker~=204 then h,w=be(p+3,2),be(p+5,2);break end
            p=p+length
        end
    end
    if w and h and w>0 and h>0 and w<10000000 and h<10000000 then return {width=w,height=h} end
end
return M
