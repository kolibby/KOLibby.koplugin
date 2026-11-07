-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- An independent, credential-free GitHub session, separate from Libby traffic.
local M={};M.__index=M
local hosts={['api.github.com']=true,['github.com']=true,['release-assets.githubusercontent.com']=true,
    ['objects.githubusercontent.com']=true,['github-releases.githubusercontent.com']=true}
function M.allowed(url)
    if type(url)~='string' or #url>16384 or url:find('[%z\1-\32\127]') then return false end
    local host=url:match('^https://([%w%.%-]+)/')
    return hosts[host]==true
end
function M.new(version,options)
    options=options or {}
    return setmetatable({version=version,driver=options.driver,transport=options.transport},M)
end
function M:request(options)
    local address=options.url
    for hop=0,5 do
        if not M.allowed(address) then error('The update requested an unsupported download host.',0) end
        local request={url=address,method='GET',destination=options.destination,max_bytes=options.max_bytes,profile='update',headers={
            ['User-Agent']='KOLibby/'..self.version..' (+https://github.com/kolibby/KOLibby.koplugin)',
            Accept=options.accept or 'application/vnd.github+json',['Accept-Encoding']='identity',Connection='keep-alive'}}
        if address:match('^https://api%.github%.com/') then request.headers['X-GitHub-Api-Version']='2026-03-10' end
        local response
        if self.driver then response=self.driver(request)
        else
            if not self.transport then self.transport=require('kolibby/transport').new() end
            response=self.transport:request(request)
        end
        local status=response.status
        if status==301 or status==302 or status==303 or status==307 or status==308 then
            if hop==5 then error('Too many update download redirects.',0) end
            local location=(response.headers or {}).location or (response.headers or {}).Location
            if type(location)~='string' then error('Invalid update download redirect.',0) end
            address=require('socket.url').absolute(address,location)
        else return response end
    end
end
function M:close() if self.transport then self.transport:close() end end
return M
