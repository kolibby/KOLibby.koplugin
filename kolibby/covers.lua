-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local M={}
function M.allowed(url)
    if type(url)~='string' or #url>2048 then return false end
    local host=url:match('^https://([%w%.%-]+)/')
    if not host then return false end
    host=host:lower()
    for _,domain in ipairs({'od-cdn.com','overdrive.com','contentreserve.com','libbyapp.com','libbyshelf.com'}) do
        if host==domain or host:sub(-#domain-1)=='.'..domain then return true end
    end
    return false
end
function M.path(item,directory)
    if not M.allowed(item.cover_url) then return nil end
    return directory..'/'..U.hash(item.cover_url)..'.img'
end
function M.cached(item,directory)
    local Store=require('kolibby/store')
    local path=M.path(item,directory)
    return path and Store.exists(path) and path or nil
end
function M.fetch(shelf,transport,directory)
    local Store=require('kolibby/store')
    Store.mkdir(directory)
    local seen,attempts={},0
    for _,collection in ipairs({'loans','holds'}) do
        for _,item in pairs(shelf[collection] or {}) do
            local path=M.path(item,directory)
            if path and not seen[path] and not Store.exists(path) and attempts<100 then
                seen[path]=true;attempts=attempts+1
                pcall(function()
                    local response=transport{url=item.cover_url,profile='resource',destination=path..'.part',max_bytes=2*1024*1024}
                    if response.status~=200 then return end
                    local f=io.open(path..'.part','rb');if not f then return end
                    local prefix=f:read(12) or '';f:close()
                    local image=prefix:sub(1,3)=='\255\216\255' or prefix:sub(1,8)=='\137PNG\r\n\26\n' or
                        prefix:sub(1,4)=='RIFF' and prefix:sub(9,12)=='WEBP' or prefix:sub(1,6)=='GIF89a' or prefix:sub(1,6)=='GIF87a'
                    if image then assert(os.rename(path..'.part',path)) end
                end)
                os.remove(path..'.part') -- Cover failures never fail a shelf refresh.
            end
        end
    end
end
return M
