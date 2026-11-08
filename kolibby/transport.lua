-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Plugin-local HTTP/1.1 transport. It neither changes KOReader's global headers
-- nor advertises HTTP/2 without implementing it. Connections are reused per job.
local TLS=require('kolibby/tls')
local Compression=require('kolibby/compression')
local Diag=require('kolibby/netdiag')
local Transport={};Transport.__index=Transport
-- verify=false matches KOReader's own LuaSec requests: KOReader 2026.07.x sets
-- no CA file and LuaSec defaults to verify='none'. Libby traffic uses it so a
-- wrong device clock or an outdated certificate store cannot block KOLibby.
-- The updater keeps the default, verified mode: a forged release runs as code.
function Transport.new(options)
    options=options or {}
    return setmetatable({connections={},observer=options.observer,ca_file=options.ca_file,verify=options.verify~=false},Transport)
end
local function lower(headers)
    local h={};for k,v in pairs(headers) do h[k:lower()]=v end;return h
end
function Transport:close()
    for key,value in pairs(self.connections) do pcall(value.close,value);self.connections[key]=nil end
end
function Transport:request(req)
    local http=require('socket.http')
    local https=require('ssl.https')
    local ssl=require('ssl')
    local url=require('socket.url')
    local ltn12=require('ltn12')
    local parsed=url.parse(req.url)
    local port=tonumber(parsed.port) or 443
    local origin=parsed.host..':'..port
    local method=req.method or 'GET'
    local uri=parsed.path or '/'
    if parsed.params then uri=uri..';'..parsed.params end
    if parsed.query then uri=uri..'?'..parsed.query end
    if uri:find('[\r\n]') then error('Invalid request address',0) end
    local headers={}
    for k,v in pairs(req.headers) do
        if type(v)~='string' and type(v)~='number' then error('Invalid request header',0) end
        if k:find('[^%w!#$%%&\'*+%.^_`|~%-]') or tostring(v):find('[\r\n]') then error('Invalid request header',0) end
        headers[k]=tostring(v)
    end
    headers.Host=parsed.host..(port~=443 and ':'..port or '')
    local input_headers=lower(headers)
    for attempt=1,2 do
        local connection=self.connections[origin]
        local reused=connection~=nil
        self.connections[origin]=nil
        local file,chunks,decoded_bytes,encoded_bytes=nil,{},0,0
        local reported=0
        local verify=self.verify
        local ca=verify and (self.ca_file or Diag.ca_bundle(ssl)) or nil
        local ok,result=pcall(function()
            if not connection then
                if verify and not ca then error('error loading CA locations (KOReader certificate bundle not found)',0) end
                local create=https.tcp(verify and {verify='peer',cafile=ca,options=Diag.OPTIONS} or {verify='none',options=Diag.OPTIONS})
                local function checked_create()
                    local conn=create();local connect=conn.connect
                    conn.connect=function(self,host,connect_port)
                        local done,status,err=pcall(connect,self,host,connect_port)
                        -- LuaSec raises after the TCP connect succeeded; do not leak that socket.
                        if not done then if self.sock then pcall(self.sock.close,self.sock) end;error(status,0) end
                        if not status then return nil,err end
                        if verify and not TLS.verify_name(self:getpeercertificate(),host) then self:close();error('TLS hostname validation failed',0) end
                        return status
                    end
                    return conn
                end
                connection=http.open(parsed.host,port,checked_create)
            end
            -- Bypass LuaSocket's high-level TE/Connection injection.
            connection:sendrequestline(method,uri)
            connection:sendheaders(headers)
            if req.body then connection:sendbody(input_headers,ltn12.source.string(req.body)) end
            local status,statusline=connection:receivestatusline()
            local response_headers=connection:receiveheaders()
            while status and status>=100 and status<200 do
                if status==101 then error('Unsupported protocol upgrade',0) end
                status,statusline=connection:receivestatusline();response_headers=connection:receiveheaders()
            end
            if not status then error('Invalid HTTP status',0) end
            local limit=req.max_bytes or 16*1024*1024
            local has_body=method~='HEAD' and status~=204 and status~=304
            if req.destination then
                local handle,open_err=io.open(req.destination,'wb')
                -- FAT storage (Kindle, Kobo) rejects some names with "Invalid argument".
                if not handle then error('Could not create the download file: '..tostring(open_err),0) end
                file=handle
            end
            local function emit(chunk)
                decoded_bytes=decoded_bytes+#chunk
                if decoded_bytes>limit then error('Decoded response exceeds size limit',0) end
                if file then assert(file:write(chunk)) else chunks[#chunks+1]=chunk end
                if req.on_progress and decoded_bytes-reported>=512*1024 then
                    reported=decoded_bytes;req.on_progress(decoded_bytes)
                end
            end
            local feed,finish=Compression.decoder(has_body and response_headers['content-encoding'] or 'identity',emit,limit)
            if has_body then
                connection:receivebody(response_headers,function(chunk,err)
                    if err then return nil,'Network response was interrupted' end
                    if chunk then
                        encoded_bytes=encoded_bytes+#chunk
                        if encoded_bytes>limit then return nil,'Encoded response exceeds size limit' end
                        feed(chunk)
                    else finish() end
                    return 1
                end)
            end
            if file then assert(file:close());file=nil end
            if req.on_progress and decoded_bytes~=reported then req.on_progress(decoded_bytes) end
            local close=(response_headers.connection or ''):lower():find('close',1,true)
            local framed=not has_body or response_headers['content-length']~=nil or (response_headers['transfer-encoding'] or ''):lower()=='chunked'
            if not close and framed and statusline:match('^HTTP/1%.1') then self.connections[origin]=connection
            else connection:close() end
            local response={status=status,headers=response_headers,body=table.concat(chunks),bytes=decoded_bytes,encoded_bytes=encoded_bytes,reused=reused,protocol='http/1.1'}
            if self.observer then self.observer({url=req.url,method=method,headers=headers,profile=req.profile},response) end
            return response
        end)
        if file then pcall(file.close,file) end
        if ok then return result end
        if connection then pcall(connection.close,connection) end
        if req.destination then os.remove(req.destination) end
        if not reused or attempt==2 or method~='GET' and method~='HEAD' then
            local context={host=parsed.host,method=method,verify=verify,ca=ca,no_ca=verify and not ca}
            if verify and Diag.classify(result)=='certificate' then context.reasons=Diag.certificate_reasons(parsed.host,port,ca) end
            local description=Diag.describe(result,context)
            Diag.log(description,context)
            error(description,0)
        end
    end
end
return Transport
