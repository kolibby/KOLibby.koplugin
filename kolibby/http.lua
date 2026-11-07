-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local Http={};Http.__index=Http
local U=require("kolibby/util")
local Profile=require("kolibby/profile")
local Compression=require("kolibby/compression")
local function parse(url)
    local scheme,authority,path=url:match("^(https?)://([^/?#]+)(.*)$")
    if scheme~="https" or not authority or authority:find("@",1,true) or authority:find("[%z\1-\32]") then
        error("A publication requested an unsupported or insecure address",0)
    end
    local host,port=authority:lower():match("^([^:]+):?(%d*)$")
    if not host then error("Unsupported network address",0) end
    path=(path=="" and "/" or path):match("^[^?#]*")
    return {host=host,origin="https://"..host..((port~="" and port~="443") and ":"..port or ""),path=path}
end
local function domain_matches(host,domain) return host==domain or host:sub(-#domain-1)=="."..domain end
function Http.new(opts)
    opts=opts or {}
    return setmetatable({cookies={},driver=opts.driver,clock=opts.clock or os.time,encodings=opts.encodings,observer=opts.observer},Http)
end
function Http:cookie_header(url)
    local q=parse(url);local out={}
    for _,c in pairs(self.cookies) do
        if (not c.expires or c.expires>self.clock()) and (c.host_only and c.domain==q.host or not c.host_only and domain_matches(q.host,c.domain))
            and q.path:sub(1,#c.path)==c.path and (c.path:sub(-1)=="/" or #q.path==#c.path or q.path:sub(#c.path+1,#c.path+1)=="/") then
            out[#out+1]=c
        end
    end
    table.sort(out,function(a,b) return #a.path>#b.path end)
    local values={};for _,c in ipairs(out) do values[#values+1]=c.name.."="..c.value end
    return #values>0 and table.concat(values,"; ") or nil
end
function Http:store_cookies(url,headers)
    local q=parse(url);local values=headers["set-cookie"] or headers["Set-Cookie"]
    if not values then return end
    if type(values)~="table" then values={values} end
    for _,header in ipairs(values) do
        local rest=header
        while #rest>0 do
            local split=rest:find(",%s*[%w!#$%%&'*+%.^_`|~%-]+%s*=")
            local part=split and rest:sub(1,split-1) or rest
            rest=split and rest:sub(split+1) or ""
            local first=part:match("^%s*([^;]+)") or ""
            local name,value=first:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
            if name and value then
                local c={name=name,value=value,domain=q.host,host_only=true,path=q.path:match("^(.*/)" ) or "/"}
                if c.path~="/" then c.path=c.path:gsub("/$","") end
                local valid=true
                for attr in part:gmatch(";([^;]+)") do
                    local k,v=attr:match("^%s*([^=]+)=?(.-)%s*$");k=k and U.trim(k):lower();v=U.trim(v)
                    if k=="domain" then
                        v=v:lower():gsub("^%.","")
                        if not v:find("%.") or not domain_matches(q.host,v) then valid=false end
                        c.domain=v;c.host_only=false
                    elseif k=="path" and v:sub(1,1)=="/" then c.path=v
                    elseif k=="max-age" and tonumber(v) then c.expires=self.clock()+tonumber(v) end
                end
                if valid then
                    local key=c.domain.."\n"..c.path.."\n"..name
                    if c.expires and c.expires<=self.clock() then self.cookies[key]=nil else self.cookies[key]=c end
                end
            end
        end
    end
end

function Http:request(options)
    local req=U.copy(options);req.method=req.method or "GET"
    req.profile=req.profile or (parse(req.url).host=='sentry.libbyapp.com' and 'api' or 'resource')
    req.headers=Profile.headers(req.profile,req.headers,self.encodings or Compression.encodings())
    if req.body then req.headers["Content-Length"]=tostring(#req.body)
    elseif req.method=="POST" then req.headers["Content-Length"]="0" end
    for hop=0,6 do
        local origin=parse(req.url).origin
        req.headers.Cookie=nil;req.headers.cookie=nil
        req.headers.Cookie=self:cookie_header(req.url)
        local response
        if self.driver then response=self.driver(req)
        else
            if not self.transport then self.transport=require('kolibby/transport').new{observer=self.observer} end
            response=self.transport:request(req)
        end
        response.headers=response.headers or {};response.body=response.body or ""
        self:store_cookies(req.url,response.headers)
        local status=response.status
        local location=response.headers.location or response.headers.Location
        if location and (status==301 or status==302 or status==303 or status==307 or status==308) then
            if hop==6 then error("Too many publication redirects",0) end
            local url=require("socket.url").absolute(req.url,location)
            if parse(url).origin~=origin then
                for k in pairs(req.headers) do
                    local lower=k:lower()
                    if lower=="authorization" or lower=="x-dervish-decree" or lower=="proxy-authorization" then req.headers[k]=nil end
                end
            end
            if status==303 or (status==301 or status==302) and req.method=="POST" then
                req.method="GET";req.body=nil;req.headers["Content-Length"]=nil;req.headers["Content-Type"]=nil
            end
            req.url=url
        else
            response.url=req.url
            return response
        end
    end
end
function Http:close() if self.transport then self.transport:close() end end
Http.parse=parse
return Http
