-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M = {}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local digits = {}
for i = 1, #alphabet do digits[alphabet:sub(i,i)] = i - 1 end

function M.base64_encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a,b,c = s:byte(i,i+2)
        local n = a*65536 + (b or 0)*256 + (c or 0)
        out[#out+1] = alphabet:sub(math.floor(n/262144)%64+1,math.floor(n/262144)%64+1)
        out[#out+1] = alphabet:sub(math.floor(n/4096)%64+1,math.floor(n/4096)%64+1)
        out[#out+1] = b and alphabet:sub(math.floor(n/64)%64+1,math.floor(n/64)%64+1) or "="
        out[#out+1] = c and alphabet:sub(n%64+1,n%64+1) or "="
    end
    return table.concat(out)
end

function M.base64_decode(s)
    s = s:gsub("%s", "")
    if #s % 4 ~= 0 or s:find("[^%w+/=]") or s:find("=[^=]") then
        error("Invalid native page encoding", 0)
    end
    local out = {}
    for i = 1, #s, 4 do
        local a,b,c,d = s:sub(i,i),s:sub(i+1,i+1),s:sub(i+2,i+2),s:sub(i+3,i+3)
        if not digits[a] or not digits[b] or (c=="=" and d~="=") or (i<#s-3 and (c=="=" or d=="=")) then
            error("Invalid native page encoding", 0)
        end
        local n = digits[a]*262144 + digits[b]*4096 + (digits[c] or 0)*64 + (digits[d] or 0)
        out[#out+1] = string.char(math.floor(n/65536)%256)
        if c~="=" then out[#out+1] = string.char(math.floor(n/256)%256) end
        if d~="=" then out[#out+1] = string.char(n%256) end
    end
    return table.concat(out)
end

function M.urlencode(s)
    return tostring(s):gsub("([^%w%-_%.~])",function(c) return string.format("%%%02X",c:byte()) end)
end
function M.urldecode(s)
    return (s:gsub("%%(%x%x)",function(h) return string.char(tonumber(h,16)) end))
end
function M.query(values)
    local keys,out = {},{}
    for k,v in pairs(values or {}) do if v~=nil and v~=false then keys[#keys+1]=k end end
    table.sort(keys)
    for _,k in ipairs(keys) do out[#out+1]=M.urlencode(k).."="..M.urlencode(values[k]) end
    return table.concat(out,"&")
end
function M.xml(s)
    return tostring(s or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")
end
function M.copy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=M.copy(v) end;return out
end
function M.count(t)
    local n=0;for _ in pairs(t or {}) do n=n+1 end;return n
end
function M.trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
function M.id(value)
    if type(value)=="number" then return tostring(value) end
    if type(value)=="string" and #value>0 and #value<=256 then return value end
end
function M.key(card_id,title_id)
    return tostring(card_id)..":"..tostring(title_id)
end
function M.hash(s)
    local a,b=5381,2166136261
    for i=1,#s do a=(a*33+s:byte(i))%4294967296;b=(b*31+s:byte(i))%4294967296 end
    return string.format("%08x%08x",a,b)
end
function M.filename(title,key,extension)
    local slug = tostring(title or "book"):gsub("[^%w %-_]",""):gsub("%s+"," "):sub(1,60)
    slug=M.trim(slug);if slug=="" then slug="book" end
    return slug.."--"..M.hash(key).."."..(extension or "epub")
end

-- Gregorian civil date -> Unix seconds, independent of the device's timezone.
function M.timestamp(value)
    if type(value)=="number" then return value>100000000000 and value/1000 or value end
    if type(value)~="string" then return nil end
    local y,m,d,h,mi,s,tail=value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y,m,d,h,mi,s=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(mi),tonumber(s)
    if m<1 or m>12 or d<1 or d>31 or h>23 or mi>59 or s>60 then return nil end
    y=y-(m<=2 and 1 or 0)
    local era=math.floor(y/400);local yo=y-era*400
    local mp=m+(m>2 and -3 or 9)
    local days=era*146097+yo*365+math.floor(yo/4)-math.floor(yo/100)+math.floor((153*mp+2)/5)+d-1-719468
    local tz=0;local sign,th,tm=tail:match("([+-])(%d%d):?(%d%d)$")
    if sign then tz=(tonumber(th)*60+tonumber(tm))*60*(sign=="+" and 1 or -1) end
    return days*86400+h*3600+mi*60+s-tz
end
function M.due_label(expires,now)
    if not expires then return "Due date unknown" end
    local delta=expires-(now or os.time())
    if delta<=0 then return "Expired" end
    if delta<86400 then return "Due today" end
    local days=math.ceil(delta/86400);return "Due in "..days.." days"
end
function M.error_message(err)
    if type(err)=="table" and type(err.message)=="string" then return err.message end
    -- Never include arbitrary transport diagnostics, signed URLs, response bodies or headers.
    if type(err)=="string" and not err:find("https?://") and #err<220 then
        return err:gsub("^.-:%d+: ","")
    end
    return "The operation could not finish. Check your connection and try again."
end
function M.resource_path(url)
    local path=tostring(url):match("^https://[^/]+(/[^?#]*)") or tostring(url):match("^(/[^?#]*)")
    if not path then error("Unsupported publication resource URL",0) end
    path=M.urldecode(path):gsub("^/+","")
    if path=="" or path:find("[%z\1-\31\\]") or path:find("//",1,true) then error("Unsafe publication resource path",0) end
    for part in path:gmatch("[^/]+") do if part=="." or part==".." then error("Unsafe publication resource path",0) end end
    return path
end
function M.href(path)
    return (path:gsub("([^%w%-_%.~/])",function(c) return string.format("%%%02X",c:byte()) end))
end
return M
